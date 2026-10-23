#!/bin/bash
set -euo pipefail
[ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --development-vm ]; } || { echo 'Usage: build.sh [--development-vm]' >&2; exit 64; }
cd "$(dirname "$0")"
app=NativeMacAudioRelay.app
mkdir -p "$app/Contents/MacOS"
python3 - <<'PY'
import plistlib
from pathlib import Path
info={'CFBundleIdentifier':'io.nativemac.AudioRelay','CFBundleExecutable':'NativeMacAudioRelay','CFBundleName':'NativeMac Audio Relay','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSUIElement':True,'NSMicrophoneUsageDescription':'Send only the virtual BlackHole VM output to Windows playback. No physical microphone is selected.'}
Path('NativeMacAudioRelay.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun clang++ -arch x86_64 -O2 -std=c++17 -fobjc-arc -Wall -Wextra -Werror AudioRelay.mm -framework AppKit -framework Foundation -framework AVFoundation -framework CoreAudio -o "$app/Contents/MacOS/NativeMacAudioRelay"
entitlements=AudioRelay.entitlements
if [ "${1:-}" = --development-vm ]; then
  [ "$(uname -m)" = x86_64 ] && [[ "$(uname -r)" = 25.6.* ]] && [[ "$(sysctl -n kern.bootargs)" = *amfi=0x80* ]] || exit 77
  # The AMFI development boot labels ad-hoc executables platform binaries,
  # for which TCC refuses to display prompts. Scope this guest-only entitlement
  # to the virtual-output relay, which selects no physical input device.
  entitlements=AudioRelay-development.entitlements
  python3 - <<'PY'
import plistlib
from pathlib import Path
value=plistlib.loads(Path('AudioRelay.entitlements').read_bytes())
value['com.apple.private.tcc.allow']=['kTCCServiceMicrophone']
Path('AudioRelay-development.entitlements').write_bytes(plistlib.dumps(value))
PY
fi
codesign --force --sign - --entitlements "$entitlements" "$app"
