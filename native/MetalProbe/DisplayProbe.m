#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <math.h>

// Run in the guest's logged-in session. Clear real Metal drawables and measure
// completed commands; host present counters separately measure visible delivery.
int main(int argc, const char **argv) {
    @autoreleasepool {
        double duration = argc > 1 ? strtod(argv[1], NULL) : 15;
        if (!isfinite(duration) || duration < 1 || duration > 3600) return 1;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) return 2;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,800,450)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"NativeMac GPU display timing";
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.displaySyncEnabled = YES;
        layer.allowsNextDrawableTimeout = YES;
        window.contentView.wantsLayer = YES;
        window.contentView.layer = layer;
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        double started = CACurrentMediaTime(), reported = started;
        unsigned frames = 0, errors = 0;
        double gpuTotal = 0, largestGap = 0, previous = started;
        while (window.visible && CACurrentMediaTime() - started < duration) {
            @autoreleasepool {
                NSEvent *event;
                while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                    untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES]))
                    [NSApp sendEvent:event];
                [NSApp updateWindows];
                NSSize size = window.contentView.bounds.size;
                layer.drawableSize = CGSizeMake(MAX(1,size.width),MAX(1,size.height));
                id<CAMetalDrawable> drawable = [layer nextDrawable];
                if (!drawable) { errors++; break; }
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = drawable.texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                double phase = CACurrentMediaTime() - started;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(
                    0.5+0.5*sin(phase*2), 0.5+0.5*sin(phase*3), 0.5+0.5*cos(phase), 1);
                id<MTLCommandBuffer> command = [queue commandBuffer];
                id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
                if (!command || !encoder) { errors++; break; }
                [encoder endEncoding];
                [command presentDrawable:drawable];
                [command commit];
                [command waitUntilCompleted];
                if (command.status != MTLCommandBufferStatusCompleted) { errors++; break; }
                gpuTotal += command.GPUEndTime - command.GPUStartTime;
                frames++;
                double now = CACurrentMediaTime();
                largestGap = MAX(largestGap, now-previous);
                previous = now;
                if (now-reported >= 1) {
                    printf("{\"elapsed\":%.3f,\"completed\":%u,\"meanFps\":%.2f,\"maxGapMs\":%.2f,\"meanGpuMs\":%.3f,\"errors\":%u}\n",
                        now-started,frames,frames/(now-started),largestGap*1000,gpuTotal*1000/frames,errors);
                    fflush(stdout);
                    reported = now;
                }
            }
        }
        double elapsed = CACurrentMediaTime()-started;
        printf("{\"stage\":\"display-timing\",\"elapsed\":%.3f,\"completed\":%u,\"meanFps\":%.2f,\"errors\":%u}\n",
            elapsed,frames,frames/MAX(elapsed,0.001),errors);
        [window orderOut:nil];
        return errors ? 3 : 0;
    }
}
