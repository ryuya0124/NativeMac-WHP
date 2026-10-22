#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdatomic.h>

// AppleParavirt's encoder lacks the object/mesh resource setters. Keep those
// independent binding tables alive for the encoder's lifetime. Traditional
// vertex/fragment draws cannot read them. Mesh execution is explicitly refused:
// this adapter does not implement a mesh command stream or claim mesh support.
// Load only into a selected test process, never into the desktop globally.
enum { NMStages = 2, NMSamplers = 16, NMTextures = 128, NMBuffers = 31 };
@interface NMStageSamplers : NSObject {
@public
    id<MTLSamplerState> slots[NMStages][NMSamplers];
    float minimum[NMStages][NMSamplers];
    float maximum[NMStages][NMSamplers];
    BOOL clamped[NMStages][NMSamplers];
    id<MTLTexture> textures[NMStages][NMTextures];
    id<MTLBuffer> buffers[NMStages][NMBuffers];
    NSUInteger offsets[NMStages][NMBuffers];
    NSData *bytes[NMStages][NMBuffers];
    NSUInteger threadgroupLengths[NMBuffers];
}
@end
@implementation NMStageSamplers
@end

static char stateKey;
static atomic_ulong bindingCalls;
static atomic_ulong rejectedDraws;

static void refuse(NSString *reason) {
    @throw [NSException exceptionWithName:NSInvalidArgumentException
        reason:reason userInfo:nil];
}

