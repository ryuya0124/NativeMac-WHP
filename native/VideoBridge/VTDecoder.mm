// Authored VideoToolbox decoder, also discoverable by explicitly opted-in consumers.
// No Apple component replacement or software video fallback.
#import <Foundation/Foundation.h>
#include "spi/VTVideoDecoderSPI.h"
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <libkern/OSByteOrder.h>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <os/log.h>
#include "VideoTransport.h"
#include <compression.h>
#include <chrono>

static constexpr OSStatus failed = -12909;
static constexpr int64_t timestampBias = 1000000000000000LL;
struct State {
    int fd=-1,writer=-1;
    size_t width=0,height=0;
    VTVideoDecoderSession session=nullptr;
    std::thread::id readerID;
    std::mutex writeMutex,pendingMutex;
    std::condition_variable drained;
    struct Frame {VTVideoDecoderFrame token;bool suppressOutput;};
    std::map<int64_t,std::deque<Frame>> pending;
    std::deque<std::vector<uint8_t>> output;
    std::atomic<bool> stopped{false},finished{false},ready{false},ended{false};
    std::atomic<unsigned> emitted{0},errors{0},barriers{0};
    uint64_t readNs=0,unpackNs=0,pixelNs=0,emitNs=0;
    size_t pendingCount=0;
    ~State(){if(writer>=0&&writer!=fd)close(writer);if(fd>=0)close(fd);}
};
using StateHandle=std::shared_ptr<State>;
static StateHandle &handle(CMBaseObjectRef object){return *static_cast<StateHandle*>(CMBaseObjectGetDerivedStorage(object));}
static State *state(CMBaseObjectRef object){
    return handle(object).get();
}
static bool transfer(int fd,void *data,size_t count,bool sending){
    return NativeMacVideoTransfer(fd,data,count,sending);
}
static bool writeMessage(State *s,const std::vector<uint8_t> &body){
    uint32_t size=htonl(static_cast<uint32_t>(body.size()));
    return transfer(s->writer,&size,4,true)&&transfer(s->writer,const_cast<uint8_t*>(body.data()),body.size(),true);
}
static bool readMessage(State *s,std::vector<uint8_t> &body,size_t limit){
    uint32_t size;
    if(!transfer(s->fd,&size,4,false))return false;
    size=ntohl(size);if(!size||size>limit)return false;
    body.resize(size);return transfer(s->fd,body.data(),size,false);
}
static void failPending(State *s, bool cancelled=false){
    std::map<int64_t,std::deque<State::Frame>> pending;
    {std::lock_guard lock(s->pendingMutex);pending.swap(s->pending);s->pendingCount=0;}
    for(auto &[pts,frames]:pending){(void)pts;for(auto frame:frames){
        VTDecoderSessionEmitDecodedFrame(s->session,frame.token,cancelled?0:failed,kVTDecodeInfo_FrameDropped,nullptr);
        if(!cancelled)s->errors++;
    }}
    s->drained.notify_all();
}
static void emitReady(State *s);
static uint64_t elapsed(std::chrono::steady_clock::time_point start){
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count());
}
static void receiveFrames(StateHandle owner){@autoreleasepool{
    State *s=owner.get();
    std::vector<uint8_t> body;
    unsigned received=0;bool complete=false;
    while(!s->stopped){
        auto readStart=std::chrono::steady_clock::now();
        bool read=readMessage(s,body,s->width*s->height*3/2+9);
        s->readNs+=elapsed(readStart);
        if(!read)break;
        if(body==std::vector<uint8_t>{'G'}){s->barriers++;s->drained.notify_all();continue;}
        if(body[0]=='E'&&body.size()==5){
            uint32_t count;memcpy(&count,body.data()+1,4);complete=ntohl(count)==received;break;
        }
        size_t pixels=s->width*s->height*3/2;
        if(body[0]=='L'&&body.size()>9){
            auto unpackStart=std::chrono::steady_clock::now();
            std::vector<uint8_t> raw(pixels+9);raw[0]='R';memcpy(raw.data()+1,body.data()+1,8);
            size_t decoded=compression_decode_buffer(raw.data()+9,pixels,body.data()+9,body.size()-9,nullptr,COMPRESSION_LZ4_RAW);
            if(decoded!=pixels){s->errors++;break;}
            body=std::move(raw);
            s->unpackNs+=elapsed(unpackStart);
        }
        if(body[0]!='R'||body.size()!=pixels+9){s->errors++;break;}
        std::unique_lock lock(s->pendingMutex);
        s->drained.wait(lock,[&]{return s->output.size()<4||s->stopped;});
        if(s->stopped)break;
        s->output.push_back(std::move(body));received++;
        s->drained.notify_all();
        lock.unlock();
        emitReady(s);
    }
    if(!complete&&!s->stopped)s->errors++;
    os_log(OS_LOG_DEFAULT,"NativeMac video timings frames=%u read_ms=%llu unpack_ms=%llu pixel_ms=%llu emit_ms=%llu",s->emitted.load(),(unsigned long long)(s->readNs/1000000),(unsigned long long)(s->unpackNs/1000000),(unsigned long long)(s->pixelNs/1000000),(unsigned long long)(s->emitNs/1000000));
    s->ended=true;s->drained.notify_all();
}}
// The single receiver owns output emission. Decode reports asynchronous work;
// output does not depend on a later API call arriving to pump the queue.
static void emitReady(State *s){
    for(;;){
        std::vector<uint8_t> body;
        {std::lock_guard lock(s->pendingMutex);
            if(s->stopped||s->output.empty())return;
            body=std::move(s->output.front());s->output.pop_front();
        }
        s->drained.notify_all();
        uint64_t wire;memcpy(&wire,body.data()+1,8);
        int64_t pts=static_cast<int64_t>(OSSwapBigToHostInt64(wire));
        VTVideoDecoderFrame frame=nullptr;
        bool suppress=false;
        int64_t firstPending=0,lastPending=0;
        {std::lock_guard lock(s->pendingMutex);
            auto found=s->pending.lower_bound(pts-100);
            if(found!=s->pending.end()&&found->first<=pts+100){
                frame=found->second.front().token;suppress=found->second.front().suppressOutput;found->second.pop_front();
                s->pendingCount--;
                if(found->second.empty())s->pending.erase(found);
            }
            if(!frame&&!s->pending.empty()){firstPending=s->pending.begin()->first;lastPending=s->pending.rbegin()->first;}
        }
        if(!frame){os_log_error(OS_LOG_DEFAULT,"NativeMac video output has no matching frame pts=%lld first=%lld last=%lld",(long long)pts,(long long)firstPending,(long long)lastPending);s->errors++;continue;}
        if(suppress){
            if(VTDecoderSessionEmitDecodedFrame(s->session,frame,0,kVTDecodeInfo_FrameDropped,nullptr))s->errors++;
            s->drained.notify_all();continue;
        }
        CVPixelBufferRef pixel=nullptr;
        auto pixelStart=std::chrono::steady_clock::now();
        OSStatus status=CVPixelBufferPoolCreatePixelBuffer(nullptr,VTDecoderSessionGetPixelBufferPool(s->session),&pixel);
        if(!status){
            status=CVPixelBufferLockBaseAddress(pixel,0);
            if(!status){
                const uint8_t *source=body.data()+9;
                for(size_t plane=0;plane<2;++plane){
                    size_t rows=plane?s->height/2:s->height;
                    auto *dest=static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel,plane));
                    size_t stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
                    if(!dest||stride<s->width){status=failed;break;}
                    for(size_t row=0;row<rows;++row){memcpy(dest+row*stride,source,s->width);source+=s->width;}
                }
                CVPixelBufferUnlockBaseAddress(pixel,0);
            }
        }
        s->pixelNs+=elapsed(pixelStart);
        auto emitStart=std::chrono::steady_clock::now();
        OSStatus emitted=VTDecoderSessionEmitDecodedFrame(s->session,frame,status,0,status?nullptr:pixel);
        s->emitNs+=elapsed(emitStart);
        if(pixel)CFRelease(pixel);
        if(status||emitted){os_log_error(OS_LOG_DEFAULT,"NativeMac video output failed pixel=%d emit=%d",(int)status,(int)emitted);s->errors++;}else s->emitted++;
        s->drained.notify_all();
    }
}
static OSStatus invalidate(CMBaseObjectRef object){
    State *s=state(object);if(!s)return 0;
    s->stopped=true;
    {std::lock_guard guard(s->writeMutex);
        if(s->fd>=0&&s->writer==s->fd)shutdown(s->fd,SHUT_RDWR);
        else if(s->writer>=0){close(s->writer);s->writer=-1;}
    }
    s->drained.notify_all();
    // Do not join the output thread here: it can be inside EmitDecodedFrame
    // waiting for the framework lock held by this invalidation callback.
    // Its shared State handle keeps storage and the socket alive. The public
    // session's subsequent frame wait accounts for an already emitting frame.
    // Invalidate precedes the framework's final asynchronous-frame wait. Every
    // accepted frame still needs a terminal notification, even when cancelled.
    failPending(s,true);
    return 0;
}
static void finalize(CMBaseObjectRef object){invalidate(object);handle(object).~StateHandle();}
static OSStatus copyProperty(CMBaseObjectRef object,CFStringRef key,CFAllocatorRef,void *out){
    if(!key||!out)return kVTParameterErr;
    if(CFEqual(key,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)){
        auto *s=state(object);*static_cast<CFTypeRef*>(out)=CFRetain(s&&s->ready?kCFBooleanTrue:kCFBooleanFalse);return 0;
    }
    return kCMBaseObjectError_ValueNotAvailable;
}
static OSStatus copySupported(VTVideoDecoderRef,CFDictionaryRef *out){@autoreleasepool{
    if(!out)return kVTParameterErr;
    NSDictionary *info=@{(__bridge NSString*)kVTPropertyTypeKey:(__bridge NSString*)kVTPropertyType_Boolean,
        (__bridge NSString*)kVTPropertyReadWriteStatusKey:(__bridge NSString*)kVTPropertyReadWriteStatus_ReadOnly};
    NSDictionary *properties=@{(__bridge NSString*)kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder:info};
    *out=static_cast<CFDictionaryRef>(CFRetain((__bridge CFTypeRef)properties));return 0;
}}
static OSStatus start(VTVideoDecoderRef object,VTVideoDecoderSession session,CMVideoFormatDescriptionRef format){@autoreleasepool{
    os_log(OS_LOG_DEFAULT,"NativeMac video decoder session start");
    State *s=state(reinterpret_cast<CMBaseObjectRef>(object));s->session=session;
    auto dimensions=CMVideoFormatDescriptionGetDimensions(format);
    if(dimensions.width<16||dimensions.height<16||dimensions.width>3840||dimensions.height>2160||dimensions.width%2||dimensions.height%2)return failed;
    s->width=dimensions.width;s->height=dimensions.height;
    auto codec=CMFormatDescriptionGetMediaSubType(format);
    NSString *codecName=(codec==kCMVideoCodecType_H264||codec=='nmq3')?@"h264":codec==kCMVideoCodecType_HEVC?@"hevc":codec==kCMVideoCodecType_VP9?@"vp9":nil;
    if(!codecName)return failed;
    NSDictionary *extensions=(__bridge NSDictionary*)CMFormatDescriptionGetExtensions(format);
    NSDictionary *atoms=extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms];
    bool vp9=codec==kCMVideoCodecType_VP9;
    NSData *config=atoms[vp9?@"vpcC":[codecName isEqualToString:@"h264"]?@"avcC":@"hvcC"];
    if(vp9&&!config)config=[NSData data];
    if(![config isKindOfClass:NSData.class]||(!vp9&&config.length<7)||config.length>65536)return failed;
    NSDictionary *attributes=@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString*)kCVPixelBufferWidthKey:@(s->width),(__bridge NSString*)kCVPixelBufferHeightKey:@(s->height),
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    OSStatus status=VTDecoderSessionSetPixelBufferAttributes(session,(__bridge CFDictionaryRef)attributes);
    if(status)return status;
    s->fd=NativeMacVideoOpenSocket(&s->writer);if(s->fd<0){os_log_error(OS_LOG_DEFAULT,"NativeMac video decoder transport connect failed errno=%d",errno);return failed;}
    int yes=1;setsockopt(s->fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    setsockopt(s->fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));
    timeval deadline{20,0};setsockopt(s->fd,SOL_SOCKET,SO_SNDTIMEO,&deadline,sizeof(deadline));
    setsockopt(s->fd,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline));
    NSDictionary *hello=@{@"version":@1,@"codec":codecName,@"width":@(s->width),@"height":@(s->height),@"configuration":[config base64EncodedStringWithOptions:0],@"compression":@"lz4-raw"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    std::vector<uint8_t> body(static_cast<const uint8_t*>(json.bytes),static_cast<const uint8_t*>(json.bytes)+json.length);
    const auto request=body;
    for(unsigned retry=0;;++retry){
        if(!writeMessage(s,request)){os_log_error(OS_LOG_DEFAULT,"NativeMac video decoder hello write failed errno=%d",errno);return failed;}
        if(!readMessage(s,body,256)){os_log_error(OS_LOG_DEFAULT,"NativeMac video decoder hello read failed errno=%d",errno);return failed;}
        if(body==std::vector<uint8_t>{'A'})break;
        if(body!=std::vector<uint8_t>{'B'}||retry>=39)return failed;
        if(s->writer!=s->fd)close(s->writer);close(s->fd);s->fd=s->writer=-1;std::this_thread::sleep_for(std::chrono::milliseconds(50));
        s->fd=NativeMacVideoOpenSocket(&s->writer);if(s->fd<0)return failed;
        setsockopt(s->fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
        setsockopt(s->fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));
        setsockopt(s->fd,SOL_SOCKET,SO_SNDTIMEO,&deadline,sizeof(deadline));
        setsockopt(s->fd,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline));
    }
    deadline.tv_sec=300;setsockopt(s->fd,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline));
    std::thread receiver(receiveFrames,handle(reinterpret_cast<CMBaseObjectRef>(object)));
    s->readerID=receiver.get_id();s->ready=true;receiver.detach();return 0;
}}
static OSStatus decode(VTVideoDecoderRef object,VTVideoDecoderFrame frame,CMSampleBufferRef sample,VTDecodeFrameFlags requested,VTDecodeInfoFlags *flags){
    StateHandle owner=handle(reinterpret_cast<CMBaseObjectRef>(object));auto *s=owner.get();
    auto reject=[&](OSStatus status){
        os_log_error(OS_LOG_DEFAULT,"NativeMac video decode rejected status=%d ready=%d stopped=%d ended=%d",(int)status,s->ready.load(),s->stopped.load(),s->ended.load());
        if(flags)*flags=kVTDecodeInfo_FrameDropped;
        // A failed decode return belongs to the framework. Emitting the same
        // frame as well would provide two terminal notifications.
        return status;
    };
    if(!s->ready||s->stopped||s->finished||s->ended)return reject(failed);
    CMTime time=CMSampleBufferGetPresentationTimeStamp(sample);
    if(!CMTIME_IS_NUMERIC(time))return reject(failed);
    int64_t ns=CMTimeConvertScale(time,1000000000,kCMTimeRoundingMethod_Default).value;
    if(ns < -timestampBias || ns > timestampBias)return reject(failed);
    ns+=timestampBias;
    CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
    size_t count=block?CMBlockBufferGetDataLength(block):0;
    if(!count||count>8*1024*1024)return reject(failed);
    std::vector<uint8_t> body(count+10);body[0]='P';uint64_t wire=OSSwapHostToBigInt64(static_cast<uint64_t>(ns));memcpy(body.data()+1,&wire,8);
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,false);
    bool key=true;
    if(attachments&&CFArrayGetCount(attachments)){
        CFDictionaryRef first=static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments,0));
        key=!CFDictionaryContainsKey(first,kCMSampleAttachmentKey_NotSync)||CFDictionaryGetValue(first,kCMSampleAttachmentKey_NotSync)==kCFBooleanFalse;
    }
    body[9]=key;
    if(CMBlockBufferCopyDataBytes(block,0,count,body.data()+10))return reject(failed);
    bool reserved=false;
    {std::unique_lock lock(s->pendingMutex);
        auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
        while(s->pendingCount>=64&&!s->stopped&&!s->ended){
            if(!s->drained.wait_until(lock,deadline,[&]{return s->pendingCount<64||s->stopped||s->ended;}))break;
        }
        if(!s->stopped&&!s->ended&&s->pendingCount<64){s->pending[ns].push_back({frame,(requested&kVTDecodeFrame_DoNotOutputFrame)!=0});s->pendingCount++;reserved=true;}
    }
    if(!reserved)return reject(failed);
    std::lock_guard writeLock(s->writeMutex);
    if(flags)*flags=kVTDecodeInfo_Asynchronous;
    if(!writeMessage(s,body)){
        {std::lock_guard lock(s->pendingMutex);
            auto found=s->pending.find(ns);
            if(found!=s->pending.end()){found->second.pop_back();s->pendingCount--;if(found->second.empty())s->pending.erase(found);}
        }
        if(s->writer==s->fd)shutdown(s->fd,SHUT_RDWR);else if(s->writer>=0){close(s->writer);s->writer=-1;}
        return reject(failed);
    }
    return 0;
}
// A nonterminal queue barrier preserves reference pictures for further input.
static OSStatus finish(VTVideoDecoderRef object){
    StateHandle owner=handle(reinterpret_cast<CMBaseObjectRef>(object));auto *s=owner.get();
    if(s->stopped){failPending(s,true);return 0;}
    unsigned barrier;
    {std::lock_guard lock(s->writeMutex);barrier=s->barriers.load()+1;if(!writeMessage(s,{'G'}))return failed;}
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
    for(;;){
        std::unique_lock lock(s->pendingMutex);
        if(s->barriers>=barrier&&!s->pendingCount)break;
        if(s->ended||s->stopped)return failed;
        if(!s->drained.wait_until(lock,deadline,[&]{return (s->barriers>=barrier&&!s->pendingCount)||s->ended||s->stopped;}))return failed;
    }
    return s->errors?failed:0;
}

