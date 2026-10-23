#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
clang++ -arch x86_64 -std=c++17 -Wall -Wextra -Werror -pthread GuestBroker.cpp -o NativeMacVideoBroker
codesign --force --sign - NativeMacVideoBroker
clang++ -arch x86_64 -std=c++17 -fobjc-arc -Wall -Wextra -Werror RefreshCachedVideo.mm -framework AppKit -o NativeMacRefreshCachedVideo
codesign --force --sign - NativeMacRefreshCachedVideo
bash build_component.sh
clang -arch x86_64 -fobjc-arc -Wall -Wextra -Werror -c RegistrySigning.m VideoBridgeEntry.m
clang++ -arch x86_64 -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pthread -dynamiclib RegistrySigning.o VideoBridgeEntry.o VTDecoder.mm VTEncoder.mm VideoTransport.cpp \
  -framework Foundation -framework Security -framework VideoToolbox -framework CoreMedia -framework CoreVideo -o NativeMacVideoEntry.dylib
codesign --force --sign - NativeMacVideoEntry.dylib
clang++ -arch x86_64 -std=c++17 -fobjc-arc -Wall -Wextra -Werror -pthread VTStreamProbe.mm VTDecoder.mm VideoTransport.cpp \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -o VTStreamProbe
clang++ -arch x86_64 -std=c++17 -fobjc-arc -Wall -Wextra -Werror VTEncodeProbe.mm VTEncoder.mm VideoTransport.cpp \
  -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -o VTEncodeProbe
clang -arch x86_64 -fobjc-arc -Wall -Wextra -Werror AVPlayerProbe.m \
  -framework Foundation -framework AVFoundation -framework QuartzCore -framework CoreVideo -framework CoreMedia -o AVPlayerProbe
clang++ -arch x86_64 -std=c++17 -fobjc-arc -Wall -Wextra -Werror AVAssetWriterProbe.mm \
  -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia -o AVAssetWriterProbe
for file in VTStreamProbe VTEncodeProbe AVPlayerProbe AVAssetWriterProbe; do codesign --force --sign - "$file"; done
