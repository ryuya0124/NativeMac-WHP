#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void vector_load(device const float4 *a [[buffer(0)]], device float4 *b [[buffer(1)]], uint i [[thread_position_in_grid]]) { b[i]=a[i]; }\n";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"vector_load"] error:&error];
    if(!pipeline) { fprintf(stderr,"pipeline creation failed\n");return 1; }
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLBuffer> input=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    for(NSUInteger i=0;i<1024;++i)((float*)input.contents)[i]=(float)i+0.25f;
    NSUInteger errors=0,checked=0;
    for(NSUInteger direction=0;direction<2;++direction)for(NSUInteger offset=0;offset<16;offset+=4) {
        NSUInteger sourceOffset=direction?0:offset,destinationOffset=direction?offset:0;
        memset(output.contents,0xa5,4096);
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:input offset:sourceOffset atIndex:0];
        [encoder setBuffer:output offset:destinationOffset atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(16,1,1)];
        [encoder endEncoding];[command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted)return 2;
        for(NSUInteger j=0;j<64;++j){
            float actual=((float*)output.contents)[destinationOffset/4+j];
            float expected=((float*)input.contents)[sourceOffset/4+j];
            if(actual!=expected)++errors;++checked;
        }
        for(NSUInteger j=0;j<destinationOffset;++j)if(((uint8_t*)output.contents)[j]!=0xa5)++errors;
        for(NSUInteger j=destinationOffset+64*sizeof(float);j<4096;++j)if(((uint8_t*)output.contents)[j]!=0xa5)++errors;
        printf("direction=%lu offset=%lu cumulativeErrors=%lu\n",(unsigned long)direction,(unsigned long)offset,(unsigned long)errors);
    }
    printf("{\"case\":\"vector-binding-offset\",\"checkedValues\":%lu,\"mismatches\":%lu,\"passed\":%s}\n",
        (unsigned long)checked,(unsigned long)errors,errors?"false":"true");
    return errors?3:0;
}}
