#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Run inside the guest: requires an actual Metal device and checks GPU results.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { puts("{\"metalAvailable\":false}"); return 1; }
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void check(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = i * 7u + 3u; }";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLComputePipelineState> pipeline = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"check"] error:&error] : nil;
        if (!pipeline) { fprintf(stderr,"Metal pipeline: %s\n",error.description.UTF8String); return 2; }
        const NSUInteger count = 4096;
        id<MTLBuffer> buffer = [device newBufferWithLength:count*sizeof(uint32_t) options:MTLResourceStorageModeShared];
        memset(buffer.contents,0,count*sizeof(uint32_t));
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:buffer offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(pipeline.maxTotalThreadsPerThreadgroup,256),1,1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        BOOL passed=command.status==MTLCommandBufferStatusCompleted;
        const uint32_t *values=buffer.contents;
        for (NSUInteger i=0;i<count;++i) if(values[i]!=(uint32_t)i*7u+3u) passed=NO;
        NSDictionary *report=@{@"metalAvailable":@YES,@"device":device.name,
            @"registryID":@(device.registryID),@"hasUnifiedMemory":@(device.hasUnifiedMemory),
            @"computedValues":@(count),@"verified":@(passed),
            @"gpuStartTime":@(command.GPUStartTime),@"gpuEndTime":@(command.GPUEndTime),
            @"error":command.error.description?:@""};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
        return passed?0:3;
    }
}
