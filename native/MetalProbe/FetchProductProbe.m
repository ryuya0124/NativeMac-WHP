#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Authored regression: ordered framebuffer fetch plus a fixed-function product
// into a half-float target. The result is compared byte for byte across devices.
static NSString *const source = @
"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 probe_triangle(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],0.5,1); }\n"
"struct F {float4 a [[color(0)]];float4 b [[color(1)]];float4 c [[color(2)]];};\n"
"fragment F product_float(float4 d [[color(1)]],float4 p [[position]],constant float4 *s [[buffer(0)]]) {F o;o.a=float4(0);o.b=float4(d.x*s[uint(p.x)].x,d.y*s[uint(p.x)].y,0.25,0.75);o.c=float4(0);return o;}\n"
"struct H {half4 a [[color(0)]];half4 b [[color(1)]];half4 c [[color(2)]];};\n"
"fragment H product_half(half4 d [[color(1)]],float4 p [[position]],constant float4 *s [[buffer(0)]]) {H o;o.a=half4(0);o.b=half4(d.x*half(s[uint(p.x)].x),d.y*half(s[uint(p.x)].y),half(0.25),half(0.75));o.c=half4(0);return o;}\n"
"struct H2 {half4 a [[color(0)]];half2 b [[color(1)]];half4 c [[color(2)]];};\n"
"fragment H2 product_half2(half2 d [[color(1)]],float4 p [[position]],constant float4 *s [[buffer(0)]]) {H2 o;o.a=half4(0);o.b=d*half2(s[uint(p.x)].xy);o.c=half4(0);return o;}\n"
"struct F2 {float4 a [[color(0)]];float2 b [[color(1)]];float4 c [[color(2)]];};\n"
"fragment F2 product_float2(float2 d [[color(1)]],float4 p [[position]],constant float4 *s [[buffer(0)]]) {F2 o;o.a=float4(0);o.b=d*s[uint(p.x)].xy;o.c=float4(0);return o;}\n";

int main(void) {@autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSError *error=nil;MTLCompileOptions *options=[MTLCompileOptions new];options.mathMode=MTLMathModeFast;
    id<MTLLibrary> library=[device newLibraryWithSource:source options:options error:&error];
    if(!library){fprintf(stderr,"compile: %s\n",error.description.UTF8String);return 1;}
    id<MTLCommandQueue> queue=[device newCommandQueue];NSMutableArray *results=[NSMutableArray array];
    const unsigned width=16;
    const float values[16]={0,1,-1,0.5f,0.333251953125f,2,-2,0.001f,0.00006103515625f,0.000000059604644775390625f,8,-8,31.984375f,0.99951171875f,1.0009765625f,0.125f};
    float factors[16][4];for(unsigned i=0;i<width;i++){factors[i][0]=values[(i+3)%width];factors[i][1]=values[(i+7)%width];factors[i][2]=0;factors[i][3]=1;}
    id<MTLBuffer> input=[device newBufferWithBytes:factors length:sizeof(factors) options:MTLResourceStorageModeShared];
    for(NSNumber *formatNumber in @[@(MTLPixelFormatR16Float),@(MTLPixelFormatRG16Float),@(MTLPixelFormatRGBA16Float)]) {
      MTLPixelFormat format=formatNumber.unsignedIntegerValue;unsigned lanes=format==MTLPixelFormatR16Float?1:format==MTLPixelFormatRG16Float?2:4;
      NSArray *functions=format==MTLPixelFormatRG16Float?@[@"product_half",@"product_float",@"product_half2",@"product_float2"]:@[@"product_half",@"product_float"];
      for(NSString *name in functions) for(NSNumber *maskNumber in @[@(MTLColorWriteMaskAll),@(MTLColorWriteMaskRed)]) {
        MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:1 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        id<MTLTexture> target=[device newTextureWithDescriptor:td];
        _Float16 initial[16*4];for(unsigned i=0;i<width;i++)for(unsigned c=0;c<lanes;c++)initial[i*lanes+c]=(_Float16)values[(i+c)%width];
        [target replaceRegion:MTLRegionMake2D(0,0,width,1) mipmapLevel:0 withBytes:initial bytesPerRow:width*lanes*2];
        MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[library newFunctionWithName:@"probe_triangle"];pd.fragmentFunction=[library newFunctionWithName:name];
        for(unsigned c=0;c<3;c++){pd.colorAttachments[c].pixelFormat=c==1?format:MTLPixelFormatBGRA8Unorm;pd.colorAttachments[c].writeMask=c==1?maskNumber.unsignedIntegerValue:MTLColorWriteMaskNone;}
        pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
        MTLRenderPipelineColorAttachmentDescriptor *ca=pd.colorAttachments[1];ca.blendingEnabled=YES;ca.sourceRGBBlendFactor=MTLBlendFactorDestinationColor;ca.destinationRGBBlendFactor=MTLBlendFactorZero;ca.sourceAlphaBlendFactor=MTLBlendFactorDestinationAlpha;ca.destinationAlphaBlendFactor=MTLBlendFactorZero;
        id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error];
        if(!pipeline){fprintf(stderr,"pipeline %lu %s: %s\n",(unsigned long)format,name.UTF8String,error.description.UTF8String);return 2;}
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        for(unsigned c=0;c<3;c++){id<MTLTexture> color=target;if(c!=1){MTLTextureDescriptor *other=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:1 mipmapped:NO];other.usage=MTLTextureUsageRenderTarget;color=[device newTextureWithDescriptor:other];}pass.colorAttachments[c].texture=color;pass.colorAttachments[c].loadAction=c==1?MTLLoadActionLoad:MTLLoadActionClear;pass.colorAttachments[c].storeAction=MTLStoreActionStore;}
        MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:width height:1 mipmapped:NO];dd.storageMode=MTLStorageModePrivate;dd.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> depth=[device newTextureWithDescriptor:dd];pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.clearDepth=1;pass.stencilAttachment.texture=depth;pass.stencilAttachment.loadAction=MTLLoadActionClear;
        id<MTLCommandBuffer> command=[queue commandBuffer];id<MTLRenderCommandEncoder> render=[command renderCommandEncoderWithDescriptor:pass];[render setRenderPipelineState:pipeline];[render setFragmentBuffer:input offset:0 atIndex:0];[render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[render endEncoding];
        id<MTLBuffer> output=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];[blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,1,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:0];[blit endEncoding];[command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted){fprintf(stderr,"command: %s\n",command.error.description.UTF8String);return 3;}
        NSMutableString *hex=[NSMutableString string];const uint8_t *bytes=output.contents;for(unsigned i=0;i<width*lanes*2;i++)[hex appendFormat:@"%02x",bytes[i]];
        [results addObject:@{@"format":formatNumber,@"function":name,@"mask":maskNumber,@"hex":hex}];
      }
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"device":device.name,@"cases":results} options:NSJSONWritingPrettyPrinted error:&error];fwrite(json.bytes,1,json.length,stdout);puts("");return 0;
}}
