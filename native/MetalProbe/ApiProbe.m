#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Observe advertised families and optional entry points without submitting
// commands to missing methods or treating an unsupported draw as successful.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        NSMutableDictionary *families = [NSMutableDictionary new];
        for (NSNumber *value in @[@1001,@1002,@1003,@1004,@1005,@1006,@1007,
                                  @1008,@1009,@1010,@2001,@2002,@3001,@3002,
                                  @3003,@4001,@5001,@5002]) {
            families[value.stringValue] = @([device supportsFamily:(MTLGPUFamily)value.integerValue]);
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [device newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!target || !command || !encoder) return 2;
        NSMutableDictionary *selectors = [NSMutableDictionary new];
        for (NSString *name in @[@"setVertexSamplerState:atIndex:",
            @"setFragmentSamplerState:atIndex:", @"setObjectSamplerState:atIndex:",
            @"setMeshSamplerState:atIndex:", @"setObjectBuffer:offset:atIndex:",
            @"setMeshBuffer:offset:atIndex:", @"drawMeshThreadgroups:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:"]) {
            selectors[name] = @([encoder respondsToSelector:NSSelectorFromString(name)]);
        }
        // Some drivers claim a selector through an inherited protocol stub.
        // Nil sampler bindings are legal; catch and report a real refusal.
        NSMutableDictionary *bindings = [NSMutableDictionary new];
        @try {
            [encoder setObjectSamplerState:nil atIndex:0];
            bindings[@"objectNilSampler"] = @"accepted";
        } @catch (NSException *exception) {
            bindings[@"objectNilSampler"] = exception.reason ?: exception.name;
        }
        @try {
            [encoder setMeshSamplerState:nil atIndex:0];
            bindings[@"meshNilSampler"] = @"accepted";
        } @catch (NSException *exception) {
            bindings[@"meshNilSampler"] = exception.reason ?: exception.name;
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        NSDictionary *result = @{@"stage":@"api-preflight", @"device":device.name,
            @"encoderClass":NSStringFromClass([encoder class]), @"families":families,
            @"encoderSelectors":selectors, @"samplerBindings":bindings,
            @"clearCompleted":@(command.status == MTLCommandBufferStatusCompleted)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes, 1, data.length, stdout);
        putchar('\n');
        return command.status == MTLCommandBufferStatusCompleted ? 0 : 3;
    }
}
