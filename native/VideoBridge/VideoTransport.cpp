// Fixed Mach capability -> anonymous codec pipes; sandbox policies stay intact.
#include "VideoTransport.h"
#include "VideoBrokerProtocol.h"
#include <servers/bootstrap.h>
#include <sys/fileport.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <fcntl.h>
#include <dispatch/dispatch.h>
#include <cerrno>
#include <cstdint>
#include <chrono>
#include <initializer_list>
#include <os/log.h>
#include <dlfcn.h>
#include <atomic>
#include <mutex>
static std::atomic<mach_port_t> broker{MACH_PORT_NULL};
static std::once_flag brokerOnce;
// A catalog-loaded component has its own copy of this transport. Borrow the
// process entry's pre-sandbox capability instead of reopening a network socket.
extern "C" mach_port_t NativeMacVideoBorrowBroker(void){return broker.load();}
extern "C" void NativeMacVideoPrimeBroker(void){
    std::call_once(brokerOnce,[]{mach_port_t found=MACH_PORT_NULL;
    auto shared=reinterpret_cast<mach_port_t(*)(void)>(dlsym(RTLD_DEFAULT,"NativeMacVideoBorrowBroker"));
    if(shared&&shared!=NativeMacVideoBorrowBroker)found=shared();
    if(found){broker=found;return;}
    if(bootstrap_look_up(bootstrap_port,NativeMacVideoBrokerName,&found)==KERN_SUCCESS)broker=found;
    });
}
extern "C" int NativeMacVideoOpenSocket(int *writer){
    if(!writer){errno=EINVAL;return -1;}*writer=-1;int reader=-1;
    NativeMacVideoPrimeBroker();
    if(broker){
        mach_port_t response=MACH_PORT_NULL;
        if(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&response)==KERN_SUCCESS){
            union {mach_msg_header_t request;struct {NativeMacVideoReply value;mach_msg_max_trailer_t trailer;} response;} message{};
            message.request.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE);
            message.request.msgh_remote_port=broker;message.request.msgh_local_port=response;
            message.request.msgh_size=sizeof(mach_msg_header_t);message.request.msgh_id=NativeMacVideoOpenRequest;
            kern_return_t status=mach_msg(&message.request,MACH_SEND_MSG|MACH_RCV_MSG|MACH_RCV_TIMEOUT|MACH_SEND_TIMEOUT,
                sizeof(mach_msg_header_t),sizeof(message),response,3000,MACH_PORT_NULL);
            auto &reply=message.response.value;
            if(status==KERN_SUCCESS&&reply.header.msgh_id==NativeMacVideoOpenRequest+1&&reply.header.msgh_size==sizeof(reply)&&
                (reply.header.msgh_bits&MACH_MSGH_BITS_COMPLEX)&&reply.body.msgh_descriptor_count==2&&
                reply.input.type==MACH_MSG_PORT_DESCRIPTOR&&reply.output.type==MACH_MSG_PORT_DESCRIPTOR){
                if(!reply.status){reader=fileport_makefd(reply.input.name);*writer=fileport_makefd(reply.output.name);}
                mach_msg_destroy(&reply.header);
            }else if(status==KERN_SUCCESS)mach_msg_destroy(&message.request);
            mach_port_mod_refs(mach_task_self(),response,MACH_PORT_RIGHT_RECEIVE,-1);
            if(reader<0||*writer<0){if(reader>=0)close(reader);if(*writer>=0)close(*writer);reader=*writer=-1;}
            os_log(OS_LOG_DEFAULT,"NativeMac video Mach capability status=%d pipes=%d",status,reader>=0);
        }
    }
    if(reader<0){
        reader=socket(AF_INET,SOCK_STREAM,0);if(reader<0)return -1;
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(54885);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        if(connect(reader,reinterpret_cast<sockaddr*>(&address),sizeof(address))){int saved=errno;close(reader);errno=saved;return -1;}
        int yes=1;setsockopt(reader,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));setsockopt(reader,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));*writer=reader;
    }
    for(int fd:{reader,*writer}){fcntl(fd,F_SETFD,FD_CLOEXEC);fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);fcntl(fd,F_SETNOSIGPIPE,1);}
    return reader;
}
extern "C" bool NativeMacVideoTransfer(int fd,void *data,size_t size,bool writing){
    if(fd<0)return false;auto bytes=static_cast<uint8_t*>(data);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(writing?20:300);
    while(size){
        ssize_t count=writing?write(fd,bytes,size):read(fd,bytes,size);
        if(count>0){bytes+=count;size-=static_cast<size_t>(count);continue;}
        if(count<0&&errno==EINTR)continue;
        if(!count||errno!=EAGAIN){os_log_error(OS_LOG_DEFAULT,"NativeMac video pipe transfer failed write=%d count=%ld errno=%d",writing,(long)count,errno);return false;}
        auto left=std::chrono::duration_cast<std::chrono::milliseconds>(deadline-std::chrono::steady_clock::now()).count();
        if(left<=0){errno=ETIMEDOUT;return false;}
        struct Ready {dispatch_semaphore_t event,cancelled;};
        Ready ready{dispatch_semaphore_create(0),dispatch_semaphore_create(0)};
        dispatch_source_t source=dispatch_source_create(writing?DISPATCH_SOURCE_TYPE_WRITE:DISPATCH_SOURCE_TYPE_READ,
            static_cast<uintptr_t>(fd),0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        if(!source){dispatch_release(ready.event);dispatch_release(ready.cancelled);return false;}
        dispatch_set_context(source,&ready);
        dispatch_source_set_event_handler_f(source,[](void*context){dispatch_semaphore_signal(static_cast<Ready*>(context)->event);});
        dispatch_source_set_cancel_handler_f(source,[](void*context){dispatch_semaphore_signal(static_cast<Ready*>(context)->cancelled);});
        dispatch_activate(source);
        long result=dispatch_semaphore_wait(ready.event,dispatch_time(DISPATCH_TIME_NOW,left*NSEC_PER_MSEC));
        dispatch_source_cancel(source);dispatch_semaphore_wait(ready.cancelled,DISPATCH_TIME_FOREVER);
        dispatch_release(source);dispatch_release(ready.event);dispatch_release(ready.cancelled);
        if(result){errno=ETIMEDOUT;return false;}
    }
    return true;
}