// The x86-64 SDK declares a 32-bit version with packed fields; padding before
// each class keeps its pointer fields naturally aligned. ARM64 uses 64 bits.
#if defined(__x86_64__)
static_assert(sizeof(CMBaseClassVersion)==4);
#pragma pack(push,4)
struct BaseWrapper {uint32_t pad;CMBaseClass value;};
// WebKit deliberately leaves drain as TBD. Keep the verified class layout but
// type our callback separately instead of casting incompatible function types.
struct DecoderWithDrain {
    CMBaseClassVersion version;
    VTVideoDecoderFunction_StartSession startSession;
    VTVideoDecoderFunction_DecodeFrame decodeFrame;
    decltype(&copySupported) copySupportedPropertyDictionary;
    VTVideoDecoderFunction_TBD setProperties;
    VTVideoDecoderFunction_TBD copySerializableProperties,canAcceptFormatDescription;
    decltype(&finish) finishDelayedFrames;
    VTVideoDecoderFunction_TBD reserved7,reserved8,reserved9;
};
struct DecoderWrapper {uint32_t pad;DecoderWithDrain value;};
static const BaseWrapper baseWrapper={0,{1,sizeof(StateHandle),nullptr,invalidate,finalize,nullptr,copyProperty,nullptr,nullptr,nullptr}};
static const DecoderWrapper decoderWrapper={0,{2,start,decode,copySupported,nullptr,nullptr,nullptr,finish,nullptr,nullptr,nullptr}};
#pragma pack(pop)
static_assert(offsetof(BaseWrapper,value)==4&&offsetof(DecoderWrapper,value)==4);
static_assert(sizeof(DecoderWithDrain)==sizeof(VTVideoDecoderClass));
static_assert(offsetof(DecoderWithDrain,finishDelayedFrames)==offsetof(VTVideoDecoderClass,finishDelayedFrames));
static const VTVideoDecoderVTable table={{nullptr,&baseWrapper.value},reinterpret_cast<const VTVideoDecoderClass*>(&decoderWrapper.value)};
#else
#error This experimental component is qualified only for the Intel guest ABI.
#endif

extern "C" OSStatus NativeMacNVDECCreate(FourCharCode codec,CFAllocatorRef allocator,VTVideoDecoderRef *out){
    if(!out)return kVTParameterErr;*out=nullptr;
    if(codec!=kCMVideoCodecType_H264&&codec!=kCMVideoCodecType_HEVC&&codec!=kCMVideoCodecType_VP9&&codec!='nmq3')return kVTVideoDecoderUnsupportedDataFormatErr;
    CMBaseObjectRef object=nullptr;
    OSStatus status=CMDerivedObjectCreate(allocator,&table.base,VTVideoDecoderGetClassID(),&object);
    if(status)return status;
    new (CMBaseObjectGetDerivedStorage(object)) StateHandle;
    try{handle(object)=std::make_shared<State>();}
    catch(const std::bad_alloc&){CFRelease(object);return kVTAllocationFailedErr;}
    *out=reinterpret_cast<VTVideoDecoderRef>(object);return 0;
}
