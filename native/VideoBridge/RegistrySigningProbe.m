#import <Foundation/Foundation.h>
#import <Security/Security.h>

int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;
    NSURL *url=[NSURL fileURLWithPath:@(argv[1])];
    SecStaticCodeRef code=NULL;SecRequirementRef requirement=NULL;
    OSStatus created=SecStaticCodeCreateWithPath((__bridge CFURLRef)url,kSecCSDefaultFlags,&code);
    OSStatus made=SecRequirementCreateWithString(CFSTR("anchor apple"),kSecCSDefaultFlags,&requirement);
    OSStatus seal=created?:SecStaticCodeCheckValidity(code,kSecCSStrictValidate,NULL);
    OSStatus anchored=created?:made?:SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement);
    NSDictionary *report=@{@"codeStatus":@(created),@"sealStatus":@(seal),@"appleAnchorStatus":@(anchored)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);return 0;
}}
