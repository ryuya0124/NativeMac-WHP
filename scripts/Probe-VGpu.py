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
parser.add_argument('--identity-only', action='store_true',
                    help='Return the actual selected renderer name from the pinned backend startup callback')
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
prefix = 'device starting on Metal device '
names = {line['message'][len(prefix):] for line in lines
         if line['target'] == 'reims_vgpu_core::device' and line['message'].startswith(prefix)}
name = next(iter(names)) if len(names) == 1 else None
identity_valid = bool(name and name != '(unnamed)' and 1 <= len(name) <= 63 and
                      all(32 <= ord(char) <= 126 for char in name))
report = {'hostVulkanDeviceCreated': status == 0, 'status': status,
          'message': library.rvg_status_message(status).decode(),
          'hostGPUName': name if identity_valid else None,
          'identitySource': 'selected GPU of the configured Reims DLL, Windows Vulkan backend startup callback',
          'macOsBooted': False, 'guestGpuAccelerated': False, 'logs': lines}
pathlib.Path(args.report).write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps({key: report[key] for key in ('hostVulkanDeviceCreated','status','hostGPUName','identitySource')}
                 if args.identity_only else report, indent=2))
raise SystemExit(0 if status == 0 and (not args.identity_only or identity_valid) else 1)
