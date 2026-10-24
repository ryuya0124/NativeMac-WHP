#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#import <dispatch/dispatch.h>

struct CompletionCounts { atomic_uint finished; atomic_uint errors; };

// Authored diagnostic workload, not a commercial benchmark score. Indexed,
// instanced, textured cubes use a depth buffer. Modes isolate private/shared
// targets, drawable acquisition and presentation. The optional -pipelined suffix
// bounds in-flight work at three; all final counts come from completed commands.
// These are completed-command rates, not physical display-frame measurements.
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

static int compareSample(const void *a, const void *b) {
    double x=*(const double *)a, y=*(const double *)b; return (x>y)-(x<y);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        double duration = argc > 1 ? strtod(argv[1], NULL) : 30;
        if (!isfinite(duration) || duration < 1 || duration > 1800) return 64;
        unsigned width = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 10) : 1920;
        unsigned height = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 10) : 1080;
        if (!((width == 1920 && height == 1080) ||
              (width == 3840 && height == 2160))) return 64;
        const char *mode=argc>4 ? argv[4] : "drawable";
        BOOL sharedOffscreen=strcmp(mode,"offscreen-shared")==0 || strcmp(mode,"offscreen-shared-pipelined")==0;
        BOOL managedOffscreen=strcmp(mode,"offscreen-managed")==0 || strcmp(mode,"offscreen-managed-pipelined")==0;
        BOOL offscreen=strcmp(mode,"offscreen")==0 || strcmp(mode,"offscreen-pipelined")==0 || sharedOffscreen || managedOffscreen;
        BOOL noPresent=strcmp(mode,"drawable-no-present")==0 || strcmp(mode,"drawable-no-present-pipelined")==0;
        BOOL presenting=strcmp(mode,"drawable")==0 || strcmp(mode,"drawable-pipelined")==0;
        if (!offscreen && !presenting && !noPresent) return 64;
        BOOL pipelined=strstr(mode,"-pipelined")!=NULL;
        if (!offscreen) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
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
            width:width height:height mipmapped:NO];
        dt.storageMode=MTLStorageModePrivate; dt.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> depth = [device newTextureWithDescriptor:dt];
        if (!vb || !ib || !witness || !texture || !depth || !depthState) return 4;
        MTLTextureDescriptor *colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        colorDescriptor.storageMode=sharedOffscreen ? MTLStorageModeShared : managedOffscreen ? MTLStorageModeManaged : MTLStorageModePrivate;
        colorDescriptor.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> offscreenTarget = offscreen ? [device newTextureWithDescriptor:colorDescriptor] : nil;
        if (offscreen && !offscreenTarget) return 4;
        NSWindow *window = nil;
        CAMetalLayer *layer = nil;
        if (!offscreen) {
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40,80,960,540)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed=NO;
        window.title=[NSString stringWithFormat:@"NativeMac Metal 3D: 441 textured cubes / %u x %u",width,height];
        layer=[CAMetalLayer layer];
        layer.device=device; layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly=NO; layer.displaySyncEnabled=NO; layer.allowsNextDrawableTimeout=YES;
        window.contentView.wantsLayer=YES; window.contentView.layer=layer;
        layer.drawableSize=CGSizeMake(width,height);
        [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        }
        printf("{\"presentation\":\"%s\"}\n",mode);
        double start=CACurrentMediaTime(), previous=start, report=start, worst=0;
        unsigned completed=0, failures=0; BOOL checked=NO;
        double totals[9]={0}, samples[9][8192]={0}, measuredWall=0;
        unsigned measured=0;
        struct CompletionCounts completionCounts;
        atomic_init(&completionCounts.finished,0);atomic_init(&completionCounts.errors,0);
        struct CompletionCounts *counts=&completionCounts;
        dispatch_semaphore_t slots=dispatch_semaphore_create(3);
        printf("{\"stage\":\"scene-start\",\"width\":%u,\"height\":%u,\"instances\":441,\"trianglesPerFrame\":5292}\n",width,height); fflush(stdout);
        while ((offscreen || window.visible) && CACurrentMediaTime()-start<duration) {
            double frameStart=CACurrentMediaTime(), phase[9]={0}, poolEnd=0;
            BOOL measure=frameStart-start>=2;
            if(pipelined) {
                if(dispatch_semaphore_wait(slots,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))) {failures++;break;}
                phase[8]=CACurrentMediaTime()-frameStart;
            }
            @autoreleasepool {
                double mark=CACurrentMediaTime();
                NSEvent *event;
                while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                    inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
                [NSApp updateWindows];
                double checkpoint=CACurrentMediaTime();phase[0]=checkpoint-mark;mark=checkpoint;
                id<CAMetalDrawable> drawable=offscreen ? nil : [layer nextDrawable];
                id<MTLTexture> target=offscreen ? offscreenTarget : drawable.texture;
                if (!target) { if(pipelined)dispatch_semaphore_signal(slots); failures++; break; }
                if (target.width!=width || target.height!=height) {
                    fprintf(stderr,"unexpected drawable size: %lux%lu\n",(unsigned long)target.width,(unsigned long)target.height);
                    if(pipelined)dispatch_semaphore_signal(slots); failures++; break;
                }
                if (!checked) {
                    printf("{\"stage\":\"target-info\",\"storageMode\":%lu,\"usage\":%lu,\"pixelFormat\":%lu,\"maxInflight\":%u}\n",
                        (unsigned long)target.storageMode,(unsigned long)target.usage,
                        (unsigned long)target.pixelFormat,pipelined?3:1);
                }
                checkpoint=CACurrentMediaTime();phase[1]=checkpoint-mark;mark=checkpoint;
                MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture=target;
                pass.colorAttachments[0].loadAction=MTLLoadActionClear;
                pass.colorAttachments[0].storeAction=MTLStoreActionStore;
                pass.colorAttachments[0].clearColor=MTLClearColorMake(0.015,0.02,0.035,1);
                pass.depthAttachment.texture=depth; pass.depthAttachment.loadAction=MTLLoadActionClear;
                pass.depthAttachment.storeAction=MTLStoreActionDontCare; pass.depthAttachment.clearDepth=1;
                id<MTLCommandBuffer> command=[queue commandBuffer];
                id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
                if (!command || !encoder) { if(pipelined)dispatch_semaphore_signal(slots); failures++; break; }
                const float uniforms[4]={(float)(CACurrentMediaTime()-start),(float)width/(float)height,21,0};
                [encoder setRenderPipelineState:pipeline]; [encoder setDepthStencilState:depthState];
                [encoder setVertexBuffer:vb offset:0 atIndex:0];
                [encoder setVertexBytes:uniforms length:sizeof(uniforms) atIndex:1];
                [encoder setFragmentTexture:texture atIndex:0];
                [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:36 indexType:MTLIndexTypeUInt16
                    indexBuffer:ib indexBufferOffset:0 instanceCount:441];
                [encoder endEncoding];
                if (!checked) {
                    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
                    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(width/2,height/2,0)
                        sourceSize:MTLSizeMake(1,1,1) toBuffer:witness destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
                    [blit endEncoding];
                }
                if(pipelined) [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
                    if(done.status!=MTLCommandBufferStatusCompleted)atomic_fetch_add(&counts->errors,1);
                    atomic_fetch_add(&counts->finished,1);
                    dispatch_semaphore_signal(slots);
                }];
                checkpoint=CACurrentMediaTime();phase[2]=checkpoint-mark;mark=checkpoint;
                if (presenting) [command presentDrawable:drawable];
                checkpoint=CACurrentMediaTime();phase[3]=checkpoint-mark;mark=checkpoint;
                [command commit];
                checkpoint=CACurrentMediaTime();phase[4]=checkpoint-mark;mark=checkpoint;
                if(!pipelined || !checked) [command waitUntilCompleted];
                checkpoint=CACurrentMediaTime();phase[5]=checkpoint-mark;
                double reported=pipelined ? 0 : command.GPUEndTime-command.GPUStartTime;
                phase[7]=isfinite(reported)&&reported>=0 ? reported : 0;
                if ((!pipelined || !checked) && command.status!=MTLCommandBufferStatusCompleted) {
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
                    unsigned finished=pipelined?atomic_load(&counts->finished):completed;
                    printf("{\"elapsed\":%.3f,\"completed\":%u,\"submitted\":%u,\"meanFps\":%.2f,\"maxGapMs\":%.2f}\n",now-start,finished,completed,finished/(now-start),worst*1000);
                    fflush(stdout); report=now;
                }
                poolEnd=CACurrentMediaTime();
            }
            double frameEnd=CACurrentMediaTime();
            phase[6]=frameEnd-poolEnd;
            if (measure) {
                measuredWall+=frameEnd-frameStart;
                for(unsigned leg=0;leg<9;leg++) {
                    totals[leg]+=phase[leg];
                    if(measured<8192)samples[leg][measured]=phase[leg];
                }
                measured++;
            }
        }
        if(pipelined) {
            for(unsigned i=0;i<3;i++) {
                if(dispatch_semaphore_wait(slots,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))) {
                    fprintf(stderr,"pipeline drain timed out\n");fflush(stdout);_Exit(124);
                }
            }
            completed=atomic_load(&counts->finished);failures+=atomic_load(&counts->errors);
            // Restore all permits before disposing the semaphore, as libdispatch requires.
            for(unsigned i=0;i<3;i++)dispatch_semaphore_signal(slots);
        }
        if (measured) {
            const char *names[]={"events","acquire","encode","presentCall","commit","completionWait","poolDrain","driverReportedGpu","inflightSlotWait"};
            printf("{\"stage\":\"phase-times\",\"mode\":\"%s\",\"warmupSeconds\":2,\"frames\":%u,\"loopMeanMs\":%.6f,\"legs\":[",mode,measured,measuredWall*1000/measured);
            unsigned n=MIN(measured,8192u);
            for(unsigned leg=0;leg<9;leg++) {
                qsort(samples[leg],n,sizeof(double),compareSample);
                printf("%s{\"name\":\"%s\",\"meanMs\":%.6f,\"p95Ms\":%.6f}",leg?",":"",names[leg],totals[leg]*1000/measured,samples[leg][(n-1)*95/100]*1000);
            }
            printf("]}\n");
        }
        double elapsed=CACurrentMediaTime()-start;
        printf("{\"stage\":\"scene-final\",\"elapsed\":%.3f,\"completed\":%u,\"meanFps\":%.2f,\"errors\":%u,\"readbackPassed\":%s}\n",elapsed,completed,completed/MAX(elapsed,0.001),failures,checked?"true":"false");
        [window orderOut:nil]; return failures||!checked ? 5 : 0;
    }
}
