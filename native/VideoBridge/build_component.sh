#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bundle=NativeMacNVDECProbe.bundle
mkdir -p "$bundle/Contents/MacOS"
python3 - <<'PY'
from pathlib import Path
import plistlib
info=plistlib.loads(Path('ProbeCodec-Info.plist').read_bytes())
for operation in ['decoder','encoder']:
    for codec in (['avc1','hvc1','vp09'] if operation=='decoder' else ['avc1','hvc1']):
        matching={'VTCodecType':codec,'VTRating':1000,'VTIsHardwareAccelerated':True,'VTIsParavirtualizationAware':True,'VTAllowSandboxedDecode':True,'VTAllowSandboxedEncode':True}
        entry={'CMClassID':'com.apple.videotoolbox.video'+operation,
          'CMClassImplementationID':'io.nativemac.video'+operation+'.'+codec+'.trial',
          'CMClassImplementationName':'NativeMac '+('NVDEC' if operation=='decoder' else 'NVENC')+' '+codec+' Trial',
          'CMClassImplementationVersion':1,'CMExecutableArchitectures':['x86_64'],
          'CMFactoryFunction':'NativeMacNVDECCreate' if operation=='decoder' else 'NativeMacNVENCCreate','CMMatchingInfo':matching,'CMManufacturer':'NativeMac'}
        if operation=='encoder':
            entry['VTCodecName']='H.264' if codec=='avc1' else 'HEVC'
            entry['VTEncoderName']='NativeMac NVENC '+entry['VTCodecName']
        info['CMClassImplementations'].append(entry)
Path('NativeMacNVDECProbe.bundle/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
clang++ -arch x86_64 -O2 -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pthread -bundle VTDecoder.mm VTEncoder.mm VideoTransport.cpp \
    -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal -framework IOSurface -lcompression \
    -o "$bundle/Contents/MacOS/NativeMacNVDECProbe"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
# Installation and signing-policy changes are separate, explicit development steps.
