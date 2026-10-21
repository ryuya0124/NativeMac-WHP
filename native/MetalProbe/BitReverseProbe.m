#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static uint32_t reverse32(uint32_t value) {
    uint32_t result = 0;
    for (unsigned bit = 0; bit < 32; ++bit) {
        result = (result << 1) | (value & 1);
        value >>= 1;
    }
    return result;
}

// Run in the guest. Compare every GPU output with an independent bit-by-bit CPU reference.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void bit_check(device uint4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
            "uint x=i*1664525u+1013904223u;"
            "out[i]=reverse_bits(uint4(x,~x,0u,0xffffffffu));}";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLComputePipelineState> pipeline = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"bit_check"] error:&error] : nil;
        if (!pipeline) { fprintf(stderr, "%s\n", error.description.UTF8String); return 2; }
        const NSUInteger count = 4096, words = count * 4;
        id<MTLBuffer> buffer = [device newBufferWithLength:words * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!buffer || !queue) return 2;
        memset(buffer.contents, 0x5a, buffer.length);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!command || !encoder) return 2;
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:buffer offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(pipeline.maxTotalThreadsPerThreadgroup,256),1,1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        NSUInteger mismatches = 0;
        const uint32_t *values = buffer.contents;
        for (NSUInteger i = 0; i < count; ++i) {
            uint32_t x = (uint32_t)i * 1664525u + 1013904223u;
            uint32_t expected[4] = {reverse32(x), reverse32(~x), 0, UINT32_MAX};
            for (unsigned lane = 0; lane < 4; ++lane)
                if (values[i * 4 + lane] != expected[lane]) ++mismatches;
        }
        BOOL passed = command.status == MTLCommandBufferStatusCompleted && mismatches == 0;
        NSDictionary *report = @{@"probe":@"uint4-bit-reverse", @"device":device.name,
            @"checkedValues":@(words), @"mismatches":@(mismatches), @"verified":@(passed),
            @"gpuSeconds":@(command.GPUEndTime-command.GPUStartTime), @"error":command.error.description?:@""};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return passed ? 0 : 3;
    }
}
