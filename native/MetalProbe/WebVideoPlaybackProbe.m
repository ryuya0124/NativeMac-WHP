#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

static void printJSON(NSDictionary *value){
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");fflush(stdout);
}

@interface WebPlaybackResult : NSObject<WKNavigationDelegate>
@property BOOL finished;
@property BOOL passed;
@property BOOL committed;
@property BOOL busy;
@property BOOL reportedDocument;
@property NSInteger httpStatus;
@property double firstTime;
@end
@implementation WebPlaybackResult
- (void)webView:(WKWebView*)webView didCommitNavigation:(WKNavigation*)navigation {
    (void)webView;(void)navigation;self.committed=YES;
}
- (void)webView:(WKWebView*)webView decidePolicyForNavigationResponse:(WKNavigationResponse*)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    (void)webView;
    if(response.forMainFrame&&[response.response isKindOfClass:NSHTTPURLResponse.class])self.httpStatus=((NSHTTPURLResponse*)response.response).statusCode;
    decisionHandler(WKNavigationResponsePolicyAllow);
}
- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error {
    (void)webView;(void)navigation;
    printJSON(@{@"stage":@"web-navigation",@"passed":@NO,@"domain":error.domain,@"code":@(error.code)});self.finished=YES;
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView*)webView {
    (void)webView;printJSON(@{@"stage":@"web-video-playback",@"passed":@NO,@"error":@"web content process terminated"});self.finished=YES;
}
@end

// An isolated foreground browser: no Safari control, saved cookies or account access.
// Native polling avoids relying on a site's lifetime for injected JavaScript timers.
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;NSURL *url=[NSURL URLWithString:@(argv[1])];
    if(![url.scheme isEqualToString:@"https"]||!url.host.length)return 64;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    id activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Bounded web video verification"];
    WebPlaybackResult *result=[WebPlaybackResult new];result.firstTime=-1;
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    config.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
    config.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    WKWebView *web=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,960,640) configuration:config];web.navigationDelegate=result;
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,100,960,640)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"NativeMac isolated web video check";window.contentView=web;[window makeKeyAndOrderFront:nil];[NSApp activate];
    [web loadRequest:[NSURLRequest requestWithURL:url]];
    NSString *sample=@"(()=>{const v=Array.from(document.querySelectorAll('video')).find(x=>x.videoWidth>0)||document.querySelector('video');"
        "if(!v)return {ready:document.readyState,videos:0,visibility:document.visibilityState};"
        "v.muted=true;if(v.paused)v.play().catch(()=>{});const q=v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():null;"
        "return {ready:document.readyState,videos:document.querySelectorAll('video').length,visibility:document.visibilityState,"
        "currentTime:v.currentTime,width:v.videoWidth,height:v.videoHeight,readyState:v.readyState,networkState:v.networkState,paused:v.paused,"
        "frames:q?q.totalVideoFrames:0,droppedFrames:q?q.droppedVideoFrames:0,error:v.error?{code:v.error.code,message:v.error.message}:null};})();";
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:75],*next=[NSDate date];
    while(!result.finished&&deadline.timeIntervalSinceNow>0){
        if(result.committed&&!result.busy&&next.timeIntervalSinceNow<=0){
            result.busy=YES;next=[NSDate dateWithTimeIntervalSinceNow:0.5];
            [web evaluateJavaScript:sample inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id value,NSError *error){
                result.busy=NO;if(result.finished)return;
                if(error){printJSON(@{@"stage":@"web-monitor",@"domain":error.domain,@"code":@(error.code)});result.finished=YES;return;}
                if(![value isKindOfClass:NSDictionary.class])return;
                NSDictionary *state=value;
                if(!result.reportedDocument&&[state[@"ready"] isEqual:@"complete"]){printJSON(@{@"stage":@"web-document",@"state":state});result.reportedDocument=YES;}
                if(state[@"error"]&&state[@"error"]!=NSNull.null){printJSON(@{@"stage":@"web-video-playback",@"passed":@NO,@"state":state});result.finished=YES;return;}
                double current=[state[@"currentTime"] doubleValue];
                if([state[@"readyState"] integerValue]>=2&&(result.firstTime<0||current<result.firstTime))result.firstTime=current;
                NSInteger shown=[state[@"frames"] integerValue]-[state[@"droppedFrames"] integerValue];
                if(shown>=30&&result.firstTime>=0&&current-result.firstTime>=1&&[state[@"width"] integerValue]>0){
                    printJSON(@{@"stage":@"web-video-playback",@"passed":@YES,@"state":state});result.passed=YES;result.finished=YES;
                }
            }];
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if(!result.finished)printJSON(@{@"stage":@"web-video-playback",@"passed":@NO,@"error":@"playback deadline",@"committed":@(result.committed),@"httpStatus":@(result.httpStatus),@"loading":@(web.loading)});
    [web stopLoading];[window orderOut:nil];[NSProcessInfo.processInfo endActivity:activity];
    return result.finished&&result.passed?0:2;
}}
