// Fixed, hardware-only codec worker. FFmpeg API headers must match the DLL build.
// Binary stdin/stdout avoids CLI demuxer and rawvideo muxer buffering.
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
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
}

#define FUNCTIONS(X) \
 X(avcodec_version) X(avutil_version) X(avcodec_find_decoder_by_name) X(avcodec_find_encoder_by_name) X(avcodec_alloc_context3) \
 X(avcodec_open2) X(avcodec_free_context) X(avcodec_send_packet) X(avcodec_receive_frame) \
 X(av_packet_alloc) X(av_packet_free) X(av_packet_unref) X(av_new_packet) \
 X(av_frame_alloc) X(av_frame_free) X(av_frame_unref) X(av_hwframe_transfer_data) \
 X(av_hwdevice_ctx_create) X(av_buffer_ref) X(av_buffer_unref) X(av_mallocz) X(av_log_set_level) \
 X(avcodec_send_frame) X(avcodec_receive_packet) X(av_frame_get_buffer) X(av_frame_make_writable) X(av_opt_set) X(av_opt_set_int)
#define DECLARE(name) static decltype(&name) api_##name;
FUNCTIONS(DECLARE)
static void check(int result,const char *stage){if(result<0)throw std::runtime_error(std::string(stage)+": "+std::to_string(result));}
static void exact(void *data,size_t size,bool output){
    auto *p=static_cast<uint8_t*>(data);
    while(size){size_t n=output?fwrite(p,1,size,stdout):fread(p,1,size,stdin);if(!n)throw std::runtime_error("codec pipe closed");p+=n;size-=n;}
}
static uint64_t getBE(const uint8_t *p,size_t size){uint64_t v=0;while(size--)v=(v<<8)|*p++;return v;}
static void putBE(uint8_t *p,uint64_t v,size_t size){while(size){p[--size]=static_cast<uint8_t>(v);v>>=8;}}
static std::vector<uint8_t> readMessage(size_t limit){
    uint8_t header[4];exact(header,4,false);size_t n=static_cast<size_t>(getBE(header,4));
    if(!n||n>limit)throw std::runtime_error("codec message limit");
    std::vector<uint8_t> body(n);exact(body.data(),n,false);return body;
}
static void writeMessage(std::vector<uint8_t> body){
    uint8_t header[4];putBE(header,body.size(),4);exact(header,4,true);exact(body.data(),body.size(),true);
    if(fflush(stdout))throw std::runtime_error("codec output flush failed");
}
struct Decoder {
    AVCodecContext *context=nullptr;AVPacket *packet=nullptr;AVFrame *frame=nullptr,*cpu=nullptr;
    AVBufferRef *hardware=nullptr;int width,height;uint32_t emitted=0;
    Decoder(const char *codec,int w,int h,const std::vector<uint8_t>& config,int gpu):width(w),height(h){
        const AVCodec *selected=api_avcodec_find_decoder_by_name(codec);
        if(!selected)throw std::runtime_error("required NVDEC decoder unavailable");
        context=api_avcodec_alloc_context3(selected);packet=api_av_packet_alloc();frame=api_av_frame_alloc();cpu=api_av_frame_alloc();
        if(!context||!packet||!frame||!cpu)throw std::runtime_error("codec allocation failed");
        std::string device=std::to_string(gpu);check(api_av_hwdevice_ctx_create(&hardware,AV_HWDEVICE_TYPE_CUDA,device.c_str(),nullptr,0),"CUDA device");
        context->hw_device_ctx=api_av_buffer_ref(hardware);if(!context->hw_device_ctx)throw std::runtime_error("CUDA context reference");
        context->get_format=[](AVCodecContext*,const AVPixelFormat *formats){
            for(auto p=formats;*p!=AV_PIX_FMT_NONE;++p)if(*p==AV_PIX_FMT_CUDA)return AV_PIX_FMT_CUDA;
            return AV_PIX_FMT_NONE;
        };
        context->width=w;context->height=h;context->pkt_timebase={1,1000000000};context->flags|=AV_CODEC_FLAG_LOW_DELAY;
        context->extradata=static_cast<uint8_t*>(api_av_mallocz(config.size()+AV_INPUT_BUFFER_PADDING_SIZE));
        if(!context->extradata)throw std::runtime_error("configuration allocation");
        memcpy(context->extradata,config.data(),config.size());context->extradata_size=static_cast<int>(config.size());
        check(api_avcodec_open2(context,selected,nullptr),"open NVDEC");
    }
    ~Decoder(){api_av_frame_free(&cpu);api_av_frame_free(&frame);api_av_packet_free(&packet);api_avcodec_free_context(&context);api_av_buffer_unref(&hardware);}
    void receive(){
        for(;;){
            int r=api_avcodec_receive_frame(context,frame);if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return;check(r,"receive NVDEC");
            if(frame->format!=AV_PIX_FMT_CUDA||frame->width!=width||frame->height!=height)throw std::runtime_error("unexpected GPU frame");
            check(api_av_hwframe_transfer_data(cpu,frame,0),"GPU frame download");
            if(cpu->format!=AV_PIX_FMT_NV12||cpu->width!=width||cpu->height!=height)throw std::runtime_error("expected NV12 output");
            std::vector<uint8_t> body(static_cast<size_t>(width)*height*3/2+9);body[0]='R';
            putBE(body.data()+1,static_cast<uint64_t>(frame->pts),8);size_t offset=9;
            for(int plane=0;plane<2;++plane){
                int rows=plane?height/2:height;
                if(!cpu->data[plane]||cpu->linesize[plane]<width)throw std::runtime_error("invalid output plane");
                for(int y=0;y<rows;++y){memcpy(body.data()+offset,cpu->data[plane]+static_cast<size_t>(y)*cpu->linesize[plane],width);offset+=width;}
            }
            writeMessage(std::move(body));++emitted;api_av_frame_unref(cpu);api_av_frame_unref(frame);
        }
    }
    void send(const std::vector<uint8_t>& body){
        api_av_packet_unref(packet);check(api_av_new_packet(packet,static_cast<int>(body.size()-10)),"packet allocation");
        memcpy(packet->data,body.data()+10,body.size()-10);packet->pts=static_cast<int64_t>(getBE(body.data()+1,8));packet->dts=AV_NOPTS_VALUE;
        if(body[9])packet->flags|=AV_PKT_FLAG_KEY;
        int r=api_avcodec_send_packet(context,packet);
        if(r==AVERROR(EAGAIN)){receive();r=api_avcodec_send_packet(context,packet);}check(r,"send NVDEC");receive();
    }
    void finish(){check(api_avcodec_send_packet(context,nullptr),"drain NVDEC");receive();}
};
struct Encoder {
    AVCodecContext *context=nullptr;AVPacket *packet=nullptr;AVFrame *frame=nullptr;int width,height;uint32_t emitted=0;
    Encoder(const char *codec,int w,int h,const std::vector<uint8_t>& options,int gpu):width(w),height(h){
        const AVCodec *selected=api_avcodec_find_encoder_by_name(codec);if(!selected)throw std::runtime_error("required NVENC encoder unavailable");
        context=api_avcodec_alloc_context3(selected);packet=api_av_packet_alloc();frame=api_av_frame_alloc();
        if(!context||!packet||!frame)throw std::runtime_error("encoder allocation failed");
        context->width=w;context->height=h;context->pix_fmt=AV_PIX_FMT_NV12;context->time_base={1,1000000000};context->framerate={30,1};
        context->gop_size=60;context->max_b_frames=0;context->flags|=AV_CODEC_FLAG_GLOBAL_HEADER|AV_CODEC_FLAG_LOW_DELAY;
        bool configured=(options.size()==13&&options[0]==1)||(options.size()==14&&options[0]==2);
        if(configured){
            unsigned bitrate=static_cast<unsigned>(getBE(options.data()+1,4)),rate=static_cast<unsigned>(getBE(options.data()+5,4)),gop=static_cast<unsigned>(getBE(options.data()+9,4));
            if(bitrate<64000||bitrate>400000000||!rate||rate>120||!gop||gop>600)throw std::runtime_error("NVENC settings limit");
            context->bit_rate=bitrate;context->framerate={static_cast<int>(rate),1};context->gop_size=static_cast<int>(gop);
        }
        unsigned profile=options.size()==14?options[13]:0;
        bool h264=!strcmp(codec,"h264_nvenc");
        if(profile>(h264?2u:0u))throw std::runtime_error("NVENC profile limit");
        check(api_av_opt_set(context->priv_data,"profile",h264?(profile==1?"baseline":profile==2?"high":"main"):"main",0),"NVENC profile");
        for(auto pair:{std::pair{"preset","p4"},std::pair{"tune","ull"},std::pair{"rc",configured?"vbr":"constqp"}})check(api_av_opt_set(context->priv_data,pair.first,pair.second,0),"NVENC option");
        if(!configured)check(api_av_opt_set_int(context->priv_data,"qp",18,0),"NVENC QP");
        check(api_av_opt_set_int(context->priv_data,"delay",0,0),"NVENC delay");
        check(api_av_opt_set_int(context->priv_data,"surfaces",4,0),"NVENC surface bound");
        check(api_av_opt_set_int(context->priv_data,"zerolatency",1,0),"NVENC zero latency");
        check(api_av_opt_set_int(context->priv_data,"forced-idr",1,0),"NVENC forced IDR");
        check(api_av_opt_set_int(context->priv_data,"gpu",gpu,0),"NVENC GPU");
        check(api_avcodec_open2(context,selected,nullptr),"open NVENC");
        if(!context->extradata||context->extradata_size<7||context->extradata_size>65536)throw std::runtime_error("NVENC configuration unavailable");
        frame->format=AV_PIX_FMT_NV12;frame->width=w;frame->height=h;check(api_av_frame_get_buffer(frame,32),"encoder frame buffer");
    }
    ~Encoder(){api_av_frame_free(&frame);api_av_packet_free(&packet);api_avcodec_free_context(&context);}
    void configuration(){std::vector<uint8_t> body(1+context->extradata_size);body[0]='C';memcpy(body.data()+1,context->extradata,context->extradata_size);writeMessage(std::move(body));}
    void receive(){for(;;){
        int r=api_avcodec_receive_packet(context,packet);if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return;check(r,"receive NVENC");
        if(packet->size<=0||packet->size>8*1024*1024)throw std::runtime_error("encoded packet size");
        std::vector<uint8_t> body(10+packet->size);body[0]='R';putBE(body.data()+1,static_cast<uint64_t>(packet->pts),8);body[9]=(packet->flags&AV_PKT_FLAG_KEY)!=0;
        memcpy(body.data()+10,packet->data,packet->size);writeMessage(std::move(body));emitted++;api_av_packet_unref(packet);
    }}
    void send(const std::vector<uint8_t>& body){
        if(body.size()!=static_cast<size_t>(width)*height*3/2+10)throw std::runtime_error("expected NV12 frame");
        check(api_av_frame_make_writable(frame),"encoder frame reuse");size_t offset=10;
        for(int plane=0;plane<2;plane++)for(int y=0;y<(plane?height/2:height);y++){
            memcpy(frame->data[plane]+static_cast<size_t>(y)*frame->linesize[plane],body.data()+offset,width);offset+=width;
        }
        frame->pts=static_cast<int64_t>(getBE(body.data()+1,8));frame->pict_type=body[9]?AV_PICTURE_TYPE_I:AV_PICTURE_TYPE_NONE;
        int r=api_avcodec_send_frame(context,frame);if(r==AVERROR(EAGAIN)){receive();r=api_avcodec_send_frame(context,frame);}check(r,"send NVENC");receive();
    }
    void finish(){check(api_avcodec_send_frame(context,nullptr),"drain NVENC");receive();}
};
int main(int argc,char **argv){
    _setmode(_fileno(stdin),_O_BINARY);_setmode(_fileno(stdout),_O_BINARY);
    try{
        if(argc!=5&&argc!=6)throw std::runtime_error("usage: worker library-directory h264|hevc width height [host-selected-gpu]");
        int gpu=argc==6?std::stoi(argv[5]):0;if(gpu<0||gpu>=64)throw std::runtime_error("invalid CUDA ordinal");
        int width=std::stoi(argv[3]),height=std::stoi(argv[4]);
        if(width<16||width>3840||height<16||height>2160||width%2||height%2)throw std::runtime_error("dimensions out of range");
        std::string codec=argv[2];bool encode=codec.starts_with("enc-");if(encode)codec.erase(0,4);
        if(codec!="h264"&&codec!="hevc")throw std::runtime_error("unsupported codec");codec+=encode?"_nvenc":"_cuvid";
        std::string directory=argv[1];
        if(!SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS))throw std::runtime_error("DLL search policy");
        std::wstring wide(directory.begin(),directory.end());auto cookie=AddDllDirectory(wide.c_str());
        if(!cookie)throw std::runtime_error("library directory unavailable");
        HMODULE utility=LoadLibraryExW((wide+L"/avutil-59.dll").c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        HMODULE library=LoadLibraryExW((wide+L"/avcodec-61.dll").c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if(!utility||!library)throw std::runtime_error("FFmpeg DLL load failed");
#define LOAD(name) api_##name=reinterpret_cast<decltype(api_##name)>(GetProcAddress(library,#name)); if(!api_##name)api_##name=reinterpret_cast<decltype(api_##name)>(GetProcAddress(utility,#name));if(!api_##name)throw std::runtime_error("missing codec API " #name);
        FUNCTIONS(LOAD)
        if(api_avcodec_version()!=LIBAVCODEC_VERSION_INT)throw std::runtime_error("FFmpeg ABI header/DLL version mismatch");
        if(api_avutil_version()!=LIBAVUTIL_VERSION_INT)throw std::runtime_error("FFmpeg utility header/DLL version mismatch");
        api_av_log_set_level(AV_LOG_ERROR);
        if(encode){
            auto hello=readMessage(14);if(hello!=std::vector<uint8_t>{0}&&!(hello.size()==13&&hello[0]==1)&&!(hello.size()==14&&hello[0]==2))throw std::runtime_error("encoder hello");
            Encoder encoder(codec.c_str(),width,height,hello,gpu);writeMessage({'A'});encoder.configuration();
            for(;;){
                auto body=readMessage(static_cast<size_t>(width)*height*3/2+10);
                if(body==std::vector<uint8_t>{'F'}){encoder.finish();std::vector<uint8_t>end(5);end[0]='E';putBE(end.data()+1,encoder.emitted,4);writeMessage(end);break;}
                if(body==std::vector<uint8_t>{'G'}){encoder.receive();std::vector<uint8_t>ack(5);ack[0]='G';putBE(ack.data()+1,encoder.emitted,4);writeMessage(ack);continue;}
                if(body.size()<11||body[0]!='P'||body[9]>1)throw std::runtime_error("invalid encoder message");
                encoder.send(body);std::vector<uint8_t>ack(5);ack[0]='D';putBE(ack.data()+1,encoder.emitted,4);writeMessage(ack);
            }
            RemoveDllDirectory(cookie);return 0;
        }
        auto configuration=readMessage(65536);Decoder decoder(codec.c_str(),width,height,configuration,gpu);
        writeMessage({'A'});
        for(;;){
            auto body=readMessage(8*1024*1024+10);
            if(body==std::vector<uint8_t>{'F'}){decoder.finish();std::vector<uint8_t> end(5);end[0]='E';putBE(end.data()+1,decoder.emitted,4);writeMessage(end);break;}
            if(body.size()<11||body[0]!='P'||body[9]>1)throw std::runtime_error("invalid packet message");
            decoder.send(body);
            // A packet boundary allows a caller to wait for all presently available
            // pictures, without closing the decoder or its reference-picture state.
            std::vector<uint8_t> ack(5);ack[0]='D';putBE(ack.data()+1,decoder.emitted,4);writeMessage(ack);
        }
        RemoveDllDirectory(cookie);return 0;
    }catch(const std::exception& error){fprintf(stderr,"hardware codec worker: %s\n",error.what());return 1;}
}
