#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <unistd.h>

// Process-local workaround for measured stale getBytes reads from the guest's
// shared textures. Copy actual texels on the GPU, wait, then copy raw bytes into
// the caller's rows. No shader/draw is replaced and no pixel values are invented.
static id<MTLCommandQueue> readbackQueue;
static void (*originalRegion)(id,SEL,void *,NSUInteger,MTLRegion,NSUInteger);
static void (*originalSlice)(id,SEL,void *,NSUInteger,NSUInteger,MTLRegion,NSUInteger,NSUInteger);
static atomic_ulong readbacks;

static NSUInteger unitSize(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm:
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: return 1;
        case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm:
        case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float:
        case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm:
        case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint: return 2;
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float:
        case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm:
        case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float:
        case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint:
        case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float: return 4;
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float:
        case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm:
        case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float: return 8;
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
        default: return 0; // Compressed, depth/stencil and unmeasured formats stay native.
    }
}

static void failed(NSString *message) {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:message userInfo:nil];
}

static BOOL copied(id<MTLTexture> texture, void *destination, NSUInteger rowStride,
                    MTLRegion region, NSUInteger level, NSUInteger slice) {
    NSUInteger unit = unitSize(texture.pixelFormat);
    if (!unit || texture.storageMode != MTLStorageModeShared || texture.sampleCount != 1 ||
        (texture.textureType != MTLTextureType2D && texture.textureType != MTLTextureType2DArray) ||
        region.origin.z || region.size.depth != 1 || level >= texture.mipmapLevelCount ||
        slice >= texture.arrayLength || !region.size.width || !region.size.height || !destination)
        return NO;
    NSUInteger width = MAX((NSUInteger)1, texture.width >> level);
    NSUInteger height = MAX((NSUInteger)1, texture.height >> level);
    if (region.origin.x > width || region.size.width > width-region.origin.x ||
        region.origin.y > height || region.size.height > height-region.origin.y) return NO;
    NSUInteger rowBytes, lastRow, extent, stagingRow, stagingSize;
    if (__builtin_mul_overflow(region.size.width,unit,&rowBytes) || rowStride < rowBytes ||
        __builtin_mul_overflow(region.size.height-1,rowStride,&lastRow) ||
        __builtin_add_overflow(lastRow,rowBytes,&extent) ||
        __builtin_add_overflow(rowBytes,(NSUInteger)255,&stagingRow)) return NO;
    stagingRow &= ~(NSUInteger)255;
    if (__builtin_mul_overflow(stagingRow,region.size.height,&stagingSize)) return NO;
    @autoreleasepool {
        id<MTLBuffer> staging = [texture.device newBufferWithLength:stagingSize options:MTLResourceStorageModeShared];
        if (!staging) failed(@"NativeMac: shared texture GPU readback allocation failed");
        id<MTLCommandBuffer> command = [readbackQueue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
        if (!command || !encoder) failed(@"NativeMac: shared texture GPU readback encoder unavailable");
        [encoder copyFromTexture:texture sourceSlice:slice sourceLevel:level sourceOrigin:region.origin
            sourceSize:region.size toBuffer:staging destinationOffset:0
            destinationBytesPerRow:stagingRow destinationBytesPerImage:stagingSize];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted || !staging.contents)
            failed(@"NativeMac: shared texture GPU readback did not complete");
        for (NSUInteger row=0; row<region.size.height; ++row)
            memcpy((uint8_t *)destination+row*rowStride,(const uint8_t *)staging.contents+row*stagingRow,rowBytes);
        atomic_fetch_add(&readbacks,1);
    }
    return YES;
}

static void regionRead(id self, SEL selector, void *bytes, NSUInteger row, MTLRegion region, NSUInteger level) {
    if (!copied(self,bytes,row,region,level,0)) originalRegion(self,selector,bytes,row,region,level);
}
static void sliceRead(id self, SEL selector, void *bytes, NSUInteger row, NSUInteger image,
                       MTLRegion region, NSUInteger level, NSUInteger slice) {
    if (!copied(self,bytes,row,region,level,slice)) originalSlice(self,selector,bytes,row,image,region,level,slice);
}
static void replace(Class cls, SEL selector, IMP implementation, Method method) {
    if (!class_addMethod(cls,selector,implementation,method_getTypeEncoding(method)))
        class_replaceMethod(cls,selector,implementation,method_getTypeEncoding(method));
}

__attribute__((constructor)) static void installReadback(void) {
    @autoreleasepool {
        // DYLD_INSERT_LIBRARIES can reach the application's compiler helpers.
        // GPU work inside their initializers can wait on the compiler itself.
        const char *targetPid=getenv("NATIVEMAC_METAL_TARGET_PID");
        if (!targetPid || strtoull(targetPid,NULL,10)!=(unsigned long long)getpid()) return;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (![NSStringFromClass([device class]) containsString:@"Paravirt"]) return;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        if (!queue || !target || ![NSStringFromClass([target class]) containsString:@"Paravirt"]) return;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1,0,0,1);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder) return;
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) return;
        uint8_t cpu[64] = {0};
        [target getBytes:cpu bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
        BOOL nativeCorrect = YES;
        for (unsigned p=0; p<16; ++p)
            nativeCorrect &= cpu[p*4]==255 && cpu[p*4+1]==0 && cpu[p*4+2]==0 && cpu[p*4+3]==255;
        if (nativeCorrect) return;
        Method a=class_getInstanceMethod([target class],@selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:));
        Method b=class_getInstanceMethod([target class],@selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:));
        if (!a || !b) return;
        readbackQueue=queue;
        @try {
            if (!copied(target,cpu,16,MTLRegionMake2D(0,0,4,4),0,0)) {readbackQueue=nil; return;}
        } @catch (NSException *exception) { (void)exception; readbackQueue=nil; return; }
        BOOL gpuCorrect=YES;
        for (unsigned p=0;p<16;++p)
            gpuCorrect &= cpu[p*4]==255 && cpu[p*4+1]==0 && cpu[p*4+2]==0 && cpu[p*4+3]==255;
        if (!gpuCorrect) {readbackQueue=nil; return;}
        originalRegion=(void (*)(id,SEL,void *,NSUInteger,MTLRegion,NSUInteger))method_getImplementation(a);
        originalSlice=(void (*)(id,SEL,void *,NSUInteger,NSUInteger,MTLRegion,NSUInteger,NSUInteger))method_getImplementation(b);
        replace([target class],@selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:),(IMP)regionRead,a);
        replace([target class],@selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:),(IMP)sliceRead,b);
        fprintf(stderr,"NativeMac: measured shared-texture readback workaround active\n");
    }
}
__attribute__((destructor)) static void reportReadback(void) {
    if (readbackQueue) fprintf(stderr,"NATIVEMAC_SHARED_TEXTURE_READBACK copies=%lu\n",atomic_load(&readbacks));
}
