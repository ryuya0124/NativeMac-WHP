#!/bin/bash
set -euo pipefail
if [ "$#" -lt 1 ]; then echo 'Usage: run_with_video.sh /absolute/path/to/executable [arguments...]' >&2; exit 64; fi
helper='/Library/Application Support/NativeMac/VideoBridge/NativeMacVideoEntry.dylib'
if [ ! -f "$helper" ] || [ -L "$helper" ] || [ "$(stat -f '%u' "$helper")" != 0 ]; then
  echo 'Root-owned video entry helper is not installed.' >&2; exit 77
fi
codesign --verify --strict "$helper"
if [ -n "${DYLD_INSERT_LIBRARIES:-}" ] && [ "$DYLD_INSERT_LIBRARIES" != "$helper" ]; then echo 'An existing dyld insertion must be resolved before using this launcher.' >&2; exit 64; fi
export NATIVEMAC_VIDEO_ENCODERS=1
export DYLD_INSERT_LIBRARIES="$helper"
exec "$@"
