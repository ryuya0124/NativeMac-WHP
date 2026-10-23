#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#include <math.h>

int main(int argc,char **argv){@autoreleasepool{
    if(argc<2 || argc>3)return 64;NSString *mode=@(argv[1]);BOOL half=argc==3 && !strcmp(argv[2],"half");
    BOOL matrix=[mode isEqualToString:@"matmul"] || [mode isEqualToString:@"matmul-transpose"];
    BOOL transpose=[mode isEqualToString:@"matmul-transpose"];
    BOOL exactSum=[mode isEqualToString:@"sum-exact"],sum=exactSum || [mode isEqualToString:@"sum"];
    if(!matrix && ![@[@"softmax",@"sigmoid",@"sum",@"sum-exact"] containsObject:mode])return 64;
    const NSUInteger m=31,k=65,n=29,element=half?2:4;
    NSUInteger inputCount=m*k,count=sum?m:(matrix?m*n:inputCount);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];if(!device || !queue)return 1;
    id<MTLBuffer> input=[device newBufferWithLength:inputCount*element options:MTLResourceStorageModeShared];
    id<MTLBuffer> weight=[device newBufferWithLength:k*n*element options:MTLResourceStorageModeShared];
    if(!input || !weight)return 2;
    NSMutableData *left=[NSMutableData dataWithLength:inputCount*4],*right=[NSMutableData dataWithLength:k*n*4];
    float *a=left.mutableBytes,*b=right.mutableBytes;
    for(NSUInteger i=0;i<inputCount;++i){float value=exactSum?((int)(i%17)-8)/16.0f:sinf((float)i*0.37f)*2;if(half)value=(float)(_Float16)value;a[i]=value;
        if(half)((_Float16*)input.contents)[i]=value;else ((float*)input.contents)[i]=value;}
    for(NSUInteger i=0;i<k*n;++i){float value=cosf((float)i*0.23f)/7;if(half)value=(float)(_Float16)value;b[i]=value;
        if(half)((_Float16*)weight.contents)[i]=value;else ((float*)weight.contents)[i]=value;}
    MPSDataType type=half?MPSDataTypeFloat16:MPSDataTypeFloat32;MPSGraph *graph=[MPSGraph new];
    MPSGraphTensor *x=[graph placeholderWithShape:@[@(m),@(k)] dataType:type name:@"input"];
    MPSGraphTensorData *feed=[[MPSGraphTensorData alloc] initWithMTLBuffer:input shape:x.shape dataType:type];
    NSMutableDictionary *feeds=[@{x:feed} mutableCopy];MPSGraphTensor *y=nil;
    if(matrix){
        MPSGraphTensor *w=[graph placeholderWithShape:transpose?@[@(n),@(k)]:@[@(k),@(n)] dataType:type name:@"weights"];
        feeds[w]=[[MPSGraphTensorData alloc] initWithMTLBuffer:weight shape:w.shape dataType:type];
        MPSGraphTensor *operand=transpose?[graph transposeTensor:w dimension:0 withDimension:1 name:nil]:w;
        y=[graph matrixMultiplicationWithPrimaryTensor:x secondaryTensor:operand name:nil];
    }else if(sum)y=[graph reductionSumWithTensor:x axis:1 name:nil];
    else if([mode isEqualToString:@"softmax"])y=[graph softMaxWithTensor:x axis:1 name:nil];
    else y=[graph sigmoidWithTensor:x name:nil];
    NSDictionary *results=[graph runWithMTLCommandQueue:queue feeds:feeds targetTensors:@[y] targetOperations:nil];
    NSMutableData *bytes=[NSMutableData dataWithLength:count*element];[[results[y] mpsndarray] readBytes:bytes.mutableBytes strideBytes:NULL];
    NSUInteger wrong=0;double maxError=0;NSMutableArray *first=[NSMutableArray new];
    for(NSUInteger index=0;index<count;++index){
        double expected=0;
        if(matrix){NSUInteger row=index/n,column=index%n;for(NSUInteger j=0;j<k;++j)expected+=(double)a[row*k+j]*b[transpose?column*k+j:j*n+column];}
        else if(sum){for(NSUInteger j=0;j<k;++j)expected+=a[index*k+j];}
        else if([mode isEqualToString:@"softmax"]){NSUInteger row=index/k;double sum=0;for(NSUInteger j=0;j<k;++j)sum+=exp(a[row*k+j]);expected=exp(a[index])/sum;}
        else expected=1.0/(1.0+exp(-a[index]));
        if(half)expected=(float)(_Float16)expected;
        float actual=half?(float)((_Float16*)bytes.mutableBytes)[index]:((float*)bytes.mutableBytes)[index];double error=fabs(actual-expected);
        if(isfinite(error) && error>maxError)maxError=error;
        if(!isfinite(actual) || error>(half?0.01:0.0001))++wrong;
        if(first.count<8)[first addObject:@{@"actual":isfinite(actual)?@(actual):@"nonfinite",@"expected":@(expected)}];
    }
    BOOL passed=results[y]!=nil && !wrong;NSDictionary *report=@{@"case":mode,@"half":@(half),@"checkedValues":@(count),
        @"maxError":@(maxError),@"mismatches":@(wrong),@"first":first,@"passed":@(passed)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:3;
}}
