#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>

int main(int argc,char **argv){@autoreleasepool{
    if(argc<2||argc>3)return 64;
    id<MTLDevice> original=MTLCreateSystemDefaultDevice();if(!original)return 2;
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(original.registryID));
    if(!service)return 3;
    NSBundle *bundle=[NSBundle bundleWithPath:@(argv[1])];NSError *error=nil;
    if(![bundle loadAndReturnError:&error]){fprintf(stderr,"identity bundle load failed: %ld\n",(long)error.code);IOObjectRelease(service);return 4;}
    Class principal=argc==3?NSClassFromString(@"AppleParavirtDevice"):bundle.principalClass;
    id<MTLDevice> device=((id(*)(id,SEL,mach_port_t))objc_msgSend)([principal alloc],sel_registerName("initWithAcceleratorPort:"),service);
    IOObjectRelease(service);
    if(!device){fprintf(stderr,"identity device initialization failed\n");return 5;}
    NSError *compile=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;kernel void write_values(device uint *p[[buffer(0)]],uint i[[thread_position_in_grid]]){p[i]=i*7+3;}" options:nil error:&compile];
    id<MTLComputePipelineState> pipeline=library?[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"write_values"] error:&compile]:nil;
    if(!pipeline){fprintf(stderr,"identity pipeline failed: %s; device=%s class=%s registry=%llu original=%llu\n",compile.description.UTF8String,device.name.UTF8String,object_getClassName(device),(unsigned long long)device.registryID,(unsigned long long)original.registryID);return 6;}
    id<MTLBuffer> buffer=[device newBufferWithLength:4096*4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];[encoder setComputePipelineState:pipeline];[encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(4096,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[encoder endEncoding];[command commit];[command waitUntilCompleted];
    unsigned wrong=0;const uint32_t *words=buffer.contents;for(unsigned i=0;i<4096;i++)if(words[i]!=i*7+3)wrong++;
    BOOL passed=command.status==MTLCommandBufferStatusCompleted&&!wrong&&device.registryID==original.registryID;
    NSDictionary *report=@{@"originalName":original.name,@"deviceName":device.name,@"sameRegistryID":@(device.registryID==original.registryID),@"checkedValues":@4096,@"mismatches":@(wrong),@"passed":@(passed)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:7;
}}
