#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>

static void report(NSDictionary *value) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");fflush(stdout);
}
int main(void) { @autoreleasepool {
    io_connect_t diagnostic=IO_OBJECT_NULL;
    if(getenv("NM_HEAP_TEXTURE_CAPS")) {
        io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleParavirtAccelerator"));
        kern_return_t status=service?IOServiceOpen(service,mach_task_self(),0x524d0005,&diagnostic):KERN_NOT_SUPPORTED;
        if(service)IOObjectRelease(service);
        if(!status)status=IOConnectCallMethod(diagnostic,0x524d0007,NULL,0,NULL,0,NULL,NULL,NULL,NULL);
        if(status){report(@{@"stage":@"diagnostic-setup",@"status":@(status)});return 2;}
    }
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 1;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:16 height:16 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.hazardTrackingMode=MTLHazardTrackingModeUntracked;
    td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    report(@{@"stage":@"before-size-query"});
    if(diagnostic)IOConnectCallMethod(diagnostic,0x524d0002,NULL,0,NULL,0,NULL,NULL,NULL,NULL);
    MTLSizeAndAlign size=[device heapTextureSizeAndAlignWithDescriptor:td];
    if(diagnostic){
        struct {uint32_t sequence,size;int32_t status;uint32_t detail;uint8_t bytes[512];} capture={0};
        size_t bytes=sizeof(capture);kern_return_t status=IOConnectCallStructMethod(diagnostic,0x524d0003,NULL,0,&capture,&bytes);
        fprintf(stderr,"HEAP_TEXTURE_QUERY capture=%x sequence=%u size=%u result=%x detail=%x bytes=",
            status,capture.sequence,capture.size,(uint32_t)capture.status,capture.detail);
        if(!status && capture.size<=512)for(unsigned i=0;i<capture.size;++i)fprintf(stderr,"%02x",capture.bytes[i]);
        fputc('\n',stderr);
    }
    report(@{@"stage":@"size-query",@"size":@(size.size),@"align":@(size.align)});
    if(!size.size || !size.align || size.size>8*1024*1024)return 2;
    MTLHeapDescriptor *hd=[MTLHeapDescriptor new];hd.size=16*1024*1024;
    hd.storageMode=MTLStorageModePrivate;hd.hazardTrackingMode=MTLHazardTrackingModeUntracked;
    id<MTLHeap> heap=[device newHeapWithDescriptor:hd];
    id<MTLTexture> texture=[heap newTextureWithDescriptor:td];
    report(@{@"stage":@"allocation",@"heap":@(heap!=nil),@"texture":@(texture!=nil)});
    if(!heap || !texture)return 3;
    id<MTLBuffer> readback=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[device newCommandQueue];if(!readback || !queue)return 4;
    memset(readback.contents,0x7d,4096);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];[render endEncoding];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(16,16,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:4096];
    [blit endEncoding];[command commit];[command waitUntilCompleted];
    unsigned mismatches=0;
    for(unsigned y=0;y<16;++y)for(unsigned x=0;x<16;++x){
        const uint8_t *p=(const uint8_t*)readback.contents+y*256+x*4;
        if(p[0]!=0 || p[1]!=0 || p[2]!=255 || p[3]!=255)++mismatches;
    }
    report(@{@"stage":@"readback",@"pixels":@256,@"mismatches":@(mismatches),
        @"commandStatus":@(command.status),@"error":command.error.description?:@""});
    if(diagnostic)IOServiceClose(diagnostic);
    return command.status==MTLCommandBufferStatusCompleted && !mismatches?0:5;
} }
