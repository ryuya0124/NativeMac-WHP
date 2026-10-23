#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec+t.tv_nsec*1e-9; }
static void deadline(int signalNumber) { (void)signalNumber; _exit(124); }

// Measure the CPU-visible submission path. GPUStartTime is intentionally not
// called GPU execution time: a virtual driver may include completion detection.
int main(void) { @autoreleasepool {
    signal(SIGALRM, deadline); alarm(120);
    id<MTLDevice> d=MTLCreateSystemDefaultDevice();
    if(!d) return 1;
    NSError *error=nil;
    double start=now();
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nkernel void submission_check(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i]=i*7u+3u; }";
    id<MTLLibrary> l=[d newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> p=l?[d newComputePipelineStateWithFunction:[l newFunctionWithName:@"submission_check"] error:&error]:nil;
    double compile=now()-start;
    if(!p){fprintf(stderr,"pipeline: %s\n",error.description.UTF8String);return 2;}
    id<MTLCommandQueue> q=[d newCommandQueue];
    NSMutableArray *rows=[NSMutableArray array];
    BOOL pass=YES;
    for(NSNumber *privateMode in @[@NO,@YES]) for(NSNumber *size in @[@4096,@1048576]) {
        NSUInteger n=size.unsignedIntegerValue;
        BOOL gpuPrivate=privateMode.boolValue;
        id<MTLBuffer> readback=[d newBufferWithLength:n*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> b=gpuPrivate?[d newBufferWithLength:n*4 options:MTLResourceStorageModePrivate]:readback;
        if(!b||!readback)return 3;
        for(NSNumber *batchSize in @[@1,@8,@64]) {
            NSUInteger batch=batchSize.unsignedIntegerValue, total=256;
            for(NSUInteger round=0;round<4;round++) {
                double encode=0,commit=0,wait=0,t0=now();
                memset(readback.contents,0,readback.length);
                for(NSUInteger command=0;command<total/batch;command++) { @autoreleasepool {
                    double t=now();
                    id<MTLCommandBuffer> cb=[q commandBuffer];
                    id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
                    [e setComputePipelineState:p]; [e setBuffer:b offset:0 atIndex:0];
                    for(NSUInteger j=0;j<batch;j++) {
                        [e dispatchThreads:MTLSizeMake(n,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(256,p.maxTotalThreadsPerThreadgroup),1,1)];
                        if(j+1<batch)[e memoryBarrierWithScope:MTLBarrierScopeBuffers];
                    }
                    [e endEncoding]; encode+=now()-t;
                    t=now();[cb commit];commit+=now()-t;
                    t=now();[cb waitUntilCompleted];wait+=now()-t;
                    if(cb.status!=MTLCommandBufferStatusCompleted){pass=NO;fprintf(stderr,"command: %s\n",cb.error.description.UTF8String);}
                }}
                double wall=now()-t0;
                if(gpuPrivate){
                    id<MTLCommandBuffer> copy=[q commandBuffer];
                    id<MTLBlitCommandEncoder> blit=[copy blitCommandEncoder];
                    [blit copyFromBuffer:b sourceOffset:0 toBuffer:readback destinationOffset:0 size:b.length];
                    [blit endEncoding];[copy commit];[copy waitUntilCompleted];
                    if(copy.status!=MTLCommandBufferStatusCompleted)pass=NO;
                }
                NSUInteger mismatches=0;const uint32_t *v=readback.contents;
                for(NSUInteger i=0;i<n;i++)if(v[i]!=(uint32_t)i*7u+3u)mismatches++;
                if(mismatches)pass=NO;
                if(round)[rows addObject:@{@"storage":gpuPrivate?@"private":@"shared",@"values":@(n),@"batch":@(batch),@"dispatches":@(total),@"round":@(round),@"encodeMs":@(encode*1000),@"commitMs":@(commit*1000),@"waitMs":@(wait*1000),@"wallMs":@(wall*1000),@"mismatches":@(mismatches)}];
            }
        }
    }
    NSDictionary *report=@{@"device":d.name,@"hasUnifiedMemory":@(d.hasUnifiedMemory),@"pipelineCreationMs":@(compile*1000),@"privateReadbackExcludedFromWall":@YES,@"verified":@(pass),@"rows":rows};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes,1,json.length,stdout);putchar('\n');return pass?0:4;
}}
