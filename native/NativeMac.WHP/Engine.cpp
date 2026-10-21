#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <WinHvPlatform.h>
#include <intrin.h>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// This is a hardware-virtualized CPU probe, not a macOS boot implementation.
namespace {
struct Failure { HRESULT hr; const char* stage; };
void Check(HRESULT hr, const char* stage) { if (FAILED(hr)) throw Failure{hr, stage}; }

struct Machine {
    WHV_PARTITION_HANDLE partition = nullptr;
    void* ram = nullptr;
    bool vp = false;
    bool mapped = false;
    static constexpr SIZE_T RamSize = 2 * 1024 * 1024;
    ~Machine() {
        if (vp) WHvDeleteVirtualProcessor(partition, 0);
        if (mapped) WHvUnmapGpaRange(partition, 0, RamSize);
        if (partition) WHvDeletePartition(partition);
        if (ram) VirtualFree(ram, 0, MEM_RELEASE);
    }
    void Create() {
        Check(WHvCreatePartition(&partition), "WHvCreatePartition");
        UINT32 count = 1;
        Check(WHvSetPartitionProperty(partition, WHvPartitionPropertyCodeProcessorCount,
            &count, sizeof(count)), "WHvSetPartitionProperty/ProcessorCount");
        Check(WHvSetupPartition(partition), "WHvSetupPartition");
        ram = VirtualAlloc(nullptr, RamSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!ram) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "VirtualAlloc"};
        auto flags = static_cast<WHV_MAP_GPA_RANGE_FLAGS>(
            WHvMapGpaRangeFlagRead | WHvMapGpaRangeFlagWrite | WHvMapGpaRangeFlagExecute);
        Check(WHvMapGpaRange(partition, ram, 0, RamSize, flags), "WHvMapGpaRange");
        mapped = true;
        Check(WHvCreateVirtualProcessor(partition, 0, 0), "WHvCreateVirtualProcessor");
        vp = true;
    }
    void EnterLongMode() {
        auto bytes = static_cast<uint8_t*>(ram);
        // Identity map the 2 MiB probe RAM with a 2 MiB page.
        *reinterpret_cast<uint64_t*>(bytes + 0x1000) = 0x2003;
        *reinterpret_cast<uint64_t*>(bytes + 0x2000) = 0x3003;
        *reinterpret_cast<uint64_t*>(bytes + 0x3000) = 0x0083;
        WHV_REGISTER_NAME names[] = {
            WHvX64RegisterRip, WHvX64RegisterRsp, WHvX64RegisterRflags,
            WHvX64RegisterCr0, WHvX64RegisterCr3, WHvX64RegisterCr4,
            WHvX64RegisterEfer, WHvX64RegisterCs, WHvX64RegisterDs,
            WHvX64RegisterEs, WHvX64RegisterSs, WHvX64RegisterFs, WHvX64RegisterGs
        };
        WHV_REGISTER_VALUE regs[ARRAYSIZE(names)]{};
        regs[0].Reg64 = 0x10000;
        regs[1].Reg64 = 0x1F0000;
        regs[2].Reg64 = 2;
        regs[3].Reg64 = 0x80000021; // PG, NE, PE
        regs[4].Reg64 = 0x1000;
        regs[5].Reg64 = 0x620; // PAE, OSFXSR, OSXMMEXCPT
        regs[6].Reg64 = 0xD00; // LME, LMA, NXE
        regs[7].Segment.Base = 0;
        regs[7].Segment.Limit = 0xFFFFFFFF;
        regs[7].Segment.Selector = 8;
        regs[7].Segment.Attributes = 0xA09B; // 64-bit code
        for (size_t i = 8; i < ARRAYSIZE(names); ++i) {
            regs[i].Segment.Base = 0;
            regs[i].Segment.Limit = 0xFFFFFFFF;
            regs[i].Segment.Selector = 16;
            regs[i].Segment.Attributes = 0xC093;
        }
        Check(WHvSetVirtualProcessorRegisters(partition, 0, names,
            ARRAYSIZE(names), regs), "WHvSetVirtualProcessorRegisters/LongMode");
    }
};

