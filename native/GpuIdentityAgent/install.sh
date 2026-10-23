#!/bin/bash
set -euo pipefail
if [[ $EUID != 0 || $# != 1 ]]; then
    echo 'usage: sudo bash install.sh BUILD_DIRECTORY' >&2
    exit 64
fi
source_dir=$(cd "$1" && pwd)
codesign --verify --strict "$source_dir/gpu-identity-agent"
plutil -lint "$source_dir/io.nativemac.gpu-identity.plist"
mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$source_dir/gpu-identity-agent" /Library/PrivilegedHelperTools/io.nativemac.gpu-identity
install -o root -g wheel -m 644 "$source_dir/io.nativemac.gpu-identity.plist" /Library/LaunchDaemons/io.nativemac.gpu-identity.plist
launchctl bootout system/io.nativemac.gpu-identity >/dev/null 2>&1 || true
launchctl bootstrap system /Library/LaunchDaemons/io.nativemac.gpu-identity.plist
