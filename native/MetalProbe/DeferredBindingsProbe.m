#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>

// Check independent deferred state and real, unchanged fragment sampling.
typedef BOOL (*Matches)(id, unsigned, NSUInteger, id, BOOL, float, float);
typedef unsigned long (*Counter)(void);
typedef BOOL (*TextureMatches)(id,unsigned,NSUInteger,id);
typedef BOOL (*BufferMatches)(id,unsigned,NSUInteger,id,NSUInteger);
typedef BOOL (*BytesMatch)(id,unsigned,NSUInteger,const void *,NSUInteger);

static BOOL expectRefusal(void (^operation)(void)) {
    @try { operation(); return NO; }
    @catch (NSException *e) { return [e.name isEqualToString:NSInvalidArgumentException]; }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL gpuIndirect = argc == 2 && strcmp(argv[1], "--gpu-indirect") == 0;
        BOOL cpuIndirect = argc == 2 && strcmp(argv[1], "--cpu-indirect") == 0;
        BOOL sharedReadback = argc == 2 && strcmp(argv[1], "--shared-cpu-readback") == 0;
        if (argc > 2 || (argc == 2 && !gpuIndirect && !cpuIndirect && !sharedReadback)) return 64;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        BOOL guest = [device.name containsString:@"Paravirt"];
        Matches matches = (Matches)dlsym(RTLD_DEFAULT, "NMDeferredSamplerMatches");
        Counter calls = (Counter)dlsym(RTLD_DEFAULT, "NMDeferredSamplerBindings");
        Counter refusals = (Counter)dlsym(RTLD_DEFAULT, "NMDeferredMeshRefusals");
        TextureMatches textureMatches = (TextureMatches)dlsym(RTLD_DEFAULT,"NMDeferredTextureMatches");
        BufferMatches bufferMatches = (BufferMatches)dlsym(RTLD_DEFAULT,"NMDeferredBufferMatches");
        BytesMatch bytesMatch = (BytesMatch)dlsym(RTLD_DEFAULT,"NMDeferredBytesMatch");
        if (!device || !queue || (guest && (!matches || !calls || !refusals || !textureMatches || !bufferMatches || !bytesMatch))) return 1;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
            "fragment float4 f(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s,float2(0.49,0.5)); }\n"
            "kernel void args(device uint *p [[buffer(0)]], uint tid [[thread_position_in_grid]]) { if(tid==0){p[0]=3;p[1]=1;p[2]=0;p[3]=0;p[4]=0;} }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [library newFunctionWithName:@"v"];
        pd.fragmentFunction = [library newFunctionWithName:@"f"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) { fprintf(stderr, "probe pipeline failed\n"); return 2; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatRGBA8Unorm width:2 height:1 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> sampled = [device newTextureWithDescriptor:td];
        id<MTLTexture> blue = [device newTextureWithDescriptor:td];
        uint8_t colors[] = {255,0,0,255, 0,0,255,255};
        uint8_t blueColors[] = {0,0,255,255, 0,0,255,255};
        [sampled replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:colors bytesPerRow:8];
        [blue replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:blueColors bytesPerRow:8];
        td.width = 4; td.height = 4; td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = sharedReadback ? MTLStorageModeShared : MTLStorageModePrivate;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = MTLSamplerMinMagFilterNearest; sd.magFilter = MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> nearest = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter = MTLSamplerMinMagFilterLinear; sd.magFilter = MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> linear = [device newSamplerStateWithDescriptor:sd];
        if (!sampled || !target || !nearest || !linear) return 3;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> command = [queue commandBuffer];
        uint32_t indexData[] = {0,1,2}, expectedArgs[] = {3,1,0,0,0};
        id<MTLBuffer> indices = [device newBufferWithBytes:indexData length:sizeof(indexData) options:MTLResourceStorageModeShared];
        id<MTLBuffer> arguments = [device newBufferWithLength:sizeof(expectedArgs) options:MTLResourceStorageModeShared];
        if (!indices || !arguments) return 8;
        memset(arguments.contents,0,sizeof(expectedArgs));
        if (cpuIndirect) memcpy(arguments.contents,expectedArgs,sizeof(expectedArgs));
        if (gpuIndirect) {
            id<MTLComputePipelineState> compute = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"args"] error:&error];
            if (!compute) return 9;
            id<MTLComputeCommandEncoder> prepass = [command computeCommandEncoder];
            [prepass setComputePipelineState:compute];
            [prepass setBuffer:arguments offset:0 atIndex:0];
            [prepass dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            [prepass endEncoding];
        }
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:sampled atIndex:0];
        [encoder setFragmentSamplerState:nearest atIndex:0];
        [encoder setObjectTexture:blue atIndex:0];
        [encoder setMeshTexture:blue atIndex:0];
        id<MTLTexture> textureArray[] = {sampled,nil,blue};
        [encoder setObjectTextures:textureArray withRange:NSMakeRange(12,3)];
        [encoder setMeshTextures:textureArray withRange:NSMakeRange(12,3)];
        id<MTLBuffer> storage = [device newBufferWithLength:128 options:MTLResourceStorageModeShared];
        if (!storage) return 7;
        [encoder setObjectBuffer:storage offset:0 atIndex:30];
        [encoder setMeshBuffer:storage offset:0 atIndex:30];
        [encoder setObjectBufferOffset:32 atIndex:30];
        [encoder setMeshBufferOffset:64 atIndex:30];
        id<MTLBuffer> bufferArray[] = {storage,nil};
        NSUInteger offsets[] = {16,0};
        [encoder setObjectBuffers:bufferArray offsets:offsets withRange:NSMakeRange(2,2)];
        [encoder setMeshBuffers:bufferArray offsets:offsets withRange:NSMakeRange(2,2)];
        uint32_t inlineData[] = {17,31,53,97}, savedData[] = {17,31,53,97};
        [encoder setObjectBytes:inlineData length:sizeof(inlineData) atIndex:4];
        [encoder setMeshBytes:inlineData length:sizeof(inlineData) atIndex:4];
        inlineData[0] = 0; // setBytes must copy rather than retain this pointer.
        [encoder setObjectThreadgroupMemoryLength:32 atIndex:0];
        [encoder setObjectSamplerState:linear atIndex:0];
        [encoder setMeshSamplerState:linear atIndex:0];
        [encoder setObjectSamplerState:nearest lodMinClamp:1 lodMaxClamp:3 atIndex:15];
        [encoder setMeshSamplerState:nearest lodMinClamp:2 lodMaxClamp:4 atIndex:15];
        id<MTLSamplerState> samplers[] = {linear, nil, nearest};
        float low[] = {0,1,2}, high[] = {3,4,5};
        [encoder setObjectSamplerStates:samplers withRange:NSMakeRange(5,3)];
        [encoder setMeshSamplerStates:samplers withRange:NSMakeRange(5,3)];
        [encoder setObjectSamplerStates:samplers lodMinClamps:low lodMaxClamps:high withRange:NSMakeRange(9,3)];
        [encoder setMeshSamplerStates:samplers lodMinClamps:low lodMaxClamps:high withRange:NSMakeRange(9,3)];
        BOOL state = !guest || (matches(encoder,0,0,linear,NO,0,0) && matches(encoder,1,0,linear,NO,0,0)
            && matches(encoder,0,15,nearest,YES,1,3) && matches(encoder,1,15,nearest,YES,2,4)
            && matches(encoder,0,6,nil,NO,0,0) && matches(encoder,1,7,nearest,NO,0,0)
            && matches(encoder,0,9,linear,YES,0,3) && matches(encoder,1,11,nearest,YES,2,5));
        state &= !guest || (textureMatches(encoder,0,0,blue) && textureMatches(encoder,1,0,blue)
            && textureMatches(encoder,0,13,nil) && textureMatches(encoder,1,14,blue)
            && bufferMatches(encoder,0,30,storage,32) && bufferMatches(encoder,1,30,storage,64)
            && bufferMatches(encoder,0,3,nil,0) && bufferMatches(encoder,1,2,storage,16)
            && bytesMatch(encoder,0,4,savedData,sizeof(savedData)) && bytesMatch(encoder,1,4,savedData,sizeof(savedData)));
        [encoder setObjectSamplerState:nil atIndex:15];
        [encoder setMeshSamplerState:nil atIndex:15];
        state &= !guest || (matches(encoder,0,15,nil,NO,0,0) && matches(encoder,1,15,nil,NO,0,0));
        // A second live encoder must have an independent binding table.
        id<MTLCommandBuffer> otherCommand = [queue commandBuffer];
        id<MTLRenderCommandEncoder> other = [otherCommand renderCommandEncoderWithDescriptor:pass];
        [other setObjectSamplerState:nearest atIndex:0];
        state &= !guest || (matches(other,0,0,nearest,NO,0,0) && matches(encoder,0,0,linear,NO,0,0));
        [other endEncoding]; [otherCommand commit]; [otherCommand waitUntilCompleted];
        if (cpuIndirect || gpuIndirect)
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt32
                indexBuffer:indices indexBufferOffset:0 indirectBuffer:arguments indirectBufferOffset:0];
        else [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        BOOL negative = YES;
        if (guest) {
            const id<MTLSamplerState> *samplerPointer = samplers;
            id<MTLBuffer> indirect = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            if (!indirect) return 5;
            negative &= expectRefusal(^{ [encoder setObjectSamplerState:nearest atIndex:16]; });
            negative &= expectRefusal(^{ [encoder setMeshSamplerStates:samplerPointer withRange:NSMakeRange(NSUIntegerMax,3)]; });
            negative &= expectRefusal(^{ [encoder setObjectTexture:blue atIndex:128]; });
            negative &= expectRefusal(^{ [encoder setMeshBuffer:storage offset:129 atIndex:0]; });
            negative &= expectRefusal(^{ [encoder setObjectBufferOffset:0 atIndex:0]; });
            negative &= expectRefusal(^{ [encoder setMeshBytes:"x" length:4097 atIndex:0]; });
            negative &= expectRefusal(^{ [encoder drawMeshThreadgroups:MTLSizeMake(1,1,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)]; });
            negative &= expectRefusal(^{ [encoder drawMeshThreads:MTLSizeMake(1,1,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)]; });
            negative &= expectRefusal(^{ [encoder drawMeshThreadgroupsWithIndirectBuffer:indirect indirectBufferOffset:0 threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)]; });
        }
        [encoder endEncoding];
        NSUInteger cpuPixels = 0;
        if (sharedReadback) {
            [command commit]; [command waitUntilCompleted];
            if (command.status != MTLCommandBufferStatusCompleted) return 10;
            uint8_t cpu[64] = {0};
            [target getBytes:cpu bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
            for (unsigned i=0; i<16; ++i)
                cpuPixels += cpu[i*4] == 255 && cpu[i*4+1] == 0 && cpu[i*4+2] == 0 && cpu[i*4+3] == 255;
            command = [queue commandBuffer];
        }
        id<MTLBuffer> readback = [device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
        if (!readback) return 6;
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(4,4,1) toBuffer:readback destinationOffset:0
            destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        const uint8_t *pixels = readback.contents;
        NSUInteger correct = 0;
        for (unsigned y=0; y<4; ++y) for (unsigned x=0; x<4; ++x) {
            unsigned i = y*256+x*4;
            correct += pixels[i] == 255 && pixels[i+1] == 0 && pixels[i+2] == 0 && pixels[i+3] == 255;
        }
        BOOL argumentsCorrect = (!cpuIndirect && !gpuIndirect) || memcmp(arguments.contents,expectedArgs,sizeof(expectedArgs)) == 0;
        BOOL passed = state && negative && correct == 16 && argumentsCorrect && (!sharedReadback || cpuPixels == 16)
            && command.status == MTLCommandBufferStatusCompleted;
        NSDictionary *result = @{@"stage":@"deferred-stage-samplers", @"passed":@(passed),
            @"stateIsolation":guest ? @(state) : [NSNull null], @"checkedPixels":@(correct),
            @"explicitRefusals":guest ? @(negative) : [NSNull null],
            @"bindings":@(calls ? calls() : 0), @"meshRefusals":@(refusals ? refusals() : 0),
            @"guestAdapter":@(guest), @"firstPixel":@[@(pixels[0]),@(pixels[1]),@(pixels[2]),@(pixels[3])],
            @"commandCompleted":@(command.status == MTLCommandBufferStatusCompleted),
            @"drawPath":gpuIndirect ? @"gpu-indirect" : cpuIndirect ? @"cpu-indirect" : sharedReadback ? @"shared-cpu-readback" : @"direct",
            @"sharedCpuReadbackPixels":sharedReadback ? @(cpuPixels) : [NSNull null],
            @"argumentsCorrect":@(argumentsCorrect)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes,1,data.length,stdout); putchar('\n');
        return passed ? 0 : 4;
    }
}
