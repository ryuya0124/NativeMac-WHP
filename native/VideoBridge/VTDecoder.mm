// Experimental authored VideoToolbox decoder. Explicit probe registration only.
// No system component replacement, library injection or software video fallback.
#import <Foundation/Foundation.h>
#include "spi/VTVideoDecoderSPI.h"
#include <arpa/inet.h>
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

static constexpr OSStatus failed = -12909;
static constexpr int64_t timestampBias = 1000000000000000LL;
struct State {
    int fd=-1;
    size_t width=0,height=0;
    VTVideoDecoderSession session=nullptr;
    std::thread::id readerID;
    std::mutex writeMutex,pendingMutex;
    std::condition_variable drained;
    std::map<int64_t,std::deque<VTVideoDecoderFrame>> pending;
    std::deque<std::vector<uint8_t>> output;
    std::atomic<bool> stopped{false},finished{false},ready{false},ended{false};
    std::atomic<unsigned> emitted{0},errors{0};
    size_t pendingCount=0;
    ~State(){if(fd>=0)close(fd);}
};
using StateHandle=std::shared_ptr<State>;
static StateHandle &handle(CMBaseObjectRef object){return *static_cast<StateHandle*>(CMBaseObjectGetDerivedStorage(object));}
static State *state(CMBaseObjectRef object){
    return handle(object).get();
}
static bool transfer(int fd,void *data,size_t count,bool sending){
    auto *bytes=static_cast<uint8_t *>(data);
    while(count){
        ssize_t done=sending?send(fd,bytes,count,0):recv(fd,bytes,count,0);
        if(done<=0)return false;
        bytes+=done;count-=static_cast<size_t>(done);
    }
    return true;
}
static bool writeMessage(State *s,const std::vector<uint8_t> &body){
    uint32_t size=htonl(static_cast<uint32_t>(body.size()));
    return transfer(s->fd,&size,4,true)&&transfer(s->fd,const_cast<uint8_t*>(body.data()),body.size(),true);
}
static bool readMessage(State *s,std::vector<uint8_t> &body,size_t limit){
    uint32_t size;
    if(!transfer(s->fd,&size,4,false))return false;
    size=ntohl(size);if(!size||size>limit)return false;
    body.resize(size);return transfer(s->fd,body.data(),size,false);
}
static void failPending(State *s){
    std::map<int64_t,std::deque<VTVideoDecoderFrame>> pending;
    {std::lock_guard lock(s->pendingMutex);pending.swap(s->pending);s->pendingCount=0;}
    for(auto &[pts,frames]:pending){(void)pts;for(auto frame:frames){
        VTDecoderSessionEmitDecodedFrame(s->session,frame,failed,0,nullptr);s->errors++;
    }}
    s->drained.notify_all();
}
static void receiveFrames(StateHandle owner){@autoreleasepool{
    State *s=owner.get();
    std::vector<uint8_t> body;
    unsigned received=0;bool complete=false;
    while(!s->stopped&&readMessage(s,body,s->width*s->height*3/2+9)){
        if(body[0]=='E'&&body.size()==5){
            uint32_t count;memcpy(&count,body.data()+1,4);complete=ntohl(count)==received;break;
        }
        if(body[0]!='R'||body.size()!=s->width*s->height*3/2+9){s->errors++;break;}
        std::unique_lock lock(s->pendingMutex);
        s->drained.wait(lock,[&]{return s->output.size()<4||s->stopped;});
        if(s->stopped)break;
        s->output.push_back(std::move(body));received++;
        s->drained.notify_all();
    }
    if(!complete&&!s->stopped)s->errors++;
    s->ended=true;s->drained.notify_all();
}}
// Emit on the synchronous decoder entry points. Delayed/reordered pictures
// are buffered codec output, not outstanding asynchronous VT operations.
// Marking those pictures asynchronous made public Invalidate wait forever
// before it could call the decoder's invalidation callback.
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
        {std::lock_guard lock(s->pendingMutex);
            auto found=s->pending.lower_bound(pts-100);
            if(found!=s->pending.end()&&found->first<=pts+100){
                frame=found->second.front();found->second.pop_front();
                s->pendingCount--;
                if(found->second.empty())s->pending.erase(found);
            }
        }
        if(!frame){s->errors++;continue;}
        CVPixelBufferRef pixel=nullptr;
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
        OSStatus emitted=VTDecoderSessionEmitDecodedFrame(s->session,frame,status,0,status?nullptr:pixel);
        if(pixel)CFRelease(pixel);
        if(status||emitted)s->errors++;else s->emitted++;
        s->drained.notify_all();
    }
}
static OSStatus invalidate(CMBaseObjectRef object){
    State *s=state(object);if(!s)return 0;
    s->stopped=true;
    if(s->fd>=0)shutdown(s->fd,SHUT_RDWR);
    s->drained.notify_all();
    if(s->ready&&std::this_thread::get_id()!=s->readerID){
        std::unique_lock lock(s->pendingMutex);
        if(!s->drained.wait_for(lock,std::chrono::seconds(20),[&]{return s->ended.load();}))return failed;
    }
    return 0;
}
static void finalize(CMBaseObjectRef object){invalidate(object);handle(object).~StateHandle();}
static OSStatus copyProperty(CMBaseObjectRef object,CFStringRef key,CFAllocatorRef,void *out){
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
    State *s=state(reinterpret_cast<CMBaseObjectRef>(object));s->session=session;
    auto dimensions=CMVideoFormatDescriptionGetDimensions(format);
    if(dimensions.width<16||dimensions.height<16||dimensions.width>3840||dimensions.height>2160||dimensions.width%2||dimensions.height%2)return failed;
    s->width=dimensions.width;s->height=dimensions.height;
    auto codec=CMFormatDescriptionGetMediaSubType(format);
    NSString *codecName=(codec==kCMVideoCodecType_H264||codec=='nmq3')?@"h264":codec==kCMVideoCodecType_HEVC?@"hevc":nil;
    if(!codecName)return failed;
    NSDictionary *extensions=(__bridge NSDictionary*)CMFormatDescriptionGetExtensions(format);
    NSDictionary *atoms=extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms];
    NSData *config=atoms[[codecName isEqualToString:@"h264"]?@"avcC":@"hvcC"];
    if(![config isKindOfClass:NSData.class]||config.length<7||config.length>65536)return failed;
    NSDictionary *attributes=@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString*)kCVPixelBufferWidthKey:@(s->width),(__bridge NSString*)kCVPixelBufferHeightKey:@(s->height),
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    OSStatus status=VTDecoderSessionSetPixelBufferAttributes(session,(__bridge CFDictionaryRef)attributes);
    if(status)return status;
    s->fd=socket(AF_INET,SOCK_STREAM,0);if(s->fd<0)return failed;
    int yes=1;setsockopt(s->fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    timeval deadline{20,0};setsockopt(s->fd,SOL_SOCKET,SO_SNDTIMEO,&deadline,sizeof(deadline));
    setsockopt(s->fd,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline));
    sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(54885);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(connect(s->fd,reinterpret_cast<sockaddr*>(&address),sizeof(address)))return failed;
    NSDictionary *hello=@{@"version":@1,@"codec":codecName,@"width":@(s->width),@"height":@(s->height),@"configuration":[config base64EncodedStringWithOptions:0]};
    NSData *json=[NSJSONSerialization dataWithJSONObject:hello options:0 error:nil];
    std::vector<uint8_t> body(static_cast<const uint8_t*>(json.bytes),static_cast<const uint8_t*>(json.bytes)+json.length);
    if(!writeMessage(s,body)||!readMessage(s,body,256)||body!=std::vector<uint8_t>{'A'})return failed;
    deadline.tv_sec=300;setsockopt(s->fd,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline));
    std::thread receiver(receiveFrames,handle(reinterpret_cast<CMBaseObjectRef>(object)));
    s->readerID=receiver.get_id();s->ready=true;receiver.detach();return 0;
}}
static OSStatus decode(VTVideoDecoderRef object,VTVideoDecoderFrame frame,CMSampleBufferRef sample,VTDecodeFrameFlags requested,VTDecodeInfoFlags *flags){
    StateHandle owner=handle(reinterpret_cast<CMBaseObjectRef>(object));auto *s=owner.get();
    auto reject=[&](OSStatus status){
        if(flags)*flags=kVTDecodeInfo_FrameDropped;
        VTDecoderSessionEmitDecodedFrame(s->session,frame,status,kVTDecodeInfo_FrameDropped,nullptr);return status;
    };
    if(!s->ready||s->stopped||s->finished||s->ended)return reject(failed);
    // The CLI worker buffers/reorders pictures. Do not accept low-delay calls
    // until that separate mode can satisfy its per-frame completion contract.
    if(!(requested&kVTDecodeFrame_EnableTemporalProcessing))return reject(kVTPropertyNotSupportedErr);
    if(requested&kVTDecodeFrame_DoNotOutputFrame)return reject(kVTPropertyNotSupportedErr);
    emitReady(s);
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
            lock.unlock();emitReady(s);lock.lock();
            if(s->pendingCount<64)break;
            if(!s->drained.wait_until(lock,deadline,[&]{return !s->output.empty()||s->stopped||s->ended;}))break;
        }
        if(!s->stopped&&!s->ended&&s->pendingCount<64){s->pending[ns].push_back(frame);s->pendingCount++;reserved=true;}
    }
    if(!reserved)return reject(failed);
    std::lock_guard writeLock(s->writeMutex);
    if(flags)*flags=0;
    if(!writeMessage(s,body)){
        {std::lock_guard lock(s->pendingMutex);
            auto found=s->pending.find(ns);
            if(found!=s->pending.end()){found->second.pop_back();s->pendingCount--;if(found->second.empty())s->pending.erase(found);}
        }
        shutdown(s->fd,SHUT_RDWR);return reject(failed);
    }
    return 0;
}
// Probe-only drain closes the stream. Midstream drain/reset is not implemented.
// This component must not be selected for ordinary apps until that is qualified.
static OSStatus finish(VTVideoDecoderRef object){
    StateHandle owner=handle(reinterpret_cast<CMBaseObjectRef>(object));auto *s=owner.get();
    {std::lock_guard lock(s->writeMutex);if(!s->finished.exchange(true)&&!writeMessage(s,{'F'}))return failed;}
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);
    for(;;){
        emitReady(s);
        std::unique_lock lock(s->pendingMutex);
        if(s->ended&&s->output.empty())break;
        if(!s->drained.wait_until(lock,deadline,[&]{return !s->output.empty()||s->ended;}))return failed;
    }
    if(!s->stopped)failPending(s);
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
    if(codec!=kCMVideoCodecType_H264&&codec!=kCMVideoCodecType_HEVC&&codec!='nmq3')return kVTVideoDecoderUnsupportedDataFormatErr;
    CMBaseObjectRef object=nullptr;
    OSStatus status=CMDerivedObjectCreate(allocator,&table.base,VTVideoDecoderGetClassID(),&object);
    if(status)return status;
    new (CMBaseObjectGetDerivedStorage(object)) StateHandle;
    try{handle(object)=std::make_shared<State>();}
    catch(const std::bad_alloc&){CFRelease(object);return kVTAllocationFailedErr;}
    *out=reinterpret_cast<VTVideoDecoderRef>(object);return 0;
}
