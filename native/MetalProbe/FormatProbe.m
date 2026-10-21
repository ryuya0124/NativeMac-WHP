#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Query the guest-visible feature claims without submitting unsupported work.
int main(int argc, const char **argv) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        NSMutableDictionary *families = [NSMutableDictionary new];
        for (NSInteger family = 1001; family <= 1010; family++)
            families[[NSString stringWithFormat:@"%ld", (long)family]] =
                @([device supportsFamily:(MTLGPUFamily)family]);
        for (NSInteger family = 2001; family <= 2002; family++)
            families[[NSString stringWithFormat:@"%ld", (long)family]] =
                @([device supportsFamily:(MTLGPUFamily)family]);
        NSMutableDictionary *result = [@{@"stage":@"format-capabilities", @"device":device.name,
            @"families":families, @"bcCompression":@(device.supportsBCTextureCompression)} mutableCopy];
        BOOL rejected = YES;
        if (argc == 2 && strcmp(argv[1], "--expect-astc-rejection") == 0) {
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_8x8_LDR
                width:16 height:16 mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
            rejected = texture == nil;
            result[@"astcAllocationRejected"] = @(rejected);
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(data.bytes,1,data.length,stdout); putchar('\n');
        return rejected ? 0 : 2;
    }
}
