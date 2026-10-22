#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>

// Grow one encoder beyond its first serializer buffer. Check actual GPU writes.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> buffer = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        if (!device || !queue || !buffer) return 2;
        memset(buffer.contents, 0, buffer.length);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
        for (unsigned i = 0; i < 16384; i++) {
            [encoder fillBuffer:buffer range:NSMakeRange((i % 256) * 16, 16)
                         value:(uint8_t)(i / 256)];
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        unsigned errors = 0;
        for (unsigned i = 0; i < 4096; i++) {
            if (((uint8_t *)buffer.contents)[i] != 63) errors++;
        }
        fprintf(stderr, "SEGMENTED_BLIT commands=16384 checked=4096 errors=%u status=%lu error=%s\n",
            errors, (unsigned long)command.status, command.error.description.UTF8String ?: "none");
        return command.status != MTLCommandBufferStatusCompleted || errors ? 1 : 0;
    }
}
