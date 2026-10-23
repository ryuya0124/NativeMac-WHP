#!/bin/bash
# Source/configuration deployment is maintenance. Live media never uses SSH.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exit 77
[ "$(uname -m)" = x86_64 ] && [[ "$(uname -r)" = 25.6.* ]] || exit 69
[ -f guest.json ] && [ -f host-certificate.pem ] || exit 66
support='/Library/Application Support/NativeMac/MediaTransport'
label=io.nativemac.media.transport
mkdir -p "$support"
install -o root -g wheel -m 755 transport.py "$support/transport.py"
install -o root -g wheel -m 600 guest.json "$support/guest.json"
install -o root -g wheel -m 644 host-certificate.pem "$support/host-certificate.pem"
python3 - <<'PY'
import plistlib
from pathlib import Path
value={'Label':'io.nativemac.media.transport','ProgramArguments':['/usr/bin/python3','/Library/Application Support/NativeMac/MediaTransport/transport.py','guest','--config','/Library/Application Support/NativeMac/MediaTransport/guest.json'],
       'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,
       'StandardOutPath':'/var/log/nativemac-media-transport.log','StandardErrorPath':'/var/log/nativemac-media-transport-error.log'}
path=Path('/Library/LaunchDaemons/io.nativemac.media.transport.plist')
path.write_bytes(plistlib.dumps(value));path.chmod(0o644)
PY
chown root:wheel "/Library/LaunchDaemons/$label.plist"
if launchctl print "system/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "system/$label"
else
  launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
fi
echo 'Installed pinned TLS media transport. No SSH media route or fallback.'
