// Public AVAssetWriter without manual VideoToolbox encoder registration.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <atomic>
#include <signal.h>
#include <unistd.h>
static void deadline(int){_exit(124);}
int main(int argc,char**argv){@autoreleasepool{
    if(argc!=3)return 64;signal(SIGALRM,deadline);alarm(45);
    unsigned w=320,h=180,count=30;size_t size=w*h*3/2;
    NSData *raw=[NSData dataWithContentsOfFile:@(argv[1])];if(raw.length<size*count)return 65;
    NSURL *output=[NSURL fileURLWithPath:@(argv[2])];if([[NSFileManager defaultManager] fileExistsAtPath:output.path])return 73;
    NSError *error=nil;AVAssetWriter *writer=[AVAssetWriter assetWriterWithURL:output fileType:AVFileTypeMPEG4 error:&error];
    NSDictionary *settings=@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@(w),AVVideoHeightKey:@(h),
        AVVideoEncoderSpecificationKey:@{(__bridge NSString*)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES},
        AVVideoCompressionPropertiesKey:@{AVVideoAverageBitRateKey:@2000000,AVVideoMaxKeyFrameIntervalKey:@30,AVVideoAllowFrameReorderingKey:@NO,AVVideoProfileLevelKey:AVVideoProfileLevelH264MainAutoLevel}};
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime=YES;
    AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:
        @{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(__bridge NSString*)kCVPixelBufferWidthKey:@(w),(__bridge NSString*)kCVPixelBufferHeightKey:@(h)}];
    BOOL began=writer&&[writer canAddInput:input];if(began){[writer addInput:input];began=[writer startWriting];if(began)[writer startSessionAtSourceTime:kCMTimeZero];}
    unsigned sent=0;
    if(began)for(unsigned i=0;i<count;i++){@autoreleasepool{
        while(!input.readyForMoreMediaData&&writer.status==AVAssetWriterStatusWriting)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
        if(writer.status!=AVAssetWriterStatusWriting)break;
        CVPixelBufferRef pixel=nullptr;OSStatus status=CVPixelBufferPoolCreatePixelBuffer(nullptr,adaptor.pixelBufferPool,&pixel);if(status)break;
        status=CVPixelBufferLockBaseAddress(pixel,0);
        if(!status){auto p=static_cast<const uint8_t*>(raw.bytes)+i*size;
            for(size_t plane=0;plane<2;plane++){auto dest=static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
                for(unsigned row=0;row<(plane?h/2:h);row++){memcpy(dest+row*stride,p,w);p+=w;}}
            CVPixelBufferUnlockBaseAddress(pixel,0);
        }
        BOOL accepted=!status&&[adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(i,30)];CFRelease(pixel);if(!accepted)break;sent++;
    }}
    std::atomic<bool> done{false};auto completion=&done;
    if(began){[input markAsFinished];[writer finishWritingWithCompletionHandler:^{completion->store(true);}];
        while(!done)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];}
    BOOL passed=began&&sent==count&&writer.status==AVAssetWriterStatusCompleted;
    NSError *underlying=writer.error.userInfo[NSUnderlyingErrorKey];
    NSDictionary *result=@{@"publicAVAssetWriter":@YES,@"manualEncoderRegistration":@NO,@"hardwareRequired":@YES,@"submittedFrames":@(sent),@"writerStatus":@(writer.status),@"errorCode":@(writer.error.code),@"underlyingErrorCode":@(underlying.code),@"passed":@(passed)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:1;
}}
