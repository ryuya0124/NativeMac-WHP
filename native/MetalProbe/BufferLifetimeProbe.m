#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>

// File-backed CPU pages enter Metal without a copy. Command buffers retain the
// input until GPU completion; releasing it must permit a checked flush/unmap.
int main(int argc, const char **argv) {
    BOOL large = argc == 2 && strcmp(argv[1], "--large") == 0;
    if (argc != 1 && !large) return 64;
    @autoreleasepool {
        NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void lifetime(device uint *in [[buffer(0)]],device uint *out [[buffer(1)]],"
            "constant uint &seed [[buffer(2)]],uint i [[thread_position_in_grid]]) {"
            "uint x=in[i]+seed; in[i]=x; out[i]=x^0xa5a55a5au;}";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLComputePipelineState> pipeline = library ? [device newComputePipelineStateWithFunction:
            [library newFunctionWithName:@"lifetime"] error:&error] : nil;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!pipeline || !queue) {
            fprintf(stderr, "pipeline/queue: %s\n", error.description.UTF8String);
            return 1;
        }
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nativemac-lifetime.XXXXXX"];
        char *path = strdup(pattern.fileSystemRepresentation);
        int fd = mkstemp(path);
        if (fd < 0) { free(path); return 2; }
        int removed = unlink(path);
        free(path);
        if (removed || ftruncate(fd, large ? 64 * 1024 * 1024 : 1024 * 1024)) { close(fd); return 2; }

        __block atomic_uint released = 0, mappingErrors = 0;
        uint64_t valuesChecked = 0;
        const unsigned rounds = large ? 3 : 192;
        for (unsigned round = 0; round < rounds; ++round) {
            @autoreleasepool {
                const size_t sizes[] = {16384, 65536, 1024 * 1024};
                const size_t largeSizes[] = {16 * 1024 * 1024, 32 * 1024 * 1024, 64 * 1024 * 1024};
                size_t bytes = large ? largeSizes[round % 3] : sizes[round % 3];
                size_t count = bytes / sizeof(uint32_t);
                uint32_t seed = round * 7919u + 1u;
                void *pages = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
                if (pages == MAP_FAILED) { close(fd); return 3; }
                uint32_t *inputValues = pages;
                for (size_t i = 0; i < count; ++i) inputValues[i] = (uint32_t)i * 1664525u + round;
                id<MTLBuffer> input = [device newBufferWithBytesNoCopy:pages length:bytes
                    options:MTLResourceStorageModeShared deallocator:^(void *pointer, NSUInteger length) {
                        if (msync(pointer, length, MS_SYNC)) atomic_fetch_add(&mappingErrors, 1);
                        if (munmap(pointer, length)) atomic_fetch_add(&mappingErrors, 1);
                        atomic_fetch_add(&released, 1);
                    }];
                if (!input) {
                    munmap(pages, bytes);
                    fprintf(stderr, "file-backed no-copy allocation refused at round %u\n", round);
                    close(fd); return 4;
                }
                id<MTLBuffer> output = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> command = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                if (!output || !command || !encoder) { close(fd); return 5; }
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:input offset:0 atIndex:0];
                [encoder setBuffer:output offset:0 atIndex:1];
                [encoder setBytes:&seed length:sizeof(seed) atIndex:2];
                [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(MIN(256, pipeline.maxTotalThreadsPerThreadgroup), 1, 1)];
                [encoder endEncoding];
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                [command addCompletedHandler:^(id<MTLCommandBuffer> _) { dispatch_semaphore_signal(done); }];
                [command commit];
                input = nil;
                if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) ||
                    command.status != MTLCommandBufferStatusCompleted) {
                    fprintf(stderr, "GPU command failed at round %u: %s\n", round, command.error.description.UTF8String);
                    close(fd); return 6;
                }
                const uint32_t *actual = output.contents;
                for (size_t i = 0; i < count; ++i) {
                    uint32_t expected = ((uint32_t)i * 1664525u + round + seed) ^ 0xa5a55a5au;
                    if (actual[i] != expected) {
                        fprintf(stderr, "round=%u element=%zu actual=%u expected=%u\n", round, i, actual[i], expected);
                        close(fd); return 7;
                    }
                }
                valuesChecked += count;
            }
            if (large || (round + 1) % 32 == 0) {
                printf("{\"completed_rounds\":%u,\"released\":%u,\"values_checked\":%llu}\n",
                    round + 1, atomic_load(&released), (unsigned long long)valuesChecked);
                fflush(stdout);
            }
        }
        for (unsigned wait = 0; atomic_load(&released) < rounds && wait < 500; ++wait) usleep(10000);
        int syncError = fsync(fd);
        close(fd);
        unsigned releases = atomic_load(&released), errors = atomic_load(&mappingErrors);
        BOOL passed = releases == rounds && !errors && !syncError;
        printf("{\"passed\":%s,\"rounds\":%u,\"released\":%u,\"mapping_errors\":%u,\"values_checked\":%llu}\n",
            passed ? "true" : "false", rounds, releases, errors, (unsigned long long)valuesChecked);
        printf("{\"large_buffers\":%s,\"elapsed_seconds\":%.6f}\n", large ? "true" : "false",
            NSProcessInfo.processInfo.systemUptime - started);
        return passed ? 0 : 8;
    }
}
