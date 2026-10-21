#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <objc/runtime.h>

// The optional bridge diagnostic records only calls made by this process's task.
// No interposition or other application's resource data is involved.
typedef struct {
    uint32_t sequence, size;
    int32_t status;
    uint32_t reserved;
    unsigned char bytes[512];
} ResourceDiagnostic;
static io_connect_t diagnosticConnection(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("AppleParavirtAccelerator"));
    io_connect_t connection = IO_OBJECT_NULL;
    if (service) {
        kern_return_t status = IOServiceOpen(service, mach_task_self(), 0x524d0005, &connection);
        IOObjectRelease(service);
        if (status != KERN_SUCCESS) return IO_OBJECT_NULL;
    }
    return connection;
}

int main(int argc, char **argv) {
    if (argc != 2 || strlen(argv[1]) != 1 || argv[1][0] < '0' || argv[1][0] > '7') return 64;
    unsigned mode = (unsigned)(argv[1][0] - '0');
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 1;
        MTLHeapDescriptor *descriptor = [MTLHeapDescriptor new];
        descriptor.size = 16 * 1024 * 1024;
        descriptor.storageMode = (mode & 1) ? MTLStorageModeShared : MTLStorageModePrivate;
        descriptor.type = (mode & 2) ? MTLHeapTypePlacement : MTLHeapTypeAutomatic;
        descriptor.hazardTrackingMode = (mode & 4) ? MTLHazardTrackingModeUntracked : MTLHazardTrackingModeTracked;
        io_connect_t diagnostic = diagnosticConnection();
        fprintf(stderr, "HEAP_DEVICE class=%s image=%s\n", object_getClassName(device),
            class_getImageName(object_getClass(device)));
        kern_return_t armed = diagnostic ? IOConnectCallMethod(diagnostic, 0x524d0002,
            NULL, 0, NULL, 0, NULL, NULL, NULL, NULL) : KERN_NOT_SUPPORTED;
        id<MTLHeap> heap = [device newHeapWithDescriptor:descriptor];
        if (armed == KERN_SUCCESS) {
            ResourceDiagnostic capture = {0};
            size_t size = sizeof(capture);
            kern_return_t status = IOConnectCallStructMethod(diagnostic, 0x524d0003,
                NULL, 0, &capture, &size);
            fprintf(stderr, "AUTHORED_HEAP_CALL capture=%x sequence=%u size=%u result=%x bytes=",
                status, capture.sequence, capture.size, (uint32_t)capture.status);
            if (status == KERN_SUCCESS && capture.size <= sizeof(capture.bytes))
                for (uint32_t i = 0; i < capture.size; ++i) fprintf(stderr, "%02x", capture.bytes[i]);
            fputc('\n', stderr);
        }
        if (diagnostic) IOServiceClose(diagnostic);
        MTLResourceOptions options = (descriptor.storageMode << MTLResourceStorageModeShift) |
            (descriptor.hazardTrackingMode << MTLResourceHazardTrackingModeShift);
        id<MTLBuffer> buffer = nil;
        if (heap) {
            buffer = descriptor.type == MTLHeapTypePlacement ?
                [heap newBufferWithLength:4096 options:options offset:0] :
                [heap newBufferWithLength:4096 options:options];
        }
        printf("{\"mode\":%u,\"storage\":%lu,\"type\":%lu,\"hazard\":%lu,\"heap_allocated\":%s,\"buffer_allocated\":%s,\"heap_size\":%llu}\n",
            mode, (unsigned long)descriptor.storageMode, (unsigned long)descriptor.type,
            (unsigned long)descriptor.hazardTrackingMode, heap ? "true" : "false",
            buffer ? "true" : "false", (unsigned long long)heap.size);
        return heap && buffer ? 0 : 2;
    }
}
