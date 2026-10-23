#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <math.h>

enum { Width=320, Height=180, FrameCount=12 };
typedef struct {
    pthread_mutex_t lock;
    CMSampleBufferRef samples[FrameCount];
    unsigned encoded, decoded, errors;
    uint64_t bytes, pixels, absoluteError, chromaPixels, chromaError;
} Results;

static uint8_t luma(unsigned x,unsigned y,unsigned frame) {
    return 32+((x/16+y/16+frame)%16)*10;
}
static void encoded(void *context,void *source,OSStatus status,
                    VTEncodeInfoFlags flags,CMSampleBufferRef sample) {
    (void)source;(void)flags;
    Results *r=context;pthread_mutex_lock(&r->lock);
    if(status || !sample || !CMSampleBufferDataIsReady(sample) || r->encoded>=FrameCount)++r->errors;
    else {
        r->samples[r->encoded++]=(CMSampleBufferRef)CFRetain(sample);
        r->bytes+=CMSampleBufferGetTotalSampleSize(sample);
    }
    pthread_mutex_unlock(&r->lock);
}
static void decoded(void *context,void *source,OSStatus status,
                    VTDecodeInfoFlags flags,CVImageBufferRef image,CMTime pts,CMTime duration) {
    (void)source;(void)flags;(void)duration;
    Results *r=context;pthread_mutex_lock(&r->lock);
    if(status || !image || CVPixelBufferGetWidth(image)!=Width || CVPixelBufferGetHeight(image)!=Height ||
       CVPixelBufferGetPixelFormatType(image)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)++r->errors;
    else {
        unsigned frame=(unsigned)llround(CMTimeGetSeconds(pts)*30);
        CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
        const uint8_t *base=CVPixelBufferGetBaseAddressOfPlane(image,0);
        size_t stride=CVPixelBufferGetBytesPerRowOfPlane(image,0);
        for(unsigned y=0;y<Height;++y)for(unsigned x=0;x<Width;++x)
            r->absoluteError+=(unsigned)abs((int)base[y*stride+x]-luma(x,y,frame));
        const uint8_t *uv=CVPixelBufferGetBaseAddressOfPlane(image,1);
        size_t uvStride=CVPixelBufferGetBytesPerRowOfPlane(image,1);
        for(unsigned y=0;y<Height/2;++y)for(unsigned x=0;x<Width;x+=2){
            r->chromaError+=(unsigned)abs((int)uv[y*uvStride+x]-96)+(unsigned)abs((int)uv[y*uvStride+x+1]-160);
        }
        r->chromaPixels+=Width*Height/2;
        CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
        r->pixels+=Width*Height;++r->decoded;
    }
    pthread_mutex_unlock(&r->lock);
}
static BOOL hardware(VTSessionRef session,CFStringRef key) {
    CFTypeRef value=NULL;VTSessionCopyProperty(session,key,kCFAllocatorDefault,&value);
    BOOL result=value && CFGetTypeID(value)==CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if(value)CFRelease(value);return result;
}
int main(int argc,char **argv) {@autoreleasepool{
    if(argc!=4)return 64;
    BOOL hevc=!strcmp(argv[1],"HEVC"),encodeHardware=!strcmp(argv[2],"hw"),decodeHardware=!strcmp(argv[3],"hw");
    if(!hevc && strcmp(argv[1],"H264"))return 64;
    Results r={0};pthread_mutex_init(&r.lock,NULL);
    NSDictionary *encodeSpec=encodeHardware ?
        @{(__bridge NSString*)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} :
        @{(__bridge NSString*)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:@NO};
    NSDictionary *attributes=@{(__bridge NSString*)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString*)kCVPixelBufferWidthKey:@(Width),(__bridge NSString*)kCVPixelBufferHeightKey:@(Height),
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    VTCompressionSessionRef encoder=NULL;VTDecompressionSessionRef decoder=NULL;
    OSStatus encodeStatus=VTCompressionSessionCreate(NULL,Width,Height,hevc?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)encodeSpec,(__bridge CFDictionaryRef)attributes,NULL,encoded,&r,&encoder);
    BOOL actualEncodeHardware=NO,actualDecodeHardware=NO;OSStatus decodeStatus=0;
    if(!encodeStatus){
        VTSessionSetProperty(encoder,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse);
        float quality=0.9f;CFNumberRef number=CFNumberCreate(NULL,kCFNumberFloatType,&quality);
        VTSessionSetProperty(encoder,kVTCompressionPropertyKey_Quality,number);CFRelease(number);
        encodeStatus=VTCompressionSessionPrepareToEncodeFrames(encoder);
        actualEncodeHardware=hardware(encoder,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder);
    }
    for(unsigned frame=0;!encodeStatus && frame<FrameCount;++frame){
        CVPixelBufferRef pixel=NULL;
        encodeStatus=CVPixelBufferCreate(NULL,Width,Height,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)attributes,&pixel);
        if(encodeStatus)break;
        CVPixelBufferLockBaseAddress(pixel,0);
        uint8_t *yBase=CVPixelBufferGetBaseAddressOfPlane(pixel,0),*uvBase=CVPixelBufferGetBaseAddressOfPlane(pixel,1);
        size_t yStride=CVPixelBufferGetBytesPerRowOfPlane(pixel,0),uvStride=CVPixelBufferGetBytesPerRowOfPlane(pixel,1);
        for(unsigned y=0;y<Height;++y)for(unsigned x=0;x<Width;++x)yBase[y*yStride+x]=luma(x,y,frame);
        for(unsigned y=0;y<Height/2;++y)for(unsigned x=0;x<Width;x+=2){uvBase[y*uvStride+x]=96;uvBase[y*uvStride+x+1]=160;}
        CVPixelBufferUnlockBaseAddress(pixel,0);
        encodeStatus=VTCompressionSessionEncodeFrame(encoder,pixel,CMTimeMake(frame,30),CMTimeMake(1,30),NULL,NULL,NULL);
        CVPixelBufferRelease(pixel);
    }
    if(encoder){
        OSStatus completion=VTCompressionSessionCompleteFrames(encoder,kCMTimeInvalid);
        if(!encodeStatus)encodeStatus=completion;
        VTCompressionSessionInvalidate(encoder);CFRelease(encoder);
    }
    if(!encodeStatus && r.encoded){
        NSDictionary *decodeSpec=decodeHardware ?
            @{(__bridge NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES} :
            @{(__bridge NSString*)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:@NO};
        VTDecompressionOutputCallbackRecord callback={decoded,&r};
        decodeStatus=VTDecompressionSessionCreate(NULL,CMSampleBufferGetFormatDescription(r.samples[0]),
            (__bridge CFDictionaryRef)decodeSpec,(__bridge CFDictionaryRef)attributes,&callback,&decoder);
        if(!decodeStatus){
            actualDecodeHardware=hardware(decoder,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder);
            for(unsigned i=0;!decodeStatus && i<r.encoded;++i)
                decodeStatus=VTDecompressionSessionDecodeFrame(decoder,r.samples[i],0,NULL,NULL);
            OSStatus completion=VTDecompressionSessionWaitForAsynchronousFrames(decoder);
            if(!decodeStatus)decodeStatus=completion;
            VTDecompressionSessionInvalidate(decoder);CFRelease(decoder);
        }
    }
    double mae=r.pixels?(double)r.absoluteError/r.pixels:-1;
    double chromaMAE=r.chromaPixels?(double)r.chromaError/r.chromaPixels:-1;
    BOOL passed=!encodeStatus && !decodeStatus && !r.errors && r.encoded==FrameCount && r.decoded==FrameCount &&
        mae>=0 && mae<4 && chromaMAE>=0 && chromaMAE<4 &&
        actualEncodeHardware==encodeHardware && actualDecodeHardware==decodeHardware;
    NSDictionary *result=@{@"codec":@(argv[1]),@"requestedEncoder":@(argv[2]),@"requestedDecoder":@(argv[3]),
        @"encodeStatus":@(encodeStatus),@"decodeStatus":@(decodeStatus),@"usingHardwareEncoder":@(actualEncodeHardware),
        @"usingHardwareDecoder":@(actualDecodeHardware),@"framesEncoded":@(r.encoded),@"framesDecoded":@(r.decoded),
        @"encodedBytes":@(r.bytes),@"callbackErrors":@(r.errors),@"lumaMAE":@(mae),@"chromaMAE":@(chromaMAE),@"passed":@(passed)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");
    for(unsigned i=0;i<r.encoded;++i)CFRelease(r.samples[i]);pthread_mutex_destroy(&r.lock);
    return passed?0:2;
}}
