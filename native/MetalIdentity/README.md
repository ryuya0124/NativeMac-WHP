# Experimental Metal name entry

This opt-in, in-process prototype reads `reims-gpu-model` from the device's
IORegistry parents. The label originates from the Windows renderer selected
by the configured Reims library at VM startup. It contains no fixed vendor
or GPU model name.

`Driver.m` creates a zero-ivar subclass of the existing Apple paravirtual
device. It overrides the display-name getter and preserves the original
class returned to the shader compiler. All resource and GPU commands remain
in the existing driver. Missing or malformed metadata retains its name.

Build and run on the Intel guest:

```bash
mkdir -p NativeMacMetal.bundle/Contents/MacOS
cp Info.plist NativeMacMetal.bundle/Contents/Info.plist
clang -fno-objc-arc -Wall -Wextra -Werror -bundle -undefined dynamic_lookup \
  Driver.m -framework Foundation -framework IOKit -framework Metal \
  -o NativeMacMetal.bundle/Contents/MacOS/NativeMacMetal
codesign --force --sign - NativeMacMetal.bundle
clang -fobjc-arc -Wall -Wextra -Werror Probe.m \
  -framework Foundation -framework Metal -framework IOKit -o MetalIdentityProbe
./MetalIdentityProbe "$PWD/NativeMacMetal.bundle"
```

The explicit probe returns the host name, retains the original registry ID
and verifies 4096 computed GPU values. An optional third argument runs the
same check with the stock class as a control.

This does **not** install or select a system Metal plug-in. Normal applications
still return `Apple Paravirtual device`. OS-wide loader and signing
compatibility remain unqualified. Do not change GPU capabilities, rewrite
the sealed system volume or weaken signing enforcement to install this probe.
