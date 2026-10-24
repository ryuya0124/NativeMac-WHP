#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>

// Authored byte checks only. Command completion is bounded by the external test runner.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) return 2;
        const NSUInteger length = 65536;
        const NSUInteger cases[][3] = {
            {0, 4, 8192}, {4, 0, 4096}, {0, 0, 16384}, {4, 16, 1024},
            {8, 12, 32768}, {16, 4, 8192}, {64, 80, 2048},
        };
        const NSUInteger count = sizeof(cases) / sizeof(cases[0]);
        NSMutableData *expected = [NSMutableData dataWithLength:length];
        uint8_t *bytes = expected.mutableBytes;
        for (NSUInteger i = 0; i < length; ++i) bytes[i] = (uint8_t)((i * 37 + 13) % 251);
        id<MTLBuffer> source = [device newBufferWithBytes:bytes length:length
                                                options:MTLResourceStorageModeShared];
        id<MTLBuffer> readback = [device newBufferWithLength:length * count
                                                   options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!source || !readback || !command || !blit) return 3;
        NSMutableData *snapshots = [NSMutableData dataWithCapacity:length * count];
        for (NSUInteger i = 0; i < count; ++i) {
            [blit copyFromBuffer:source sourceOffset:cases[i][0] toBuffer:source
              destinationOffset:cases[i][1] size:cases[i][2]];
            memmove(bytes + cases[i][1], bytes + cases[i][0], cases[i][2]);
            [snapshots appendBytes:bytes length:length];
            [blit copyFromBuffer:source sourceOffset:0 toBuffer:readback
              destinationOffset:i * length size:length];
        }
        [blit endEncoding];
        blit = nil;
        source = nil;
        [command commit];
        [command waitUntilCompleted];
        BOOL buffersPass = command.status == MTLCommandBufferStatusCompleted &&
            memcmp(readback.contents, snapshots.bytes, snapshots.length) == 0;
        if (!buffersPass) {
            fprintf(stderr, "buffer copies failed: %s\n", command.error.description.UTF8String ?: "byte mismatch");
            return 4;
        }

        uint8_t texels[64];
        for (NSUInteger i = 0; i < sizeof(texels); ++i) texels[i] = (uint8_t)(i * 29 + 7);
        id<MTLBuffer> upload = [device newBufferWithBytes:texels length:sizeof(texels)
                                                options:MTLResourceStorageModeShared];
        id<MTLBuffer> pixels = [device newBufferWithLength:sizeof(texels) * 3
                                                  options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        command = [queue commandBuffer];
        blit = [command blitCommandEncoder];
        if (!upload || !pixels || !texture || !command || !blit) return 5;
        [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:64
                 sourceSize:MTLSizeMake(4, 4, 1) toTexture:texture destinationSlice:0
           destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        NSMutableData *pixelSnapshots = [NSMutableData dataWithCapacity:sizeof(texels) * 3];
        for (NSUInteger iteration = 0; iteration < 3; ++iteration) {
            uint8_t before[64];
            memcpy(before, texels, sizeof(before));
            for (NSUInteger y = 0; y < 3; ++y) {
                memcpy(texels + (y + 1) * 16 + 4, before + y * 16, 12);
            }
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(3, 3, 1)
                       toTexture:texture destinationSlice:0 destinationLevel:0
               destinationOrigin:MTLOriginMake(1, 1, 0)];
            [pixelSnapshots appendBytes:texels length:sizeof(texels)];
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1)
                        toBuffer:pixels destinationOffset:iteration * sizeof(texels)
          destinationBytesPerRow:16 destinationBytesPerImage:64];
        }
        [blit endEncoding];
        blit = nil;
        upload = nil;
        texture = nil;
        [command commit];
        [command waitUntilCompleted];
        BOOL texturesPass = command.status == MTLCommandBufferStatusCompleted &&
            memcmp(pixels.contents, pixelSnapshots.bytes, pixelSnapshots.length) == 0;
        if (!texturesPass) {
            fprintf(stderr, "%s\n", command.error.description.UTF8String ?: "texture byte mismatch");
            return 6;
        }

        // A texture backed by a buffer takes the separate overlapping-texel-row path.
        const NSUInteger pitch = MAX((NSUInteger)256,
            [device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatRGBA8Unorm]);
        const NSUInteger linearLength = pitch * 4;
        NSMutableData *linearExpected = [NSMutableData dataWithLength:linearLength];
        memset(linearExpected.mutableBytes, 0xa5, linearLength);
        uint8_t *linearBytes = linearExpected.mutableBytes;
        for (NSUInteger y = 0; y < 4; ++y) {
            for (NSUInteger x = 0; x < 16; ++x) linearBytes[y * pitch + x] = (uint8_t)(y * 47 + x * 13);
        }
        id<MTLBuffer> linear = [device newBufferWithBytes:linearBytes length:linearLength
                                                options:MTLResourceStorageModeShared];
        id<MTLBuffer> linearReadback = [device newBufferWithLength:linearLength * 3
                                                         options:MTLResourceStorageModeShared];
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> linearTexture = [linear newTextureWithDescriptor:descriptor offset:0 bytesPerRow:pitch];
        command = [queue commandBuffer];
        blit = [command blitCommandEncoder];
        if (!linear || !linearReadback || !linearTexture || !command || !blit) return 7;
        NSMutableData *linearSnapshots = [NSMutableData dataWithCapacity:linearLength * 3];
        for (NSUInteger iteration = 0; iteration < 3; ++iteration) {
            NSData *before = [linearExpected copy];
            for (NSUInteger y = 0; y < 3; ++y) {
                memcpy(linearBytes + (y + 1) * pitch + 4, (const uint8_t *)before.bytes + y * pitch, 12);
            }
            [blit copyFromTexture:linearTexture sourceSlice:0 sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(3, 3, 1)
                       toTexture:linearTexture destinationSlice:0 destinationLevel:0
               destinationOrigin:MTLOriginMake(1, 1, 0)];
            [linearSnapshots appendBytes:linearBytes length:linearLength];
            [blit copyFromBuffer:linear sourceOffset:0 toBuffer:linearReadback
              destinationOffset:iteration * linearLength size:linearLength];
        }
        [blit endEncoding];
        blit = nil;
        linear = nil;
        linearTexture = nil;
        [command commit];
        [command waitUntilCompleted];
        BOOL linearPass = command.status == MTLCommandBufferStatusCompleted &&
            memcmp(linearReadback.contents, linearSnapshots.bytes, linearSnapshots.length) == 0;
        NSDictionary *result = @{
            @"device": device.name,
            @"bufferSnapshots": @(count), @"bufferVerifiedBytes": @(snapshots.length),
            @"textureSnapshots": @3, @"textureVerifiedBytes": @(pixelSnapshots.length),
            @"linearSnapshots": @3, @"linearVerifiedBytes": @(linearSnapshots.length),
            @"linearBytesPerRow": @(pitch), @"linearPass": @(linearPass),
            @"bufferPass": @(buffersPass), @"texturePass": @(texturesPass),
            @"passed": linearPass ? @YES : @NO,
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        if (!linearPass) fprintf(stderr, "%s\n", command.error.description.UTF8String ?: "linear byte mismatch");
        return linearPass ? 0 : 8;
    }
}