// Always cancel a stuck guest before the Machine is destroyed. WHvCancelRun...
// is the only operation the watchdog performs on the live virtual processor.
struct Watchdog {
    WHV_PARTITION_HANDLE partition;
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    bool expired = false;
    std::thread worker;
    explicit Watchdog(WHV_PARTITION_HANDLE p) : partition(p), worker([this] {
        std::unique_lock lock(mutex);
        if (!cv.wait_for(lock, std::chrono::seconds(5), [this] { return done; })) {
            expired = true;
            // Repeat cancellation to close the race between successive Run calls.
            while (!done) {
                WHvCancelRunVirtualProcessor(partition, 0, 0);
                cv.wait_for(lock, std::chrono::milliseconds(10), [this] { return done; });
            }
        }
    }) {}
    ~Watchdog() {
        { std::lock_guard lock(mutex); done = true; }
        cv.notify_all();
        worker.join();
    }
};

constexpr uint64_t Expected = 0x123456789ABCDEF1ULL;
std::vector<uint8_t> Payload() {
    // Real x86-64 instructions. CPUID results are not spoofed or intercepted.
    std::vector<uint8_t> code = {
        0x48,0xC7,0xC7,0x00,0x10,0x01,0x00, // mov rdi,11000h
        0x31,0xC0,0x0F,0xA2,               // xor eax,eax; cpuid
        0x89,0x1F,0x89,0x57,0x04,0x89,0x4F,0x08,
        0xB8,0x01,0x00,0x00,0x00,0x0F,0xA2,0x89,0x4F,0x0C,
        0xB8,0x07,0x00,0x00,0x00,0x31,0xC9,0x0F,0xA2,0x89,0x5F,0x10,
        0x66,0xBA,0xE9,0x00                 // mov dx,e9h
    };
    // Only this debug device is emulated in this initial engine.
    for (char c : std::string("WHP x64 OK")) {
        code.push_back(0xB0); code.push_back(static_cast<uint8_t>(c)); // mov al,c
        code.push_back(0xEE); // out dx,al -> VM exit
    }
    const uint8_t tail[] = {
        0x48,0xB8,0xF0,0xDE,0xBC,0x9A,0x78,0x56,0x34,0x12, // mov rax,imm64
        0x48,0x83,0xC0,0x01,                              // add rax,1
        0x48,0x89,0x47,0x18,                              // mov [rdi+18h],rax
        0xF4                                               // hlt
    };
    code.insert(code.end(), std::begin(tail), std::end(tail));
    return code;
}
}

