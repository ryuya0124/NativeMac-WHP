"""Check that the independent virtual GPU library creates its Vulkan backend.

This is a host library probe, never evidence of guest GPU acceleration.
"""
import argparse
import ctypes as c
import json
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument('library')
parser.add_argument('--report', default='artifacts/vgpu-library-probe.json')
args = parser.parse_args()


class Config(c.Structure):
    _fields_ = [('struct_size', c.c_uint32), ('display_port_count', c.c_uint32),
                ('metal_registry_id', c.c_uint64), ('feature_level', c.c_uint64),
                ('display_port_connection_types', c.c_uint32),
                ('use_iosurface_mapper', c.c_bool), ('process_isolation', c.c_bool),
                ('disable_argument_buffers', c.c_bool), ('memory_map', c.c_void_p),
                ('callbacks', c.c_void_p), ('memory_files', c.c_void_p),
                ('memory_sections', c.c_void_p)]


lines = []
LogFn = c.CFUNCTYPE(None, c.c_void_p, c.c_uint32, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t)


@LogFn
def logger(_ctx, level, target, target_length, message, message_length):
    lines.append({'level': level, 'target': c.string_at(target, target_length).decode(errors='replace'),
                  'message': c.string_at(message, message_length).decode(errors='replace')})


library = c.CDLL(str(pathlib.Path(args.library).resolve()))
library.rvg_log_set_handler.argtypes = [LogFn, c.c_void_p, c.c_uint32]
library.rvg_log_set_handler(logger, None, 4)
library.rvg_device_create.argtypes = [c.POINTER(Config), c.POINTER(c.c_void_p)]
library.rvg_device_create.restype = c.c_uint32
library.rvg_device_release.argtypes = [c.c_void_p]
library.rvg_status_message.argtypes = [c.c_uint32]
library.rvg_status_message.restype = c.c_char_p
config = Config(struct_size=c.sizeof(Config), display_port_count=1, feature_level=4)
device = c.c_void_p()
status = library.rvg_device_create(c.byref(config), c.byref(device))
if device:
    library.rvg_device_release(device)
report = {'hostVulkanDeviceCreated': status == 0, 'status': status,
          'message': library.rvg_status_message(status).decode(),
          'macOsBooted': False, 'guestGpuAccelerated': False, 'logs': lines}
pathlib.Path(args.report).write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
raise SystemExit(0 if status == 0 else 1)
