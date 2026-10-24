#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#include <stdatomic.h>
#include <math.h>

// Authored two-stage/ping-pong prototype. Private intermediates have no CPU
// aliases; this does not change system IOSurface coherency or accelerate apps.
static NSString *const source=@
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; float2 uv; float3 n; };\n"
"vertex V scene(uint v [[vertex_id]], uint i [[instance_id]], constant float4 *vertices [[buffer(0)]]) {\n"
" float3 p=vertices[v].xyz; float a=0.73+float(i)*0.071; float c=cos(a),s=sin(a);\n"
" float3 q=float3(c*p.x+s*p.z,p.y,-s*p.x+c*p.z);\n"
" float cb=cos(0.5329),sb=sin(0.5329); q=float3(q.x,cb*q.y-sb*q.z,sb*q.y+cb*q.z);\n"
" float step=14.0/21.0; float2 xy=(float2(i%21,i/21)-10.0)*step;\n"
" float3 w=q*step*0.37+float3(xy,-16.0); V o;\n"
" o.p=float4(w.x*1.7/(16.0/9.0),w.y*1.7,-1.001001*w.z-0.1001001,-w.z);\n"
" o.uv=p.xy*0.5+0.5; o.n=q; return o; }\n"
"fragment float4 shade(V v [[stage_in]], texture2d<float> image [[texture(0)]]) {\n"
" constexpr sampler s(coord::normalized,address::repeat,filter::linear);\n"
" float light=0.3+0.7*abs(dot(normalize(v.n),normalize(float3(0.3,0.7,1.0))));\n"
" return float4(image.sample(s,v.uv).rgb*light,1); }\n"
"vertex float4 handoff_vertex(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
"fragment float4 handoff(float4 p [[position]], texture2d<float,access::read> image [[texture(0)]]) { return image.read(uint2(p.xy)); }\n";

struct Counts { atomic_uint finished, measured, errors; };

static id<MTLTexture> intermediate(id<MTLDevice> device,NSUInteger w,NSUInteger h,BOOL shared,IOSurfaceRef *surface) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;
    d.storageMode=MTLStorageModePrivate;
    if(!shared)return [device newTextureWithDescriptor:d];
#if defined(__arm64__) || defined(__aarch64__)
    d.storageMode=MTLStorageModeShared;
#else
    d.storageMode=MTLStorageModeManaged;