extern "C" __declspec(dllexport) int __cdecl NmRunCpuProbe(char* output, uint32_t capacity) {
    if (!output || capacity < 4096) return E_INVALIDARG;
    auto start = std::chrono::steady_clock::now();
    const char* status = "failed";
    const char* stage = "WHvGetCapability";
    HRESULT hr = S_OK;
    BOOL present = FALSE;
    char hostVendor[13]{}, guestVendor[13]{};
    int cpuid[4]{};
    __cpuid(cpuid, 0);
    memcpy(hostVendor, &cpuid[1], 4); memcpy(hostVendor+4, &cpuid[3], 4);
    memcpy(hostVendor+8, &cpuid[2], 4);
    uint32_t exits = 0, ioExits = 0, guestLeaf1 = 0, guestLeaf7 = 0, lastExit = 0;
    uint64_t rax = 0, stored = 0, rip = 0;
    std::string serial;
    try {
        Check(WHvGetCapability(WHvCapabilityCodeHypervisorPresent,
            &present, sizeof(present), nullptr), stage);
        if (!present) throw Failure{HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED), "HypervisorNotPresent"};
        Machine machine;
        machine.Create();
        auto payload = Payload();
        memcpy(static_cast<uint8_t*>(machine.ram) + 0x10000, payload.data(), payload.size());
        machine.EnterLongMode();
        bool halted = false;
        {
            Watchdog watchdog(machine.partition);
            for (; exits < 256; ++exits) {
                WHV_RUN_VP_EXIT_CONTEXT context{};
                Check(WHvRunVirtualProcessor(machine.partition, 0, &context, sizeof(context)),
                    "WHvRunVirtualProcessor");
                lastExit = static_cast<uint32_t>(context.ExitReason);
                rip = context.VpContext.Rip;
                if (context.ExitReason == WHvRunVpExitReasonX64Halt) {
                    halted = true;
                    ++exits;
                    break;
                }
                if (context.ExitReason == WHvRunVpExitReasonCanceled)
                    throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "GuestTimeout"};
                if (context.ExitReason != WHvRunVpExitReasonX64IoPortAccess)
                    throw Failure{E_FAIL, "UnexpectedVmExit"};
                const auto& io = context.IoPortAccess;
                if (io.PortNumber != 0xE9 || !io.AccessInfo.IsWrite ||
                    io.AccessInfo.AccessSize != 1 || io.AccessInfo.StringOp || io.AccessInfo.RepPrefix)
                    throw Failure{E_FAIL, "UnsupportedIoAccess"};
                serial.push_back(static_cast<char>(io.Rax & 0xFF));
                ++ioExits;
                WHV_REGISTER_NAME name = WHvX64RegisterRip;
                WHV_REGISTER_VALUE value{};
                value.Reg64 = context.VpContext.Rip + context.VpContext.InstructionLength;
                Check(WHvSetVirtualProcessorRegisters(machine.partition, 0, &name, 1, &value),
                    "AdvanceRipAfterIo");
            }
        }
        if (!halted) throw Failure{E_FAIL, "ExitLimitExceeded"};
        WHV_REGISTER_NAME names[] = { WHvX64RegisterRax, WHvX64RegisterRip };
        WHV_REGISTER_VALUE regs[2]{};
        Check(WHvGetVirtualProcessorRegisters(machine.partition, 0, names, 2, regs), "ReadGuestRegisters");
        rax = regs[0].Reg64; rip = regs[1].Reg64;
        auto results = static_cast<uint8_t*>(machine.ram) + 0x11000;
        memcpy(guestVendor, results, 12);
        memcpy(&guestLeaf1, results+12, 4); memcpy(&guestLeaf7, results+16, 4);
        memcpy(&stored, results+24, 8);
        if (rax != Expected || stored != Expected || serial != "WHP x64 OK" ||
            strcmp(guestVendor, hostVendor) != 0)
            throw Failure{E_FAIL, "GuestResultMismatch"};
        stage = "Complete";
        status = "passed";
    } catch (const Failure& failure) {
        hr = failure.hr; stage = failure.stage;
        if (!present) status = "unavailable";
    } catch (...) {
        hr = E_UNEXPECTED; stage = "NativeException";
    }
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count();
    // All interpolated text comes from fixed stage names, CPUID vendors and our
    // fixed guest, not arbitrary guest input. Keep this C ABI independent of CRT ownership.
    snprintf(output, capacity,
        "{\"status\":\"%s\",\"stage\":\"%s\",\"hresult\":\"0x%08X\","
        "\"hypervisorPresent\":%s,\"hostVendor\":\"%s\",\"guestVendor\":\"%s\","
        "\"guestAvx\":%s,\"guestAvx2\":%s,\"vmExits\":%u,\"ioExits\":%u,\"lastExit\":%u,"
        "\"rax\":\"0x%016llX\",\"storedValue\":\"0x%016llX\",\"rip\":\"0x%016llX\","
        "\"serial\":\"%s\",\"elapsedMs\":%lld,\"macOsBooted\":false}",
        status, stage, static_cast<unsigned>(hr), present ? "true" : "false",
        hostVendor, guestVendor, (guestLeaf1 & (1u<<28)) ? "true" : "false",
        (guestLeaf7 & (1u<<5)) ? "true" : "false", exits, ioExits, lastExit,
        rax, stored, rip, serial.c_str(), ms);
    return hr;
}
