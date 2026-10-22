#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Authored mixed texture/sampler/data argument buffer, with a GPU atomic count
// and exact integer outputs. Every value is checked; this is not a timed score.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue=[device newCommandQueue];
        NSError *error=nil;
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct Args { texture2d<float> image [[id(0)]]; sampler filter [[id(1)]]; device atomic_uint *count [[id(2)]]; constant uint *values [[id(3)]]; };\n"
            "kernel void mixed(constant Args &a [[buffer(0)]], device uint4 *out [[buffer(1)]], uint tid [[thread_position_in_grid]]) {\n"
            " float4 p=a.image.sample(a.filter,float2(0.25,0.5));\n"
            " uint input=a.values[tid]; uint transformed=(input*17u)^0x5a5a1234u;\n"
            " out[tid]=uint4(transformed,uint(p.r*255.0+0.5),uint(p.b*255.0+0.5),tid);\n"
            " atomic_fetch_add_explicit(a.count,1u,memory_order_relaxed); }\n";
        id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> function=[library newFunctionWithName:@"mixed"];
        id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
        if (!pipeline) {fprintf(stderr,"argument pipeline failed: %s\n",error.localizedDescription.UTF8String);return 2;}
        id<MTLArgumentEncoder> arguments=[function newArgumentEncoderWithBufferIndex:0];
        uint32_t inputs[256]; for(unsigned i=0;i<256;++i)inputs[i]=i*31+7;
        id<MTLBuffer> input=[device newBufferWithBytes:inputs length:sizeof(inputs) options:MTLResourceStorageModeShared];
        id<MTLBuffer> count=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> output=[device newBufferWithLength:256*16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> encoded=[device newBufferWithLength:arguments.encodedLength options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:1 mipmapped:NO];
        td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td];
        MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
        sd.supportArgumentBuffers=YES;
        sd.minFilter=MTLSamplerMinMagFilterNearest;sd.magFilter=MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:sd];
        if (!queue || !arguments || !input || !count || !output || !encoded || !texture || !sampler)return 3;
        uint8_t pixels[]={255,0,0,255,0,0,255,255};
        [texture replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:pixels bytesPerRow:8];
        memset(count.contents,0,16);memset(output.contents,0,256*16);
        [arguments setArgumentBuffer:encoded offset:0];
        [arguments setTexture:texture atIndex:0];[arguments setSamplerState:sampler atIndex:1];
        [arguments setBuffer:count offset:0 atIndex:2];[arguments setBuffer:input offset:0 atIndex:3];
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLComputeCommandEncoder> compute=[command computeCommandEncoder];
        [compute setComputePipelineState:pipeline];
        [compute setBuffer:encoded offset:0 atIndex:0];[compute setBuffer:output offset:0 atIndex:1];
        [compute useResource:texture usage:MTLResourceUsageRead];
        [compute useResource:input usage:MTLResourceUsageRead];
        [compute useResource:count usage:MTLResourceUsageRead|MTLResourceUsageWrite];
        [compute dispatchThreadgroups:MTLSizeMake(4,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
        [compute endEncoding];[command commit];[command waitUntilCompleted];
        const uint32_t *actual=output.contents;unsigned checked=0, laneMatches[4]={0};
        for(unsigned i=0;i<256;++i) {
            uint32_t expected[]={((inputs[i]*17u)^0x5a5a1234u),255,0,i};
            for(unsigned n=0;n<4;++n) {BOOL match=actual[i*4+n]==expected[n];checked+=match;laneMatches[n]+=match;}
        }
        unsigned atomicCount=*(const uint32_t *)count.contents;
        BOOL passed=checked==1024 && atomicCount==256 && command.status==MTLCommandBufferStatusCompleted;
        NSDictionary *result=@{@"stage":@"mixed-argument-buffer",@"passed":@(passed),@"checked":@(checked),
            @"expectedValues":@1024,@"atomicCount":@(atomicCount),@"encodedLength":@(arguments.encodedLength),
            @"commandCompleted":@(command.status==MTLCommandBufferStatusCompleted),
            @"laneMatches":@[@(laneMatches[0]),@(laneMatches[1]),@(laneMatches[2]),@(laneMatches[3])],
            @"firstOutput":@[@(actual[0]),@(actual[1]),@(actual[2]),@(actual[3])],
            @"argumentWords":@[@(((const uint64_t *)encoded.contents)[0]),@(((const uint64_t *)encoded.contents)[1]),
                @(((const uint64_t *)encoded.contents)[2]),@(((const uint64_t *)encoded.contents)[3])],
            @"inputGpuAddress":@(input.gpuAddress),@"countGpuAddress":@(count.gpuAddress),
            @"textureResourceId":@(texture.gpuResourceID._impl),@"samplerResourceId":@(sampler.gpuResourceID._impl),
            @"argumentBufferTier":@(device.argumentBuffersSupport)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
        return passed?0:4;
    }
}