#endif
    *surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth:@(w),(__bridge NSString *)kIOSurfaceHeight:@(h),
        (__bridge NSString *)kIOSurfaceBytesPerElement:@4,(__bridge NSString *)kIOSurfaceBytesPerRow:@(w*4),
        (__bridge NSString *)kIOSurfaceAllocSize:@(w*h*4),(__bridge NSString *)kIOSurfacePixelFormat:@(0x42475241u)});
    return *surface ? [device newTextureWithDescriptor:d iosurface:*surface plane:0] : nil;
}

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=9 && argc!=10)return 64;
    double seconds=strtod(argv[1],NULL);
    NSUInteger width=strtoul(argv[2],NULL,10),height=strtoul(argv[3],NULL,10),passes=strtoul(argv[6],NULL,10);
    BOOL shared=strcmp(argv[4],"surface")==0,visible=strcmp(argv[5],"drawable")==0;
    if(!isfinite(seconds)||seconds<3||seconds>60||passes<1||passes>16||
       !((width==1920&&height==1080)||(width==3840&&height==2160))||
       (!shared&&strcmp(argv[4],"private"))||(!visible&&strcmp(argv[5],"offscreen"))||strcmp(argv[7],"snapshot"))return 64;
    if(visible) { [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; }
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];
    NSError *error=nil;id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];
    if(!lib||!queue) {fprintf(stderr,"library: %s\n",error.description.UTF8String);return 2;}
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"scene"];pd.fragmentFunction=[lib newFunctionWithName:@"shade"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> scene=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    pd.vertexFunction=[lib newFunctionWithName:@"handoff_vertex"];pd.fragmentFunction=[lib newFunctionWithName:@"handoff"];pd.depthAttachmentPixelFormat=MTLPixelFormatInvalid;
    id<MTLRenderPipelineState> copy=[device newRenderPipelineStateWithDescriptor:pd error:&error];
    if(!scene||!copy||!queue) {fprintf(stderr,"pipeline: %s\n",error.description.UTF8String);return 2;}
    const float vertices[8][4]={{-1,-1,-1,1},{1,-1,-1,1},{1,1,-1,1},{-1,1,-1,1},{-1,-1,1,1},{1,-1,1,1},{1,1,1,1},{-1,1,1,1}};
    const uint16_t indices[]={0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,0,4,7,0,7,3,1,2,6,1,6,5};
    id<MTLBuffer> vb=[device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib=[device newBufferWithBytes:indices length:sizeof(indices) options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback=[device newBufferWithLength:width*height*4 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> image=[device newTextureWithDescriptor:d];uint8_t pixels[64*64*4];
    for(unsigned y=0;y<64;y++)for(unsigned x=0;x<64;x++) {unsigned a=(y*64+x)*4;BOOL b=((x/8+y/8)%2)==0;pixels[a]=b?240:70;pixels[a+1]=b?170:130;pixels[a+2]=b?60:240;pixels[a+3]=255;}
    [image replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:pixels bytesPerRow:256];
    d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:width height:height mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;id<MTLTexture> depth=[device newTextureWithDescriptor:d];
    MTLDepthStencilDescriptor *dd=[MTLDepthStencilDescriptor new];dd.depthCompareFunction=MTLCompareFunctionLess;dd.depthWriteEnabled=YES;
    id<MTLDepthStencilState> ds=[device newDepthStencilStateWithDescriptor:dd];
    IOSurfaceRef surfaces[2]={NULL,NULL};
    id<MTLTexture> a=intermediate(device,width,height,shared,&surfaces[0]);
    id<MTLTexture> b=passes>1 ? intermediate(device,width,height,shared,&surfaces[1]) : nil;
    IOSurfaceRef unused=NULL;id<MTLTexture> output=visible?nil:intermediate(device,width,height,NO,&unused);
    if(!a||(passes>1&&!b)||(!visible&&!output)||!depth||!vb||!ib||!readback||!image||!ds) {for(unsigned i=0;i<2;i++)if(surfaces[i])CFRelease(surfaces[i]);return 3;}
    NSWindow *window=nil;CAMetalLayer *layer=nil;
    if(visible) {
        window=[[NSWindow alloc] initWithContentRect:NSMakeRect(40,80,960,540) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed=NO;window.title=@"NativeMac GPU-local handoff prototype";
        layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly=NO;layer.displaySyncEnabled=NO;layer.allowsNextDrawableTimeout=YES;
        window.contentView.wantsLayer=YES;window.contentView.layer=layer;layer.drawableSize=CGSizeMake(width,height);
        [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    }
    struct Counts counts;atomic_init(&counts.finished,0);atomic_init(&counts.measured,0);atomic_init(&counts.errors,0);
    struct Counts *c=&counts;dispatch_semaphore_t slots=dispatch_semaphore_create(3);
    BOOL checked=NO,readbackPass=NO;NSUInteger different=0,nonBackground=0;uint64_t hash=14695981039346656037ull;
    double start=CACurrentMediaTime(),acquire=0,encode=0,wait=0;unsigned submitted=0,failures=0;
    while((!visible||window.visible)&&CACurrentMediaTime()-start<seconds) { @autoreleasepool {
        double mark=CACurrentMediaTime();
        if(dispatch_semaphore_wait(slots,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC))) {failures++;break;}
        wait+=CACurrentMediaTime()-mark;
        if(visible) {NSEvent *event;while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES]))[NSApp sendEvent:event];[NSApp updateWindows];}
        mark=CACurrentMediaTime();id<CAMetalDrawable> drawable=visible?[layer nextDrawable]:nil;
        id<MTLTexture> final=visible?drawable.texture:output;acquire+=CACurrentMediaTime()-mark;
        if(!final||final.width!=width||final.height!=height) {dispatch_semaphore_signal(slots);failures++;break;}
        mark=CACurrentMediaTime();id<MTLCommandBuffer> command=[queue commandBuffer];
        MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture=a;p.colorAttachments[0].loadAction=MTLLoadActionClear;p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=MTLClearColorMake(0.015,0.02,0.035,1);
        p.depthAttachment.texture=depth;p.depthAttachment.loadAction=MTLLoadActionClear;p.depthAttachment.storeAction=MTLStoreActionDontCare;p.depthAttachment.clearDepth=1;
        id<MTLRenderCommandEncoder> e=[command renderCommandEncoderWithDescriptor:p];
        if(!command||!e) {dispatch_semaphore_signal(slots);failures++;break;}
        [e setRenderPipelineState:scene];[e setDepthStencilState:ds];[e setVertexBuffer:vb offset:0 atIndex:0];[e setFragmentTexture:image atIndex:0];
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:36 indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0 instanceCount:441];[e endEncoding];
        id<MTLTexture> current=a;
        for(NSUInteger n=0;n<passes;n++) {
            id<MTLTexture> next=n+1==passes?final:(current==a?b:a);
            p=[MTLRenderPassDescriptor renderPassDescriptor];p.colorAttachments[0].texture=next;p.colorAttachments[0].loadAction=MTLLoadActionDontCare;p.colorAttachments[0].storeAction=MTLStoreActionStore;
            e=[command renderCommandEncoderWithDescriptor:p];
            if(!e) {failures++;break;}
            [e setRenderPipelineState:copy];[e setFragmentTexture:current atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[e endEncoding];current=next;
        }
        if(!checked) {id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];[blit copyFromTexture:final sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:width*4 destinationBytesPerImage:width*height*4];[blit endEncoding];}
        BOOL measured=CACurrentMediaTime()-start>=2;
        [command addCompletedHandler:^(id<MTLCommandBuffer> done) {if(done.status!=MTLCommandBufferStatusCompleted)atomic_fetch_add(&c->errors,1);atomic_fetch_add(&c->finished,1);if(measured)atomic_fetch_add(&c->measured,1);dispatch_semaphore_signal(slots);}];
        if(visible)[command presentDrawable:drawable];[command commit];encode+=CACurrentMediaTime()-mark;submitted++;
        if(!checked) {
            [command waitUntilCompleted];checked=YES;
            if(command.status!=MTLCommandBufferStatusCompleted) {failures++;break;}
            NSData *snapshot=[NSData dataWithBytes:readback.contents length:width*height*4];
            const uint8_t *bytes=snapshot.bytes;for(NSUInteger i=0;i<snapshot.length;i++) {hash^=bytes[i];hash*=1099511628211ull;}
            for(NSUInteger i=0;i<snapshot.length;i+=4)if(MAX(bytes[i],MAX(bytes[i+1],bytes[i+2]))>40)nonBackground++;
            BOOL alpha=YES;for(NSUInteger i=3;i<snapshot.length;i+=4)if(bytes[i]!=255) {alpha=NO;break;}
            readbackPass=nonBackground>width*height/20&&alpha;
            if(argc==10) {NSData *reference=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[9]]];if(reference.length!=snapshot.length)readbackPass=NO;else {const uint8_t *r=reference.bytes;for(NSUInteger i=0;i<snapshot.length;i++)different+=bytes[i]!=r[i];readbackPass=readbackPass&&different==0;}}
            if(![snapshot writeToFile:[NSString stringWithUTF8String:argv[8]] options:NSDataWritingAtomic error:&error])readbackPass=NO;
            if(!readbackPass) {failures++;break;}
        }
    } }
    for(unsigned i=0;i<3;i++)if(dispatch_semaphore_wait(slots,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC)))_Exit(124);
    for(unsigned i=0;i<3;i++)dispatch_semaphore_signal(slots);
    double elapsed=CACurrentMediaTime()-start;unsigned completed=atomic_load(&counts.finished);failures+=atomic_load(&counts.errors);
    NSDictionary *result=@{@"prototypeOnly":@YES,@"device":device.name,@"mode":[NSString stringWithUTF8String:argv[4]],@"output":[NSString stringWithUTF8String:argv[5]],@"width":@(width),@"height":@(height),@"handoffPasses":@(passes),@"intermediateStorage":@(a.storageMode),@"submitted":@(submitted),@"completed":@(completed),@"elapsed":@(elapsed),@"completedPerSecond":@(completed/elapsed),@"afterWarmupCompletedPerSecond":@(atomic_load(&counts.measured)/MAX(elapsed-2,0.001)),@"acquireMeanMs":@(acquire*1000/MAX(submitted,1)),@"slotWaitMeanMs":@(wait*1000/MAX(submitted,1)),@"encodeAndCommitMeanMs":@(encode*1000/MAX(submitted,1)),@"readbackPassed":@(readbackPass),@"referenceCompared":@(argc==10),@"comparedBytes":@(argc==10?width*height*4:0),@"mismatchingBytes":@(different),@"nonBackgroundPixels":@(nonBackground),@"frameFnv1a64":[NSString stringWithFormat:@"%016llx",(unsigned long long)hash],@"errors":@(failures),@"physicalDisplayFps":@NO};
    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL] encoding:NSUTF8StringEncoding].UTF8String);
    [window orderOut:nil];for(unsigned i=0;i<2;i++)if(surfaces[i])CFRelease(surfaces[i]);
    return failures||!readbackPass?5:0;
} }
