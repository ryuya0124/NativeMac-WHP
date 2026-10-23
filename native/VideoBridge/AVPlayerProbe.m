// Public AVPlayer playback without registering a VideoToolbox decoder in code.
// Use only an authored local movie. Host counters separately establish routing.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <signal.h>
#include <unistd.h>
static void deadline(int s){(void)s;_exit(124);}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;signal(SIGALRM,deadline);alarm(30);
    AVPlayerItem *item=[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:@(argv[1])]];
    AVPlayerItemVideoOutput *output=[[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:
        @{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
    [item addOutput:output];AVPlayer *player=[AVPlayer playerWithPlayerItem:item];
    double start=CFAbsoluteTimeGetCurrent();unsigned frames=0;CMTime last=kCMTimeInvalid;
    BOOL began=NO,ended=NO;double first=-1;unsigned nonempty=0;
    while(CFAbsoluteTimeGetCurrent()-start<20){@autoreleasepool{
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
        if(item.status==AVPlayerItemStatusFailed)break;
        if(item.status==AVPlayerItemStatusReadyToPlay&&!began){[player play];began=YES;}
        CMTime time=[output itemTimeForHostTime:CACurrentMediaTime()];
        if([output hasNewPixelBufferForItemTime:time]){
            CMTime display;CVPixelBufferRef pixel=[output copyPixelBufferForItemTime:time itemTimeForDisplay:&display];
            if(pixel){
                if(!CMTIME_IS_NUMERIC(last)||CMTimeCompare(display,last)!=0){
                    frames++;last=display;if(first<0)first=CFAbsoluteTimeGetCurrent()-start;
                    if(CVPixelBufferGetWidth(pixel)&&CVPixelBufferGetHeight(pixel))nonempty++;
                }
                CVPixelBufferRelease(pixel);
            }
        }
        double duration=CMTimeGetSeconds(item.duration),position=CMTimeGetSeconds(player.currentTime);
        if(began&&isfinite(duration)&&duration>0&&position>=duration-.01){ended=YES;break;}
    }}
    [player pause];BOOL passed=began&&ended&&frames>=60&&nonempty==frames;
    NSDictionary *result=@{@"publicAVPlayer":@YES,@"manualDecoderRegistration":@NO,@"ready":@(began),@"ended":@(ended),
        @"uniqueFrames":@(frames),@"nonemptyFrames":@(nonempty),@"firstFrameSeconds":@(first),
        @"seconds":@(CFAbsoluteTimeGetCurrent()-start),@"errorCode":@(item.error.code),@"passed":@(passed)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    return passed?0:1;
}}
