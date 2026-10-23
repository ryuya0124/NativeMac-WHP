#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static void deadline(int s){(void)s;_exit(124);}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;signal(SIGALRM,deadline);alarm(120);
    id<MTLDevice> d=MTLCreateSystemDefaultDevice();if(!d)return 1;
    NSError *error=nil;
    NSString *path=@(argv[1]);id<MTLLibrary> lib=nil;
    if([path.pathExtension isEqualToString:@"metal"]){
        NSString *source=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        MTLCompileOptions *options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion2_4;
        lib=source?[d newLibraryWithSource:source options:options error:&error]:nil;
    }else lib=[d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    id<MTLComputePipelineState> p=lib?[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"resident_search"] error:&error]:nil;
    if(!p){fprintf(stderr,"pipeline: %s\n",error.description.UTF8String);return 2;}
    id<MTLCommandQueue> q=[d newCommandQueue];NSMutableArray *rows=[NSMutableArray array];
    const uint32_t n=65536;
    for(NSNumber *number in @[@1,@4,@16,@64,@256,@4096]){@autoreleasepool{
        uint32_t count=number.unsignedIntValue;NSMutableArray<id<MTLBuffer>> *buffers=[NSMutableArray array];
        id<MTLBuffer> nodes=[d newBufferWithLength:count*8 options:MTLResourceStorageModeShared];
        for(uint32_t b=0;b<count;b++){
            id<MTLBuffer> buffer=[d newBufferWithLength:1024 options:MTLResourceStorageModeShared];
            if(!buffer||!nodes)return 3;
            if(!buffer.gpuAddress){fprintf(stderr,"UNAVAILABLE: driver exposes no buffer GPU address\n");return 77;}
            for(uint32_t j=0;j<256;j++)((uint32_t*)buffer.contents)[j]=(b*257+j)^0x5a5a5a5a;
            ((uint64_t*)nodes.contents)[b]=buffer.gpuAddress;[buffers addObject:buffer];
        }
        id<MTLBuffer> countBuffer=[d newBufferWithBytes:&count length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output=[d newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
        if(!countBuffer||!output)return 3;
        for(uint32_t round=0;round<8;round++){@autoreleasepool{
            id<MTLCommandBuffer> cb=[q commandBuffer];double start=now();
            id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:p];
            [e setBuffer:nodes offset:0 atIndex:0];[e setBuffer:output offset:0 atIndex:1];[e setBuffer:countBuffer offset:0 atIndex:2];
            for(id<MTLBuffer> b in buffers)[e useResource:b usage:MTLResourceUsageRead];
            [e dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[e endEncoding];
            double encode=now()-start;[cb commit];[cb waitUntilCompleted];double wall=now()-start;
            if(cb.status!=MTLCommandBufferStatusCompleted)return 4;
            const uint32_t *values=output.contents;
            for(uint32_t i=0;i<n;i++){
                uint32_t expected=0;for(uint32_t j=0;j<16;j++){
                    uint32_t b=(i+j)&(count-1),k=(i+j)&255;
                    expected+=(b*257+k)^0x5a5a5a5a;
                }
                if(values[i]!=expected){fprintf(stderr,"mismatch count=%u index=%u\n",count,i);return 5;}
            }
            if(round)[rows addObject:@{@"buffers":@(count),@"round":@(round),@"values":@(n),@"encodeMs":@(encode*1000),@"wallMs":@(wall*1000),@"gpuMs":@((cb.GPUEndTime-cb.GPUStartTime)*1000),@"verified":@YES}];
        }}
    }}
    NSDictionary *report=@{@"device":d.name,@"rows":rows,@"verified":@YES};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");return 0;
}}
