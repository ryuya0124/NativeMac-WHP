#!/bin/bash
# Install only the authored relay in the qualified Intel development guest.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exit 77
[ "$(uname -m)" = x86_64 ] && [[ "$(uname -r)" = 25.6.* ]] || exit 69
[[ "$(sysctl -n kern.bootargs)" = *amfi=0x80* ]] || exit 77
codesign --verify --strict NativeMacAudioRelay.app
support='/Library/Application Support/NativeMac/AudioBridge'
mkdir -p "$support"
uid=$(stat -f %u /dev/console)
label=io.nativemac.audio.relay
if [ "$uid" -ge 501 ] && launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
  launchctl bootout "gui/$uid/$label"
fi
ditto NativeMacAudioRelay.app "$support/NativeMacAudioRelay.app"
chown -R root:wheel "$support/NativeMacAudioRelay.app"
chmod -R go-w "$support/NativeMacAudioRelay.app"
python3 - <<'PY'
import plistlib
from pathlib import Path
value={'Label':'io.nativemac.audio.relay',
       'ProgramArguments':['/Library/Application Support/NativeMac/AudioBridge/NativeMacAudioRelay.app/Contents/MacOS/NativeMacAudioRelay'],
       'RunAtLoad':True, 'ProcessType':'Interactive'}
target=Path('/Library/LaunchAgents/io.nativemac.audio.relay.plist')
target.write_bytes(plistlib.dumps(value));target.chmod(0o644)
PY
chown root:wheel /Library/LaunchAgents/io.nativemac.audio.relay.plist
if [ "$uid" -ge 501 ] && launchctl print "gui/$uid" >/dev/null 2>&1; then
  launchctl bootstrap "gui/$uid" /Library/LaunchAgents/io.nativemac.audio.relay.plist
fi
echo 'Installed the virtual-output relay for GUI logins. No physical input is selected.'
