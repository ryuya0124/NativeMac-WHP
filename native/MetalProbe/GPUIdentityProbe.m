#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device)return 2;
    NSMutableDictionary *report=[@{@"metalName":device.name} mutableCopy];
    @try {
        struct objc_super parent={device,class_getSuperclass([device class])};
        NSString *name=((NSString *(*)(struct objc_super *,SEL))objc_msgSendSuper)(&parent,@selector(name));
        if(name)report[@"superclassName"]=name;
    } @catch(NSException *exception) {
        report[@"superclassNameUnavailable"]=exception.name;
    }
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(device.registryID));
    if(service){
        CFTypeRef model=IORegistryEntrySearchCFProperty(service,kIOServicePlane,CFSTR("model"),
            kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
        if(model){
            id value=(__bridge id)model;
            if([value isKindOfClass:NSData.class]){
                NSData *bytes=value;size_t length=bytes.length;
                const char *text=bytes.bytes;
                if(length&&text[length-1]==0)--length;
                value=[[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
            }
            if([value isKindOfClass:NSString.class])report[@"registryModel"]=value;
            CFRelease(model);
        }
        IOObjectRelease(service);
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes,1,data.length,stdout);puts("");return 0;
}}
