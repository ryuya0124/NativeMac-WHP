#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

static void report(NSDictionary *value) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");fflush(stdout);
}

int main(int argc,char **argv) {
    @autoreleasepool {
        NSString *mode = argc == 2 ? @(argv[1]) : @"resources";
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 2;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> buffer = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLBuffer> privateBuffer = [device newBufferWithLength:256 options:MTLResourceStorageModePrivate];
        report(@{@"stage":@"resources", @"queue":@(queue != nil),
            @"queueDevice":@(queue.device != nil), @"buffer":@(buffer != nil),
            @"bufferDevice":@(buffer.device != nil), @"privateBuffer":@(privateBuffer != nil),
            @"privateBufferDevice":@(privateBuffer.device != nil)});
        if ([mode isEqualToString:@"resources"]) return buffer && queue ? 0 : 3;
        if (!buffer || !queue) return 3;
        for (unsigned i=0; i<64; ++i) ((float *)buffer.contents)[i]=(float)i;
        report(@{@"stage":@"before-tensor-data"});
        MPSGraphTensorData *input = [[MPSGraphTensorData alloc] initWithMTLBuffer:buffer shape:@[@64] dataType:MPSDataTypeFloat32];
        report(@{@"stage":@"tensor-data", @"available":@(input != nil), @"ndarray":@([input mpsndarray] != nil)});
        if ([mode isEqualToString:@"buffer"]) return input ? 0 : 4;
        MPSGraph *graph = [MPSGraph new];
        MPSGraphTensor *placeholder = [graph placeholderWithShape:@[@64] dataType:MPSDataTypeFloat32 name:@"input"];
        BOOL vectorConstant = [mode isEqualToString:@"constant"];
        float constants[64];
        for (unsigned i=0; i<64; ++i) constants[i]=(float)(i+1);
        MPSGraphTensor *one = vectorConstant ?
            [graph constantWithData:[NSData dataWithBytes:constants length:sizeof(constants)] shape:@[@64] dataType:MPSDataTypeFloat32] :
            [graph constantWithScalar:1.0 shape:@[@64] dataType:MPSDataTypeFloat32];
        MPSGraphTensor *sum = [graph additionWithPrimaryTensor:placeholder secondaryTensor:one name:@"sum"];
        report(@{@"stage":@"before-graph-run", @"mode":mode});
        NSDictionary *results = [mode isEqualToString:@"default"] ?
            [graph runWithFeeds:@{placeholder:input} targetTensors:@[sum] targetOperations:nil] :
            [graph runWithMTLCommandQueue:queue feeds:@{placeholder:input} targetTensors:@[sum] targetOperations:nil];
        float values[64] = {0};
        [[results[sum] mpsndarray] readBytes:values strideBytes:NULL];
        unsigned mismatches=0;
        for (unsigned i=0; i<64; ++i) if (values[i]!=(float)(vectorConstant ? 2*i+1 : i+1)) ++mismatches;
        report(@{@"stage":@"graph-result", @"checked":@64, @"mismatches":@(mismatches), @"resultAvailable":@(results[sum]!=nil)});
        return mismatches ? 5 : 0;
    }
}
