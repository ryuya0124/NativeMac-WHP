#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <math.h>

// Authored diagnostic workload, not a commercial benchmark score. Indexed,
// instanced, textured cubes use a depth buffer and real GPU drawable presentation.
static NSString *const shader = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Out { float4 p [[position]]; float2 uv; float3 n; };\n"
"vertex Out scene_vertex(uint v [[vertex_id]], uint i [[instance_id]],\n"
" constant float4 *vertices [[buffer(0)]], constant float4 &u [[buffer(1)]]) {\n"
" float3 p=vertices[v].xyz; float a=u.x+float(i)*0.071;\n"
" float c=cos(a), s=sin(a); float3 q=float3(c*p.x+s*p.z,p.y,-s*p.x+c*p.z);\n"
" float b=u.x*0.73; float cb=cos(b), sb=sin(b);\n"
" q=float3(q.x,cb*q.y-sb*q.z,sb*q.y+cb*q.z);\n"
" uint grid=uint(u.z); float step=14.0/float(grid);\n"
" float2 xy=(float2(i%grid,i/grid)-float(grid-1)*0.5)*step;\n"
" float3 world=q*step*0.37+float3(xy,-16.0);\n"
" Out o; o.p=float4(world.x*1.7/u.y,world.y*1.7,-1.001001*world.z-0.1001001,-world.z);\n"
" o.uv=p.xy*0.5+0.5; o.n=q; return o; }\n"
"fragment float4 scene_fragment(Out in [[stage_in]], texture2d<float> image [[texture(0)]]) {\n"
" constexpr sampler samp(coord::normalized,address::repeat,filter::linear);\n"
" float light=0.3+0.7*abs(dot(normalize(in.n),normalize(float3(0.3,0.7,1.0))));\n"
" return float4(image.sample(samp,in.uv).rgb*light,1.0); }\n";

