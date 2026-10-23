#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <vulkan/vulkan.h>
#include "GpuFrameInterop.h"
#include <array>
#include <cstring>
#include <stdexcept>
#include <string>

namespace {
void vkCheck(VkResult status){if(status!=VK_SUCCESS)throw std::runtime_error("Vulkan interop status "+std::to_string(status));}
void cuCheck(CUresult status){if(status!=CUDA_SUCCESS)throw std::runtime_error("CUDA interop status "+std::to_string(status));}
template<class T> T load(HMODULE module,const char* name){
    auto address=GetProcAddress(module,name);
    if(!address)throw std::runtime_error(std::string("Missing GPU entry ")+name);
    return reinterpret_cast<T>(address);
}
#define VK_ENTRIES(X) \
 X(CreateInstance) X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties2) X(GetPhysicalDeviceFeatures2) \
 X(GetPhysicalDeviceMemoryProperties) X(GetPhysicalDeviceQueueFamilyProperties) X(GetPhysicalDeviceExternalBufferProperties) \
 X(GetPhysicalDeviceExternalSemaphoreProperties) X(CreateDevice) X(DestroyDevice) X(GetDeviceProcAddr) X(GetDeviceQueue) \
 X(CreateBuffer) X(DestroyBuffer) X(GetBufferMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) \
 X(CreateImage) X(DestroyImage) X(GetImageMemoryRequirements) X(BindImageMemory) \
 X(CreateSemaphore) X(DestroySemaphore) X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers) \
 X(BeginCommandBuffer) X(EndCommandBuffer) X(CmdPipelineBarrier) X(CmdCopyBufferToImage) X(CmdCopyImageToBuffer) \
 X(CreateFence) X(DestroyFence) X(ResetFences) X(WaitForFences) X(WaitSemaphores) X(QueueSubmit) X(DeviceWaitIdle) X(MapMemory) X(UnmapMemory)
#define CU_ENTRIES(X) \
 X(cuDeviceGetUuid) X(cuImportExternalMemory) X(cuDestroyExternalMemory) X(cuExternalMemoryGetMappedBuffer) X(cuMemFree_v2) \
 X(cuImportExternalSemaphore) X(cuDestroyExternalSemaphore) X(cuWaitExternalSemaphoresAsync) X(cuSignalExternalSemaphoresAsync) \
 X(cuMemcpy2DAsync_v2) X(cuStreamCreate) X(cuStreamSynchronize) X(cuStreamDestroy_v2)
}

