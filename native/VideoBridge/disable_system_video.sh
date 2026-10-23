#!/bin/bash
# Removes only this opt-in and jobs; reboot clears GUI-parent inheritance.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exit 77
support='/Library/Application Support/NativeMac/VideoBridge'
[ ! -L "$support" ] && [ "$(stat -f %u "$support")" = 0 ] || exit 73
python3 configure_system_video.py --check
rm -f "$support/enabled"
uid=$(stat -f %u /dev/console)
if [ "$uid" -ge 501 ]; then
  for kind in user gui; do
    launchctl print "$kind/$uid" >/dev/null 2>&1 || continue
    if [ "$kind" = user ]; then label=io.nativemac.video.background-environment; else label=io.nativemac.video.environment; fi
    if launchctl print "$kind/$uid/$label" >/dev/null 2>&1; then launchctl bootout "$kind/$uid/$label"; fi
    # Clear matching values inside that exact bootstrap domain, not the SSH
    # process's possibly different user/background environment.
    cleanup="io.nativemac.video.disable-$kind"
    temporary="$support/$cleanup.plist"
    python3 - "$temporary" "$cleanup" "$kind" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]);assert not p.exists()
d={'Label':sys.argv[2],'ProgramArguments':['/bin/bash','/Library/Application Support/NativeMac/VideoBridge/video_environment.sh','disable'],'RunAtLoad':True}
if sys.argv[3]=='user':d['LimitLoadToSessionType']='Background'
p.write_bytes(plistlib.dumps(d));p.chmod(0o644)
PY
    launchctl bootstrap "$kind/$uid" "$temporary"
    sleep 1
    launchctl bootout "$kind/$uid/$cleanup"
    rm -f "$temporary"
  done
fi
# SSH/sudo retains a user bootstrap port. Clear the system domain from its own
# one-shot job as well, rather than assuming that uid 0 implies system launchd.
temporary="$support/io.nativemac.video.disable-system.plist"
python3 - "$temporary" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]);assert not p.exists()
d={'Label':'io.nativemac.video.disable-system','ProgramArguments':['/bin/bash','/Library/Application Support/NativeMac/VideoBridge/video_environment.sh','disable'],'RunAtLoad':True}
p.write_bytes(plistlib.dumps(d));p.chmod(0o644)
PY
launchctl bootstrap system "$temporary"
sleep 1
launchctl bootout system/io.nativemac.video.disable-system
rm -f "$temporary"
for label in io.nativemac.video.broker io.nativemac.video.environment; do
  if launchctl print "system/$label" >/dev/null 2>&1; then launchctl bootout "system/$label"; fi
  rm -f "/Library/LaunchDaemons/$label.plist"
done
rm -f /Library/LaunchAgents/io.nativemac.video.environment.plist
rm -f /Library/LaunchAgents/io.nativemac.video.background-environment.plist
echo 'Disabled standard-app injection. Reboot the guest to clear inherited GUI-parent environments.'
