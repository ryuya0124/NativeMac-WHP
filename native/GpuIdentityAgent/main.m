// Publish the real host model through Metal's existing display-name setting.
// No device IDs, capability claims, driver images or GPU commands are changed.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <unistd.h>
#include <string.h>

static BOOL clearManagedName(void) {
    CFTypeRef managed=CFPreferencesCopyValue(CFSTR("publishedName"),CFSTR("io.nativemac.gpu-identity"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    CFTypeRef actual=CFPreferencesCopyValue(CFSTR("forceDeviceName"),CFSTR("com.apple.Metal"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    BOOL changed=managed&&actual&&CFEqual(managed,actual);
    if(changed)CFPreferencesSetValue(CFSTR("forceDeviceName"),NULL,CFSTR("com.apple.Metal"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR("publishedName"),NULL,CFSTR("io.nativemac.gpu-identity"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    BOOL synchronized=CFPreferencesSynchronize(CFSTR("com.apple.Metal"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    synchronized=CFPreferencesSynchronize(CFSTR("io.nativemac.gpu-identity"),kCFPreferencesAnyUser,kCFPreferencesAnyHost)&&synchronized;
    if(managed)CFRelease(managed);if(actual)CFRelease(actual);return synchronized;
}

static NSString *hostModel(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleParavirtAccelerator"));
    if(!service)return nil;
    CFTypeRef property=IORegistryEntrySearchCFProperty(service,kIOServicePlane,CFSTR("reims-gpu-model"),
        kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
    IOObjectRelease(service);
    if(!property)return nil;
    NSString *name=nil;
    if(CFGetTypeID(property)==CFDataGetTypeID()){
        CFDataRef data=property;CFIndex count=CFDataGetLength(data);const UInt8 *bytes=CFDataGetBytePtr(data);
        if(count>=2&&count<=64&&bytes[count-1]==0){
            BOOL valid=YES;for(CFIndex i=0;i<count-1;i++)if(bytes[i]<32||bytes[i]>126)valid=NO;
            if(valid)name=[[NSString alloc] initWithBytes:bytes length:(NSUInteger)count-1 encoding:NSASCIIStringEncoding];
        }
    }
    CFRelease(property);return name;
}

int main(int argc,char **argv){@autoreleasepool{
    if(geteuid()!=0){fprintf(stderr,"Run as root to publish an all-user GPU display name.\n");return 77;}
    if(argc==2&&!strcmp(argv[1],"--clear-owned-name"))return clearManagedName()?0:3;
    if(argc!=1)return 64;
    NSString *name=nil;
    for(unsigned attempt=0;attempt<60&&!name;++attempt){name=hostModel();if(!name)sleep(1);}
    if(!name){clearManagedName();fprintf(stderr,"No validated Windows renderer metadata; removed any previously managed name.\n");return 2;}
    CFPreferencesSetValue(CFSTR("forceDeviceName"),(__bridge CFStringRef)name,CFSTR("com.apple.Metal"),
        kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    BOOL synchronized=CFPreferencesSynchronize(CFSTR("com.apple.Metal"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    CFTypeRef actual=CFPreferencesCopyValue(CFSTR("forceDeviceName"),CFSTR("com.apple.Metal"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
    BOOL matched=actual&&CFEqual(actual,(__bridge CFStringRef)name);if(actual)CFRelease(actual);
    if(synchronized&&matched){
        CFPreferencesSetValue(CFSTR("publishedName"),(__bridge CFStringRef)name,CFSTR("io.nativemac.gpu-identity"),kCFPreferencesAnyUser,kCFPreferencesAnyHost);
        synchronized=CFPreferencesSynchronize(CFSTR("io.nativemac.gpu-identity"),kCFPreferencesAnyUser,kCFPreferencesAnyHost)&&synchronized;
    }
    NSDictionary *report=@{@"hostModel":name,@"preferenceSynchronized":@(synchronized),@"readbackMatches":@(matched),@"scope":@"all-user Metal display name only"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");
    return synchronized&&matched?0:3;
}}