struct GpuFrameInterop::State {
    HMODULE vulkan=nullptr,cuda=nullptr;
#define DECLARE_VK(name) PFN_vk##name name=nullptr;
    VK_ENTRIES(DECLARE_VK)
#undef DECLARE_VK
#define DECLARE_CU(name) t##name* name=nullptr;
    CU_ENTRIES(DECLARE_CU)
#undef DECLARE_CU
    PFN_vkGetMemoryWin32HandleKHR getMemory=nullptr;
    PFN_vkGetSemaphoreWin32HandleKHR getSemaphore=nullptr;
    VkInstance instance=nullptr;
    VkPhysicalDevice physical=nullptr;
    VkDevice device=nullptr;
    VkQueue queue=nullptr;
    uint32_t family=0;
    VkPhysicalDeviceMemoryProperties memoryProperties{};
    VkBuffer shared=nullptr,readback=nullptr;
    VkDeviceMemory sharedMemory=nullptr,readbackMemory=nullptr;
    std::array<VkImage,2> planes{};
    std::array<VkDeviceMemory,2> planeMemory{};
    VkSemaphore ready=nullptr,released=nullptr;
    VkCommandPool pool=nullptr;
    VkCommandBuffer command=nullptr;
    VkFence fence=nullptr;
    CUexternalMemory imported=nullptr;
    CUdeviceptr destination=0;
    CUexternalSemaphore cudaReady=nullptr,cudaReleased=nullptr;
    CUstream stream=nullptr;
    unsigned width,height;
    size_t bytes;
    bool exporting;
    unsigned stride;
    uint64_t generation=0,allocationSize=0;
    uint32_t sharedMemoryType=0,sharedUsage=0;
    std::array<uint8_t,16> deviceUuid{};
    std::array<HANDLE,3> exports{};
    bool submitted=false;
    State(unsigned w,unsigned h,bool exportingFrames):width(w),height(h),bytes(static_cast<size_t>(w)*h*3/2),exporting(exportingFrames),stride(exportingFrames?(w+255)&~255u:w){
        if(exporting)bytes=static_cast<size_t>(stride)*height*3/2;
    }
    ~State(){
        // The owning worker's watchdog bounds a device failure. Nothing is
        // freed while either API can still refer to the shared allocation.
        if(device&&DeviceWaitIdle)DeviceWaitIdle(device);
        if(stream&&cuStreamSynchronize)cuStreamSynchronize(stream);
        if(stream&&cuStreamDestroy_v2)cuStreamDestroy_v2(stream);
        if(cudaReady&&cuDestroyExternalSemaphore)cuDestroyExternalSemaphore(cudaReady);
        if(cudaReleased&&cuDestroyExternalSemaphore)cuDestroyExternalSemaphore(cudaReleased);
        if(destination&&cuMemFree_v2)cuMemFree_v2(destination);
        if(imported&&cuDestroyExternalMemory)cuDestroyExternalMemory(imported);
        for(auto handle:exports)if(handle)CloseHandle(handle);
        if(device){
            if(fence)DestroyFence(device,fence,nullptr);
            if(pool)DestroyCommandPool(device,pool,nullptr);
            if(ready)DestroySemaphore(device,ready,nullptr);
            if(released)DestroySemaphore(device,released,nullptr);
            for(size_t i=0;i<planes.size();++i){
                if(planes[i])DestroyImage(device,planes[i],nullptr);
                if(planeMemory[i])FreeMemory(device,planeMemory[i],nullptr);
            }
            if(shared)DestroyBuffer(device,shared,nullptr);
            if(readback)DestroyBuffer(device,readback,nullptr);
            if(sharedMemory)FreeMemory(device,sharedMemory,nullptr);
            if(readbackMemory)FreeMemory(device,readbackMemory,nullptr);
            DestroyDevice(device,nullptr);
        }
        if(instance)DestroyInstance(instance,nullptr);
        if(cuda)FreeLibrary(cuda);
        if(vulkan)FreeLibrary(vulkan);
    }
    uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags flags){
        for(uint32_t i=0;i<memoryProperties.memoryTypeCount;++i)
            if((bits&(1u<<i))&&(memoryProperties.memoryTypes[i].propertyFlags&flags)==flags)return i;
        throw std::runtime_error("GPU interop memory type unavailable");
    }
    void semaphore(VkSemaphore& output,CUexternalSemaphore& external){
        VkExportSemaphoreCreateInfo exportInfo{VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO};
        exportInfo.handleTypes=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;
        VkSemaphoreTypeCreateInfo type{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};type.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;
        if(exporting)exportInfo.pNext=&type;
        VkSemaphoreCreateInfo info{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};info.pNext=&exportInfo;
        vkCheck(CreateSemaphore(device,&info,nullptr,&output));
        VkSemaphoreGetWin32HandleInfoKHR handleInfo{VK_STRUCTURE_TYPE_SEMAPHORE_GET_WIN32_HANDLE_INFO_KHR};
        handleInfo.semaphore=output;handleInfo.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;
        HANDLE handle=nullptr;vkCheck(getSemaphore(device,&handleInfo,&handle));
        CUDA_EXTERNAL_SEMAPHORE_HANDLE_DESC descriptor{};
        descriptor.type=exporting?CU_EXTERNAL_SEMAPHORE_HANDLE_TYPE_TIMELINE_SEMAPHORE_WIN32:CU_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32;descriptor.handle.win32.handle=handle;
        auto status=cuImportExternalSemaphore(&external,&descriptor);
        if(exporting)exports[&output==&ready?1:2]=handle;else CloseHandle(handle);
        cuCheck(status);
    }
    void initialize(CUdevice selected){
        vulkan=LoadLibraryExW(L"vulkan-1.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
        cuda=LoadLibraryExW(L"nvcuda.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
        if(!vulkan||!cuda)throw std::runtime_error("GPU interop driver unavailable");
#define LOAD_VK(name) name=load<PFN_vk##name>(vulkan,"vk" #name);
        VK_ENTRIES(LOAD_VK)
#undef LOAD_VK
#define LOAD_CU(name) name=load<t##name*>(cuda,#name);
        CU_ENTRIES(LOAD_CU)
#undef LOAD_CU
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.apiVersion=exporting?VK_API_VERSION_1_2:VK_API_VERSION_1_1;
        VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};instanceInfo.pApplicationInfo=&app;
        vkCheck(CreateInstance(&instanceInfo,nullptr,&instance));
        uint32_t count=0;vkCheck(EnumeratePhysicalDevices(instance,&count,nullptr));
        if(!count||count>64)throw std::runtime_error("Unbounded Vulkan device enumeration");
        std::vector<VkPhysicalDevice> devices(count);vkCheck(EnumeratePhysicalDevices(instance,&count,devices.data()));
        CUuuid uuid{};cuCheck(cuDeviceGetUuid(&uuid,selected));memcpy(deviceUuid.data(),uuid.bytes,16);
        for(auto candidate:devices){
            VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
            VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};properties.pNext=&id;
            GetPhysicalDeviceProperties2(candidate,&properties);
            if(!memcmp(uuid.bytes,id.deviceUUID,VK_UUID_SIZE)){
                if(physical)throw std::runtime_error("Ambiguous CUDA/Vulkan UUID");
                physical=candidate;
            }
        }
        if(!physical)throw std::runtime_error("CUDA/Vulkan device UUID mismatch");
        VkPhysicalDeviceExternalBufferInfo query{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO};
        query.usage=VK_BUFFER_USAGE_TRANSFER_SRC_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        // Match the runtime's general Metal-buffer usages, including BDA.
        // The importing device checks this exact set before wrapping it.
        if(exporting)query.usage=static_cast<VkBufferUsageFlags>(0x201ff);
        sharedUsage=query.usage;
        query.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
        VkExternalBufferProperties properties{VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES};
        GetPhysicalDeviceExternalBufferProperties(physical,&query,&properties);
        if(!(properties.externalMemoryProperties.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT))throw std::runtime_error("Vulkan buffer is not exportable");
        VkPhysicalDeviceExternalSemaphoreInfo semaphoreQuery{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO};
        semaphoreQuery.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;
        VkSemaphoreTypeCreateInfo timelineQuery{VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};timelineQuery.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;
        if(exporting)semaphoreQuery.pNext=&timelineQuery;
        VkExternalSemaphoreProperties semaphoreProperties{VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES};
        GetPhysicalDeviceExternalSemaphoreProperties(physical,&semaphoreQuery,&semaphoreProperties);
        if(!(semaphoreProperties.externalSemaphoreFeatures&VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT))throw std::runtime_error("Vulkan semaphore is not exportable");
        GetPhysicalDeviceMemoryProperties(physical,&memoryProperties);
        uint32_t families=0;GetPhysicalDeviceQueueFamilyProperties(physical,&families,nullptr);
        if(!families||families>128)throw std::runtime_error("Unbounded Vulkan queue families");
        std::vector<VkQueueFamilyProperties> queues(families);GetPhysicalDeviceQueueFamilyProperties(physical,&families,queues.data());
        family=UINT32_MAX;
        for(uint32_t i=0;i<families;++i)if(queues[i].queueCount&&(queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT)){family=i;break;}
        if(family==UINT32_MAX)throw std::runtime_error("Vulkan graphics queue unavailable");
        float priority=0.5f;
        VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};queueInfo.queueFamilyIndex=family;queueInfo.queueCount=1;queueInfo.pQueuePriorities=&priority;
        const char* extensions[]={VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME,VK_KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME};
        VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};deviceInfo.queueCreateInfoCount=1;deviceInfo.pQueueCreateInfos=&queueInfo;
        deviceInfo.enabledExtensionCount=2;deviceInfo.ppEnabledExtensionNames=extensions;
        VkPhysicalDeviceVulkan12Features features{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
        if(exporting){
            VkPhysicalDeviceFeatures2 supported{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};supported.pNext=&features;
            GetPhysicalDeviceFeatures2(physical,&supported);
            if(!features.timelineSemaphore||!features.bufferDeviceAddress)throw std::runtime_error("GPU timeline/BDA unavailable");
            features={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};features.timelineSemaphore=VK_TRUE;features.bufferDeviceAddress=VK_TRUE;
            deviceInfo.pNext=&features;
        }
        vkCheck(CreateDevice(physical,&deviceInfo,nullptr,&device));GetDeviceQueue(device,family,0,&queue);
        getMemory=reinterpret_cast<PFN_vkGetMemoryWin32HandleKHR>(GetDeviceProcAddr(device,"vkGetMemoryWin32HandleKHR"));
        getSemaphore=reinterpret_cast<PFN_vkGetSemaphoreWin32HandleKHR>(GetDeviceProcAddr(device,"vkGetSemaphoreWin32HandleKHR"));
        if(!getMemory||!getSemaphore)throw std::runtime_error("Vulkan Win32 export API unavailable");
        VkExternalMemoryBufferCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};external.handleTypes=query.handleType;
        VkBufferCreateInfo bufferInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bufferInfo.pNext=&external;bufferInfo.size=bytes;bufferInfo.usage=query.usage;
        vkCheck(CreateBuffer(device,&bufferInfo,nullptr,&shared));
        VkMemoryRequirements requirement{};GetBufferMemoryRequirements(device,shared,&requirement);
        VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};dedicated.buffer=shared;
        VkExportMemoryAllocateInfo exportInfo{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};exportInfo.pNext=&dedicated;exportInfo.handleTypes=query.handleType;
        VkMemoryAllocateFlagsInfo address{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};address.flags=VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        if(exporting)dedicated.pNext=&address;
        VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};allocate.pNext=&exportInfo;allocate.allocationSize=requirement.size;
        allocate.memoryTypeIndex=memoryType(requirement.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        allocationSize=requirement.size;sharedMemoryType=allocate.memoryTypeIndex;
        vkCheck(AllocateMemory(device,&allocate,nullptr,&sharedMemory));vkCheck(BindBufferMemory(device,shared,sharedMemory,0));
        VkMemoryGetWin32HandleInfoKHR handleInfo{VK_STRUCTURE_TYPE_MEMORY_GET_WIN32_HANDLE_INFO_KHR};handleInfo.memory=sharedMemory;handleInfo.handleType=query.handleType;
        HANDLE handle=nullptr;vkCheck(getMemory(device,&handleInfo,&handle));
        CUDA_EXTERNAL_MEMORY_HANDLE_DESC descriptor{};descriptor.type=CU_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32;
        descriptor.handle.win32.handle=handle;descriptor.size=requirement.size;descriptor.flags=1; // CUDA dedicated allocation.
        auto importedStatus=cuImportExternalMemory(&imported,&descriptor);
        if(exporting)exports[0]=handle;else CloseHandle(handle);
        cuCheck(importedStatus);
        CUDA_EXTERNAL_MEMORY_BUFFER_DESC mapped{};mapped.size=bytes;cuCheck(cuExternalMemoryGetMappedBuffer(&destination,imported,&mapped));
        semaphore(ready,cudaReady);semaphore(released,cudaReleased);cuCheck(cuStreamCreate(&stream,CU_STREAM_NON_BLOCKING));
        // Export mode never allocates a CPU readback or local plane images.
        if(exporting)return;
        bufferInfo.pNext=nullptr;bufferInfo.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        vkCheck(CreateBuffer(device,&bufferInfo,nullptr,&readback));GetBufferMemoryRequirements(device,readback,&requirement);
        allocate.pNext=nullptr;allocate.allocationSize=requirement.size;
        allocate.memoryTypeIndex=memoryType(requirement.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        vkCheck(AllocateMemory(device,&allocate,nullptr,&readbackMemory));vkCheck(BindBufferMemory(device,readback,readbackMemory,0));
        for(size_t i=0;i<planes.size();++i){
            VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};info.imageType=VK_IMAGE_TYPE_2D;
            info.format=i?VK_FORMAT_R8G8_UNORM:VK_FORMAT_R8_UNORM;
            info.extent={width/(i?2:1),height/(i?2:1),1};info.mipLevels=info.arrayLayers=1;info.samples=VK_SAMPLE_COUNT_1_BIT;
            info.tiling=VK_IMAGE_TILING_OPTIMAL;info.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_SAMPLED_BIT;
            vkCheck(CreateImage(device,&info,nullptr,&planes[i]));GetImageMemoryRequirements(device,planes[i],&requirement);
            allocate.allocationSize=requirement.size;allocate.memoryTypeIndex=memoryType(requirement.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            vkCheck(AllocateMemory(device,&allocate,nullptr,&planeMemory[i]));vkCheck(BindImageMemory(device,planes[i],planeMemory[i],0));
        }
        VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};poolInfo.queueFamilyIndex=family;
        vkCheck(CreateCommandPool(device,&poolInfo,nullptr,&pool));
        VkCommandBufferAllocateInfo commands{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};commands.commandPool=pool;commands.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;commands.commandBufferCount=1;
        vkCheck(AllocateCommandBuffers(device,&commands,&command));
        VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};vkCheck(CreateFence(device,&fenceInfo,nullptr,&fence));
        record();
    }
    void record(){
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};vkCheck(BeginCommandBuffer(command,&begin));
        VkBufferMemoryBarrier acquire{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};acquire.srcQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL;
        acquire.dstQueueFamilyIndex=family;acquire.buffer=shared;acquire.size=VK_WHOLE_SIZE;acquire.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        CmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,1,&acquire,0,nullptr);
        for(size_t i=0;i<planes.size();++i){
            VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};barrier.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED;barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;barrier.image=planes[i];
            barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
            CmdPipelineBarrier(command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
            VkBufferImageCopy region{};region.bufferOffset=i?static_cast<VkDeviceSize>(width)*height:0;
            region.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};region.imageExtent={width/(i?2:1),height/(i?2:1),1};
            CmdCopyBufferToImage(command,shared,planes[i],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&region);
            barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
            CmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
            // Validation alone reads back the images *after* Vulkan consumed
            // the CUDA-written allocation. This is never the display path.
            CmdCopyImageToBuffer(command,planes[i],VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,readback,1,&region);
        }
        VkBufferMemoryBarrier release=acquire;release.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;release.dstAccessMask=0;
        release.srcQueueFamilyIndex=family;release.dstQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL;
        VkBufferMemoryBarrier host{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};host.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;host.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        host.srcQueueFamilyIndex=host.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;host.buffer=readback;host.size=VK_WHOLE_SIZE;
        std::array<VkBufferMemoryBarrier,2> barriers{release,host};
        CmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT|VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,2,barriers.data(),0,nullptr);
        vkCheck(EndCommandBuffer(command));
    }
    std::vector<uint8_t> validate(CUdeviceptr source,unsigned pitch){
        if(exporting)throw std::runtime_error("Readback forbidden in GPU export mode");
        if(!source||pitch<width)throw std::runtime_error("Invalid NVDEC surface pitch");
        if(submitted){
            CUDA_EXTERNAL_SEMAPHORE_WAIT_PARAMS wait{};cuCheck(cuWaitExternalSemaphoresAsync(&cudaReleased,&wait,1,stream));
            vkCheck(ResetFences(device,1,&fence));
        }
        CUDA_MEMCPY2D copy{};copy.srcMemoryType=copy.dstMemoryType=CU_MEMORYTYPE_DEVICE;
        copy.srcDevice=source;copy.srcPitch=pitch;copy.dstDevice=destination;copy.dstPitch=width;
        copy.WidthInBytes=width;copy.Height=height*3/2;cuCheck(cuMemcpy2DAsync_v2(&copy,stream));
        CUDA_EXTERNAL_SEMAPHORE_SIGNAL_PARAMS signal{};cuCheck(cuSignalExternalSemaphoresAsync(&cudaReady,&signal,1,stream));
        VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.waitSemaphoreCount=1;submit.pWaitSemaphores=&ready;submit.pWaitDstStageMask=&stage;
        submit.commandBufferCount=1;submit.pCommandBuffers=&command;submit.signalSemaphoreCount=1;submit.pSignalSemaphores=&released;
        vkCheck(QueueSubmit(queue,1,&submit,fence));submitted=true;
        vkCheck(WaitForFences(device,1,&fence,VK_TRUE,20000000000ULL));
        void* mapped=nullptr;vkCheck(MapMemory(device,readbackMemory,0,bytes,0,&mapped));
        std::vector<uint8_t> result(bytes);memcpy(result.data(),mapped,bytes);UnmapMemory(device,readbackMemory);
        return result;
    }
    std::vector<uint8_t> descriptor()const{
        if(!exporting)throw std::runtime_error("Not a GPU export source");
        std::vector<uint8_t> result(72);memcpy(result.data(),deviceUuid.data(),16);
        auto wide=[&](size_t at,uint64_t value){for(unsigned i=0;i<8;i++)result[at+i]=static_cast<uint8_t>(value>>(8*i));};
        auto word=[&](size_t at,uint32_t value){for(unsigned i=0;i<4;i++)result[at+i]=static_cast<uint8_t>(value>>(8*i));};
        for(size_t i=0;i<exports.size();i++)wide(16+8*i,reinterpret_cast<uintptr_t>(exports[i]));
        wide(40,allocationSize);word(48,width);word(52,height);word(56,stride);word(60,sharedMemoryType);word(64,sharedUsage);
        return result;
    }
    uint64_t publish(CUdeviceptr source,unsigned pitch){
        if(!exporting||!source||pitch<width||generation==UINT64_MAX)throw std::runtime_error("Invalid GPU frame publication");
        // A bounded CPU timeline query precedes any GPU wait. A dead consumer
        // cannot strand a CUDA stream behind an unsignalled semaphore.
        if(generation){
            VkSemaphoreWaitInfo wait{VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO};wait.semaphoreCount=1;wait.pSemaphores=&released;wait.pValues=&generation;
            vkCheck(WaitSemaphores(device,&wait,20000000000ULL));
            CUDA_EXTERNAL_SEMAPHORE_WAIT_PARAMS acquire{};acquire.params.fence.value=generation;
            cuCheck(cuWaitExternalSemaphoresAsync(&cudaReleased,&acquire,1,stream));
        }
        CUDA_MEMCPY2D copy{};copy.srcMemoryType=copy.dstMemoryType=CU_MEMORYTYPE_DEVICE;
        copy.srcDevice=source;copy.srcPitch=pitch;copy.dstDevice=destination;copy.dstPitch=stride;
        copy.WidthInBytes=width;copy.Height=height*3/2;cuCheck(cuMemcpy2DAsync_v2(&copy,stream));
        CUDA_EXTERNAL_SEMAPHORE_SIGNAL_PARAMS signal{};signal.params.fence.value=++generation;
        cuCheck(cuSignalExternalSemaphoresAsync(&cudaReady,&signal,1,stream));
        // NVDEC may unmap/reuse its input only after its device copy finishes.
        cuCheck(cuStreamSynchronize(stream));return generation;
    }
};

GpuFrameInterop::GpuFrameInterop(CUdevice device,unsigned width,unsigned height,bool exportFrames):state(std::make_unique<State>(width,height,exportFrames)){
    if(width<16||height<16||width>3840||height>2160||width%2||height%2)throw std::runtime_error("Bounded even NV12 dimensions required");
    state->initialize(device);
}
GpuFrameInterop::~GpuFrameInterop()=default;
std::vector<uint8_t> GpuFrameInterop::validate(CUdeviceptr source,unsigned pitch){return state->validate(source,pitch);}
CUstream GpuFrameInterop::outputStream() const{return state->stream;}
std::vector<uint8_t> GpuFrameInterop::exportDescriptor()const{return state->descriptor();}
uint64_t GpuFrameInterop::publish(CUdeviceptr source,unsigned pitch){return state->publish(source,pitch);}
