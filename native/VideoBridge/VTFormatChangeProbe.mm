// Public API format-acceptance checks for the authored decoder.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include "spi/VTVideoDecoderSPI.h"
extern "C" OSStatus NativeMacNVDECCreate(FourCharCode,CFAllocatorRef,VTVideoDecoderRef*);
extern "C" OSStatus VTRegisterVideoDecoderWithInfo(FourCharCode,CFDictionaryRef,VTVideoDecoderFunction_CreateInstance);
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 64;
    NSData *data=[NSData dataWithContentsOfFile:@(argv[1])];if(!data)return 65;
    NSDictionary *input=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSData *configuration=[[NSData alloc] initWithBase64EncodedString:input[@"configuration"] options:0];
    if(!configuration||![input[@"codec"] isEqualToString:@"vp9"])return 65;
    int width=[input[@"width"] intValue],height=[input[@"height"] intValue];
    NSDictionary *extensions=@{(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:@{@"vpcC":configuration}};
    CMVideoFormatDescriptionRef format=nullptr,changed=nullptr;
    OSStatus status=CMVideoFormatDescriptionCreate(nullptr,kCMVideoCodecType_VP9,width,height,(__bridge CFDictionaryRef)extensions,&format);
    if(!status)status=CMVideoFormatDescriptionCreate(nullptr,kCMVideoCodecType_VP9,width+16,height,(__bridge CFDictionaryRef)extensions,&changed);
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
    NSDictionary *info=@{@"VTIsHardwareAccelerated":@YES,@"VTIsParavirtualizationAware":@YES,@"VTRating":@1000};
    if(!status)status=VTRegisterVideoDecoderWithInfo(kCMVideoCodecType_VP9,(__bridge CFDictionaryRef)info,NativeMacNVDECCreate);
    VTDecompressionSessionRef session=nullptr;
    NSDictionary *spec=@{(__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES};
    if(!status)status=VTDecompressionSessionCreate(nullptr,format,(__bridge CFDictionaryRef)spec,nullptr,nullptr,&session);
    bool same=false,different=true;
    if(!status){same=VTDecompressionSessionCanAcceptFormatDescription(session,format);different=VTDecompressionSessionCanAcceptFormatDescription(session,changed);}
    bool passed=!status&&same&&!different;
    printf("{\"createStatus\":%d,\"sameFormatAccepted\":%s,\"changedDimensionsAccepted\":%s,\"passed\":%s}\n",(int)status,same?"true":"false",different?"true":"false",passed?"true":"false");
    if(session){VTDecompressionSessionInvalidate(session);CFRelease(session);}if(format)CFRelease(format);if(changed)CFRelease(changed);
    return passed?0:1;
}}
