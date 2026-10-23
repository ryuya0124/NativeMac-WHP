#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 77
if launchctl print system/io.nativemac.media.transport >/dev/null 2>&1; then
  launchctl bootout system/io.nativemac.media.transport
fi
rm -f /Library/LaunchDaemons/io.nativemac.media.transport.plist
echo 'Disabled the direct media transport; no SSH fallback is started.'
