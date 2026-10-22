#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>

// Check raw GPU copies followed by CPU readback, including array slices, mips,
// subregions and padded destination rows. Padding must retain its sentinel.
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue=[device newCommandQueue];
        const MTLPixelFormat formats[]={MTLPixelFormatR8Uint,MTLPixelFormatRG8Uint,
            MTLPixelFormatR16Uint,MTLPixelFormatR32Uint,MTLPixelFormatRGBA8Unorm,
            MTLPixelFormatBGRA8Unorm,MTLPixelFormatRGBA32Uint};
        const NSUInteger units[]={1,2,2,4,4,4,16};
        NSUInteger cases=0,checked=0,errors=0;
        for (unsigned f=0;f<sizeof(formats)/sizeof(formats[0]);++f) {
            for (unsigned array=0;array<2;++array) {
                MTLTextureDescriptor *td=[MTLTextureDescriptor new];
                td.textureType=array?MTLTextureType2DArray:MTLTextureType2D;
                td.pixelFormat=formats[f];td.width=16;td.height=8;
                td.arrayLength=array?3:1;td.mipmapLevelCount=3;
                td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
                id<MTLTexture> texture=[device newTextureWithDescriptor:td];
                if (!texture || !queue) return 2;
                for (NSUInteger slice=0;slice<td.arrayLength;++slice) {
                    for (NSUInteger level=0;level<td.mipmapLevelCount;++level) {
                        NSUInteger width=td.width>>level,height=td.height>>level,unit=units[f];
                        NSUInteger gpuRow=256,gpuSize=gpuRow*height;
                        id<MTLBuffer> input=[device newBufferWithLength:gpuSize options:MTLResourceStorageModeShared];
                        if (!input) return 2;
                        uint8_t *source=input.contents;
                        memset(source,0,gpuSize);
                        for(NSUInteger y=0;y<height;++y)
                            for(NSUInteger x=0;x<width*unit;++x)
                                source[y*gpuRow+x]=(uint8_t)((x*13+y*7+slice*31+level*19)&255);
                        id<MTLCommandBuffer> command=[queue commandBuffer];
                        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
                        [blit copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:gpuRow
                            sourceBytesPerImage:gpuSize sourceSize:MTLSizeMake(width,height,1)
                            toTexture:texture destinationSlice:slice destinationLevel:level
                            destinationOrigin:MTLOriginMake(0,0,0)];
                        [blit endEncoding];[command commit];[command waitUntilCompleted];
                        if(command.status!=MTLCommandBufferStatusCompleted)return 3;
                        MTLRegion region=MTLRegionMake2D(1,1,width-2,height-1);
                        NSUInteger packed=region.size.width*unit,row=packed+17,length=row*region.size.height+32;
                        NSMutableData *actual=[NSMutableData dataWithLength:length];
                        NSMutableData *expected=[NSMutableData dataWithLength:length];
                        memset(actual.mutableBytes,0xa5,length);memset(expected.mutableBytes,0xa5,length);
                        for(NSUInteger y=0;y<region.size.height;++y)
                            memcpy((uint8_t *)expected.mutableBytes+16+y*row,
                                source+(y+1)*gpuRow+unit,packed);
                        void *destination=(uint8_t *)actual.mutableBytes+16;
                        if(array)
                            [texture getBytes:destination bytesPerRow:row bytesPerImage:row*region.size.height
                                fromRegion:region mipmapLevel:level slice:slice];
                        else
                            [texture getBytes:destination bytesPerRow:row fromRegion:region mipmapLevel:level];
                        const uint8_t *a=actual.bytes,*e=expected.bytes;
                        for(NSUInteger n=0;n<length;++n){++checked;errors+=a[n]!=e[n];}
                        ++cases;
                    }
                }
            }
        }
        printf("{\"stage\":\"texture-readback-regions\",\"cases\":%lu,\"checkedBytes\":%lu,\"errors\":%lu,\"passed\":%s}\n",
            (unsigned long)cases,(unsigned long)checked,(unsigned long)errors,errors?"false":"true");
        return errors?4:0;
    }
}
