# Video decoder interface declarations

`CMBaseObjectSPI.h` and `VTVideoDecoderSPI.h` preserve BSD-licensed WebKit
declarations, with their copyright and redistribution notices kept. Formatting
normalizes line endings and one blank line's trailing whitespace only.
Source revision: `8cd1f6cc395ca82effa2968efe87339d54be2b66` in
[WebKit](https://github.com/WebKit/WebKit/tree/8cd1f6cc395ca82effa2968efe87339d54be2b66/Source/ThirdParty/libwebrtc/Source/webrtc/sdk/WebKit).

They describe private interfaces, not a guarantee of compatibility with a
particular macOS build. The bridge must qualify their ABI and frame output
on the actual Intel guest. No code extracted from an Apple binary is included.

`NativeMacEncoderABI.h` is an authored declaration set measured with an authored
encoder on the Intel Darwin 25.6 guest. It includes the five-argument encoded
frame emission function and measured start/encode/complete slots. It is not
an Apple SDK header and does not qualify other OS versions or architectures.
