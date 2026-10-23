#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

@interface PlaybackResult : NSObject<WKScriptMessageHandler>
@property BOOL finished;
@property BOOL passed;
@end
@implementation PlaybackResult
- (void)userContentController:(WKUserContentController*)controller didReceiveScriptMessage:(WKScriptMessage*)message {
    (void)controller;
    if(![message.body isKindOfClass:NSDictionary.class])return;
    NSDictionary *value=message.body;
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");fflush(stdout);
    self.passed=[value[@"passed"] boolValue];self.finished=YES;
}
@end

int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;NSURL *movie=[NSURL fileURLWithPath:@(argv[1])];
    if(![[NSFileManager defaultManager] fileExistsAtPath:movie.path])return 66;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    PlaybackResult *result=[PlaybackResult new];WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    config.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    config.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
    [config.userContentController addScriptMessageHandler:result name:@"result"];
    WKWebView *web=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,640,400) configuration:config];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,100,640,400)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"NativeMac authored video playback check";window.contentView=web;[window orderFront:nil];
    NSData *urlData=[NSJSONSerialization dataWithJSONObject:@[movie.absoluteString] options:0 error:nil];
    NSString *urlArray=[[NSString alloc] initWithData:urlData encoding:NSUTF8StringEncoding];
    NSString *html=[NSString stringWithFormat:@"<!doctype html><meta charset=utf-8><video id=v muted autoplay loop playsinline width=640 height=360></video><canvas id=c width=1 height=1></canvas><script>"
        "let done=false,frames=0,changes=0,last='',started=performance.now();const v=document.getElementById('v'),c=document.getElementById('c'),ctx=c.getContext('2d',{willReadFrequently:true});"
        "function report(passed,error){if(done)return;done=true;window.webkit.messageHandlers.result.postMessage({stage:'webkit-video-playback',passed,error,frames,changes,currentTime:v.currentTime,width:v.videoWidth,height:v.videoHeight,readyState:v.readyState});}"
        "function frame(){frames++;if(!done)v.requestVideoFrameCallback(frame);}if(v.requestVideoFrameCallback)v.requestVideoFrameCallback(frame);"
        "v.onerror=()=>report(false,v.error?{code:v.error.code,message:v.error.message}:'unknown video error');"
        "v.src=(%@)[0];v.play().catch(e=>report(false,String(e)));"
        "setInterval(()=>{try{if(v.readyState>=2){ctx.drawImage(v,0,0,1,1);let p=Array.from(ctx.getImageData(0,0,1,1).data).join(',');if(last&&last!==p)changes++;last=p;}"
        "if(!v.requestVideoFrameCallback)frames=v.getVideoPlaybackQuality().totalVideoFrames;"
        "if(frames>=30&&changes>=3&&v.videoWidth>0)report(true,null);else if(performance.now()-started>25000)report(false,'playback deadline');"
        "}catch(e){report(false,String(e));}},100);</script>",urlArray];
    NSURL *page=[[movie URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"authored-playback-check.html"];
    NSError *error=nil;if(![html writeToURL:page atomically:YES encoding:NSUTF8StringEncoding error:&error])return 1;
    [web loadFileURL:page allowingReadAccessToURL:movie.URLByDeletingLastPathComponent];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:35];
    while(!result.finished && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if(!result.finished)puts("{\"stage\":\"webkit-video-playback\",\"passed\":false,\"error\":\"web process deadline\"}");
    [window orderOut:nil];[config.userContentController removeScriptMessageHandlerForName:@"result"];
    return result.finished && result.passed?0:2;
}}
