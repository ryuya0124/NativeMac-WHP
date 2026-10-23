// Explicit process entry for unmodified VideoToolbox/AVFoundation consumers.
// Register only when a video API is called. Constructor-time CoreMedia/Security
// work can re-enter launchd while it is starting an unrelated process.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <os/log.h>
#include "VideoTransport.h"
typedef OSStatus(*Factory)(FourCharCode,CFAllocatorRef,void**);
typedef OSStatus(*Register)(FourCharCode,CFDictionaryRef,Factory);
extern OSStatus NativeMacNVENCCreate(FourCharCode,CFAllocatorRef,void**);
extern OSStatus NativeMacNVDECCreate(FourCharCode,CFAllocatorRef,void**);
static bool processEnabled=false;
// Capture consent before an XPC service initializes its sandbox. This performs
// no Objective-C, Security or codec registration from a loader constructor;
// only the fixed broker's Mach capability is acquired before sandbox entry.
__attribute__((constructor)) static void captureVideoConfiguration(void){
    if(!strcmp(getprogname(),"NativeMacVideoBroker"))return;
    const char *enabled=getenv("NATIVEMAC_VIDEO_ENCODERS");
    if(enabled){processEnabled=!strcmp(enabled,"1");if(processEnabled)NativeMacVideoPrimeBroker();return;}
    int fd=open("/Library/Application Support/NativeMac/VideoBridge/enabled",O_RDONLY|O_NOFOLLOW);
    if(fd<0)return;struct stat st;char value=0;
    processEnabled=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==0&&!(st.st_mode&0022)&&read(fd,&value,1)==1&&value=='1';
    close(fd);
    if(processEnabled)NativeMacVideoPrimeBroker();
}
static void registerNativeMacCodecs(void){
    static dispatch_once_t observed;dispatch_once(&observed,^{os_log(OS_LOG_DEFAULT,"NativeMac video API entry enabled=%d",processEnabled);});
    if(!processEnabled)return;
    static dispatch_once_t once;dispatch_once(&once,^{@autoreleasepool{
    // Factories are part of this root-installed, seal-checked image. A sandboxed
    // consumer need not reopen a plug-in's metadata or contact Security services.
    Factory factory=NativeMacNVENCCreate;
    Register registration=(Register)dlsym(RTLD_DEFAULT,"VTRegisterVideoEncoderWithInfo");
    if(factory&&registration){
        for(NSNumber *number in @[@(kCMVideoCodecType_H264),@(kCMVideoCodecType_HEVC)]){
            NSDictionary *info=@{@"VTIsHardwareAccelerated":@YES,@"VTIsParavirtualizationAware":@YES,@"VTAllowSandboxedEncode":@YES,@"VTAllowSandboxedDecode":@YES,@"VTRating":@1000,
                @"CMClassImplementationID":[NSString stringWithFormat:@"io.nativemac.nvenc.%u",number.unsignedIntValue],
                @"VTCodecName":number.unsignedIntValue==kCMVideoCodecType_H264?@"H.264":@"HEVC",@"VTEncoderName":@"NativeMac NVENC"};
            OSStatus registered=registration(number.unsignedIntValue,(__bridge CFDictionaryRef)info,factory);
            if(registered)fprintf(stderr,"NativeMac encoder registration failed: %d\n",(int)registered);
        }
    }
    Factory decoder=NativeMacNVDECCreate;
    Register decoderRegistration=(Register)dlsym(RTLD_DEFAULT,"VTRegisterVideoDecoderWithInfo");
    if(decoder&&decoderRegistration){
        // VP9 is supplemental on Intel macOS. Initialize that registry before
        // installing our factory; its deferred initialization otherwise hides
        // a successfully registered VP9 decoder at first session creation.
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
        NSDictionary *info=@{@"VTIsHardwareAccelerated":@YES,@"VTIsParavirtualizationAware":@YES,@"VTAllowSandboxedDecode":@YES,@"VTRating":@1000};
        for(NSNumber *number in @[@(kCMVideoCodecType_H264),@(kCMVideoCodecType_HEVC),@(kCMVideoCodecType_VP9)]){
            OSStatus registered=decoderRegistration(number.unsignedIntValue,(__bridge CFDictionaryRef)info,decoder);
            if(registered)fprintf(stderr,"NativeMac decoder registration failed: %d\n",(int)registered);
        }
    }
    os_log(OS_LOG_DEFAULT,"NativeMac video factories registered");
}});
}
static OSStatus createEncoder(CFAllocatorRef allocator,int32_t width,int32_t height,CMVideoCodecType codec,
    CFDictionaryRef specification,CFDictionaryRef attributes,CFAllocatorRef compressedAllocator,
    VTCompressionOutputCallback callback,void *context,VTCompressionSessionRef *session){
    registerNativeMacCodecs();
    if(processEnabled&&(codec==kCMVideoCodecType_H264||codec==kCMVideoCodecType_HEVC)){
        CFTypeRef identifier=specification?CFDictionaryGetValue(specification,kVTVideoEncoderSpecification_EncoderID):NULL;
        CFTypeRef hardware=specification?CFDictionaryGetValue(specification,kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder):NULL;
        os_log(OS_LOG_DEFAULT,"NativeMac video compression create explicitEncoder=%d hardwareDisabled=%d",identifier!=NULL,hardware==kCFBooleanFalse);
        if(!identifier&&hardware!=kCFBooleanFalse){
            NSMutableDictionary *choice=specification?[(__bridge NSDictionary*)specification mutableCopy]:[NSMutableDictionary dictionary];
            choice[(__bridge NSString*)kVTVideoEncoderSpecification_EncoderID]=[NSString stringWithFormat:@"io.nativemac.nvenc.%u",codec];
            // Apple's conferencing selector accepts only its own encoder IDs.
            // Our backend already uses NVENC ULL, zero delay and no B frames;
            // select that encoder directly, keeping actual property errors.
            [choice removeObjectForKey:(__bridge NSString*)kVTVideoEncoderSpecification_EnableLowLatencyRateControl];
            [choice removeObjectForKey:@"RequiredLowLatency"];
            OSStatus result=VTCompressionSessionCreate(allocator,width,height,codec,(__bridge CFDictionaryRef)choice,attributes,compressedAllocator,callback,context,session);
            os_log(OS_LOG_DEFAULT,"NativeMac video default encoder create status=%d",(int)result);return result;
        }
    }
    return VTCompressionSessionCreate(allocator,width,height,codec,specification,attributes,compressedAllocator,callback,context,session);
}
static OSStatus createDecoder(CFAllocatorRef allocator,CMVideoFormatDescriptionRef format,CFDictionaryRef specification,
    CFDictionaryRef attributes,const VTDecompressionOutputCallbackRecord *callback,VTDecompressionSessionRef *session){
    registerNativeMacCodecs();return VTDecompressionSessionCreate(allocator,format,specification,attributes,callback,session);
}
static Boolean hardwareDecoder(CMVideoCodecType codec){
    registerNativeMacCodecs();return VTIsHardwareDecodeSupported(codec);
}
__attribute__((used,section("__DATA,__interpose")))
static const struct {const void *replacement;const void *original;} videoInterpose[]={
    {(const void*)createEncoder,(const void*)VTCompressionSessionCreate},
    {(const void*)createDecoder,(const void*)VTDecompressionSessionCreate},
    {(const void*)hardwareDecoder,(const void*)VTIsHardwareDecodeSupported}
};
