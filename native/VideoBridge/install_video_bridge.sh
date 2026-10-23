#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(id -u)" != 0 ]; then echo 'Run this installer with sudo in the Intel development VM.' >&2; exit 77; fi
source_bundle="$PWD/NativeMacNVDECProbe.bundle"
destination=/Library/Video/Plug-Ins/NativeMacNVDECProbe.bundle
support='/Library/Application Support/NativeMac/VideoBridge'
codesign --verify --strict "$source_bundle"
codesign --verify --strict NativeMacVideoEntry.dylib
if [ -e "$destination" ]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")
  [ "$identifier" = io.nativemac.NVDECProbe ] || { echo 'Refusing to replace an unrelated component.' >&2; exit 73; }
fi
mkdir -p /Library/Video/Plug-Ins "$support"
ditto "$source_bundle" "$destination"
install -m 755 NativeMacVideoEntry.dylib "$support/NativeMacVideoEntry.dylib"
install -m 755 run_with_video.sh "$support/run_with_video.sh"
chown -R root:wheel "$destination"
chmod -R go-w "$destination"
chown root:wheel "$support" "$support/NativeMacVideoEntry.dylib" "$support/run_with_video.sh"
chmod 755 "$support"
codesign --verify --strict "$destination"
codesign --verify --strict "$support/NativeMacVideoEntry.dylib"
echo 'Installed the authored component and explicit process launcher; no global injection was enabled.'
