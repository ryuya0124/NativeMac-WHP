#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#include <math.h>

// Integer multiples of powers of two make the independent CPU reference exact.
static float inputValue(NSUInteger i){return ((int)(i*17%31)-15)/16.0f;}
static float weightValue(NSUInteger i){return ((int)(i*7%13)-6)/32.0f;}
int main(int argc,char **argv){@autoreleasepool{
    NSUInteger channels=argc>1?strtoul(argv[1],NULL,10):4,width=argc>2?strtoul(argv[2],NULL,10):8;
    BOOL half=argc>3 && !strcmp(argv[3],"half");
    NSUInteger layers=argc>4?strtoul(argv[4],NULL,10):1;BOOL relu=argc>5 && !strcmp(argv[5],"relu");
    NSUInteger groups=argc>6?strtoul(argv[6],NULL,10):1;
    NSUInteger outputs=argc>7?strtoul(argv[7],NULL,10):channels;
    if(!channels || channels>64 || !outputs || outputs>64 || !groups || channels%groups || outputs%groups ||
       !layers || layers>8 || (outputs!=channels && layers!=1) || width<=2*layers || width>128)return 64;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];
    if(!device || !queue)return 1;
    NSUInteger perGroup=channels/groups,inputCount=width*width*channels,weightCount=9*perGroup*outputs;
    NSUInteger outputWidth=width-2*layers,outputCount=outputWidth*outputWidth*outputs,elementSize=half?2:4;
    id<MTLBuffer> input=[device newBufferWithLength:inputCount*elementSize options:MTLResourceStorageModeShared];
    if(!input)return 2;
    NSMutableData *weights=[NSMutableData dataWithLength:weightCount*elementSize];
    for(NSUInteger i=0;i<inputCount;++i){if(half)((_Float16*)input.contents)[i]=inputValue(i);else ((float*)input.contents)[i]=inputValue(i);}
    for(NSUInteger i=0;i<weightCount;++i){if(half)((_Float16*)weights.mutableBytes)[i]=weightValue(i);else ((float*)weights.mutableBytes)[i]=weightValue(i);}
    MPSDataType type=half?MPSDataTypeFloat16:MPSDataTypeFloat32;
    MPSGraph *graph=[MPSGraph new];MPSGraphTensor *x=[graph placeholderWithShape:@[@1,@(width),@(width),@(channels)] dataType:type name:@"input"];
    MPSGraphTensor *w=[graph constantWithData:weights shape:@[@3,@3,@(perGroup),@(outputs)] dataType:type];
    MPSGraphConvolution2DOpDescriptor *descriptor=[MPSGraphConvolution2DOpDescriptor descriptorWithStrideInX:1 strideInY:1
        dilationRateInX:1 dilationRateInY:1 groups:groups paddingLeft:0 paddingRight:0 paddingTop:0 paddingBottom:0
        paddingStyle:MPSGraphPaddingStyleExplicit dataLayout:MPSGraphTensorNamedDataLayoutNHWC weightsLayout:MPSGraphTensorNamedDataLayoutHWIO];
    MPSGraphTensor *y=x;
    for(NSUInteger layer=0;layer<layers;++layer){
        y=[graph convolution2DWithSourceTensor:y weightsTensor:w descriptor:descriptor name:nil];
        if(relu)y=[graph reLUWithTensor:y name:nil];
    }
    MPSGraphTensorData *feed=[[MPSGraphTensorData alloc] initWithMTLBuffer:input shape:x.shape dataType:type];
    NSDictionary *results=[graph runWithMTLCommandQueue:queue feeds:@{x:feed} targetTensors:@[y] targetOperations:nil];
    NSMutableData *actual=[NSMutableData dataWithLength:outputCount*elementSize];
    [[results[y] mpsndarray] readBytes:actual.mutableBytes strideBytes:NULL];
    NSMutableData *reference=[NSMutableData dataWithLength:inputCount*sizeof(float)];
    for(NSUInteger i=0;i<inputCount;++i)((float*)reference.mutableBytes)[i]=inputValue(i);
    NSUInteger previousWidth=width;
    for(NSUInteger layer=0;layer<layers;++layer){
        NSUInteger nextWidth=previousWidth-2;
        NSMutableData *next=[NSMutableData dataWithLength:nextWidth*nextWidth*outputs*sizeof(float)];
        const float *previous=reference.bytes;float *destination=next.mutableBytes;
        for(NSUInteger oy=0;oy<nextWidth;++oy)for(NSUInteger ox=0;ox<nextWidth;++ox)for(NSUInteger o=0;o<outputs;++o){
            float value=0;
            for(NSUInteger ky=0;ky<3;++ky)for(NSUInteger kx=0;kx<3;++kx)for(NSUInteger c=0;c<perGroup;++c)
                value+=previous[((oy+ky)*previousWidth+ox+kx)*channels+(o/(outputs/groups))*perGroup+c]*weightValue(((ky*3+kx)*perGroup+c)*outputs+o);
            if(half)value=(float)(_Float16)value;if(relu && value<0)value=0;
            destination[(oy*nextWidth+ox)*outputs+o]=value;
        }
        reference=next;previousWidth=nextWidth;
    }
    NSUInteger mismatches=0;double maxError=0;NSMutableArray *first=[NSMutableArray new];
    for(NSUInteger oy=0;oy<outputWidth;++oy)for(NSUInteger ox=0;ox<outputWidth;++ox)for(NSUInteger o=0;o<outputs;++o){
        NSUInteger index=(oy*outputWidth+ox)*outputs+o;
        float expected=((const float*)reference.bytes)[index];
        float value=half?(float)((_Float16*)actual.mutableBytes)[index]:((float*)actual.mutableBytes)[index];
        double error=fabs(value-expected);if(isfinite(error) && error>maxError)maxError=error;
        if(!isfinite(value) || error>(half?0.02:0.0001))++mismatches;
        if(first.count<8)[first addObject:@{@"actual":isfinite(value)?@(value):@"nonfinite",@"expected":@(expected)}];
    }
    NSDictionary *report=@{@"case":@"mps-convolution",@"channels":@(channels),@"outputs":@(outputs),@"groups":@(groups),@"width":@(width),@"half":@(half),@"layers":@(layers),@"relu":@(relu),
        @"checkedValues":@(outputCount),@"mismatches":@(mismatches),@"maxError":@(maxError),@"first":first,
        @"passed":@(results[y]!=nil && !mismatches)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");return results[y] && !mismatches?0:3;
}}
