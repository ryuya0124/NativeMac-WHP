#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <string.h>

// Authored integer-endpoint colors verify stores, loads and untouched row padding.
int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    if(!device || !queue)return 2;
    const NSUInteger width=32,height=16,pitch=256;
    IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth:@(width),
        (__bridge NSString *)kIOSurfaceHeight:@(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement:@4,
        (__bridge NSString *)kIOSurfaceBytesPerRow:@(pitch),
        (__bridge NSString *)kIOSurfaceAllocSize:@(pitch*height),
        (__bridge NSString *)kIOSurfacePixelFormat:@(0x42475241u)});
    if(!surface)return 3;
    IOSurfaceLock(surface,0,NULL);
    memset(IOSurfaceGetBaseAddress(surface),0xa5,IOSurfaceGetAllocSize(surface));
    IOSurfaceUnlock(surface,0,NULL);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
#if defined(__arm64__) || defined(__aarch64__)
    td.storageMode=MTLStorageModeShared;
#else
    td.storageMode=MTLStorageModeManaged;
#endif
    td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsagePixelFormatView;
    id<MTLTexture> color=[device newTextureWithDescriptor:td iosurface:surface plane:0];
    td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
        width:width height:height mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> depth=[device newTextureWithDescriptor:td];
    id<MTLBuffer> readback=[device newBufferWithLength:pitch*height options:MTLResourceStorageModeShared];
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment float4 f() { return float4(0,1,0,0); }\n";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[library newFunctionWithName:@"v"];pd.fragmentFunction=[library newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
    pd.colorAttachments[0].blendingEnabled=YES;
    pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorOne;
    pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorOne;
    pd.colorAttachments[0].sourceAlphaBlendFactor=MTLBlendFactorOne;
    pd.colorAttachments[0].destinationAlphaBlendFactor=MTLBlendFactorOne;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    if(!color || !depth || !readback || !pipeline) {
        fprintf(stderr,"allocation/pipeline: %s\n",error.description.UTF8String ?: "nil");
        CFRelease(surface);return 4;
    }
    const uint8_t bgra[][4]={{0,0,255,255},{0,255,0,255},{255,0,0,255},{0,0,0,0},{255,255,255,255},{0,0,255,255}};
    NSUInteger mismatch=0,verifiedPixels=0,verifiedPadding=0;
    for(NSUInteger round=0;round<7;++round) {
        BOOL loads=round==6;
        const uint8_t *expected=loads ? (const uint8_t[]){0,255,255,255} : bgra[round];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=color;
        pass.colorAttachments[0].loadAction=loads ? MTLLoadActionLoad : MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        if(!loads)pass.colorAttachments[0].clearColor=MTLClearColorMake(expected[2]/255.0,expected[1]/255.0,expected[0]/255.0,expected[3]/255.0);
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;
        pass.depthAttachment.storeAction=MTLStoreActionDontCare;pass.depthAttachment.clearDepth=1;
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];
        if(loads) {
            [render setRenderPipelineState:pipeline];
            [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [render endEncoding];
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0
            destinationBytesPerRow:pitch destinationBytesPerImage:pitch*height];
        [blit endEncoding];[command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted) { CFRelease(surface);return 5; }
        IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL);
        const uint8_t *cpu=IOSurfaceGetBaseAddress(surface),*gpu=readback.contents;
        for(NSUInteger y=0;y<height;++y) {
            for(NSUInteger x=0;x<width;++x) {
                mismatch+=memcmp(cpu+y*pitch+x*4,expected,4)!=0;
                mismatch+=memcmp(gpu+y*pitch+x*4,expected,4)!=0;
                verifiedPixels+=2;
            }
            for(NSUInteger x=width*4;x<pitch;++x) {
                mismatch+=cpu[y*pitch+x]!=0xa5;
                ++verifiedPadding;
            }
        }
        IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);
    }
    NSDictionary *result=@{@"device":device.name,@"rounds":@7,@"clearRounds":@6,@"loadBlendRounds":@1,
        @"verifiedPixels":@(verifiedPixels),@"verifiedPaddingBytes":@(verifiedPadding),
        @"storageMode":@(color.storageMode),@"mismatches":@(mismatch),@"passed":mismatch==0 ? @YES : @NO};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    CFRelease(surface);return mismatch ? 6 : 0;
} }