static NMStageSamplers *stateFor(id encoder) {
    NMStageSamplers *state = objc_getAssociatedObject(encoder, &stateKey);
    if (!state) {
        state = [NMStageSamplers new];
        objc_setAssociatedObject(encoder, &stateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static unsigned stageFor(SEL selector) {
    return strncmp(sel_getName(selector), "setObject", 9) == 0 ? 0 : 1;
}

static void checkRange(NSRange range) {
    if (range.location > NMSamplers || range.length > NMSamplers - range.location)
        refuse(@"NativeMac: object/mesh sampler index outside [0, 16)");
}
static void checkSlots(NSRange range, NSUInteger limit) {
    if (range.location > limit || range.length > limit - range.location)
        refuse(@"NativeMac: object/mesh resource range out of bounds");
}
static void textureArray(id encoder, SEL selector, const id<MTLTexture> *textures, NSRange range) {
    checkSlots(range, NMTextures);
    if (range.length && !textures) refuse(@"NativeMac: missing texture array");
    NMStageSamplers *state = stateFor(encoder);
    unsigned stage = stageFor(selector);
    for (NSUInteger n=0; n<range.length; ++n) state->textures[stage][range.location+n] = textures[n];
    atomic_fetch_add(&bindingCalls, 1);
}
static void textureSingle(id encoder, SEL selector, id<MTLTexture> texture, NSUInteger index) {
    textureArray(encoder, selector, &texture, NSMakeRange(index,1));
}
static void bufferArray(id encoder, SEL selector, const id<MTLBuffer> *buffers,
                         const NSUInteger *offsets, NSRange range) {
    checkSlots(range, NMBuffers);
    if (range.length && (!buffers || !offsets)) refuse(@"NativeMac: missing buffer array or offsets");
    for (NSUInteger n=0; n<range.length; ++n)
        if (buffers[n] && offsets[n] > buffers[n].length) refuse(@"NativeMac: buffer offset exceeds length");
    NMStageSamplers *state = stateFor(encoder);
    unsigned stage = stageFor(selector);
    for (NSUInteger n=0; n<range.length; ++n) {
        NSUInteger index = range.location+n;
        state->buffers[stage][index] = buffers[n];
        state->offsets[stage][index] = offsets[n];
        state->bytes[stage][index] = nil;
    }
    atomic_fetch_add(&bindingCalls, 1);
}
static void bufferSingle(id encoder, SEL selector, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) {
    bufferArray(encoder, selector, &buffer, &offset, NSMakeRange(index,1));
}
static void bufferOffset(id encoder, SEL selector, NSUInteger offset, NSUInteger index) {
    checkSlots(NSMakeRange(index,1), NMBuffers);
    NMStageSamplers *state = stateFor(encoder);
    unsigned stage = stageFor(selector);
    if (!state->buffers[stage][index] || offset > state->buffers[stage][index].length)
        refuse(@"NativeMac: object/mesh buffer offset needs a bound buffer within range");
    state->offsets[stage][index] = offset;
    atomic_fetch_add(&bindingCalls, 1);
}
static void inlineBytes(id encoder, SEL selector, const void *bytes, NSUInteger length, NSUInteger index) {
    checkSlots(NSMakeRange(index,1), NMBuffers);
    if (length > 4096 || (length && !bytes)) refuse(@"NativeMac: invalid object/mesh inline bytes");
    NMStageSamplers *state = stateFor(encoder);
    unsigned stage = stageFor(selector);
    state->bytes[stage][index] = [NSData dataWithBytes:bytes length:length];
    state->buffers[stage][index] = nil;
    state->offsets[stage][index] = 0;
    atomic_fetch_add(&bindingCalls, 1);
}
static void threadgroupMemory(id encoder, SEL selector, NSUInteger length, NSUInteger index) {
    (void)selector;
    checkSlots(NSMakeRange(index,1), NMBuffers);
    NMStageSamplers *state = stateFor(encoder);
    state->threadgroupLengths[index] = length;
    atomic_fetch_add(&bindingCalls, 1);
}

static void bind(id encoder, SEL selector, const id<MTLSamplerState> *samplers,
                 const float *minimum, const float *maximum, NSRange range) {
    checkRange(range);
    if (range.length && !samplers) refuse(@"NativeMac: missing sampler array");
    if ((minimum == NULL) != (maximum == NULL)) refuse(@"NativeMac: incomplete LOD clamps");
    unsigned stage = stageFor(selector);
    NMStageSamplers *state = stateFor(encoder);
    for (NSUInteger n = 0; n < range.length; ++n) {
        NSUInteger index = range.location + n;
        state->slots[stage][index] = samplers[n];
        state->clamped[stage][index] = minimum != NULL;
        state->minimum[stage][index] = minimum ? minimum[n] : 0;
        state->maximum[stage][index] = maximum ? maximum[n] : 0;
    }
    atomic_fetch_add(&bindingCalls, 1);
}

static void single(id encoder, SEL selector, id<MTLSamplerState> sampler, NSUInteger index) {
    bind(encoder, selector, &sampler, NULL, NULL, NSMakeRange(index, 1));
}
static void singleClamped(id encoder, SEL selector, id<MTLSamplerState> sampler,
                           float minimum, float maximum, NSUInteger index) {
    bind(encoder, selector, &sampler, &minimum, &maximum, NSMakeRange(index, 1));
}
static void multiple(id encoder, SEL selector, const id<MTLSamplerState> *samplers, NSRange range) {
    bind(encoder, selector, samplers, NULL, NULL, range);
}
static void multipleClamped(id encoder, SEL selector, const id<MTLSamplerState> *samplers,
                             const float *minimum, const float *maximum, NSRange range) {
    bind(encoder, selector, samplers, minimum, maximum, range);
}
static void unsupportedMesh(id encoder, SEL selector, MTLSize grid, MTLSize object, MTLSize mesh) {
    (void)encoder; (void)grid; (void)object; (void)mesh;
    atomic_fetch_add(&rejectedDraws, 1);
    refuse([NSString stringWithFormat:@"NativeMac: %@ requires an unimplemented guest mesh command stream",
        NSStringFromSelector(selector)]);
}
static void unsupportedIndirectMesh(id encoder, SEL selector, id buffer, NSUInteger offset,
                                     MTLSize object, MTLSize mesh) {
    (void)buffer; (void)offset;
    unsupportedMesh(encoder, selector, MTLSizeMake(0,0,0), object, mesh);
}

// Test observability: these inspect only adapter-owned state, never guest data
// or driver internals. They do not change the public Metal feature queries.
__attribute__((visibility("default"))) unsigned long NMDeferredSamplerBindings(void) {
    return atomic_load(&bindingCalls);
}
__attribute__((visibility("default"))) unsigned long NMDeferredMeshRefusals(void) {
    return atomic_load(&rejectedDraws);
}
__attribute__((visibility("default"))) BOOL NMDeferredSamplerMatches(id encoder,
    unsigned stage, NSUInteger index, id sampler, BOOL clamped, float low, float high) {
    if (stage >= NMStages || index >= NMSamplers) return NO;
    NMStageSamplers *state = objc_getAssociatedObject(encoder, &stateKey);
    return state && state->slots[stage][index] == sampler && state->clamped[stage][index] == clamped
        && (!clamped || (state->minimum[stage][index] == low && state->maximum[stage][index] == high));
}
__attribute__((visibility("default"))) BOOL NMDeferredTextureMatches(id encoder,
    unsigned stage, NSUInteger index, id texture) {
    if (stage >= NMStages || index >= NMTextures) return NO;
    NMStageSamplers *state = objc_getAssociatedObject(encoder, &stateKey);
    return state && state->textures[stage][index] == texture;
}
__attribute__((visibility("default"))) BOOL NMDeferredBufferMatches(id encoder,
    unsigned stage, NSUInteger index, id buffer, NSUInteger offset) {
    if (stage >= NMStages || index >= NMBuffers) return NO;
    NMStageSamplers *state = objc_getAssociatedObject(encoder, &stateKey);
    return state && state->buffers[stage][index] == buffer && state->offsets[stage][index] == offset;
}
__attribute__((visibility("default"))) BOOL NMDeferredBytesMatch(id encoder,
    unsigned stage, NSUInteger index, const void *bytes, NSUInteger length) {
    if (stage >= NMStages || index >= NMBuffers) return NO;
    NMStageSamplers *state = objc_getAssociatedObject(encoder, &stateKey);
    return state && [state->bytes[stage][index] isEqualToData:[NSData dataWithBytes:bytes length:length]];
}

static BOOL replace(Class cls, SEL selector, IMP implementation) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, implementation, types))
        class_replaceMethod(cls, selector, implementation, types);
    return YES;
}

