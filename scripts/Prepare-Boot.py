"""Prepare a read-only file manifest for OpenCore and Apple's original recovery DMG."""
import argparse
import copy
import json
import pathlib
import plistlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--processors', type=int, default=8, choices=range(1, 9))
parser.add_argument('--gpu', action='store_true')
args = parser.parse_args()
firmware = ROOT / 'backend/firmware'
oc = firmware / 'opencore-1.0.8-debug'
hv = firmware / 'hyperv-0.4.0'
out = ROOT / 'backend/boot'
out.mkdir(parents=True, exist_ok=True)


def merge(schema, values):
    if isinstance(schema, dict):
        return {key: merge(value, values.get(key, value)) for key, value in schema.items() if not key.startswith('#')}
    return copy.deepcopy(values)


config = merge(plistlib.loads((oc / 'Docs/Sample.plist').read_bytes()),
               plistlib.loads((hv / 'EFI/OC/config.plist').read_bytes()))
patches = plistlib.loads((ROOT / 'backend/amd-vanilla/patches.plist').read_bytes())['Kernel']['Patch']
for patch in patches:
    # These patches target physical AM5 PCIe hardware. Our PCIe devices do
    # not advertise the problematic 10-bit-tag feature. The pre-Tahoe byte
    # pattern also matches a different branch in Tahoe's probeBusGated.
    if patch['Identifier'] == 'com.apple.iokit.IOPCIFamily':
        patch['Enabled'] = False
    if 'Force cpuid_cores_per_package' in patch['Comment']:
        replacement = bytearray(patch['Replace'])
        replacement[1] = args.processors
        patch['Replace'] = bytes(replacement)
config['Kernel']['Patch'].extend(patches)
config['Kernel']['Patch'].extend(plistlib.loads((firmware / 'hyperv-msr-patch/patch.plist').read_bytes())['Kernel']['Patch'])
config['Kernel']['Emulate']['DummyPowerManagement'] = True
config['Kernel']['Quirks']['ProvideCurrentCpuInfo'] = True
for table in config['ACPI']['Add']:
    if table['Path'] == 'SSDT-HV-VMBUS.aml':
        table['Path'] = 'SSDT-NM-VMBUS.aml'
config['Misc']['Boot']['HideAuxiliary'] = False
config['Misc']['Boot']['Timeout'] = 15
config['UEFI']['Output']['Resolution'] = '1280x800'
config['Misc']['Debug']['Target'] = 11  # logging, console, serial
config['Misc']['Serial']['Init'] = True
for driver in config['UEFI']['Drivers']:
    driver.setdefault('HideVerbose', False)
if args.gpu:
    config['UEFI']['Drivers'].append({'Arguments':'','Comment':'NativeMac PCI GPU GOP',
        'Enabled':True,'LoadEarly':False,'HideVerbose':False,'Path':'ReimsVgpu.efi'})
config['NVRAM']['Add']['7C436110-AB2A-4BBB-A880-FE41995C9F82']['boot-args'] = '-v debug=0x10a keepsyms=1 serial=9 -lilubetaall'
if args.gpu:
    config['NVRAM']['Add']['7C436110-AB2A-4BBB-A880-FE41995C9F82']['boot-args'] += ' npci=0x2000 -hvpcinative -hvctrldbg -hvvmbusdbg -hvkbddbg -hvmousedbg'
# These identities belong only to this isolated VM, with no Apple account use.
config['PlatformInfo']['Generic']['SystemUUID'] = 'D488B4F3-9A52-4C77-A188-461088798C2E'
(out / 'config.plist').write_bytes(plistlib.dumps(config))

files = {}
for source in (hv / 'EFI').rglob('*'):
    if source.is_file():
        files[source.relative_to(hv).as_posix()] = source
for target, source in {
    'EFI/BOOT/BOOTX64.EFI': oc / 'X64/EFI/BOOT/BOOTX64.EFI',
    'EFI/OC/OpenCore.efi': oc / 'X64/EFI/OC/OpenCore.efi',
    'EFI/OC/Drivers/OpenRuntime.efi': oc / 'X64/EFI/OC/Drivers/OpenRuntime.efi',
    'EFI/OC/Drivers/OpenPartitionDxe.efi': oc / 'X64/EFI/OC/Drivers/OpenPartitionDxe.efi',
    'EFI/OC/Drivers/ResetNvramEntry.efi': oc / 'X64/EFI/OC/Drivers/ResetNvramEntry.efi',
    'EFI/OC/Tools/OpenShell.efi': oc / 'X64/EFI/OC/Tools/OpenShell.efi',
    'EFI/OC/config.plist': out / 'config.plist',
    'com.apple.recovery.boot/BaseSystem.dmg': ROOT / 'backend/media/BaseSystem.dmg',
    'com.apple.recovery.boot/BaseSystem.chunklist': ROOT / 'backend/media/BaseSystem.chunklist',
}.items():
    for existing in list(files):
        if existing.casefold() == target.casefold():
            del files[existing]
    files[target] = source
for source in files.values():
    if not source.is_file():
        raise FileNotFoundError(source)
if args.gpu:
    files['EFI/OC/Drivers/ReimsVgpu.efi'] = ROOT / 'artifacts/vgpu-firmware/ReimsVgpu.efi'
    # Its Gen1 PCI personality wins over Apple's ECAM driver but reads byte
    # offsets from CFC without selecting the byte lane. It is unnecessary for
    # OpenVMM's PCIe roots; keep synthetic CPU/VMBus/storage support instead.
    built_kext = ROOT / 'artifacts/machyperv/MacHyperVSupportMonterey.kext'
    if not (built_kext / 'Contents/MacOS/MacHyperVSupportMonterey').is_file():
        raise FileNotFoundError('Build the NativeMac MacHyperVSupport patch before GPU boot')
    for source in built_kext.rglob('*'):
        if source.is_file():
            files['EFI/OC/Kexts/MacHyperVSupportMonterey.kext/' + source.relative_to(built_kext).as_posix()] = source
    name = 'EFI/OC/Kexts/MacHyperVSupportMonterey.kext/Contents/Info.plist'
    info = plistlib.loads(files[name].read_bytes())
    info['IOKitPersonalities'].pop('HyperVPCIRootGen1', None)
    info['IOKitPersonalities'].pop('HyperVPCIRootGen2', None)
    modified_info = out / 'MacHyperVSupportMonterey-Info.plist'
    modified_info.write_bytes(plistlib.dumps(info))
    files[name] = modified_info
files['EFI/OC/ACPI/SSDT-NM-VMBUS.aml'] = ROOT / 'artifacts/SSDT-NM-VMBUS.aml'
for source in files.values():
    if not source.is_file():
        raise FileNotFoundError(source)
manifest = {'files': [{'path': path, 'source': str(source)} for path, source in sorted(files.items())]}
(out / 'recovery.nmfat').write_bytes(b'NMFAT01\n' + json.dumps(manifest).encode())
(out / 'metadata.json').write_text(json.dumps({'processors': args.processors, 'macOsBooted': False, 'guestGpuAccelerated': False}, indent=2))
print(f'Prepared {len(files)} original files for {args.processors} virtual cores. No DMG conversion.')
