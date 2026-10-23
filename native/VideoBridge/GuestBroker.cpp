// Fixed-destination codec pipe broker. Anonymous pipes cross the sandbox;
// network sockets stay in this dedicated process. No caller supplies options.
#include "VideoBrokerProtocol.h"
#include <servers/bootstrap.h>
#include <sys/fileport.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <atomic>
#include <thread>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <initializer_list>
#include <chrono>
static std::atomic<unsigned> active{0};
static bool copy(int from,int to,std::atomic<bool>&stopped,std::chrono::steady_clock::time_point started){
    char bytes[65536];
    auto activity=started;
    while(!stopped){
        auto now=std::chrono::steady_clock::now();
        if(now-started>std::chrono::hours(1)||now-activity>std::chrono::seconds(300))return false;
        pollfd ready{from,POLLIN,0};int available=poll(&ready,1,1000);if(available<0&&errno==EINTR)continue;if(available<0)return false;if(!available)continue;
        ssize_t n=read(from,bytes,sizeof(bytes));if(n<0&&(errno==EINTR||errno==EAGAIN))continue;if(n<=0)return n==0;
        activity=std::chrono::steady_clock::now();auto deadline=activity+std::chrono::seconds(20);
        for(ssize_t at=0;at<n&&!stopped;){
            if(std::chrono::steady_clock::now()>deadline)return false;
            pollfd writable{to,POLLOUT,0};int result=poll(&writable,1,1000);if(result<0&&errno==EINTR)continue;if(result<0)return false;if(!result)continue;
            ssize_t sent=write(to,bytes+at,static_cast<size_t>(n-at));if(sent<0&&(errno==EINTR||errno==EAGAIN))continue;if(sent<=0)return false;at+=sent;}
    }
    return false;
}
static void relay(int input,int output,int network){
    std::atomic<bool> stopped{false};
    auto started=std::chrono::steady_clock::now();
    std::thread upload([&]{copy(input,network,stopped,started);stopped=true;shutdown(network,SHUT_RDWR);});
    copy(network,output,stopped,started);stopped=true;shutdown(network,SHUT_RDWR);upload.join();
    close(input);close(output);close(network);active--;
}
int main(){
    if(geteuid()){fprintf(stderr,"Codec broker requires root ownership.\n");return 77;}
    mach_port_t service=MACH_PORT_NULL;
    if(bootstrap_check_in(bootstrap_port,NativeMacVideoBrokerName,&service)!=KERN_SUCCESS){fprintf(stderr,"Codec broker Mach service unavailable.\n");return 1;}
    for(;;){
        struct {mach_msg_header_t header;char padding[256];mach_msg_max_trailer_t trailer;} request{};
        kern_return_t received=mach_msg(&request.header,MACH_RCV_MSG,0,sizeof(request),service,MACH_MSG_TIMEOUT_NONE,MACH_PORT_NULL);
        if(received!=KERN_SUCCESS)continue;
        if((request.header.msgh_bits&MACH_MSGH_BITS_COMPLEX)||request.header.msgh_id!=NativeMacVideoOpenRequest||request.header.msgh_size!=sizeof(mach_msg_header_t)){
            mach_msg_destroy(&request.header);continue;
        }
        NativeMacVideoReply reply{};reply.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE,0)|MACH_MSGH_BITS_COMPLEX;
        reply.header.msgh_remote_port=request.header.msgh_remote_port;reply.header.msgh_id=NativeMacVideoOpenRequest+1;reply.header.msgh_size=sizeof(reply);
        reply.body.msgh_descriptor_count=2;reply.input.type=reply.output.type=MACH_MSG_PORT_DESCRIPTOR;
        reply.input.disposition=reply.output.disposition=MACH_MSG_TYPE_MOVE_SEND;reply.status=EIO;
        int upstream[2]{-1,-1},downstream[2]{-1,-1},network=-1;bool reserved=false;
        if(request.header.msgh_id==NativeMacVideoOpenRequest&&request.header.msgh_size==sizeof(mach_msg_header_t)){
            reserved=active.fetch_add(1)<2;if(!reserved){active--;reply.status=EBUSY;}
            else{
                network=socket(AF_INET,SOCK_STREAM,0);sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(54885);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
                if(network>=0&&!connect(network,reinterpret_cast<sockaddr*>(&address),sizeof(address))&&!pipe(upstream)&&!pipe(downstream)&&
                    fileport_makeport(downstream[0],&reply.input.name)==KERN_SUCCESS&&fileport_makeport(upstream[1],&reply.output.name)==KERN_SUCCESS){reply.status=0;}
            }
        }
        if(!reply.status){for(int fd:{upstream[0],downstream[1],network}){fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);fcntl(fd,F_SETNOSIGPIPE,1);}}
        kern_return_t sent=mach_msg(&reply.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(reply),0,MACH_PORT_NULL,1000,MACH_PORT_NULL);
        if(!reply.status&&sent==KERN_SUCCESS){std::thread(relay,upstream[0],downstream[1],network).detach();upstream[0]=downstream[1]=network=-1;reserved=false;}
        if(sent!=KERN_SUCCESS){if(reply.input.name)mach_port_deallocate(mach_task_self(),reply.input.name);if(reply.output.name)mach_port_deallocate(mach_task_self(),reply.output.name);}
        for(int fd:{upstream[0],upstream[1],downstream[0],downstream[1],network})if(fd>=0)close(fd);
        if(reserved)active--;
    }
}
