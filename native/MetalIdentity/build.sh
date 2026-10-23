#!/bin/bash
set -euo pipefail
if [[ $# != 1 ]]; then echo 'usage: build.sh output-directory' >&2; exit 64; fi
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$1"
output=$(cd "$1" && pwd)
bundle="$output/NativeMacMetal.bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
xcrun clang -arch x86_64 -fno-objc-arc -Wall -Wextra -Werror -bundle \
    -undefined dynamic_lookup "$source_dir/Driver.m" -framework Foundation \
    -framework IOKit -framework Metal -Wl,"$source_dir/IOGPU.tbd" \
    -o "$bundle/Contents/MacOS/NativeMacMetal"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
