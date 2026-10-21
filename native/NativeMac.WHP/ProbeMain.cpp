#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>

extern "C" __declspec(dllimport) int __cdecl NmRunCpuProbe(char*, uint32_t);
extern "C" __declspec(dllimport) int __cdecl NmGpuCreate(void*, void**, char*, uint32_t);
extern "C" __declspec(dllimport) void __cdecl NmGpuDestroy(void*);

int main(int argc, char** argv) {
    char output[16384]{};
    bool gpu = argc > 1 && strcmp(argv[1], "--gpu") == 0;
    void* handle = nullptr;
    int result = gpu ? NmGpuCreate(nullptr, &handle, output, sizeof(output)) :
        NmRunCpuProbe(output, sizeof(output));
    if (handle) NmGpuDestroy(handle);
    puts(output);
    if (argc == 3 && strcmp(argv[1], "--report") == 0) {
        std::ofstream report(argv[2]);
        if (!report) return 2;
        report << output << '\n';
    }
    return result < 0 ? 1 : 0;
}
