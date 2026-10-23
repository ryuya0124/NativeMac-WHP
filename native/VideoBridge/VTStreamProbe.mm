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
#include <chrono>
#include <deque>
extern "C" OSStatus NativeMacNVDECCreate(FourCharCode,CFAllocatorRef,VTVideoDecoderRef*);
extern "C" OSStatus VTRegisterVideoDecoderWithInfo(FourCharCode,CFDictionaryRef,VTVideoDecoderFunction_CreateInstance);
struct Results {
    NSData *baseline;
    size_t width,height;
    unsigned frames=0,errors=0,dropped=0;
    uint64_t mismatch=0;
    std::vector<int64_t> timestamps;
    std::vector<int64_t> baselineOrder;
    std::vector<int64_t> expectedDropped,droppedTimes;
    std::mutex lock;
    bool retainWindow=false;
    unsigned retainedChecks=0;
    std::deque<std::pair<int64_t,CVPixelBufferRef>> held;
};
static void verifyHeld(Results *r){
    auto [pts,pixel]=r->held.front();r->held.pop_front();
    auto found=std::find(r->baselineOrder.begin(),r->baselineOrder.end(),pts);
    size_t index=static_cast<size_t>(found-r->baselineOrder.begin()),size=r->width*r->height*3/2;
    if(found==r->baselineOrder.end()||(index+1)*size>r->baseline.length){r->errors++;CFRelease(pixel);return;}
    const auto *expected=static_cast<const uint8_t*>(r->baseline.bytes)+index*size;
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    for(size_t plane=0;plane<2;plane++){
        auto actual=static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));
        size_t rows=plane?r->height/2:r->height,stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
        if(!actual||stride<r->width){r->errors++;break;}
        for(size_t y=0;y<rows;y++){for(size_t x=0;x<r->width;x++)r->mismatch+=actual[y*stride+x]!=expected[x];expected+=r->width;}
    }
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);CFRelease(pixel);r->retainedChecks++;
}
static void decoded(void *context,void*,OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef pixel,CMTime pts,CMTime){
    auto *r=static_cast<Results*>(context);std::lock_guard lock(r->lock);
    if(!status&&!pixel&&(flags&kVTDecodeInfo_FrameDropped)){
        r->dropped++;if(CMTIME_IS_NUMERIC(pts))r->droppedTimes.push_back(CMTimeConvertScale(pts,1000000000,kCMTimeRoundingMethod_Default).value);return;
    }
    if(status||!pixel){r->errors++;return;}
    size_t size=r->width*r->height*3/2;
    int64_t ns=CMTimeConvertScale(pts,1000000000,kCMTimeRoundingMethod_Default).value;
    auto found=std::find(r->baselineOrder.begin(),r->baselineOrder.end(),ns);
    if(found==r->baselineOrder.end()||std::find(r->timestamps.begin(),r->timestamps.end(),ns)!=r->timestamps.end()){r->errors++;return;}
    size_t index=static_cast<size_t>(found-r->baselineOrder.begin());
    if((index+1)*size>r->baseline.length){r->errors++;return;}
    const auto *expected=static_cast<const uint8_t*>(r->baseline.bytes)+index*size;
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    for(size_t plane=0;plane<2;++plane){
        const auto *actual=static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));
        size_t rows=plane?r->height/2:r->height,stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
        if(!actual||stride<r->width){r->errors++;break;}
        for(size_t y=0;y<rows;++y){for(size_t x=0;x<r->width;++x)r->mismatch+=actual[y*stride+x]!=expected[x];expected+=r->width;}
    }
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    r->timestamps.push_back(ns);r->frames++;
    if(r->retainWindow){CFRetain(pixel);r->held.emplace_back(ns,pixel);if(r->held.size()>8)verifyHeld(r);}
}
static void deadlineExceeded(int){
    static const char result[]="{\"passed\":false,\"deadlineExceeded\":true,\"ordinaryAppIntegration\":false}\n";
    write(STDOUT_FILENO,result,sizeof(result)-1);_exit(124);
}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=3&&argc!=4)return 64;
    bool discovery=argc==4&&!strcmp(argv[3],"--discover");
    bool activeCancel=argc==4&&!strcmp(argv[3],"--cancel-active");
    bool cancel=activeCancel||(argc==4&&!strcmp(argv[3],"--cancel"));
    bool serial=argc==4&&!strcmp(argv[3],"--serial");
    bool lowDelay=serial||(argc==4&&!strcmp(argv[3],"--low-delay"));
    bool drainMidstream=argc==4&&!strcmp(argv[3],"--drain-midstream");
    bool retainWindow=argc==4&&!strcmp(argv[3],"--retain-window");
    if(argc==4&&!discovery&&!cancel&&!lowDelay&&!drainMidstream&&!retainWindow)return 64;
    signal(SIGALRM,deadlineExceeded);alarm(cancel?8:45);
    NSData *inputData=[NSData dataWithContentsOfFile:@(argv[1])];
    if(!inputData)return 65;
    NSDictionary *input=[NSJSONSerialization JSONObjectWithData:inputData options:0 error:nil];
    Results r;r.width=[input[@"width"] unsignedIntegerValue];r.height=[input[@"height"] unsignedIntegerValue];r.retainWindow=retainWindow;
    r.baseline=[NSData dataWithContentsOfFile:@(argv[2])];
    NSArray *packets=input[@"packets"];NSData *config=[[NSData alloc] initWithBase64EncodedString:input[@"configuration"] options:0];
    if(!input||!config||!r.baseline||!packets.count)return 65;
    bool hevc=[input[@"codec"] isEqualToString:@"hevc"],vp9=[input[@"codec"] isEqualToString:@"vp9"];
    FourCharCode codec=vp9?kCMVideoCodecType_VP9:hevc?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264;
    for(NSNumber *pts in input[@"expectedDroppedPts"])r.expectedDropped.push_back(pts.longLongValue);
    for(NSDictionary *packet in packets){int64_t pts=[packet[@"pts"] longLongValue];if(std::find(r.expectedDropped.begin(),r.expectedDropped.end(),pts)==r.expectedDropped.end())r.baselineOrder.push_back(pts);}
    std::sort(r.baselineOrder.begin(),r.baselineOrder.end());
    NSDictionary *extensions=@{(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:@{vp9?@"vpcC":hevc?@"hvcC":@"avcC":config}};
    CMVideoFormatDescriptionRef format=nullptr;
    OSStatus status=CMVideoFormatDescriptionCreate(nullptr,discovery&&!hevc&&!vp9?'nmq3':codec,(int32_t)r.width,(int32_t)r.height,(__bridge CFDictionaryRef)extensions,&format);
    NSDictionary *registration=@{@"VTIsHardwareAccelerated":@YES,@"VTIsParavirtualizationAware":@YES,@"VTRating":@1000};
    if(vp9)VTRegisterSupplementalVideoDecoderIfAvailable(codec);
    OSStatus registered=discovery?0:VTRegisterVideoDecoderWithInfo(codec,(__bridge CFDictionaryRef)registration,NativeMacNVDECCreate);
    VTDecompressionSessionRef session=nullptr;
    VTDecompressionOutputCallbackRecord callback={decoded,&r};
    NSDictionary *spec=@{(__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES};
    OSStatus created=status?status:VTDecompressionSessionCreate(nullptr,format,discovery?nullptr:(__bridge CFDictionaryRef)spec,nullptr,&callback,&session);
    CFTypeRef hardware=nullptr;OSStatus queried=created?created:VTSessionCopyProperty(session,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,nullptr,&hardware);
    bool hardwareTrue=hardware&&CFEqual(hardware,kCFBooleanTrue);
    if(hardware)CFRelease(hardware);
    OSStatus submitted=created;unsigned sent=0;
    std::vector<int64_t> expected;
    std::vector<double> roundTrips;
    if(!created)for(NSDictionary *packet in packets){
        auto started=std::chrono::steady_clock::now();
        NSData *bytes=[[NSData alloc] initWithBase64EncodedString:packet[@"data"] options:0];
        int64_t pts=[packet[@"pts"] longLongValue];if(std::find(r.expectedDropped.begin(),r.expectedDropped.end(),pts)==r.expectedDropped.end())expected.push_back(pts);
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
        if(serial){
            submitted=VTDecompressionSessionWaitForAsynchronousFrames(session);
            roundTrips.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count());
            if(submitted)break;
        }
        if(drainMidstream&&sent==packets.count/2){
            submitted=VTDecompressionSessionFinishDelayedFrames(session);
            if(!submitted)submitted=VTDecompressionSessionWaitForAsynchronousFrames(session);
            if(submitted)break;
        }
        if(cancel&&sent==(activeCancel?60u:12u)){
            if(activeCancel){
                auto until=std::chrono::steady_clock::now()+std::chrono::seconds(5);
                while(std::chrono::steady_clock::now()<until){
                    bool output=false;{std::lock_guard lock(r.lock);output=r.frames!=0;}
                    if(output)break;usleep(1000);
                }
            }
            break;
        }
    }
    if(cancel&&session)VTDecompressionSessionInvalidate(session);
    OSStatus drained=cancel?0:created?created:VTDecompressionSessionFinishDelayedFrames(session);
    OSStatus waited=cancel?0:created?created:VTDecompressionSessionWaitForAsynchronousFrames(session);
    while(!r.held.empty())verifyHeld(&r);
    std::sort(expected.begin(),expected.end());
    std::sort(r.timestamps.begin(),r.timestamps.end());
    bool timestamps=expected==r.timestamps;
    std::sort(r.droppedTimes.begin(),r.droppedTimes.end());std::sort(r.expectedDropped.begin(),r.expectedDropped.end());
    bool droppedTimestamps=r.droppedTimes==r.expectedDropped;
    bool passed=!registered&&!created&&!queried&&hardwareTrue&&!drained&&!waited&&!r.mismatch&&
        !submitted&&!r.errors&&(cancel?sent==(activeCancel?60u:12u)&&r.frames+r.dropped==sent:r.frames+r.expectedDropped.size()==packets.count&&timestamps&&r.dropped==r.expectedDropped.size()&&droppedTimestamps);
    std::sort(roundTrips.begin(),roundTrips.end());
    NSDictionary *report=@{@"registrationStatus":@(registered),@"createStatus":@(created),@"hardwarePropertyStatus":@(queried),
        @"hardwareProperty":@(hardwareTrue),@"submitted":@(sent),@"submitStatus":@(submitted),@"drainStatus":@(drained),@"waitStatus":@(waited),
        @"decodedFrames":@(r.frames),@"droppedFrames":@(r.dropped),@"callbackErrors":@(r.errors),@"comparedBytes":@(r.frames*r.width*r.height*3/2),@"mismatchingBytes":@(r.mismatch),
        @"timestampsMatchOriginalSamples":@(timestamps),@"passed":@(passed),@"ordinaryAppIntegration":@NO,@"componentDiscovery":@(discovery),@"cancelledEarly":@(cancel),@"midstreamDrain":@(drainMidstream),@"temporalProcessingRequested":@(!lowDelay),
        @"width":@(r.width),@"height":@(r.height),@"serialRoundTrip":@(serial),@"roundTripMedianMs":roundTrips.empty()?NSNull.null:@(roundTrips[roundTrips.size()/2])};
    NSMutableDictionary *finalReport=[report mutableCopy];finalReport[@"retainedFrameChecks"]=@(r.retainedChecks);
    finalReport[@"droppedTimestampsMatchExpected"]=@(droppedTimestamps);
    NSData *json=[NSJSONSerialization dataWithJSONObject:finalReport options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    if(session){VTDecompressionSessionInvalidate(session);CFRelease(session);}if(format)CFRelease(format);
    return passed?0:1;
}}
