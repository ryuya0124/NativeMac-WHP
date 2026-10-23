#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>

int main(int argc,char **argv){@autoreleasepool{
    if(argc!=4)return 64;
    NSUInteger length=strtoull(argv[1],NULL,0),options=strtoull(argv[2],NULL,0),offset=strtoull(argv[3],NULL,0);
    if(!length || length>16*1024*1024 || offset>4095 || length%4)return 64;
    void *allocation=NULL;if(posix_memalign(&allocation,4096,((length+offset+4095)/4096)*4096))return 1;
    void *bytes=(uint8_t*)allocation+offset;
    for(NSUInteger i=0;i<length/4;++i){uint32_t value=(uint32_t)i*7+3;memcpy((uint8_t*)bytes+i*4,&value,4);}
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device){free(allocation);return 1;}
    io_service_t service=(getenv("NM_NOCOPY_MODE") || getenv("NM_CAPTURE_ALLOCATIONS")) ?
        IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleParavirtAccelerator")) : IO_OBJECT_NULL;
    io_connect_t diagnostic=IO_OBJECT_NULL;
    if(service){IOServiceOpen(service,mach_task_self(),0x524d0005,&diagnostic);IOObjectRelease(service);}
    if(diagnostic && getenv("NM_NOCOPY_MODE")){
        uint64_t mode=strtoull(getenv("NM_NOCOPY_MODE"),NULL,0);
        kern_return_t status=IOConnectCallScalarMethod(diagnostic,0x524d0008,&mode,1,NULL,NULL);
        fprintf(stderr,"NOCOPY_DIAGNOSTIC_MODE mode=%llu status=%x\n",mode,status);
    }
    if(diagnostic)IOConnectCallMethod(diagnostic,0x524d0002,NULL,0,NULL,0,NULL,NULL,NULL,NULL);
    id<MTLBuffer> buffer=[device newBufferWithBytesNoCopy:bytes length:length options:options deallocator:nil];
    if(diagnostic){
        struct{uint32_t sequence,size;int32_t status;uint32_t detail;uint8_t bytes[512];} capture={0};
        size_t size=sizeof(capture);kern_return_t status=IOConnectCallStructMethod(diagnostic,0x524d0003,NULL,0,&capture,&size);
        fprintf(stderr,"NOCOPY_CALL capture=%x sequence=%u size=%u result=%x detail=%x bytes=",
            status,capture.sequence,capture.size,(uint32_t)capture.status,capture.detail);
        if(!status && capture.size<=512)for(unsigned i=0;i<capture.size;++i)fprintf(stderr,"%02x",capture.bytes[i]);
        fputc('\n',stderr);IOServiceClose(diagnostic);
    }
    BOOL verified=NO,aliasVerified=NO,computeVerified=NO;unsigned mismatches=0;
    if(buffer){
        id<MTLBuffer> output=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue=[device newCommandQueue];
        if(output && queue){
            memset(output.contents,0,length);
            id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
            [blit copyFromBuffer:buffer sourceOffset:0 toBuffer:output destinationOffset:0 size:length];
            [blit endEncoding];[command commit];[command waitUntilCompleted];
            for(NSUInteger i=0;i<length/4;++i)if(((uint32_t*)output.contents)[i]!=(uint32_t)i*7+3)++mismatches;
            verified=command.status==MTLCommandBufferStatusCompleted && !mismatches;
            NSError *error=nil;
            NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
                "kernel void alias_check(device uint *data [[buffer(0)]],device uint *out [[buffer(1)]],uint i [[thread_position_in_grid]]){out[i]=data[i];data[i]^=0x12345678u;}";
            id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
            id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"alias_check"] error:&error];
            if(pipeline){
                command=[queue commandBuffer];id<MTLComputeCommandEncoder> compute=[command computeCommandEncoder];
                [compute setComputePipelineState:pipeline];[compute setBuffer:buffer offset:0 atIndex:0];[compute setBuffer:output offset:0 atIndex:1];
                [compute dispatchThreads:MTLSizeMake(length/4,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(length/4,MIN(pipeline.maxTotalThreadsPerThreadgroup,256)),1,1)];
                [compute endEncoding];[command commit];[command waitUntilCompleted];
                computeVerified=command.status==MTLCommandBufferStatusCompleted;
                for(NSUInteger i=0;i<length/4;++i){
                    uint32_t original=(uint32_t)i*7+3,changed;memcpy(&changed,(uint8_t*)bytes+i*4,4);
                    if(((uint32_t*)output.contents)[i]!=original || changed!=(original^0x12345678u))computeVerified=NO;
                }
            }
            // Writes made after registration must remain visible to the GPU.
            memset(bytes,0xa5,length);
            command=[queue commandBuffer];blit=[command blitCommandEncoder];
            [blit copyFromBuffer:buffer sourceOffset:0 toBuffer:output destinationOffset:0 size:length];
            [blit endEncoding];[command commit];[command waitUntilCompleted];
            BOOL cpuToGPU=command.status==MTLCommandBufferStatusCompleted;
            for(NSUInteger i=0;i<length;++i)if(((uint8_t*)output.contents)[i]!=0xa5)cpuToGPU=NO;
            // GPU writes must also update the caller's original allocation.
            command=[queue commandBuffer];blit=[command blitCommandEncoder];
            [blit fillBuffer:buffer range:NSMakeRange(0,length) value:0x5a];
            [blit endEncoding];[command commit];[command waitUntilCompleted];
            aliasVerified=cpuToGPU && command.status==MTLCommandBufferStatusCompleted;
            for(NSUInteger i=0;i<length;++i)if(((uint8_t*)bytes)[i]!=0x5a)aliasVerified=NO;
        }
    }
    printf("{\"length\":%lu,\"options\":%lu,\"offset\":%lu,\"allocated\":%d,\"device\":%d,\"sameContents\":%d,\"verified\":%d,\"aliasVerified\":%d,\"computeVerified\":%d,\"mismatches\":%u}\n",
        (unsigned long)length,(unsigned long)options,(unsigned long)offset,buffer!=nil,buffer.device!=nil,
        buffer.contents==bytes,verified,aliasVerified,computeVerified,mismatches);
    buffer=nil;free(allocation);return verified && aliasVerified && computeVerified?0:2;
}}
