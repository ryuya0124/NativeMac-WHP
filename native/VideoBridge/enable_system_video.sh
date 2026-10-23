#!/bin/bash
# Explicit VM-wide opt-in; never run on a physical Mac.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo 'Requires sudo in the Intel development VM.' >&2; exit 77; }
[ "$(uname -m)" = x86_64 ] && [[ "$(uname -r)" = 25.6.* ]] || { echo 'Unqualified encoder ABI on this OS.' >&2; exit 69; }
[[ "$(sysctl -n kern.bootargs)" = *amfi=0x80* ]] || { echo 'The VM development-signing boot profile is required.' >&2; exit 77; }
support='/Library/Application Support/NativeMac/VideoBridge'
broker_changed=1
if cmp -s NativeMacVideoBroker "$support/NativeMacVideoBroker"; then broker_changed=0; fi
bash install_video_bridge.sh
codesign --verify --strict NativeMacVideoBroker
codesign --verify --strict NativeMacRefreshCachedVideo
install -o root -g wheel -m 755 NativeMacVideoBroker "$support/NativeMacVideoBroker"
install -o root -g wheel -m 755 NativeMacRefreshCachedVideo "$support/NativeMacRefreshCachedVideo"
install -o root -g wheel -m 755 video_environment.sh "$support/video_environment.sh"
python3 configure_system_video.py
printf 1 > "$support/enabled"
chown root:wheel "$support/enabled"; chmod 644 "$support/enabled"
# Booting out a Mach service destroys the capabilities held by sandboxed
# clients. Leave an identical broker running; use launchd's existing service
# instance for upgrades so that the registered Mach endpoint stays owned.
if ! launchctl print system/io.nativemac.video.broker >/dev/null 2>&1; then
  launchctl bootstrap system /Library/LaunchDaemons/io.nativemac.video.broker.plist
elif [ "$broker_changed" = 1 ]; then
  launchctl kickstart -k system/io.nativemac.video.broker
fi
label=io.nativemac.video.environment
if launchctl print "system/$label" >/dev/null 2>&1; then launchctl bootout "system/$label"; fi
launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
uid=$(stat -f %u /dev/console)
if [ "$uid" -ge 501 ] && launchctl print "user/$uid" >/dev/null 2>&1; then
  if launchctl print "user/$uid/io.nativemac.video.background-environment" >/dev/null 2>&1; then launchctl bootout "user/$uid/io.nativemac.video.background-environment"; fi
  launchctl bootstrap "user/$uid" /Library/LaunchAgents/io.nativemac.video.background-environment.plist
fi
if [ "$uid" -ge 501 ] && launchctl print "gui/$uid" >/dev/null 2>&1; then
  if launchctl print "gui/$uid/io.nativemac.video.environment" >/dev/null 2>&1; then launchctl bootout "gui/$uid/io.nativemac.video.environment"; fi
  launchctl bootstrap "gui/$uid" /Library/LaunchAgents/io.nativemac.video.environment.plist
fi
echo 'Enabled the fixed Mach broker and standard-app video entry for future launches and logins.'
echo 'Restart already-running consumers. Windows Run-VideoBridge.py must be running.'
