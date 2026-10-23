// Authored NVENC VideoToolbox component. NV12 copies and transport are explicit.
#import <Foundation/Foundation.h>
#include "spi/NativeMacEncoderABI.h"
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <libkern/OSByteOrder.h>
#include <mutex>
#include <vector>
#include <os/log.h>
#include "VideoTransport.h"
static constexpr OSStatus failure=-12908;
static constexpr int64_t timestampBias=1000000000000000LL;
struct EncoderState {
    int fd=-1,writer=-1,width=0,height=0,bitrate=8000000,rate=30,gop=60,profile=0;FourCharCode codec=0;
    NMEncoderSession session=nullptr;CMVideoFormatDescriptionRef format=nullptr;
    bool stopped=false;std::mutex lock;
    ~EncoderState(){if(writer>=0&&writer!=fd)close(writer);if(fd>=0)close(fd);if(format)CFRelease(format);}
};
static EncoderState *state(CMBaseObjectRef object){return *static_cast<EncoderState**>(CMBaseObjectGetDerivedStorage(object));}
static bool transfer(int fd,void *data,size_t size,bool sendData){return NativeMacVideoTransfer(fd,data,size,sendData);}
static bool writeMessage(EncoderState*s,const std::vector<uint8_t>& b){uint32_t n=htonl(static_cast<uint32_t>(b.size()));return transfer(s->writer,&n,4,true)&&transfer(s->writer,const_cast<uint8_t*>(b.data()),b.size(),true);}
static bool readMessage(EncoderState*s,std::vector<uint8_t>& b,size_t limit){uint32_t n;if(!transfer(s->fd,&n,4,false))return false;n=ntohl(n);if(!n||n>limit)return false;b.resize(n);return transfer(s->fd,b.data(),n,false);}
static std::vector<NSData*> splitNAL(const std::vector<uint8_t>& b,size_t offset){
    std::vector<NSData*> result;size_t start=0;bool found=false;
    for(size_t i=offset;i+3<=b.size();){
        size_t prefix=0;
        if(i+4<=b.size()&&!b[i]&&!b[i+1]&&!b[i+2]&&b[i+3]==1)prefix=4;
        else if(!b[i]&&!b[i+1]&&b[i+2]==1)prefix=3;
        if(prefix){if(found&&i>start)result.push_back([NSData dataWithBytes:b.data()+start length:i-start]);start=i+prefix;found=true;i=start;}
        else i++;
    }
    if(found&&b.size()>start)result.push_back([NSData dataWithBytes:b.data()+start length:b.size()-start]);return result;
}
static OSStatus connectWorker(EncoderState *s){@autoreleasepool{
    if(s->fd>=0)return s->format?0:failure;
    NSDictionary *request=@{@"version":@1,@"operation":@"encode",@"codec":s->codec==kCMVideoCodecType_H264?@"h264":@"hevc",
        @"width":@(s->width),@"height":@(s->height),@"bitrate":@(s->bitrate),@"frameRate":@(s->rate),@"keyInterval":@(s->gop),@"profile":@(s->profile)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    std::vector<uint8_t> hello(static_cast<const uint8_t*>(json.bytes),static_cast<const uint8_t*>(json.bytes)+json.length),body;
    for(unsigned retry=0;;retry++){
        s->fd=NativeMacVideoOpenSocket(&s->writer);if(s->fd<0)return failure;int yes=1;
        setsockopt(s->fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));setsockopt(s->fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));
        timeval deadline{20,0};setsockopt(s->fd,SOL_SOCKET,SO_SNDTIMEO,&deadline,sizeof(deadline));setsockopt(s->fd,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline));
        if(!writeMessage(s,hello)||!readMessage(s,body,65537))return failure;
        if(body!=std::vector<uint8_t>{'B'})break;
        if(s->writer!=s->fd)close(s->writer);close(s->fd);s->fd=s->writer=-1;if(retry>=39)return failure;usleep(50000);
    }
    if(body.size()<8||body[0]!='A')return failure;
    auto units=splitNAL(body,1);std::vector<const uint8_t*> pointers;std::vector<size_t> sizes;
    for(NSData *unit:units){
        auto bytes=static_cast<const uint8_t*>(unit.bytes);unsigned type=s->codec==kCMVideoCodecType_H264?bytes[0]&31:(bytes[0]>>1)&63;
        if((s->codec==kCMVideoCodecType_H264&&(type==7||type==8))||(s->codec==kCMVideoCodecType_HEVC&&(type==32||type==33||type==34))){pointers.push_back(bytes);sizes.push_back(unit.length);}
    }
    if(pointers.size()!=(s->codec==kCMVideoCodecType_H264?2u:3u))return failure;
    return s->codec==kCMVideoCodecType_H264?
        CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr,pointers.size(),pointers.data(),sizes.data(),4,&s->format):
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(nullptr,pointers.size(),pointers.data(),sizes.data(),4,nullptr,&s->format);
}}
static OSStatus invalidate(CMBaseObjectRef object){auto s=state(object);if(!s)return 0;std::lock_guard guard(s->lock);s->stopped=true;if(s->fd>=0){if(s->writer==s->fd)shutdown(s->fd,SHUT_RDWR);else if(s->writer>=0)close(s->writer);close(s->fd);s->fd=s->writer=-1;}return 0;}
static void finalize(CMBaseObjectRef object){invalidate(object);delete state(object);}
static OSStatus copyProperty(CMBaseObjectRef object,CFStringRef key,CFAllocatorRef,void *out){
    if(!out)return kVTParameterErr;auto s=state(object);std::lock_guard guard(s->lock);
    CFTypeRef value=nullptr;
    if(CFEqual(key,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder))value=s->fd>=0&&s->format&&!s->stopped?kCFBooleanTrue:kCFBooleanFalse;
    else if(CFEqual(key,kVTCompressionPropertyKey_AllowFrameReordering))value=kCFBooleanFalse;
    else if(CFEqual(key,kVTCompressionPropertyKey_RealTime))value=kCFBooleanTrue;
    else if(CFEqual(key,kVTCompressionPropertyKey_AverageBitRate))value=(__bridge CFTypeRef)@(s->bitrate);
    else if(CFEqual(key,kVTCompressionPropertyKey_ExpectedFrameRate))value=(__bridge CFTypeRef)@(s->rate);
    else if(CFEqual(key,kVTCompressionPropertyKey_MaxKeyFrameInterval))value=(__bridge CFTypeRef)@(s->gop);
    else if(CFEqual(key,kVTCompressionPropertyKey_ProfileLevel))value=s->codec==kCMVideoCodecType_HEVC?kVTProfileLevel_HEVC_Main_AutoLevel:
        s->profile==1?CFSTR("H264_ConstrainedBaseline_AutoLevel"):s->profile==2?kVTProfileLevel_H264_High_AutoLevel:kVTProfileLevel_H264_Main_AutoLevel;
    else return kCMBaseObjectError_ValueNotAvailable;
    *static_cast<CFTypeRef*>(out)=CFRetain(value);return 0;
}
static OSStatus setProperty(CMBaseObjectRef object,CFStringRef key,CFTypeRef value){
    auto s=state(object);std::lock_guard guard(s->lock);if(s->stopped||s->fd>=0)return kVTPropertyNotSupportedErr;
    if(CFEqual(key,kVTCompressionPropertyKey_AllowFrameReordering))return value==kCFBooleanFalse?0:kVTPropertyNotSupportedErr;
    if(CFEqual(key,kVTCompressionPropertyKey_RealTime))return value==kCFBooleanTrue?0:kVTPropertyNotSupportedErr;
    if(CFEqual(key,kVTCompressionPropertyKey_ProfileLevel)){
        if(!value)return kVTParameterErr;
        if(s->codec==kCMVideoCodecType_HEVC)return CFEqual(value,kVTProfileLevel_HEVC_Main_AutoLevel)?0:kVTPropertyNotSupportedErr;
        if(CFEqual(value,kVTProfileLevel_H264_Main_AutoLevel))s->profile=0;
        else if(CFEqual(value,kVTProfileLevel_H264_Baseline_AutoLevel)||CFEqual(value,CFSTR("H264_ConstrainedBaseline_AutoLevel")))s->profile=1;
        else if(CFEqual(value,kVTProfileLevel_H264_High_AutoLevel))s->profile=2;
        else return kVTPropertyNotSupportedErr;return 0;
    }
    if(!value||CFGetTypeID(value)!=CFNumberGetTypeID())return kVTPropertyNotSupportedErr;
    int number;if(!CFNumberGetValue(static_cast<CFNumberRef>(value),kCFNumberIntType,&number))return kVTParameterErr;
    if(CFEqual(key,kVTCompressionPropertyKey_AverageBitRate)&&number>=64000&&number<=400000000)s->bitrate=number;
    else if(CFEqual(key,kVTCompressionPropertyKey_ExpectedFrameRate)&&number>=1&&number<=120)s->rate=number;
    else if(CFEqual(key,kVTCompressionPropertyKey_MaxKeyFrameInterval)&&number>=1&&number<=600)s->gop=number;
    else return kVTPropertyNotSupportedErr;return 0;
}
static OSStatus supported(NMEncoderRef,CFDictionaryRef*out){@autoreleasepool{
    if(!out)return kVTParameterErr;NSMutableDictionary *all=[NSMutableDictionary dictionary];
    for(NSString *key in @[(__bridge NSString*)kVTCompressionPropertyKey_RealTime,(__bridge NSString*)kVTCompressionPropertyKey_AllowFrameReordering,
        (__bridge NSString*)kVTCompressionPropertyKey_AverageBitRate,(__bridge NSString*)kVTCompressionPropertyKey_ExpectedFrameRate,(__bridge NSString*)kVTCompressionPropertyKey_MaxKeyFrameInterval]){
        BOOL boolean=[key isEqualToString:(__bridge NSString*)kVTCompressionPropertyKey_RealTime]||[key isEqualToString:(__bridge NSString*)kVTCompressionPropertyKey_AllowFrameReordering];
        all[key]=@{(__bridge NSString*)kVTPropertyTypeKey:(__bridge NSString*)(boolean?kVTPropertyType_Boolean:kVTPropertyType_Number),
            (__bridge NSString*)kVTPropertyReadWriteStatusKey:(__bridge NSString*)kVTPropertyReadWriteStatus_ReadWrite};
    }
    all[(__bridge NSString*)kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder]=@{
        (__bridge NSString*)kVTPropertyTypeKey:(__bridge NSString*)kVTPropertyType_Boolean,
        (__bridge NSString*)kVTPropertyReadWriteStatusKey:(__bridge NSString*)kVTPropertyReadWriteStatus_ReadOnly};
    all[(__bridge NSString*)kVTCompressionPropertyKey_ProfileLevel]=@{
        (__bridge NSString*)kVTPropertyTypeKey:(__bridge NSString*)kVTPropertyType_Enumeration,
        (__bridge NSString*)kVTPropertyReadWriteStatusKey:(__bridge NSString*)kVTPropertyReadWriteStatus_ReadWrite};
    *out=static_cast<CFDictionaryRef>(CFRetain((__bridge CFTypeRef)all));return 0;
}}
static OSStatus start(NMEncoderRef object,NMEncoderSession session,CMVideoDimensions dimensions){@autoreleasepool{
    os_log(OS_LOG_DEFAULT,"NativeMac video encoder session start");
    auto s=state(reinterpret_cast<CMBaseObjectRef>(object));if(dimensions.width<16||dimensions.width>3840||dimensions.height<16||dimensions.height>2160||dimensions.width%2||dimensions.height%2)return kVTParameterErr;
    s->session=session;s->width=dimensions.width;s->height=dimensions.height;
    NSDictionary *attributes=@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      (__bridge NSString*)kCVPixelBufferWidthKey:@(s->width),(__bridge NSString*)kCVPixelBufferHeightKey:@(s->height),(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    return VTEncoderSessionSetPixelBufferAttributes(session,(__bridge CFDictionaryRef)attributes);
}}
static OSStatus encode(NMEncoderRef object,NMEncoderFrame frame,CVPixelBufferRef pixel,CMTime pts,CMTime duration,CFDictionaryRef properties,VTEncodeInfoFlags*flags){@autoreleasepool{
    auto s=state(reinterpret_cast<CMBaseObjectRef>(object));std::unique_lock guard(s->lock);
    if(flags)*flags=0;if(s->stopped)return failure;
    if(!pixel||CVPixelBufferGetWidth(pixel)!=static_cast<size_t>(s->width)||CVPixelBufferGetHeight(pixel)!=static_cast<size_t>(s->height)||CVPixelBufferGetPixelFormatType(pixel)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange||!CMTIME_IS_NUMERIC(pts))return kVTParameterErr;
    int64_t ns=CMTimeConvertScale(pts,1000000000,kCMTimeRoundingMethod_Default).value;if(ns < -timestampBias||ns>timestampBias)return kVTParameterErr;
    OSStatus status=connectWorker(s);if(status)return status;
    std::vector<uint8_t> body(static_cast<size_t>(s->width)*s->height*3/2+10);body[0]='P';uint64_t wire=OSSwapHostToBigInt64(static_cast<uint64_t>(ns+timestampBias));memcpy(body.data()+1,&wire,8);
    CFTypeRef force=properties?CFDictionaryGetValue(properties,kVTEncodeFrameOptionKey_ForceKeyFrame):nullptr;body[9]=force==kCFBooleanTrue;
    status=CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);if(status)return status;size_t offset=10;
    for(size_t plane=0;plane<2;plane++){
        auto source=static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
        if(!source||stride<static_cast<size_t>(s->width)){status=failure;break;}
        for(int y=0;y<(plane?s->height/2:s->height);y++){memcpy(body.data()+offset,source+y*stride,s->width);offset+=s->width;}
    }
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);if(status)return status;
    if(!writeMessage(s,body)||!readMessage(s,body,8*1024*1024+10)||body.size()<11||body[0]!='R')return failure;
    uint64_t returned;memcpy(&returned,body.data()+1,8);if(OSSwapBigToHostInt64(returned)!=static_cast<uint64_t>(ns+timestampBias))return failure;
    auto units=splitNAL(body,10);if(units.empty())return failure;NSMutableData *coded=[NSMutableData data];
    for(NSData*unit:units){
        const auto bytes=static_cast<const uint8_t*>(unit.bytes);
        unsigned type=s->codec==kCMVideoCodecType_H264?bytes[0]&31:(bytes[0]>>1)&63;
        // avc1/hvc1 parameter sets live in the format description, not in-band.
        if(s->codec==kCMVideoCodecType_H264?(type==7||type==8||type==9):(type==32||type==33||type==34||type==35))continue;
        uint32_t n=htonl(static_cast<uint32_t>(unit.length));[coded appendBytes:&n length:4];[coded appendData:unit];
    }
    if(!coded.length)return failure;
    CMBlockBufferRef block=nullptr;CMSampleBufferRef sample=nullptr;size_t size=coded.length;
    status=CMBlockBufferCreateWithMemoryBlock(nullptr,nullptr,size,nullptr,nullptr,0,size,0,&block);
    if(!status)status=CMBlockBufferReplaceDataBytes(coded.bytes,block,0,size);
    CMSampleTimingInfo timing{CMTIME_IS_NUMERIC(duration)&&CMTimeCompare(duration,kCMTimeZero)>0?duration:CMTimeMake(1,s->rate),pts,pts};
    if(!status)status=CMSampleBufferCreateReady(nullptr,block,s->format,1,1,&timing,1,&size,&sample);
    if(!status){auto array=CMSampleBufferGetSampleAttachmentsArray(sample,true);auto dict=static_cast<CFMutableDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(array,0)));
        // Match Apple's sync-sample convention. Some standard consumers test
        // key presence rather than reading a false NotSync value.
        if(!body[9])CFDictionarySetValue(dict,kCMSampleAttachmentKey_NotSync,kCFBooleanTrue);
        guard.unlock();status=VTEncoderSessionEmitEncodedFrame(s->session,frame,0,0,sample);
    }
    if(sample)CFRelease(sample);if(block)CFRelease(block);return status;
}}
static OSStatus complete(NMEncoderRef,CMTime){return 0;}
#if !defined(__x86_64__)
#error This measured encoder ABI is restricted to the Intel guest.
#endif
#pragma pack(push,4)
static const struct {uint32_t pad;CMBaseClass value;} base={0,{1,sizeof(EncoderState*),nullptr,invalidate,finalize,nullptr,copyProperty,setProperty,nullptr,nullptr}};
static const struct {uint32_t pad;NMEncoderClass value;} encoder={0,{1,start,encode,complete,supported,{}}};
#pragma pack(pop)
static const struct {CMBaseVTable base;const NMEncoderClass*encoder;} table={{nullptr,&base.value},&encoder.value};
extern "C" OSStatus NativeMacNVENCCreate(FourCharCode codec,CFAllocatorRef allocator,NMEncoderRef*out){
    os_log(OS_LOG_DEFAULT,"NativeMac video encoder factory");
    if(!out)return kVTParameterErr;*out=nullptr;if(codec!=kCMVideoCodecType_H264&&codec!=kCMVideoCodecType_HEVC)return kVTParameterErr;
    CMBaseObjectRef object=nullptr;OSStatus status=CMDerivedObjectCreate(allocator,&table.base,VTVideoEncoderGetClassID(),&object);if(status)return status;
    auto storage=static_cast<EncoderState**>(CMBaseObjectGetDerivedStorage(object));*storage=nullptr;
    try{*storage=new EncoderState;(*storage)->codec=codec;}catch(const std::bad_alloc&){CFRelease(object);return kVTAllocationFailedErr;}
    *out=object;return 0;
}
