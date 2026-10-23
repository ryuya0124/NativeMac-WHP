// Capture only the explicitly selected virtual VM output, never a microphone.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#include <CoreAudio/CoreAudio.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <unistd.h>
#include <signal.h>
#include <atomic>
#include <array>
#include <cstring>
#include <cstdio>
#include <algorithm>
#include <memory>
static volatile sig_atomic_t stopped=0;
static void stop(int){stopped=1;}
struct Ring {
    static constexpr size_t capacity=65536;
    std::array<uint8_t,capacity> bytes{};
    std::atomic<uint64_t> written{0},read{0},dropped{0};
};
static OSStatus input(AudioDeviceID,const AudioTimeStamp*,const AudioBufferList*data,const AudioTimeStamp*,AudioBufferList*out,const AudioTimeStamp*,void*context){
    auto &ring=*static_cast<Ring*>(context);
    if(out)for(UInt32 i=0;i<out->mNumberBuffers;i++)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);
    if(!data||data->mNumberBuffers!=1)return 0;
    auto &buffer=data->mBuffers[0];size_t n=buffer.mDataByteSize;
    if(!buffer.mData||buffer.mNumberChannels!=2||n%8||n>ring.capacity)return 0;
    uint64_t at=ring.written.load(std::memory_order_relaxed);
    if(at-ring.read.load(std::memory_order_acquire)+n>ring.capacity){ring.dropped+=n/8;return 0;}
    size_t offset=at%ring.capacity,first=std::min(n,ring.capacity-offset);
    memcpy(ring.bytes.data()+offset,buffer.mData,first);memcpy(ring.bytes.data(),static_cast<const uint8_t*>(buffer.mData)+first,n-first);
    ring.written.store(at+n,std::memory_order_release);return 0;
}
static bool transfer(int fd,const void*data,size_t size){
    auto bytes=static_cast<const uint8_t*>(data);
    while(size&&!stopped){ssize_t n=send(fd,bytes,size,0);if(n<=0)return false;bytes+=n;size-=static_cast<size_t>(n);}return size==0;
}
static AudioDeviceID device(){
    AudioObjectPropertyAddress property{kAudioHardwarePropertyDeviceForUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    CFStringRef uid=CFSTR("BlackHole2ch_UID");AudioDeviceID found=kAudioObjectUnknown;
    AudioValueTranslation value{&uid,sizeof(uid),&found,sizeof(found)};UInt32 size=sizeof(value);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject,&property,0,nullptr,&size,&value)?kAudioObjectUnknown:found;
}
int main(){@autoreleasepool{
    signal(SIGTERM,stop);signal(SIGINT,stop);signal(SIGPIPE,SIG_IGN);
    AudioDeviceID selected=device();if(!selected){fprintf(stderr,"The qualified BlackHole 2ch virtual device is missing.\n");return 69;}
    [NSApplication sharedApplication];
    auto authorization=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if(authorization==AVAuthorizationStatusNotDetermined){
        [NSApp activate];
        struct Access {std::atomic<bool> done{false},allowed{false};};auto access=std::make_shared<Access>();
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted){access->allowed=granted;access->done=true;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:60];
        while(!access->done&&deadline.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
        if(!access->done||!access->allowed){fprintf(stderr,"Virtual audio capture permission was not granted.\n");return 77;}
    }else if(authorization!=AVAuthorizationStatusAuthorized){fprintf(stderr,"Virtual audio capture permission is disabled.\n");return 77;}
    AudioObjectPropertyAddress property{kAudioDevicePropertyStreamFormat,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription format{};UInt32 size=sizeof(format);
    if(AudioObjectGetPropertyData(selected,&property,0,nullptr,&size,&format)||format.mFormatID!=kAudioFormatLinearPCM||
       !(format.mFormatFlags&kAudioFormatFlagIsFloat)||(format.mFormatFlags&kAudioFormatFlagIsNonInterleaved)||format.mSampleRate!=48000||format.mChannelsPerFrame!=2||format.mBitsPerChannel!=32){fprintf(stderr,"Expected 48-kHz stereo float PCM on the virtual device.\n");return 69;}
    Ring ring;AudioDeviceIOProcID callback=nullptr;
    OSStatus status=AudioDeviceCreateIOProcID(selected,input,&ring,&callback);if(status){fprintf(stderr,"AudioDeviceCreateIOProcID: %d\n",(int)status);return 1;}
    status=AudioDeviceStart(selected,callback);if(status){AudioDeviceDestroyIOProcID(selected,callback);fprintf(stderr,"AudioDeviceStart: %d\n",(int)status);return 1;}
    uint64_t sent=0;time_t reported=0;
    while(!stopped){
        int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)break;
        int yes=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));timeval timeout{1,0};setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(54886);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        if(connect(fd,reinterpret_cast<sockaddr*>(&address),sizeof(address))||!transfer(fd,"NMA1",4)){close(fd);sleep(1);continue;}
        ring.read=ring.written.load(std::memory_order_acquire);
        while(!stopped){
            auto at=ring.read.load(std::memory_order_relaxed),available=ring.written.load(std::memory_order_acquire)-at;
            size_t n=static_cast<size_t>(std::min<uint64_t>(available,4096));n-=n%8;
            if(!n){usleep(2000);continue;}
            std::array<uint8_t,4096> block{};size_t offset=at%ring.capacity,first=std::min(n,ring.capacity-offset);
            memcpy(block.data(),ring.bytes.data()+offset,first);memcpy(block.data()+first,ring.bytes.data(),n-first);
            uint32_t length=htonl(static_cast<uint32_t>(n));
            if(!transfer(fd,&length,4)||!transfer(fd,block.data(),n))break;
            ring.read.store(at+n,std::memory_order_release);sent+=n/8;
            if(time(nullptr)-reported>=5){printf("{\"framesSent\":%llu,\"ringDroppedFrames\":%llu}\n",(unsigned long long)sent,(unsigned long long)ring.dropped.load());fflush(stdout);reported=time(nullptr);}
        }
        close(fd);
    }
    AudioDeviceStop(selected,callback);AudioDeviceDestroyIOProcID(selected,callback);return 0;
}}
