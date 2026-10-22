#!/bin/bash
# Opt-in, one-process compatibility. Do not export this into login sessions.
set -eu
[ "$(uname -s)" = Darwin ] || exit 69
[ "$#" -ge 1 ] || { echo 'usage: Run-With-DeferredBindings.sh executable [arguments...]' >&2; exit 64; }
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
library="$here/deferred-stage-bindings.dylib"
[ -r "$library" ] || { echo 'Build and place deferred-stage-bindings.dylib next to this script.' >&2; exit 66; }
[ -z "${DYLD_INSERT_LIBRARIES:-}" ] || { echo 'Refusing to replace an existing DYLD_INSERT_LIBRARIES setting.' >&2; exit 64; }
exec /usr/bin/env NATIVEMAC_METAL_TARGET_PID="$$" DYLD_INSERT_LIBRARIES="$library" "$@"
