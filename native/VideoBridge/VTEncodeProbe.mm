// Authored NV12 frames -> public VT compression APIs -> NVENC component.
#import <Foundation/Foundation.h>
#include "spi/NativeMacEncoderABI.h"
#include <arpa/inet.h>
#include <signal.h>
#include <unistd.h>
#include <string>
extern "C" OSStatus NativeMacNVENCCreate(FourCharCode,CFAllocatorRef,NMEncoderRef*);
struct Results {NSMutableData *coded;unsigned frames=0,errors=0,keyframes=0;bool timestamps=true,hevc=false;};
static void encoded(void *context,void*,OSStatus status,VTEncodeInfoFlags,CMSampleBufferRef sample){
    auto r=static_cast<Results*>(context);if(status||!sample){r->errors++;return;}
    CMTime time=CMSampleBufferGetPresentationTimeStamp(sample);
    if(CMTimeCompare(time,CMTimeMake(r->frames,30))!=0)r->timestamps=false;
    auto format=CMSampleBufferGetFormatDescription(sample);const uint8_t prefix[]={0,0,0,1};
    if(!r->frames){for(size_t i=0;i<(r->hevc?3u:2u);i++){
        const uint8_t *data=nullptr;size_t size=0;
        OSStatus status=r->hevc?CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,i,&data,&size,nullptr,nullptr):CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,i,&data,&size,nullptr,nullptr);
        if(status){r->errors++;return;}
        [r->coded appendBytes:prefix length:4];[r->coded appendBytes:data length:size];
    }}
    CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);size_t size=CMBlockBufferGetDataLength(block);NSMutableData *bytes=[NSMutableData dataWithLength:size];
    if(CMBlockBufferCopyDataBytes(block,0,size,bytes.mutableBytes)){r->errors++;return;}
    auto p=static_cast<const uint8_t*>(bytes.bytes);size_t at=0;
    while(at<size){if(size-at<4){r->errors++;return;}uint32_t n;memcpy(&n,p+at,4);n=ntohl(n);at+=4;if(!n||n>size-at){r->errors++;return;}
        [r->coded appendBytes:prefix length:4];[r->coded appendBytes:p+at length:n];at+=n;
    }
    auto array=CMSampleBufferGetSampleAttachmentsArray(sample,false);bool key=true;
    if(array&&CFArrayGetCount(array)){auto d=static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(array,0));key=CFDictionaryGetValue(d,kCMSampleAttachmentKey_NotSync)!=kCFBooleanTrue;}
    if(key&&array&&CFArrayGetCount(array)&&CFDictionaryContainsKey(static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(array,0)),kCMSampleAttachmentKey_NotSync))r->errors++;
    r->keyframes+=key;r->frames++;
}
static void deadline(int){_exit(124);}
int main(int argc,char**argv){@autoreleasepool{
    if(argc<3)return 64;signal(SIGALRM,deadline);alarm(45);
    bool discover=false,hevc=false,outputHandler=false;unsigned w=320,h=180,n=30;std::string profile="main";
    for(int i=3;i<argc;i++){
        if(!strcmp(argv[i],"--discover"))discover=true;
        else if(!strcmp(argv[i],"--hevc"))hevc=true;
        else if(!strcmp(argv[i],"--output-handler"))outputHandler=true;
        else if(i+1<argc&&!strcmp(argv[i],"--profile"))profile=argv[++i];
        else if(i+1<argc&&!strcmp(argv[i],"--width"))w=static_cast<unsigned>(strtoul(argv[++i],nullptr,10));
        else if(i+1<argc&&!strcmp(argv[i],"--height"))h=static_cast<unsigned>(strtoul(argv[++i],nullptr,10));
        else if(i+1<argc&&!strcmp(argv[i],"--frames"))n=static_cast<unsigned>(strtoul(argv[++i],nullptr,10));
        else return 64;
    }
    if(profile!="main"&&profile!="baseline"&&profile!="high")return 64;
    if(hevc&&profile!="main")return 64;
    if(w<16||w>3840||h<16||h>2160||w%2||h%2||n<2||n>120||static_cast<uint64_t>(w)*h*3/2*n>64*1024*1024)return 64;
    const size_t frameBytes=w*h*3/2;FourCharCode codec=hevc?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264;
    NSData *raw=[NSData dataWithContentsOfFile:@(argv[1])];if(raw.length<n*frameBytes)return 65;
    Results r;r.coded=[NSMutableData data];r.hevc=hevc;
    NSDictionary *registration=@{@"VTIsHardwareAccelerated":@YES,@"VTIsParavirtualizationAware":@YES,@"VTRating":@1000,@"CMClassImplementationID":@"io.nativemac.nvenc.probe"};
    OSStatus registered=discover?0:VTRegisterVideoEncoderWithInfo(codec,(__bridge CFDictionaryRef)registration,NativeMacNVENCCreate);
    NSDictionary *spec=@{(__bridge NSString*)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES};
    VTCompressionSessionRef session=nullptr;OSStatus created=VTCompressionSessionCreate(nullptr,w,h,codec,(__bridge CFDictionaryRef)spec,nullptr,nullptr,outputHandler?nullptr:encoded,outputHandler?nullptr:&r,&session);
    OSStatus properties=created;
    if(!created){NSDictionary *values=@{(__bridge NSString*)kVTCompressionPropertyKey_RealTime:@YES,(__bridge NSString*)kVTCompressionPropertyKey_AllowFrameReordering:@NO,
        (__bridge NSString*)kVTCompressionPropertyKey_AverageBitRate:@(w>=1920?30000000:2000000),(__bridge NSString*)kVTCompressionPropertyKey_ExpectedFrameRate:@30,(__bridge NSString*)kVTCompressionPropertyKey_MaxKeyFrameInterval:@30};
        NSMutableDictionary *settings=[values mutableCopy];
        settings[(__bridge NSString*)kVTCompressionPropertyKey_ProfileLevel]=hevc?(__bridge NSString*)kVTProfileLevel_HEVC_Main_AutoLevel:
            profile=="baseline"?@"H264_ConstrainedBaseline_AutoLevel":profile=="high"?(__bridge NSString*)kVTProfileLevel_H264_High_AutoLevel:(__bridge NSString*)kVTProfileLevel_H264_Main_AutoLevel;
        properties=VTSessionSetProperties(session,(__bridge CFDictionaryRef)settings);
    }
    OSStatus prepared=properties?properties:VTCompressionSessionPrepareToEncodeFrames(session),submitted=prepared;unsigned sent=0;
    if(!prepared)for(unsigned i=0;i<n;i++){
        CVPixelBufferRef pixel=nullptr;NSDictionary *attributes=@{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        submitted=CVPixelBufferCreate(nullptr,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attributes,&pixel);if(submitted)break;
        submitted=CVPixelBufferLockBaseAddress(pixel,0);
        if(!submitted){auto p=static_cast<const uint8_t*>(raw.bytes)+i*frameBytes;for(size_t plane=0;plane<2;plane++){
            auto dest=static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
            for(unsigned row=0;row<(plane?h/2:h);row++){memcpy(dest+row*stride,p,w);p+=w;}
        }CVPixelBufferUnlockBaseAddress(pixel,0);}
        NSDictionary *options=@{(__bridge NSString*)kVTEncodeFrameOptionKey_ForceKeyFrame:@(i==0||i==n/2)};
        if(!submitted){
            if(outputHandler){auto results=&r;submitted=VTCompressionSessionEncodeFrameWithOutputHandler(session,pixel,CMTimeMake(i,30),CMTimeMake(1,30),(__bridge CFDictionaryRef)options,nullptr,^(OSStatus status,VTEncodeInfoFlags flags,CMSampleBufferRef sample){encoded(results,nullptr,status,flags,sample);});}
            else submitted=VTCompressionSessionEncodeFrame(session,pixel,CMTimeMake(i,30),CMTimeMake(1,30),(__bridge CFDictionaryRef)options,nullptr,nullptr);
        }
        CFRelease(pixel);if(submitted)break;sent++;
    }
    OSStatus complete=created?created:VTCompressionSessionCompleteFrames(session,kCMTimeInvalid);
    CFTypeRef hardware=nullptr;OSStatus queried=created?created:VTSessionCopyProperty(session,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,nullptr,&hardware);
    bool usingHardware=hardware&&CFEqual(hardware,kCFBooleanTrue);if(hardware)CFRelease(hardware);
    bool passed=!registered&&!created&&!properties&&!prepared&&!submitted&&!complete&&!queried&&usingHardware&&sent==n&&r.frames==n&&!r.errors&&r.timestamps&&r.keyframes>=2;
    if(passed&&![r.coded writeToFile:@(argv[2]) atomically:YES])passed=false;
    NSDictionary *report=@{@"registered":@(registered),@"created":@(created),@"properties":@(properties),@"prepared":@(prepared),@"submittedStatus":@(submitted),@"submitted":@(sent),@"complete":@(complete),
        @"hardwareQuery":@(queried),@"hardware":@(usingHardware),@"frames":@(r.frames),@"codec":hevc?@"hevc":@"h264",@"width":@(w),@"height":@(h),@"callbackErrors":@(r.errors),@"timestampsMatch":@(r.timestamps),@"keyframes":@(r.keyframes),@"encodedBytes":@(r.coded.length),@"passed":@(passed),@"componentDiscovery":@(discover),@"ordinaryAppIntegration":@NO};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    if(session){VTCompressionSessionInvalidate(session);CFRelease(session);}return passed?0:1;
}}