int main(int argc, const char **argv) {
    @autoreleasepool {
        double duration = argc > 1 ? strtod(argv[1], NULL) : 30;
        if (!isfinite(duration) || duration < 1 || duration > 1800) return 64;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:&error];
        if (!library || !queue) { fprintf(stderr,"library: %s\n",error.description.UTF8String); return 2; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [library newFunctionWithName:@"scene_vertex"];
        pd.fragmentFunction = [library newFunctionWithName:@"scene_fragment"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) { fprintf(stderr,"pipeline: %s\n",error.description.UTF8String); return 3; }
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionLess;
        dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:dd];
        const float vertices[8][4] = {
            {-1,-1,-1,1},{1,-1,-1,1},{1,1,-1,1},{-1,1,-1,1},
            {-1,-1,1,1},{1,-1,1,1},{1,1,1,1},{-1,1,1,1}};
        const uint16_t indices[] = {0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,
            3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5};
        id<MTLBuffer> vb = [device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
        id<MTLBuffer> ib = [device newBufferWithBytes:indices length:sizeof(indices) options:MTLResourceStorageModeShared];
        id<MTLBuffer> witness = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
            width:64 height:64 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        uint8_t pixels[64*64*4];
        for (unsigned y=0;y<64;y++) for(unsigned x=0;x<64;x++) {
            unsigned at=(y*64+x)*4; BOOL bright=((x/8+y/8)%2)==0;
            pixels[at]=bright?240:70; pixels[at+1]=bright?170:130; pixels[at+2]=bright?60:240; pixels[at+3]=255;
        }
        [texture replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:pixels bytesPerRow:256];
        MTLTextureDescriptor *dt = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
            width:1920 height:1080 mipmapped:NO];
        dt.storageMode=MTLStorageModePrivate; dt.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> depth = [device newTextureWithDescriptor:dt];
        if (!vb || !ib || !witness || !texture || !depth || !depthState) return 4;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40,80,960,540)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed=NO;
        window.title=@"NativeMac Metal 3D: 441 textured cubes / FHD";
        CAMetalLayer *layer=[CAMetalLayer layer];
        layer.device=device; layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly=NO; layer.displaySyncEnabled=NO; layer.allowsNextDrawableTimeout=YES;
        window.contentView.wantsLayer=YES; window.contentView.layer=layer;
        layer.drawableSize=CGSizeMake(1920,1080);
        [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        double start=CACurrentMediaTime(), previous=start, report=start, worst=0;
        unsigned completed=0, failures=0; BOOL checked=NO;
        printf("{\"stage\":\"scene-start\",\"width\":1920,\"height\":1080,\"instances\":441,\"trianglesPerFrame\":5292}\n"); fflush(stdout);
        while (window.visible && CACurrentMediaTime()-start<duration) {
            @autoreleasepool {
                NSEvent *event;
                while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                    inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
                [NSApp updateWindows];
                id<CAMetalDrawable> drawable=[layer nextDrawable];
                if (!drawable) { failures++; break; }
                if (drawable.texture.width!=1920 || drawable.texture.height!=1080) {
                    fprintf(stderr,"unexpected drawable size: %lux%lu\n",(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height);
                    failures++; break;
                }
                MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture=drawable.texture;
                pass.colorAttachments[0].loadAction=MTLLoadActionClear;
                pass.colorAttachments[0].storeAction=MTLStoreActionStore;
                pass.colorAttachments[0].clearColor=MTLClearColorMake(0.015,0.02,0.035,1);
                pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
                pass.depthAttachment.storeAction=MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
                id<MTLCommandBuffer> command=[queue commandBuffer];
                id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
                if (!command || !encoder) { failures++; break; }
                const float uniforms[4]={(float)(CACurrentMediaTime()-start),1920.0f/1080.0f,21,0};
                [encoder setRenderPipelineState:pipeline]; [encoder setDepthStencilState:depthState];
                [encoder setVertexBuffer:vb offset:0 atIndex:0];
                [encoder setVertexBytes:uniforms length:sizeof(uniforms) atIndex:1];
                [encoder setFragmentTexture:texture atIndex:0];
                [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:36 indexType:MTLIndexTypeUInt16
                    indexBuffer:ib indexBufferOffset:0 instanceCount:441];
                [encoder endEncoding];
                if (!checked) {
                    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
                    [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(960,540,0)
                        sourceSize:MTLSizeMake(1,1,1) toBuffer:witness destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
                    [blit endEncoding];
                }
                [command presentDrawable:drawable]; [command commit];
                [command waitUntilCompleted];
                if (command.status!=MTLCommandBufferStatusCompleted) {
                    fprintf(stderr,"command: %s\n",command.error.description.UTF8String); failures++; break;
                }
                if (!checked) {
                    const uint8_t *p=witness.contents;
                    checked=p[3]==255 && MAX(p[0],MAX(p[1],p[2]))>40;
                    printf("{\"stage\":\"render-readback\",\"bgra\":[%u,%u,%u,%u],\"passed\":%s}\n",p[0],p[1],p[2],p[3],checked?"true":"false");
                    fflush(stdout); if(!checked) { failures++; break; }
                }
                completed++; double now=CACurrentMediaTime(); worst=MAX(worst,now-previous); previous=now;
                if(now-report>=1) {
                    printf("{\"elapsed\":%.3f,\"completed\":%u,\"meanFps\":%.2f,\"maxGapMs\":%.2f}\n",now-start,completed,completed/(now-start),worst*1000);
                    fflush(stdout); report=now;
                }
            }
        }
        double elapsed=CACurrentMediaTime()-start;
        printf("{\"stage\":\"scene-final\",\"elapsed\":%.3f,\"completed\":%u,\"meanFps\":%.2f,\"errors\":%u,\"readbackPassed\":%s}\n",elapsed,completed,completed/MAX(elapsed,0.001),failures,checked?"true":"false");
        [window orderOut:nil]; return failures||!checked ? 5 : 0;
    }
}
