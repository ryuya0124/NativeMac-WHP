// Metadata-only Metal driver entry. Rendering stays in the existing driver;
// no GPU capability, resource method, shader or command is replaced.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface IOGPUMetalDevice : NSObject
@end

// The compiler resolves the vendor bundle from this class. Keep the original
// compiler identity while the real Objective-C subclass adds only -name.
static Class compilerClass(id object,SEL selector){
    (void)selector;
    return class_getSuperclass(object_getClass(object));
}

static NSString *hostName(id object,SEL selector){
    id<MTLDevice> device=object;
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(device.registryID));
    NSString *name=nil;
    if(service){
        CFTypeRef property=IORegistryEntrySearchCFProperty(service,kIOServicePlane,CFSTR("reims-gpu-model"),
            kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
        if(property){
            if(CFGetTypeID(property)==CFDataGetTypeID()){
                CFDataRef data=property;CFIndex count=CFDataGetLength(data);
                const UInt8 *bytes=CFDataGetBytePtr(data);
                if(count>=2&&count<=64&&bytes[count-1]==0){
                    BOOL valid=YES;for(CFIndex i=0;i<count-1;i++)if(bytes[i]<32||bytes[i]>126)valid=NO;
                    if(valid)name=[[[NSString alloc] initWithBytes:bytes length:(NSUInteger)count-1 encoding:NSASCIIStringEncoding] autorelease];
                }
            }
            CFRelease(property);
        }
        IOObjectRelease(service);
    }
    if(name)return name;
    struct objc_super parent={object,class_getSuperclass(object_getClass(object))};
    return ((NSString *(*)(struct objc_super *,SEL))objc_msgSendSuper)(&parent,selector);
}

static Class namedDeviceClass(void){
    static Class result=Nil;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSBundle *original=[NSBundle bundleWithPath:@"/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle"];
        NSError *error=nil;
        if(![original loadAndReturnError:&error]){NSLog(@"NativeMac Metal identity: stock driver unavailable (%ld)",(long)error.code);return;}
        Class parent=NSClassFromString(@"AppleParavirtDevice");
        if(!parent)return;
        Class cls=objc_allocateClassPair(parent,"NativeMacHostNamedDevice",0);
        if(!cls)return;
        if(!class_addMethod(cls,@selector(name),(IMP)hostName,"@@:")){objc_disposeClassPair(cls);return;}
        if(!class_addMethod(cls,@selector(class),(IMP)compilerClass,"#@:")){objc_disposeClassPair(cls);return;}
        objc_registerClassPair(cls);result=cls;
    });
    return result;
}

@interface NativeMacMetalDevice : IOGPUMetalDevice
@end
@implementation NativeMacMetalDevice
// Return a native driver allocation with precisely the parent's layout.
// Its normal initializer, lifetime and every GPU method remain inherited.
+ (id)alloc {return [namedDeviceClass() alloc];}
+ (id)allocWithZone:(NSZone*)zone {return [namedDeviceClass() allocWithZone:zone];}
@end
