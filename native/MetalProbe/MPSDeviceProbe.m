#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

// Separate ordinary Metal device discovery from MPS/Graph initialization.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSMutableDictionary *report = [@{@"stage":@"mps-device",
            @"metalDeviceAvailable":@(device != nil),
            @"deviceName":device.name ?: @"",
            @"mpsSupportsDevice":@(MPSSupportsMTLDevice(device))} mutableCopy];
        if (!device) return 2;
        @try {
            MPSGraphDevice *graph = [MPSGraphDevice deviceWithMTLDevice:device];
            report[@"graphDeviceAvailable"] = @(graph != nil);
            report[@"graphMetalDeviceAvailable"] = @(graph.metalDevice != nil);
            report[@"graphMetalDeviceMatches"] = @(graph.metalDevice.registryID == device.registryID);
            MPSNDArray *array = [[MPSNDArray alloc] initWithDevice:device scalar:1.0];
            report[@"ndArrayAvailable"] = @(array != nil);
            report[@"ndArrayDeviceAvailable"] = @(array.device != nil);
        } @catch (NSException *exception) {
            report[@"exceptionName"] = exception.name;
            report[@"exceptionReason"] = exception.reason ?: @"";
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        fwrite(data.bytes, 1, data.length, stdout); puts("");
        return report[@"exceptionName"] ? 4 : 0;
    }
}
