"""Choose the CUDA device matching the selected Windows renderer, not adapter order."""
import ctypes as c


def selected_device(renderer_name=None):
    cuda=c.WinDLL('nvcuda.dll',winmode=0x800)  # System32 only.
    cuda.cuInit.argtypes=[c.c_uint];cuda.cuInit.restype=c.c_int
    cuda.cuDeviceGetCount.argtypes=[c.POINTER(c.c_int)];cuda.cuDeviceGetCount.restype=c.c_int
    cuda.cuDeviceGet.argtypes=[c.POINTER(c.c_int),c.c_int];cuda.cuDeviceGet.restype=c.c_int
    cuda.cuDeviceGetName.argtypes=[c.c_char_p,c.c_int,c.c_int];cuda.cuDeviceGetName.restype=c.c_int
    def check(status):
        if status:raise RuntimeError('CUDA identity query failed: '+str(status))
    check(cuda.cuInit(0));count=c.c_int();check(cuda.cuDeviceGetCount(c.byref(count)))
    if not 1<=count.value<=64:raise RuntimeError('No bounded CUDA device set')
    candidates=[]
    for index in range(count.value):
        device=c.c_int();check(cuda.cuDeviceGet(c.byref(device),index));name=c.create_string_buffer(256)
        check(cuda.cuDeviceGetName(name,len(name),device.value));text=name.value.decode('utf-8')
        if renderer_name is None or renderer_name==text:candidates.append((index,text))
    if len(candidates)!=1:raise RuntimeError('The renderer does not uniquely match a CUDA device; supply its actual Windows renderer name')
    return candidates[0]
