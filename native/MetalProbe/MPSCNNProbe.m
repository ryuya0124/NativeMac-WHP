#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <math.h>

@interface AuthoredWeights : NSObject<MPSCNNConvolutionDataSource>
@property(nonatomic,strong) NSMutableData *values;
@property(nonatomic,strong) MPSCNNConvolutionDescriptor *configuration;
@end
@implementation AuthoredWeights
- (MPSDataType)dataType{return MPSDataTypeFloat32;}
- (MPSCNNConvolutionDescriptor*)descriptor{return self.configuration;}
- (void*)weights{return self.values.mutableBytes;}
- (float*)biasTerms{return NULL;}
- (BOOL)load{return YES;}
- (void)purge{}
- (NSString*)label{return @"Authored convolution weights";}
- (id)copyWithZone:(NSZone*)zone{(void)zone;return self;}
@end

static float inputValue(NSUInteger i){return ((int)(i*17%31)-15)/16.0f;}
static float weightValue(NSUInteger i){return ((int)(i*7%13)-6)/32.0f;}
int main(int argc,char **argv){@autoreleasepool{
    NSUInteger channels=argc>1?strtoul(argv[1],NULL,10):4,width=argc>2?strtoul(argv[2],NULL,10):8;
    BOOL managed=argc>3 && !strcmp(argv[3],"managed");
#if defined(__arm64__)
    if(managed){puts("{\"stage\":\"managed-storage\",\"applicable\":false,\"reason\":\"Apple Silicon has no distinct Managed storage mode\"}");return 77;}
#endif
    if(!channels || channels>32 || width<3 || width>64)return 64;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];
    if(!device || !queue)return 1;
    AuthoredWeights *weights=[AuthoredWeights new];weights.values=[NSMutableData dataWithLength:9*channels*channels*sizeof(float)];
    for(NSUInteger i=0;i<9*channels*channels;++i)((float*)weights.values.mutableBytes)[i]=weightValue(i);
    weights.configuration=[MPSCNNConvolutionDescriptor cnnConvolutionDescriptorWithKernelWidth:3 kernelHeight:3 inputFeatureChannels:channels outputFeatureChannels:channels neuronFilter:nil];
    MPSCNNConvolution *convolution=[[MPSCNNConvolution alloc] initWithDevice:device weights:weights];
    convolution.offset=(MPSOffset){1,1,0};convolution.edgeMode=MPSImageEdgeModeZero;
    MPSImageDescriptor *inputDescriptor=[MPSImageDescriptor imageDescriptorWithChannelFormat:MPSImageFeatureChannelFormatFloat32 width:width height:width featureChannels:channels];
    MPSImageDescriptor *outputDescriptor=[MPSImageDescriptor imageDescriptorWithChannelFormat:MPSImageFeatureChannelFormatFloat32 width:width-2 height:width-2 featureChannels:channels];
#if defined(__arm64__)
    inputDescriptor.storageMode=MTLStorageModeShared;
#else
    inputDescriptor.storageMode=managed?MTLStorageModeManaged:MTLStorageModeShared;
#endif
    outputDescriptor.storageMode=inputDescriptor.storageMode;
    MPSImage *input=[[MPSImage alloc] initWithDevice:device imageDescriptor:inputDescriptor];
    MPSImage *output=[[MPSImage alloc] initWithDevice:device imageDescriptor:outputDescriptor];
    if(!input || !output || !convolution)return 2;
    NSMutableData *pixels=[NSMutableData dataWithLength:width*width*channels*sizeof(float)];
    for(NSUInteger i=0;i<width*width*channels;++i)((float*)pixels.mutableBytes)[i]=inputValue(i);
    [input writeBytes:pixels.bytes dataLayout:MPSDataLayoutHeightxWidthxFeatureChannels imageIndex:0];
    id<MTLCommandBuffer> command=[queue commandBuffer];[convolution encodeToCommandBuffer:command sourceImage:input destinationImage:output];
    if(managed)[output synchronizeOnCommandBuffer:command];
    [command commit];[command waitUntilCompleted];
    NSUInteger outWidth=width-2,count=outWidth*outWidth*channels,wrong=0;
    NSMutableData *actual=[NSMutableData dataWithLength:count*sizeof(float)];
    [output readBytes:actual.mutableBytes dataLayout:MPSDataLayoutHeightxWidthxFeatureChannels imageIndex:0];
    double maxError=0;NSMutableArray *first=[NSMutableArray new];
    for(NSUInteger oy=0;oy<outWidth;++oy)for(NSUInteger ox=0;ox<outWidth;++ox)for(NSUInteger o=0;o<channels;++o){
        float expected=0;
        for(NSUInteger ky=0;ky<3;++ky)for(NSUInteger kx=0;kx<3;++kx)for(NSUInteger c=0;c<channels;++c)
            expected+=inputValue(((oy+ky)*width+ox+kx)*channels+c)*weightValue(((o*3+ky)*3+kx)*channels+c);
        float value=((float*)actual.mutableBytes)[(oy*outWidth+ox)*channels+o];double error=fabs(value-expected);
        if(isfinite(error) && error>maxError)maxError=error;if(!isfinite(value)||error>0.02)++wrong;
        if(first.count<8)[first addObject:@{@"actual":isfinite(value)?@(value):@"nonfinite",@"expected":@(expected)}];
    }
    BOOL passed=command.status==MTLCommandBufferStatusCompleted && !wrong;
    NSDictionary *report=@{@"case":@"mps-cnn-image-convolution",@"channels":@(channels),@"width":@(width),@"managed":@(managed),
        @"checkedValues":@(count),@"mismatches":@(wrong),@"maxError":@(maxError),@"first":first,
        @"commandCompleted":@(command.status==MTLCommandBufferStatusCompleted),@"passed":@(passed)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:3;
}}
