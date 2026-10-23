#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

// Capability preflight only. Successful session creation is not an encode test.
static NSDictionary *encoder(CMVideoCodecType codec, BOOL requireHardware) {
    NSDictionary *spec = @{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@(requireHardware)};
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, 640, 360, codec,
        (__bridge CFDictionaryRef)spec, NULL, NULL, NULL, NULL, &session);
    CFTypeRef hardware = NULL;
    if (!status && session)
        VTSessionCopyProperty(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            kCFAllocatorDefault, &hardware);
    BOOL actualHardware = hardware && CFGetTypeID(hardware) == CFBooleanGetTypeID() &&
        CFBooleanGetValue((CFBooleanRef)hardware);
    if (hardware) CFRelease(hardware);
    if (session) { VTCompressionSessionInvalidate(session); CFRelease(session); }
    return @{@"requireHardware":@(requireHardware), @"sessionStatus":@(status),
        @"usingHardware":@(actualHardware), @"framesEncoded":@0};
}
int main(void) {
    @autoreleasepool {
        NSArray *codecs = @[@(kCMVideoCodecType_H264), @(kCMVideoCodecType_HEVC),
            @(kCMVideoCodecType_VP9), @(kCMVideoCodecType_AV1)];
        NSArray *names = @[@"H264", @"HEVC", @"VP9", @"AV1"];
        NSMutableArray *results = [NSMutableArray new];
        for (NSUInteger i=0; i<codecs.count; ++i) {
            CMVideoCodecType codec = [codecs[i] unsignedIntValue];
            NSMutableDictionary *value = [@{@"codec":names[i],
                @"hardwareDecodeAdvertised":@(VTIsHardwareDecodeSupported(codec))} mutableCopy];
            if (i<2) value[@"encoderPreflight"] = @[encoder(codec,YES),encoder(codec,NO)];
            [results addObject:value];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"stage":@"preflight",@"codecs":results}
            options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes,1,json.length,stdout); puts("");
    }
}
