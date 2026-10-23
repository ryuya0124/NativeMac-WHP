# Windows GPU name in standard Metal applications

The Windows launcher asks the same Reims DLL used by the VM which Vulkan
renderer it selected. The validated name travels through the boot property
`reims-gpu-model`; the guest bridge publishes the corresponding model data.

This boot helper reads that property and writes Metal's existing
`forceDeviceName` display-name preference for all users. The name contains
no configured vendor/model string. Existing Apple driver code, PCI IDs,
feature families, resources, shader compilation and GPU execution remain
unchanged. An app-specific user preference can override an all-user value.

On the tested Intel macOS 26.6.2 VM, the ordinary Metal device and its base
class getter return the selected Windows name. A cold boot starts the stock
WindowServer and the helper exits successfully. GPU compute verifies 4096
values; FP32/FP16 matrix multiplication and a four-layer MPS convolution also
pass after the update. This is display metadata, not an NVIDIA macOS driver
or additional GPU API support.

Build in the Intel guest, placing the executable next to these files:

```bash
clang -fobjc-arc -Wall -Wextra -Werror main.m \
  -framework Foundation -framework IOKit -o gpu-identity-agent
codesign --force --sign - gpu-identity-agent
sudo bash install.sh "$PWD"
```

The launch daemon runs once per boot and waits up to 60 seconds for validated
metadata. If the property is absent or malformed, it removes a previous
name managed by this helper rather than retaining an old renderer label.
Other Metal preferences remain intact. On a new boot, already-open apps
may retain strings they cached themselves; newly created Metal devices read
the updated preference.

To stop publishing the name:

```bash
sudo launchctl bootout system/io.nativemac.gpu-identity
sudo /Library/PrivilegedHelperTools/io.nativemac.gpu-identity --clear-owned-name
```

The clear operation removes the preference only when it still equals the
helper's recorded value. Removing the launch-daemon plist after stopping it
prevents it from running on later boots.

The separate `MetalIdentity` bundle is an experiment. Its explicit process
test works, but the standard WindowServer refuses its non-platform code
signature. Do not select that bundle for the desktop; this preference-based
helper leaves the stock Metal entry selected and needs no signing-policy
change.
