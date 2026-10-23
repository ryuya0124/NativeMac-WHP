// Authored compressed fixture -> public VT APIs -> registered NVDEC component.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include "spi/VTVideoDecoderSPI.h"
#include <algorithm>
#include <atomic>
#include <mutex>
#include <signal.h>
#include <unistd.h>
#include <vector>
extern "C" OSStatus NativeMacNVDECCreate(FourCharCode,CFAllocatorRef,VTVideoDecoderRef*);
extern "C" OSStatus VTRegisterVideoDecoderWithInfo(FourCharCode,CFDictionaryRef,VTVideoDecoderFunction_CreateInstance);
struct Results {
    NSData *baseline;
    size_t width,height;
    unsigned frames=0,errors=0;
    uint64_t mismatch=0;
    std::vector<int64_t> timestamps;
    std::mutex lock;
};
static void decoded(void *context,void*,OSStatus status,VTDecodeInfoFlags,CVImageBufferRef pixel,CMTime pts,CMTime){
    auto *r=static_cast<Results*>(context);std::lock_guard lock(r->lock);
    if(status||!pixel){r->errors++;return;}
    size_t size=r->width*r->height*3/2;
    if((r->frames+1)*size>r->baseline.length){r->errors++;return;}
    const auto *expected=static_cast<const uint8_t*>(r->baseline.bytes)+r->frames*size;
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    for(size_t plane=0;plane<2;++plane){
        const auto *actual=static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));
        size_t rows=plane?r->height/2:r->height,stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
        if(!actual||stride<r->width){r->errors++;break;}
        for(size_t y=0;y<rows;++y){for(size_t x=0;x<r->width;++x)r->mismatch+=actual[y*stride+x]!=expected[x];expected+=r->width;}
    }
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    r->timestamps.push_back(CMTimeConvertScale(pts,1000000000,kCMTimeRoundingMethod_Default).value);r->frames++;
}
static void deadlineExceeded(int){
    static const char result[]="{\"passed\":false,\"deadlineExceeded\":true,\"ordinaryAppIntegration\":false}\n";
    write(STDOUT_FILENO,result,sizeof(result)-1);_exit(124);
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=3&&argc!=4)return 64;
    bool discovery=argc==4&&!strcmp(argv[3],"--discover");
    bool cancel=argc==4&&!strcmp(argv[3],"--cancel");
    bool lowDelay=argc==4&&!strcmp(argv[3],"--low-delay");
    if(argc==4&&!discovery&&!cancel&&!lowDelay)return 64;
    signal(SIGALRM,deadlineExceeded);alarm(cancel||lowDelay?8:45);
    NSDictionary *input=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
    Results r;r.width=[input[@"width"] unsignedIntegerValue];r.height=[input[@"height"] unsignedIntegerValue];
    r.baseline=[NSData dataWithContentsOfFile:@(argv[2])];
    NSArray *packets=input[@"packets"];NSData *config=[[NSData alloc] initWithBase64EncodedString:input[@"configuration"] options:0];
    if(!input||!config||!r.baseline||!packets.count)return 65;
    NSDictionary *extensions=@{(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:@{@"avcC":config}};
    CMVideoFormatDescriptionRef format=nullptr;
    OSStatus status=CMVideoFormatDescriptionCreate(nullptr,discovery?'nmq3':kCMVideoCodecType_H264,(int32_t)r.width,(int32_t)r.height,(__bridge CFDictionaryRef)extensions,&format);
    NSDictionary *registration=@{@"VTIsHardwareAccelerated":@YES,@"VTIsParavirtualizationAware":@YES,@"VTRating":@1000};
    OSStatus registered=discovery?0:VTRegisterVideoDecoderWithInfo(kCMVideoCodecType_H264,(__bridge CFDictionaryRef)registration,NativeMacNVDECCreate);
    VTDecompressionSessionRef session=nullptr;
    VTDecompressionOutputCallbackRecord callback={decoded,&r};
    NSDictionary *spec=@{(__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES};
    OSStatus created=status?status:VTDecompressionSessionCreate(nullptr,format,discovery?nullptr:(__bridge CFDictionaryRef)spec,nullptr,&callback,&session);
    CFTypeRef hardware=nullptr;OSStatus queried=created?created:VTSessionCopyProperty(session,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,nullptr,&hardware);
    bool hardwareTrue=hardware&&CFEqual(hardware,kCFBooleanTrue);
    if(hardware)CFRelease(hardware);
    OSStatus submitted=created;unsigned sent=0;
    std::vector<int64_t> expected;
    if(!created)for(NSDictionary *packet in packets){
        NSData *bytes=[[NSData alloc] initWithBase64EncodedString:packet[@"data"] options:0];
        int64_t pts=[packet[@"pts"] longLongValue];expected.push_back(pts);
        CMBlockBufferRef block=nullptr;CMSampleBufferRef sample=nullptr;
        submitted=CMBlockBufferCreateWithMemoryBlock(nullptr,nullptr,bytes.length,nullptr,nullptr,0,bytes.length,0,&block);
        if(!submitted)submitted=CMBlockBufferReplaceDataBytes(bytes.bytes,block,0,bytes.length);
        CMSampleTimingInfo timing={CMTimeMake([packet[@"duration"] longLongValue],1000000000),CMTimeMake(pts,1000000000),
            CMTimeMake([packet[@"dts"] longLongValue],1000000000)};
        size_t sampleSize=bytes.length;
        if(!submitted)submitted=CMSampleBufferCreateReady(nullptr,block,format,1,1,&timing,1,&sampleSize,&sample);
        if(!submitted){
            auto attachments=CMSampleBufferGetSampleAttachmentsArray(sample,true);
            auto first=static_cast<CFMutableDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(attachments,0)));
            CFDictionarySetValue(first,kCMSampleAttachmentKey_NotSync,[packet[@"key"] boolValue]?kCFBooleanFalse:kCFBooleanTrue);
            VTDecodeFrameFlags flags=kVTDecodeFrame_EnableAsynchronousDecompression;
            if(!lowDelay)flags|=kVTDecodeFrame_EnableTemporalProcessing;
            submitted=VTDecompressionSessionDecodeFrame(session,sample,flags,nullptr,nullptr);
        }
        if(sample)CFRelease(sample);if(block)CFRelease(block);
        if(submitted)break;sent++;
        if(cancel&&sent==12)break;
    }
    if((cancel||lowDelay)&&session)VTDecompressionSessionInvalidate(session);
    OSStatus drained=(cancel||lowDelay)?0:created?created:VTDecompressionSessionFinishDelayedFrames(session);
    OSStatus waited=(cancel||lowDelay)?0:created?created:VTDecompressionSessionWaitForAsynchronousFrames(session);
    std::sort(expected.begin(),expected.end());
    bool timestamps=expected==r.timestamps;
    bool passed=!registered&&!created&&!queried&&hardwareTrue&&!drained&&!waited&&!r.mismatch&&
        (lowDelay?submitted==kVTPropertyNotSupportedErr&&sent==0&&r.frames==0&&r.errors==1:
            !submitted&&!r.errors&&(cancel?sent==12:r.frames==packets.count&&timestamps));
    NSDictionary *report=@{@"registrationStatus":@(registered),@"createStatus":@(created),@"hardwarePropertyStatus":@(queried),
        @"hardwareProperty":@(hardwareTrue),@"submitted":@(sent),@"submitStatus":@(submitted),@"drainStatus":@(drained),@"waitStatus":@(waited),
        @"decodedFrames":@(r.frames),@"callbackErrors":@(r.errors),@"comparedBytes":@(r.frames*r.width*r.height*3/2),@"mismatchingBytes":@(r.mismatch),
        @"timestampsMatchOriginalSamples":@(timestamps),@"passed":@(passed),@"ordinaryAppIntegration":@NO,@"componentDiscovery":@(discovery),@"cancelledEarly":@(cancel),@"unsupportedLowDelayRejected":@(lowDelay)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    if(session){VTDecompressionSessionInvalidate(session);CFRelease(session);}if(format)CFRelease(format);
    return passed?0:1;
}}
