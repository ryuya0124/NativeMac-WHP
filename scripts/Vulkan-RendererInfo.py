"""Read facts of a uniquely named physical Vulkan renderer, never adapter order."""
import ctypes as c
import struct


def renderer_info(name):
    # Vulkan's ABI: the first five VkPhysicalDeviceProperties words precede
    # deviceName[256]. Reserve more than the complete properties struct.
    class Application(c.Structure):
        _fields_ = [('type', c.c_uint32), ('next', c.c_void_p),
                    ('name', c.c_char_p), ('version', c.c_uint32),
                    ('engine', c.c_char_p), ('engineVersion', c.c_uint32),
                    ('api', c.c_uint32)]

    class InstanceInfo(c.Structure):
        _fields_ = [('type', c.c_uint32), ('next', c.c_void_p),
                    ('flags', c.c_uint32), ('app', c.POINTER(Application)),
                    ('layers', c.c_uint32), ('layerNames', c.c_void_p),
                    ('extensions', c.c_uint32), ('extensionNames', c.c_void_p)]

    vk = c.WinDLL('vulkan-1.dll')
    vk.vkCreateInstance.argtypes = [c.POINTER(InstanceInfo), c.c_void_p, c.POINTER(c.c_void_p)]
    vk.vkCreateInstance.restype = c.c_int32
    vk.vkEnumeratePhysicalDevices.argtypes = [c.c_void_p, c.POINTER(c.c_uint32), c.POINTER(c.c_void_p)]
    vk.vkEnumeratePhysicalDevices.restype = c.c_int32
    vk.vkGetPhysicalDeviceProperties.argtypes = [c.c_void_p, c.c_void_p]
    vk.vkGetPhysicalDeviceProperties.restype = None
    vk.vkDestroyInstance.argtypes = [c.c_void_p, c.c_void_p]
    vk.vkDestroyInstance.restype = None
    app = Application(type=0, api=1 << 22)
    instance = c.c_void_p()
    info = InstanceInfo(type=1, app=c.pointer(app))
    if vk.vkCreateInstance(c.byref(info), None, c.byref(instance)):
        raise RuntimeError('Vulkan fact probe could not create an instance')
    try:
        count = c.c_uint32()
        if vk.vkEnumeratePhysicalDevices(instance, c.byref(count), None) or not 0 < count.value <= 64:
            raise RuntimeError('Vulkan physical-device enumeration failed')
        devices = (c.c_void_p * count.value)()
        if vk.vkEnumeratePhysicalDevices(instance, c.byref(count), devices):
            raise RuntimeError('Vulkan physical-device enumeration changed')
        matches = []
        for device in devices[:count.value]:
            properties = c.create_string_buffer(8192)
            vk.vkGetPhysicalDeviceProperties(device, properties)
            raw = properties.raw
            device_name = raw[20:276].split(b'\0', 1)[0].decode('utf-8')
            if device_name == name:
                _, _, vendor, product, kind = struct.unpack_from('<5I', raw)
                matches.append({'hostGPUName': device_name, 'vulkanDeviceType': kind,
                                'hostHasUnifiedMemory': {1: True, 2: False, 4: True}.get(kind),
                                'vendorID': vendor, 'deviceID': product})
        if len(matches) != 1:
            raise RuntimeError('Selected renderer name does not uniquely identify a physical Vulkan device')
        return matches[0]
    finally:
        vk.vkDestroyInstance(instance, None)
