#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

// An authored moving color pattern, encoded with an explicitly software encoder.
// Used to separate browser video presentation from YouTube/network failures.
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;NSURL *url=[NSURL fileURLWithPath:@(argv[1])];
    if([[NSFileManager defaultManager] fileExistsAtPath:url.path])return 73;
    NSError *error=nil;AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
    NSDictionary *settings=@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@320,AVVideoHeightKey:@180,
        AVVideoEncoderSpecificationKey:@{(__bridge NSString*)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:@NO}};
    AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    NSDictionary *attributes=@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
        (__bridge NSString*)kCVPixelBufferWidthKey:@320,(__bridge NSString*)kCVPixelBufferHeightKey:@180};
    AVAssetWriterInputPixelBufferAdaptor *adapter=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:attributes];
    if(!writer || ![writer canAddInput:input]){fprintf(stderr,"writer unavailable\n");return 1;}
    [writer addInput:input];if(![writer startWriting])return 2;[writer startSessionAtSourceTime:kCMTimeZero];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:25];unsigned frames=0;
    for(unsigned f=0;f<90;++f){
        while(!input.readyForMoreMediaData && deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:0.001];
        if(!input.readyForMoreMediaData)break;
        CVPixelBufferRef pixel=NULL;
        if(CVPixelBufferCreate(NULL,320,180,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&pixel))break;
        CVPixelBufferLockBaseAddress(pixel,0);uint8_t *base=CVPixelBufferGetBaseAddress(pixel);size_t row=CVPixelBufferGetBytesPerRow(pixel);
        for(unsigned y=0;y<180;++y)for(unsigned x=0;x<320;++x){
            uint8_t *p=base+y*row+x*4;p[0]=(uint8_t)(x+f*3);p[1]=(uint8_t)(y+f*5);p[2]=(uint8_t)(x/2+y/2+f*7);p[3]=255;
        }
        CVPixelBufferUnlockBaseAddress(pixel,0);
        BOOL appended=[adapter appendPixelBuffer:pixel withPresentationTime:CMTimeMake(f,30)];CVPixelBufferRelease(pixel);
        if(!appended)break;++frames;
    }
    [input markAsFinished];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(done);}];
    long waited=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC));
    BOOL passed=!waited && frames==90 && writer.status==AVAssetWriterStatusCompleted;
    printf("{\"stage\":\"software-video-fixture\",\"framesEncoded\":%u,\"passed\":%s}\n",frames,passed?"true":"false");
    if(writer.error)fprintf(stderr,"%s\n",writer.error.localizedDescription.UTF8String);
    return passed?0:3;
}}
