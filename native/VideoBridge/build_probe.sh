#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror ABIProbe.mm \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -o ABIProbe
./ABIProbe
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pthread \
  VTDecoder.mm VTStreamProbe.mm VideoTransport.cpp -framework Foundation -framework VideoToolbox \
  -framework CoreMedia -framework CoreVideo -o VTStreamProbe
codesign --force --sign - VTStreamProbe
# This decoder-only probe does not install a component. For the opt-in
# VideoToolbox/AVFoundation codec bundle and launcher, use build_video_bridge.sh.
