#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror ABIProbe.mm \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -o ABIProbe
./ABIProbe
clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pthread \
  VTDecoder.mm VTStreamProbe.mm -framework Foundation -framework VideoToolbox \
  -framework CoreMedia -framework CoreVideo -o VTStreamProbe
codesign --force --sign - VTStreamProbe
# Deliberately do not install a codec bundle: automatic registry selection rejects
# the ad-hoc signature, and low-delay, reset and early invalidation remain unqualified.
