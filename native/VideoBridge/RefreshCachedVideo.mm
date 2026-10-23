// One-shot GUI-login initialization. Read mapping metadata, never app contents.
// Gracefully relaunch only a restored Safari missing the configured entry.
#import <AppKit/AppKit.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>
#include <limits>
#include <fcntl.h>
#include <string>
#include <spawn.h>
#include <sys/wait.h>
#include <poll.h>
#include <chrono>
#include <crt_externs.h>
#include <atomic>
#include <memory>
static constexpr const char *entry="/Library/Application Support/NativeMac/VideoBridge/NativeMacVideoEntry.dylib";
static constexpr const char *enabled="/Library/Application Support/NativeMac/VideoBridge/enabled";
static constexpr const char *safari="/System/Applications/Safari.app/Contents/MacOS/Safari";
static bool optedIn(){
    int fd=open(enabled,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return false;
    struct stat st{};char value=0;
    bool result=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==0&&!(st.st_mode&0022)&&read(fd,&value,1)==1&&value=='1';
    close(fd);return result;
}
enum class Mapping { Present, Missing, Unknown };
static Mapping platformMapping(pid_t pid){
    // The platform metadata reader can inspect Safari where libproc alone is
    // denied. No memory contents, app URLs or report files are requested.
    int descriptors[2];if(pipe(descriptors))return Mapping::Unknown;
    for(int fd:descriptors)fcntl(fd,F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,descriptors[1],STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
    std::string argument=std::to_string(pid);
    char *arguments[]={const_cast<char*>("/usr/bin/vmmap"),const_cast<char*>("-w"),argument.data(),nullptr};
    pid_t child=0;int result=posix_spawn(&child,arguments[0],&actions,nullptr,arguments,*_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);close(descriptors[1]);
    if(result){close(descriptors[0]);return Mapping::Unknown;}
    fcntl(descriptors[0],F_SETFL,fcntl(descriptors[0],F_GETFL)|O_NONBLOCK);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);
    std::string report;bool eof=false;
    while(std::chrono::steady_clock::now()<deadline&&report.size()<4*1024*1024){
        char bytes[16384];ssize_t n=read(descriptors[0],bytes,sizeof(bytes));
        if(n>0){report.append(bytes,static_cast<size_t>(n));continue;}
        if(!n){eof=true;break;}
        if(errno!=EAGAIN&&errno!=EINTR)break;
        pollfd ready{descriptors[0],POLLIN,0};poll(&ready,1,100);
    }
    close(descriptors[0]);int status=0;bool completed=false;
    while(eof&&std::chrono::steady_clock::now()<deadline){
        pid_t finished=waitpid(child,&status,WNOHANG);
        if(finished==child){completed=true;break;}if(finished<0&&errno!=EINTR)break;usleep(10000);
    }
    if(!completed){kill(child,SIGKILL);while(waitpid(child,&status,0)<0&&errno==EINTR){}return Mapping::Unknown;}
    if(!WIFEXITED(status)||WEXITSTATUS(status)||report.find("Virtual Memory Map of process "+argument)==std::string::npos)return Mapping::Unknown;
    return report.find(entry)!=std::string::npos?Mapping::Present:Mapping::Missing;
}
static Mapping mapping(pid_t pid){
    uint64_t address=0;unsigned regions=0;
    for(;regions<32768;regions++){
        proc_regionwithpathinfo region{};
        errno=0;int count=proc_pidinfo(pid,PROC_PIDREGIONPATHINFO,address,&region,sizeof(region));
        if(count!=sizeof(region))return regions&&(errno==EINVAL||errno==EFAULT||errno==0)?Mapping::Missing:Mapping::Unknown;
        if(!strcmp(region.prp_vip.vip_path,entry))return Mapping::Present;
        auto &info=region.prp_prinfo;
        if(!info.pri_size||info.pri_address>std::numeric_limits<uint64_t>::max()-info.pri_size)return Mapping::Unknown;
        uint64_t next=info.pri_address+info.pri_size;if(next<=address)return Mapping::Unknown;address=next;
    }
    return Mapping::Unknown;
}
static bool eligible(pid_t pid,proc_bsdinfo &info){
    char path[PROC_PIDPATHINFO_MAXSIZE]{};struct stat expected{},actual{};
    if(pid<=1||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid()||
        proc_pidpath(pid,path,sizeof(path))<=0||stat(path,&actual)||actual.st_uid!=0||(actual.st_mode&0022))return false;
    // Updated Safari executes from the app cryptex, not the older SSV stub.
    for(const char *prefix:{"","/System/Volumes/Preboot/Cryptexes/App","/System/Volumes/Preboot/Cryptexes/Incoming/App"}){
        std::string trusted=std::string(prefix)+safari;
        if(!stat(trusted.c_str(),&expected)&&expected.st_dev==actual.st_dev&&expected.st_ino==actual.st_ino)return true;
    }
    return false;
}
int main(){@autoreleasepool{
    if(getuid()<501||!optedIn())return 0;
    // launchctl has finished installing the environment before this executable
    // starts. A restored app may still hold an older XPC bootstrap environment.
    // Apps born during this initialization are never interrupted.
    timeval installed{};if(gettimeofday(&installed,nullptr))return 69;
    // The launch environment must be installed before checking restored XPCs.
    sleep(5);if(!optedIn())return 0;
    int capacity=proc_listallpids(nullptr,0)+64;
    if(capacity<64||capacity>32768)return 69;
    std::vector<pid_t> pids(static_cast<size_t>(capacity));
    int count=proc_listallpids(pids.data(),static_cast<int>(pids.size()*sizeof(pid_t)));
    if(count<0||count>capacity)return 69;
    unsigned checked=0,refreshed=0,unknown=0,newer=0,failed=0;
    for(int i=0;i<count&&refreshed<1;i++){
        proc_bsdinfo initial{};if(!eligible(pids[i],initial))continue;checked++;
        bool older=initial.pbi_start_tvsec<static_cast<uint64_t>(installed.tv_sec)||
            (initial.pbi_start_tvsec==static_cast<uint64_t>(installed.tv_sec)&&initial.pbi_start_tvusec<static_cast<uint64_t>(installed.tv_usec));
        if(!older){newer++;continue;}
        Mapping result=mapping(pids[i]);if(result==Mapping::Unknown)result=platformMapping(pids[i]);
        if(result==Mapping::Present)continue;
        // Never restart an uninspectable process.
        if(result==Mapping::Unknown){unknown++;continue;}
        proc_bsdinfo current{};
        if(optedIn()&&eligible(pids[i],current)&&current.pbi_start_tvsec==initial.pbi_start_tvsec&&current.pbi_start_tvusec==initial.pbi_start_tvusec){
            NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pids[i]];
            NSURL *url=app.bundleURL;
            if(!app||![app.bundleIdentifier isEqualToString:@"com.apple.Safari"]||!url||![app terminate]){failed++;continue;}
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
            while(!app.terminated&&deadline.timeIntervalSinceNow>0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            // A page can refuse termination. Do not force quit or discard work.
            if(!app.terminated){failed++;continue;}
            NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
            configuration.activates=NO;
            struct OpenState {std::atomic<bool> done{false},opened{false};};
            auto opening=std::make_shared<OpenState>();
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:configuration completionHandler:^(NSRunningApplication *launched,NSError *error){opening->opened=launched!=nil&&error==nil;opening->done=true;}];
            deadline=[NSDate dateWithTimeIntervalSinceNow:15];
            while(!opening->done&&deadline.timeIntervalSinceNow>0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            if(opening->opened)refreshed++;else failed++;
        }
    }
    printf("{\"restoredSafariChecked\":%u,\"gracefullyRelaunched\":%u,\"mappingUnavailable\":%u,\"newerServicesSkipped\":%u,\"failed\":%u,\"forcedTerminations\":0}\n",checked,refreshed,unknown,newer,failed);
    return failed||unknown?69:0;
}}
