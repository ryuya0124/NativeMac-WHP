#!/bin/bash
# Runs once in each launchd domain, including every GUI login.
set -euo pipefail
mode=${1:?enable or disable}
[ "$mode" = enable ] || [ "$mode" = disable ] || exit 64
helper='/Library/Application Support/NativeMac/VideoBridge/NativeMacVideoEntry.dylib'
for prefix in '' __XPC_ __XPC___XPC_ __XPC___XPC___XPC_; do
  for pair in "DYLD_INSERT_LIBRARIES=$helper" NATIVEMAC_VIDEO_ENCODERS=1; do
    name="$prefix${pair%%=*}"; value=${pair#*=}
    current=$(/bin/launchctl getenv "$name" || true)
    if [ "$mode" = enable ]; then
      [ -z "$current" ] || [ "$current" = "$value" ] || { echo "Conflicting launch environment: $name" >&2; exit 73; }
      /bin/launchctl setenv "$name" "$value"
    elif [ "$current" = "$value" ]; then
      /bin/launchctl unsetenv "$name"
    fi
  done
done
if [ "$mode" = enable ] && [ "${2:-}" = refresh-cached-video ] && [ "$(id -u)" -ge 501 ]; then
  umask 077
  logs="$HOME/Library/Logs/NativeMacVideoBridge"
  mkdir -p "$logs"
  [ ! -L "$logs/session-setup.json" ] && [ ! -L "$logs/session-setup-error.log" ] || exit 73
  exec '/Library/Application Support/NativeMac/VideoBridge/NativeMacRefreshCachedVideo' > "$logs/session-setup.json" 2> "$logs/session-setup-error.log"
fi
