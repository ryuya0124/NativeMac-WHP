#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Exercise public heap APIs and verify real GPU writes through a shared readback.
int main(int argc,char **argv){@autoreleasepool{
    unsigned mode=argc==2?(unsigned)strtoul(argv[1],NULL,0):0;
    if(argc>2 || mode>7)return 64;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 1;
    MTLHeapDescriptor *descriptor=[MTLHeapDescriptor new];descriptor.size=16*1024*1024;
    descriptor.storageMode=(mode&1)?MTLStorageModeShared:MTLStorageModePrivate;
    descriptor.type=(mode&2)?MTLHeapTypePlacement:MTLHeapTypeAutomatic;
    descriptor.hazardTrackingMode=(mode&4)?MTLHazardTrackingModeUntracked:MTLHazardTrackingModeTracked;
    MTLResourceOptions options=(descriptor.storageMode<<MTLResourceStorageModeShift)|
        (descriptor.hazardTrackingMode<<MTLResourceHazardTrackingModeShift);
    id<MTLHeap> heap=[device newHeapWithDescriptor:descriptor];
    id<MTLBuffer> buffer=descriptor.type==MTLHeapTypePlacement?
        [heap newBufferWithLength:4096 options:options offset:0]:[heap newBufferWithLength:4096 options:options];
    BOOL verified=NO;NSUInteger wrong=0,checked=0;
    if(heap && buffer){
        id<MTLBuffer> readback=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue=[device newCommandQueue];
        if(readback && queue){
            memset(readback.contents,0,4096);
            id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
            [blit fillBuffer:buffer range:NSMakeRange(0,4096) value:0x5a];
            [blit copyFromBuffer:buffer sourceOffset:0 toBuffer:readback destinationOffset:0 size:4096];
            [blit endEncoding];[command commit];[command waitUntilCompleted];
            for(NSUInteger i=0;i<4096;++i)wrong+=((const uint8_t*)readback.contents)[i]!=0x5a;
            checked=4096;
            verified=command.status==MTLCommandBufferStatusCompleted && !wrong;
        }
    }
    NSDictionary *report=@{@"stage":@"heap-buffer-gpu-readback",@"mode":@(mode),@"heap":@(heap!=nil),
        @"buffer":@(buffer!=nil),@"verified":@(verified),@"checkedBytes":@(checked),@"mismatches":@(wrong)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");return verified?0:2;
}}
