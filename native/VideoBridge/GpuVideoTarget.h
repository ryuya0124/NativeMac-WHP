// An explicitly host-armed NV12 IOSurface. Only its separate 64-byte metadata
// header is CPU-written. Decoded pixels arrive later through host GPU commands.
#pragma once
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <os/log.h>
#include <array>
#include <cstring>
#include <map>
#include <memory>
#include <atomic>
#include <chrono>
#include <thread>

// The host completion acknowledgement already orders GPU DMA. Publish the
// changed IOSurface seed for clients that cache an image by surface + seed;
// no CPU pixel read, conversion or write is required here.
static bool NativeMacPublishGpuVideoTarget(CVPixelBufferRef pixel){
    IOSurfaceRef surface=CVPixelBufferGetIOSurface(pixel);
    if(!surface||IOSurfaceLock(surface,kIOSurfaceLockAvoidSync,nullptr))return false;
    return IOSurfaceUnlock(surface,kIOSurfaceLockAvoidSync,nullptr)==KERN_SUCCESS;
}

class NativeMacGpuVideoPool {
    struct Entry {
        IOSurfaceRef surface=nullptr;
        NSArray<id<MTLTexture>> *textures=nil;
        ~Entry(){if(surface)CFRelease(surface);}
    };
    CVPixelBufferPoolRef pool=nullptr;
    id<MTLDevice> device=nil;
    id<MTLCommandQueue> queue=nil;
    id<MTLBuffer> scratch=nil;
    std::map<uint32_t,std::unique_ptr<Entry>> entries;
    size_t width,height;
    bool materialize(NSArray<id<MTLTexture>> *textures){
    id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    if(!scratch||!command||!blit)return false;
    // This tiny authored GPU operation materializes both plane backings. It
    // reads existing plane bytes, never decodes or fills a frame.
    for(NSUInteger i=0;i<2;i++)[blit copyFromTexture:textures[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:scratch destinationOffset:i*256 destinationBytesPerRow:256 destinationBytesPerImage:0];
    [blit endEncoding];[command commit];[command waitUntilCompleted];
    return command.status==MTLCommandBufferStatusCompleted;
    }
public:
    NativeMacGpuVideoPool(size_t w,size_t h):width(w),height(h){@autoreleasepool{
        if(w<16||w>3840||h<16||h>2160||(w&1)||(h&1))return;
        NSDictionary *attributes=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferWidthKey:@(w),(id)kCVPixelBufferHeightKey:@(h),(id)kCVPixelBufferBytesPerRowAlignmentKey:@256,(id)kCVPixelBufferPlaneAlignmentKey:@4096,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        // CoreVideo alone decides when a pixel buffer is no longer retained
        // by any consumer. Keep materialized slots cached for this session.
        NSDictionary *limits=@{(id)kCVPixelBufferPoolMinimumBufferCountKey:@24};
        if(CVPixelBufferPoolCreate(nullptr,(__bridge CFDictionaryRef)limits,(__bridge CFDictionaryRef)attributes,&pool))pool=nullptr;
        device=MTLCreateSystemDefaultDevice();queue=[device newCommandQueue];scratch=[device newBufferWithLength:512 options:MTLResourceStorageModeShared];
    }}
    ~NativeMacGpuVideoPool(){if(pool)CFRelease(pool);}
    CVPixelBufferRef acquire(const uint8_t *capability,uint8_t *actual,const std::atomic<bool> &stopped){@autoreleasepool{
    if(!pool||!device||!queue)return nullptr;
    CVPixelBufferRef pixel=nullptr;
    NSDictionary *limits=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@24};
    OSStatus status=0;auto began=std::chrono::steady_clock::now();unsigned retries=0;
    do {
        if(stopped)return nullptr;
        status=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr,pool,(__bridge CFDictionaryRef)limits,&pixel);
        if(status!=kCVReturnWouldExceedAllocationThreshold)break;
        if(std::chrono::steady_clock::now()-began>=std::chrono::seconds(15))break;
        retries++;std::this_thread::sleep_for(std::chrono::milliseconds(5));
    } while(true);
    if(retries)os_log(OS_LOG_DEFAULT,"NativeMac GPU pixel pool backpressure retries=%u status=%d slots=%zu",retries,(int)status,entries.size());
    if(status){os_log_error(OS_LOG_DEFAULT,"NativeMac GPU pixel pool refused status=%d slots=%zu",(int)status,entries.size());return nullptr;}
    IOSurfaceRef surface=CVPixelBufferGetIOSurface(pixel);
    if(!surface||IOSurfaceGetPlaneCount(surface)!=2||static_cast<uint8_t*>(IOSurfaceGetBaseAddressOfPlane(surface,0))-static_cast<uint8_t*>(IOSurfaceGetBaseAddress(surface))<4096){CFRelease(pixel);return nullptr;}
    auto found=entries.find(IOSurfaceGetID(surface));
    if(found!=entries.end()){
        if(found->second->surface!=surface){os_log_error(OS_LOG_DEFAULT,"NativeMac GPU pixel pool surface proxy changed slots=%zu",entries.size());CFRelease(pixel);return nullptr;}
    }
    if(found==entries.end()&&entries.size()>=24){os_log_error(OS_LOG_DEFAULT,"NativeMac GPU pixel pool materialized slot limit");CFRelease(pixel);return nullptr;}
    std::array<uint8_t,64> metadata{};memcpy(metadata.data(),"NativeMacVideo01",16);memcpy(metadata.data()+16,capability,16);
    auto word=[&](size_t at,uint32_t value){memcpy(metadata.data()+at,&value,4);};
    word(32,1);word(36,static_cast<uint32_t>(width));word(40,static_cast<uint32_t>(height));word(44,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if(IOSurfaceLock(surface,0,nullptr)){CFRelease(pixel);return nullptr;}
    // Keep CoreVideo's planar metadata at the beginning intact.
    memcpy(static_cast<uint8_t*>(IOSurfaceGetBaseAddress(surface))+1024,metadata.data(),metadata.size());IOSurfaceUnlock(surface,0,nullptr);
    if(found!=entries.end()){
        if(!materialize(found->second->textures)){CFRelease(pixel);return nullptr;}
        memcpy(actual,capability,16);return pixel;
    }
    NSMutableArray<id<MTLTexture>> *textures=[NSMutableArray array];
    for(NSUInteger plane=0;plane<2;plane++){
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:plane?MTLPixelFormatRG8Unorm:MTLPixelFormatR8Unorm width:plane?width/2:width height:plane?height/2:height mipmapped:NO];
        desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> texture=[device newTextureWithDescriptor:desc iosurface:surface plane:plane];
        if(!texture){CFRelease(pixel);return nullptr;}[textures addObject:texture];
    }
    if(!materialize(textures)){CFRelease(pixel);return nullptr;}
    // These are pool-owned GPU views, not extra CVPixelBuffer references.
    // They preserve the registered backing while CoreVideo independently
    // checks consumer ownership before recycling that pixel buffer.
    auto entry=std::make_unique<Entry>();entry->surface=surface;CFRetain(surface);entry->textures=textures;
    memcpy(actual,capability,16);
    entries.emplace(IOSurfaceGetID(surface),std::move(entry));return pixel;
    }}
};
