#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || exit 77
uid=$(stat -f %u /dev/console)
if [ "$uid" -ge 501 ] && launchctl print "gui/$uid/io.nativemac.audio.relay" >/dev/null 2>&1; then
  launchctl bootout "gui/$uid/io.nativemac.audio.relay"
fi
rm -f /Library/LaunchAgents/io.nativemac.audio.relay.plist
echo 'Disabled future relay launches. The third-party virtual audio device is retained.'