__attribute__((constructor)) static void install(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        Class cls = [encoder class];
        if ([NSStringFromClass(cls) isEqualToString:@"AppleParavirtRenderCommandEncoder"]) {
            // Install only when both measured legal nil calls really fail. A
            // future driver with native support must retain its implementation.
            unsigned missing = 0;
            @try { [encoder setObjectSamplerState:nil atIndex:0]; }
            @catch (NSException *e) {
                if ([e.name isEqualToString:NSInvalidArgumentException] &&
                    [e.reason containsString:@"unrecognized selector"]) missing++;
            }
            @try { [encoder setMeshSamplerState:nil atIndex:0]; }
            @catch (NSException *e) {
                if ([e.name isEqualToString:NSInvalidArgumentException] &&
                    [e.reason containsString:@"unrecognized selector"]) missing++;
            }
            if (missing == 2) {
                BOOL installed = YES;
                for (NSString *stage in @[@"Object", @"Mesh"]) {
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@Texture:atIndex:", stage]), (IMP)textureSingle);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@Textures:withRange:", stage]), (IMP)textureArray);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@Buffer:offset:atIndex:", stage]), (IMP)bufferSingle);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@Buffers:offsets:withRange:", stage]), (IMP)bufferArray);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@BufferOffset:atIndex:", stage]), (IMP)bufferOffset);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@Bytes:length:atIndex:", stage]), (IMP)inlineBytes);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@SamplerState:atIndex:", stage]), (IMP)single);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@SamplerState:lodMinClamp:lodMaxClamp:atIndex:", stage]), (IMP)singleClamped);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@SamplerStates:withRange:", stage]), (IMP)multiple);
                    installed &= replace(cls, NSSelectorFromString([NSString stringWithFormat:
                        @"set%@SamplerStates:lodMinClamps:lodMaxClamps:withRange:", stage]), (IMP)multipleClamped);
                }
                installed &= replace(cls, @selector(setObjectThreadgroupMemoryLength:atIndex:), (IMP)threadgroupMemory);
                installed &= replace(cls, @selector(drawMeshThreadgroups:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:), (IMP)unsupportedMesh);
                installed &= replace(cls, @selector(drawMeshThreads:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:), (IMP)unsupportedMesh);
                installed &= replace(cls, @selector(drawMeshThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:), (IMP)unsupportedIndirectMesh);
                if (!installed) abort(); // Never leave an incomplete adapter active.
                fprintf(stderr, "NativeMac: deferred object/mesh sampler tables active; mesh execution unsupported\n");
            }
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
    }
}

__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "NATIVEMAC_DEFERRED_SAMPLERS bindings=%lu meshRefusals=%lu\n",
        atomic_load(&bindingCalls), atomic_load(&rejectedDraws));
}
