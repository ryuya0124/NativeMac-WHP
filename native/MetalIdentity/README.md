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
  -Wl,IOGPU.tbd \
  -o NativeMacMetal.bundle/Contents/MacOS/NativeMacMetal
codesign --force --sign - NativeMacMetal.bundle
clang -fobjc-arc -Wall -Wextra -Werror Probe.m \
  -framework Foundation -framework Metal -framework IOKit -o MetalIdentityProbe
./MetalIdentityProbe "$PWD/NativeMacMetal.bundle"
```

`IOGPU.tbd` declares the already measured superclass symbol and its framework
dependency; it contains no framework code. The dependency must load before
the entry's Objective-C class is registered in a fresh application.

The explicit probe returns the host name, retains the original registry ID
and verifies 4096 computed GPU values. An optional third argument runs the
same check with the stock class as a control.

This does **not** install or select a system Metal plug-in. The normal VM
keeps the stock entry. An explicit development-signing trial now loads the
dependency-correct bundle in WindowServer, presents at 4K, and verifies 4096
GPU values after a reboot. `amfi=0x80` is applied only to that VM boot. The
sealed system volume and Windows signing policy are unchanged.

`scripts/Start-VM.ps1 -Gpu -EphemeralDisk -DevelopmentSigning -HostMetalEntry`
selects this experiment. It requires a bridge built from the host-entry patch
in `patches/reims-metal-host-entry.patch`, staged separately at
`artifacts/metal-signing/ReimsMetalCompat.kext`, and the linked bundle installed
in the test guest's `/Library/GPUBundles`. Build it with
`bash build.sh output-directory`; install only the resulting authored bundle.
Omit these switches to retain the normal signing policy and stock entry.

The host probe also reads the Vulkan physical-device type of the uniquely
named selected renderer. OpenCore publishes it separately from the GPU name.
The Metal entry keeps the virtual driver's normal memory contract by default.
`-HostMemoryArchitecture` additionally changes `hasUnifiedMemory` to that host
fact. **This is an unqualified negative experiment:** on the RTX 5080, ordinary
compute passed but Geekbench Background Blur and Face Tracking failed result
validation. It was stopped and the getter restored before the compatibility
rerun. Do not use that switch for benchmarks or ordinary applications.

The custom entry also failed Geekbench Super Resolution validation after the
memory getter was restored to its parent. Its WindowServer load is established,
but it is not a qualified replacement driver. The stock-entry rerun completes
all eleven workloads without validation errors.

The authored `SubmissionProbe.m` compares shared and private buffer writes,
batch sizes and CPU encode/commit/wait costs, verifying every output value.
On this VM a large batched private-buffer case was about eight times faster
than its shared-buffer case. This comparison does not establish an application
speedup, and the final private-to-shared readback is outside its timed interval.

Use the [GPU identity helper](../GpuIdentityAgent/README.md) for the tested
standard-driver name path. It uses Metal's existing display-name preference,
keeping the original driver selected without changing signing enforcement,
GPU capabilities or the sealed system volume.
