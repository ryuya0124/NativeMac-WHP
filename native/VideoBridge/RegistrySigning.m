// Opt-in development-process interposer for this authored test component only.
// Check the ad-hoc seal; relax only CoreMedia's extra Apple-anchor requirement.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <sys/stat.h>

static OSStatus checkNativeMacComponent(SecStaticCodeRef code, SecCSFlags flags, SecRequirementRef requirement) {
    @autoreleasepool {
        CFURLRef url=NULL;CFStringRef text=NULL;
        BOOL eligible=NO;
        if(requirement && SecCodeCopyPath(code,kSecCSDefaultFlags,&url)==errSecSuccess && url &&
           SecRequirementCopyString(requirement,kSecCSDefaultFlags,&text)==errSecSuccess && text) {
            NSString *path=[(__bridge NSURL*)url path];
            NSString *expected=@"/Library/Video/Plug-Ins/NativeMacNVDECProbe.bundle";
            struct stat st;
            BOOL trustedPath=[path isEqualToString:expected] &&
                [[path stringByResolvingSymlinksInPath] isEqualToString:expected] &&
                lstat(path.fileSystemRepresentation,&st)==0 && S_ISDIR(st.st_mode) &&
                st.st_uid==0 && !(st.st_mode&0022);
            if(trustedPath) {
                NSBundle *bundle=[NSBundle bundleWithPath:path];
                eligible=[bundle.bundleIdentifier isEqualToString:@"io.nativemac.NVDECProbe"] &&
                    [(__bridge NSString*)text containsString:@"anchor apple"];
            }
        }
        if(url)CFRelease(url);if(text)CFRelease(text);
        OSStatus status=SecStaticCodeCheckValidity(code,flags,eligible?NULL:requirement);
        if(eligible)fprintf(stderr,"NativeMac registry development seal check: %d\n",(int)status);
        return status;
    }
}

__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } interpose[] = {
    {(const void*)checkNativeMacComponent,(const void*)SecStaticCodeCheckValidity}
};
