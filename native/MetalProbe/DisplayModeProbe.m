#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

// Enumerate real guest modes; an optional width/height changes this session only.
int main(int argc, const char **argv) {
    @autoreleasepool {
        CGDirectDisplayID display = CGMainDisplayID();
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(display, NULL);
        if (!modes) return 2;
        CGDisplayModeRef selected = NULL;
        size_t width = argc == 3 ? strtoul(argv[1], NULL, 10) : 0;
        size_t height = argc == 3 ? strtoul(argv[2], NULL, 10) : 0;
        NSMutableArray *list = [NSMutableArray array];
        for (CFIndex i = 0; i < CFArrayGetCount(modes); ++i) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t w = CGDisplayModeGetPixelWidth(mode), h = CGDisplayModeGetPixelHeight(mode);
            [list addObject:@{@"pixelWidth":@(w), @"pixelHeight":@(h),
                @"width":@(CGDisplayModeGetWidth(mode)), @"height":@(CGDisplayModeGetHeight(mode)),
                @"refreshHz":@(CGDisplayModeGetRefreshRate(mode))}];
            if (w == width && h == height && CGDisplayModeGetWidth(mode) == width)
                selected = mode;
        }
        CGError status = kCGErrorSuccess;
        if (argc == 3) {
            if (!selected) { CFRelease(modes); return 3; }
            CGDisplayConfigRef configuration = NULL;
            status = CGBeginDisplayConfiguration(&configuration);
            if (status == kCGErrorSuccess) {
                status = CGConfigureDisplayWithDisplayMode(configuration, display, selected, NULL);
                if (status == kCGErrorSuccess)
                    status = CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
                else
                    CGCancelDisplayConfiguration(configuration);
            }
        }
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
        NSDictionary *report = @{@"stage":@"display-modes", @"setStatus":@(status),
            @"currentWidth":@(current ? CGDisplayModeGetWidth(current) : 0),
            @"currentHeight":@(current ? CGDisplayModeGetHeight(current) : 0),
            @"currentPixelWidth":@(current ? CGDisplayModeGetPixelWidth(current) : 0),
            @"currentPixelHeight":@(current ? CGDisplayModeGetPixelHeight(current) : 0),
            @"currentRefreshHz":@(current ? CGDisplayModeGetRefreshRate(current) : 0),
            @"screenMaximumFramesPerSecond":@([NSScreen mainScreen].maximumFramesPerSecond), @"modes":list};
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        fwrite(data.bytes, 1, data.length, stdout); puts("");
        if (current) CFRelease(current);
        CFRelease(modes);
        return status == kCGErrorSuccess ? 0 : 4;
    }
}
