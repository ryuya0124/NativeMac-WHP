// Hardware-only NVDEC parser/decoder with explicit per-picture packet boundaries.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>
#include <dynlink_cuda.h>
#include <dynlink_nvcuvid.h>
#define CUDA_APIS(X) X(cuInit) X(cuDeviceGet) X(cuCtxCreate_v2) X(cuCtxDestroy_v2) X(cuMemcpy2D_v2)
#define VIDEO_APIS(X) X(cuvidCreateVideoParser) X(cuvidDestroyVideoParser) X(cuvidParseVideoData) X(cuvidCreateDecoder) X(cuvidDestroyDecoder) X(cuvidDecodePicture) X(cuvidMapVideoFrame64) X(cuvidUnmapVideoFrame64) X(cuvidGetDecoderCaps)
#define DECLARE(name) static t##name *api_##name;
CUDA_APIS(DECLARE) VIDEO_APIS(DECLARE)
static void check(CUresult r){if(r!=CUDA_SUCCESS)throw std::runtime_error("NVDEC/CUDA status "+std::to_string(static_cast<int>(r)));}
static void exact(void *data,size_t size,bool out){auto p=static_cast<uint8_t*>(data);while(size){auto n=out?fwrite(p,1,size,stdout):fread(p,1,size,stdin);if(!n)throw std::runtime_error("codec pipe closed");p+=n;size-=n;}}
static uint64_t be(const uint8_t *p,size_t n){uint64_t v=0;while(n--)v=v*256+*p++;return v;}
static void put(uint8_t *p,uint64_t v,size_t n){while(n){p[--n]=static_cast<uint8_t>(v);v>>=8;}}
static std::vector<uint8_t> read(size_t limit){uint8_t h[4];exact(h,4,false);size_t n=static_cast<size_t>(be(h,4));if(!n||n>limit)throw std::runtime_error("message limit");std::vector<uint8_t>b(n);exact(b.data(),n,false);return b;}
static void write(std::vector<uint8_t> b){uint8_t h[4];put(h,b.size(),4);exact(h,4,true);exact(b.data(),b.size(),true);if(fflush(stdout))throw std::runtime_error("output flush failed");}
struct Decoder {
    CUcontext context=nullptr;CUvideoparser parser=nullptr;CUvideodecoder decoder=nullptr;
    unsigned width,height,lengthBytes=4,surfaces=0,emitted=0,codedWidth=0,codedHeight=0;cudaVideoCodec codec;std::string error;int64_t currentPts=0;
    Decoder(unsigned w,unsigned h,bool hevc,const std::vector<uint8_t>& config,int gpu):width(w),height(h),codec(hevc?cudaVideoCodec_HEVC:cudaVideoCodec_H264){
        check(api_cuInit(0));CUdevice device;check(api_cuDeviceGet(&device,gpu));check(api_cuCtxCreate_v2(&context,0,device));
        CUVIDPARSERPARAMS parameters{};parameters.CodecType=codec;parameters.ulMaxNumDecodeSurfaces=1;
        parameters.ulClockRate=1000000000;parameters.ulMaxDisplayDelay=0;parameters.pUserData=this;
        parameters.pfnSequenceCallback=sequence;parameters.pfnDecodePicture=decode;parameters.pfnDisplayPicture=[](void*,CUVIDPARSERDISPINFO*){return 1;};
        check(api_cuvidCreateVideoParser(&parser,&parameters));
        std::vector<uint8_t> annex;size_t at=hevc?23:6;
        if(config.size()<at||config[0]!=1)throw std::runtime_error("invalid codec configuration");
        lengthBytes=(config[hevc?21:4]&3)+1;
        auto nal=[&]{if(at+2>config.size())throw std::runtime_error("truncated parameter set");size_t n=static_cast<size_t>(be(config.data()+at,2));at+=2;if(!n||at+n>config.size())throw std::runtime_error("parameter set limit");annex.insert(annex.end(),{0,0,0,1});annex.insert(annex.end(),config.begin()+at,config.begin()+at+n);at+=n;};
        if(hevc){for(unsigned arrays=config[22],i=0;i<arrays;i++){if(at+3>config.size())throw std::runtime_error("truncated HEVC array");at++;unsigned count=static_cast<unsigned>(be(config.data()+at,2));at+=2;for(unsigned j=0;j<count;j++)nal();}}
        else{for(unsigned n=config[5]&31;n;n--)nal();if(at>=config.size())throw std::runtime_error("missing PPS");unsigned n=config[at++];while(n--)nal();}
        parse(annex,0,0);
    }
    ~Decoder(){if(parser)api_cuvidDestroyVideoParser(parser);if(decoder)api_cuvidDestroyDecoder(decoder);if(context)api_cuCtxDestroy_v2(context);}
    void parse(const std::vector<uint8_t>& data,unsigned flags,int64_t pts){
        CUVIDSOURCEDATAPACKET packet{};packet.payload=data.data();packet.payload_size=static_cast<unsigned long>(data.size());packet.flags=flags;packet.timestamp=pts;
        check(api_cuvidParseVideoData(parser,&packet));if(!error.empty())throw std::runtime_error(error);
    }
    void send(const std::vector<uint8_t>& body){
        std::vector<uint8_t> annex;size_t at=10;
        while(at<body.size()){
            if(at+lengthBytes>body.size())throw std::runtime_error("truncated NAL length");
            size_t n=static_cast<size_t>(be(body.data()+at,lengthBytes));at+=lengthBytes;
            if(!n||n>body.size()-at)throw std::runtime_error("invalid NAL length");
            annex.insert(annex.end(),{0,0,0,1});annex.insert(annex.end(),body.begin()+at,body.begin()+at+n);at+=n;
        }
        unsigned before=emitted;currentPts=static_cast<int64_t>(be(body.data()+1,8));
        parse(annex,CUVID_PKT_TIMESTAMP|CUVID_PKT_ENDOFPICTURE,currentPts);
        if(emitted!=before+1)throw std::runtime_error("expected exactly one progressive picture per sample");
    }
    static int CUDAAPI sequence(void *user,CUVIDEOFORMAT *f){auto s=static_cast<Decoder*>(user);try{
        if(f->codec!=s->codec||!f->progressive_sequence||f->bit_depth_luma_minus8||f->bit_depth_chroma_minus8||f->chroma_format!=cudaVideoChromaFormat_420||
           f->display_area.right-f->display_area.left!=static_cast<int>(s->width)||f->display_area.bottom-f->display_area.top!=static_cast<int>(s->height))throw std::runtime_error("unsupported sequence format");
        if(s->decoder){
            if(f->coded_width!=s->codedWidth||f->coded_height!=s->codedHeight||f->min_num_decode_surfaces>s->surfaces)throw std::runtime_error("midstream sequence reconfiguration unsupported");
            return static_cast<int>(s->surfaces);
        }
        CUVIDDECODECAPS caps{};caps.eCodecType=f->codec;caps.eChromaFormat=f->chroma_format;check(api_cuvidGetDecoderCaps(&caps));
        if(!caps.bIsSupported||f->coded_width>caps.nMaxWidth||f->coded_height>caps.nMaxHeight||f->coded_width>4096||f->coded_height>2304||!f->min_num_decode_surfaces||f->min_num_decode_surfaces>32)throw std::runtime_error("hardware sequence limits");
        CUVIDDECODECREATEINFO info{};info.CodecType=f->codec;info.ChromaFormat=f->chroma_format;info.ulWidth=f->coded_width;info.ulHeight=f->coded_height;
        s->codedWidth=f->coded_width;s->codedHeight=f->coded_height;
        info.ulNumDecodeSurfaces=s->surfaces=f->min_num_decode_surfaces;info.OutputFormat=cudaVideoSurfaceFormat_NV12;
        info.ulCreationFlags=cudaVideoCreate_PreferCUVID;info.DeinterlaceMode=cudaVideoDeinterlaceMode_Weave;
        info.display_area.left=static_cast<short>(f->display_area.left);info.display_area.top=static_cast<short>(f->display_area.top);
        info.display_area.right=static_cast<short>(f->display_area.right);info.display_area.bottom=static_cast<short>(f->display_area.bottom);
        info.ulTargetWidth=s->width;info.ulTargetHeight=s->height;info.ulNumOutputSurfaces=2;
        check(api_cuvidCreateDecoder(&s->decoder,&info));return static_cast<int>(s->surfaces);
    }catch(const std::exception& e){s->error=e.what();return 0;}}
    static int CUDAAPI decode(void *user,CUVIDPICPARAMS *picture){auto s=static_cast<Decoder*>(user);try{
        if(picture->field_pic_flag)throw std::runtime_error("interlaced pictures unsupported");
        check(api_cuvidDecodePicture(s->decoder,picture));
        CUVIDPARSERDISPINFO output{};output.picture_index=picture->CurrPicIdx;output.progressive_frame=1;output.timestamp=s->currentPts;
        return display(user,&output);
    }catch(const std::exception&e){s->error=e.what();return 0;}}
    static int CUDAAPI display(void *user,CUVIDPARSERDISPINFO *f){auto s=static_cast<Decoder*>(user);unsigned long long device=0;bool mapped=false;try{
        CUVIDPROCPARAMS processing{};processing.progressive_frame=f->progressive_frame;processing.top_field_first=f->top_field_first;processing.unpaired_field=1;
        unsigned pitch=0;check(api_cuvidMapVideoFrame64(s->decoder,f->picture_index,&device,&pitch,&processing));mapped=true;
        std::vector<uint8_t> body(static_cast<size_t>(s->width)*s->height*3/2+9);body[0]='R';put(body.data()+1,static_cast<uint64_t>(f->timestamp),8);
        CUDA_MEMCPY2D copy{};copy.srcMemoryType=CU_MEMORYTYPE_DEVICE;copy.srcDevice=device;copy.srcPitch=pitch;
        copy.dstMemoryType=CU_MEMORYTYPE_HOST;copy.dstHost=body.data()+9;copy.dstPitch=s->width;copy.WidthInBytes=s->width;copy.Height=s->height*3/2;
        check(api_cuMemcpy2D_v2(&copy));check(api_cuvidUnmapVideoFrame64(s->decoder,device));mapped=false;write(std::move(body));s->emitted++;return 1;
    }catch(const std::exception&e){if(mapped)api_cuvidUnmapVideoFrame64(s->decoder,device);s->error=e.what();return 0;}}
};
int main(int argc,char**argv){_setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);try{
    if(argc!=5&&argc!=6)throw std::runtime_error("usage: nvdec-worker reserved-directory h264|hevc width height [host-selected-gpu]");
    int gpu=argc==6?std::stoi(argv[5]):0;if(gpu<0||gpu>=64)throw std::runtime_error("invalid CUDA ordinal");
    unsigned w=static_cast<unsigned>(std::stoul(argv[3])),h=static_cast<unsigned>(std::stoul(argv[4]));std::string codec=argv[2];
    if(w<16||w>3840||h<16||h>2160||w%2||h%2||(codec!="h264"&&codec!="hevc"))throw std::runtime_error("invalid session");
    auto cuda=LoadLibraryExW(L"nvcuda.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);auto video=LoadLibraryExW(L"nvcuvid.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!cuda||!video)throw std::runtime_error("NVIDIA driver unavailable");
#define LOAD_CUDA(name) api_##name=reinterpret_cast<t##name*>(GetProcAddress(cuda,#name));if(!api_##name)throw std::runtime_error("missing " #name);
#define LOAD_VIDEO(name) api_##name=reinterpret_cast<t##name*>(GetProcAddress(video,#name));if(!api_##name)throw std::runtime_error("missing " #name);
    CUDA_APIS(LOAD_CUDA) VIDEO_APIS(LOAD_VIDEO)
    auto config=read(65536);Decoder decoder(w,h,codec=="hevc",config,gpu);write({'A'});
    for(;;){auto body=read(8*1024*1024+10);
        if(body==std::vector<uint8_t>{'F'}||body==std::vector<uint8_t>{'D'}||body==std::vector<uint8_t>{'G'}){
            bool end=body[0]=='F';if(end)decoder.parse({},CUVID_PKT_ENDOFSTREAM,0);std::vector<uint8_t> ack(5);ack[0]=end?'E':body[0];put(ack.data()+1,decoder.emitted,4);write(ack);if(end)break;continue;
        }
        if(body.size()<11||body[0]!='P'||body[9]>1)throw std::runtime_error("invalid picture packet");
        decoder.send(body);std::vector<uint8_t> ack(5);ack[0]='D';put(ack.data()+1,decoder.emitted,4);write(ack);
    }
    return 0;
}catch(const std::exception&e){fprintf(stderr,"NVDEC worker: %s\n",e.what());return 1;}}
