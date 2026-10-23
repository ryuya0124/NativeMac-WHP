#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Each invocation submits one authored operation and checks its GPU output.
// Allocation/selector presence alone never counts as successful execution.
static NSMutableDictionary *result;
static BOOL completed(id<MTLCommandBuffer> command) {
    [command commit];[command waitUntilCompleted];
    result[@"commandCompleted"]=@(command.status==MTLCommandBufferStatusCompleted);
    if(command.error)result[@"error"]=command.error.localizedDescription;
    return command.status==MTLCommandBufferStatusCompleted;
}
static BOOL textureTransfer(id<MTLDevice> device,id<MTLCommandQueue> queue,NSString *name) {
    NSDictionary *formats=@{@"r8":@[@(MTLPixelFormatR8Unorm),@1],@"rg8":@[@(MTLPixelFormatRG8Unorm),@2],
        @"rgba8":@[@(MTLPixelFormatRGBA8Unorm),@4],@"bgra8":@[@(MTLPixelFormatBGRA8Unorm),@4],
        @"r32uint":@[@(MTLPixelFormatR32Uint),@4],@"rgba8uint":@[@(MTLPixelFormatRGBA8Uint),@4],
        @"r32float":@[@(MTLPixelFormatR32Float),@4],@"rgba16float":@[@(MTLPixelFormatRGBA16Float),@8],
        @"rgba32float":@[@(MTLPixelFormatRGBA32Float),@16]};
    NSArray *format=formats[name];if(!format)return NO;
    NSUInteger bpp=[format[1] unsignedIntegerValue],stride=256,size=stride*16;
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:[format[0] unsignedIntegerValue]
        width:16 height:16 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> texture=[device newTextureWithDescriptor:td];result[@"allocated"]=@(texture!=nil);
    if(!texture)return NO;
    id<MTLBuffer> input=[device newBufferWithLength:size options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:size options:MTLResourceStorageModeShared];
    if(!input || !output)return NO;
    for(NSUInteger i=0;i<size;++i)((uint8_t*)input.contents)[i]=(uint8_t)(i*31+i/stride+7);
    memset(output.contents,0,size);
    id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:stride sourceBytesPerImage:size sourceSize:MTLSizeMake(16,16,1)
        toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:size];
    [blit endEncoding];BOOL done=completed(command);NSUInteger wrong=0;
    for(NSUInteger y=0;y<16;++y)for(NSUInteger x=0;x<16*bpp;++x)
        wrong+=((uint8_t*)input.contents)[y*stride+x]!=((uint8_t*)output.contents)[y*stride+x];
    result[@"checkedBytes"]=@(16*16*bpp);result[@"mismatches"]=@(wrong);return done && !wrong;
}
static BOOL synchronization(id<MTLDevice> device,id<MTLCommandQueue> queue,BOOL sharedEvent) {
    id<MTLBuffer> input=[device newBufferWithLength:4096 options:MTLResourceStorageModePrivate|MTLResourceHazardTrackingModeUntracked];
    id<MTLBuffer> output=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if(!input || !output)return NO;memset(output.contents,0,4096);
    id<MTLFence> fence=sharedEvent?nil:[device newFence];
    id<MTLSharedEvent> event=sharedEvent?[device newSharedEvent]:nil;
    result[@"allocated"]=@(sharedEvent?event!=nil:fence!=nil);if(!fence && !event)return NO;
    id<MTLCommandBuffer> first=[queue commandBuffer];id<MTLBlitCommandEncoder> write=[first blitCommandEncoder];
    [write fillBuffer:input range:NSMakeRange(0,4096) value:0x5a];if(fence)[write updateFence:fence];[write endEncoding];
    id<MTLCommandBuffer> last=first;
    if(event){[first encodeSignalEvent:event value:1];[first commit];last=[[device newCommandQueue] commandBuffer];[last encodeWaitForEvent:event value:1];}
    id<MTLBlitCommandEncoder> read=[last blitCommandEncoder];if(fence)[read waitForFence:fence];
    [read copyFromBuffer:input sourceOffset:0 toBuffer:output destinationOffset:0 size:4096];[read endEncoding];
    BOOL done=completed(last);NSUInteger wrong=0;
    for(NSUInteger i=0;i<4096;++i)wrong+=((uint8_t*)output.contents)[i]!=0x5a;
    result[@"checkedBytes"]=@4096;result[@"mismatches"]=@(wrong);return done && !wrong;
}
static BOOL draw(id<MTLDevice> device,id<MTLCommandQueue> queue,NSString *mode) {
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0,1);}\n"
        "fragment float4 f(){return float4(0.25,0.5,0.75,1);}";
    NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[library newFunctionWithName:@"v"];
    pd.fragmentFunction=[library newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    pd.supportIndirectCommandBuffers=[mode isEqualToString:@"icb"];
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    if(!pipeline){result[@"error"]=error.localizedDescription?:@"pipeline unavailable";return NO;}
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> texture=[device newTextureWithDescriptor:td];
    id<MTLBuffer> output=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if(!texture || !output)return NO;memset(output.contents,0,4096);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];
    if([mode isEqualToString:@"icb"]){
        MTLIndirectCommandBufferDescriptor *descriptor=[MTLIndirectCommandBufferDescriptor new];
        descriptor.commandTypes=MTLIndirectCommandTypeDraw;descriptor.inheritPipelineState=NO;
        descriptor.inheritBuffers=YES;descriptor.maxVertexBufferBindCount=0;descriptor.maxFragmentBufferBindCount=0;
        id<MTLIndirectCommandBuffer> buffer=[device newIndirectCommandBufferWithDescriptor:descriptor maxCommandCount:1 options:MTLResourceStorageModeShared];
        result[@"allocated"]=@(buffer!=nil);if(!buffer){[render endEncoding];return NO;}
        id<MTLIndirectRenderCommand> indirect=[buffer indirectRenderCommandAtIndex:0];
        [indirect setRenderPipelineState:pipeline];[indirect drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:0];
        [render executeCommandsInBuffer:buffer withRange:NSMakeRange(0,1)];
    }else{
        [render setRenderPipelineState:pipeline];
        if([mode isEqualToString:@"indirect-draw"]){
            MTLDrawPrimitivesIndirectArguments args={3,1,0,0};
            id<MTLBuffer> arguments=[device newBufferWithBytes:&args length:sizeof(args) options:MTLResourceStorageModeShared];
            [render drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:arguments indirectBufferOffset:0];
        }else [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [render endEncoding];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:4096];[blit endEncoding];
    BOOL done=completed(command);NSUInteger wrong=0;uint8_t expected[]={191,128,64,255};
    for(NSUInteger y=0;y<16;++y)for(NSUInteger x=0;x<16;++x)for(unsigned c=0;c<4;++c)
        wrong+=abs(((uint8_t*)output.contents)[y*256+x*4+c]-expected[c])>1;
    result[@"checkedValues"]=@1024;result[@"mismatches"]=@(wrong);return done && !wrong;
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;NSString *name=@(argv[1]);result=[@{@"case":name} mutableCopy];
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];BOOL passed=NO;
    @try{
        if(device && queue){
            if([name hasPrefix:@"texture-"])passed=textureTransfer(device,queue,[name substringFromIndex:8]);
            else if([name isEqualToString:@"fence"] || [name isEqualToString:@"shared-event"])passed=synchronization(device,queue,[name isEqualToString:@"shared-event"]);
            else if([@[@"draw",@"indirect-draw",@"icb"] containsObject:name])passed=draw(device,queue,name);
        }
    }@catch(NSException *exception){result[@"exception"]=exception.reason?:exception.name;}
    result[@"passed"]=@(passed);NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:2;
}}
