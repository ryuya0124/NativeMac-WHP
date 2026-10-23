// Windows-only CUDA -> device-local Vulkan -> NV12 plane images qualification.
// The CPU readback returned here exists only to compare every validation byte.
// This is not a guest IOSurface exporter or the production video transport.
#pragma once
#include <cstdint>
#include <memory>
#include <vector>
#include <dynlink_cuda.h>

class GpuFrameInterop {
public:
    GpuFrameInterop(CUdevice cudaDevice, unsigned width, unsigned height);
    ~GpuFrameInterop();
    GpuFrameInterop(const GpuFrameInterop&) = delete;
    GpuFrameInterop& operator=(const GpuFrameInterop&) = delete;
    std::vector<uint8_t> validate(CUdeviceptr decoded, unsigned pitch);
    CUstream outputStream() const;
private:
    struct State;
    std::unique_ptr<State> state;
};
