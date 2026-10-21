# GPU stability investigation

Status: in progress; the earlier successful Metal compute result does not establish desktop stability.

## Reproduction and evidence

- macOS 26.6.2, WHP, 12 GiB RAM, 8 virtual processors, RTX 5080 through Reims/Vulkan.
- The user reports the visible freeze after unlocking the guest.
- The VMM remains alive while guest presents stop and the serial log repeats GPU hang/restart attempts.
- Resource, depth-stencil, sampler and pipeline lookups can fail with empty object-table entries.
- Bounded diagnostics show an entire table of unallocated entries (type 0 and offset UINT64_MAX). A fresh mapping through the current guest page table returned the same entry as the cached mapping. This does not support a simple stale mapping explanation.
- Detailed logs are private local artifacts, not repository contents.

## Current candidate (not qualified)

- The pinned Reims `guest/metal-compat` Lilu plugin is loaded after Lilu, with
  `-reimsmetal`, restricted to Darwin 25.6.0. Its CPU ABI checks pass. It does
  not fake GPU results or replace failed commands with successful completions.
- The user confirms that unlock became much smoother after coalescing pointer
  motion to one pending position, flushed every 8 ms. Button transitions and
  the last held-button position remain ordered. Five frontend unit tests pass.
  One observed session forwarded 4,081 of 18,883 window pointer events.
- Per-event Hyper-V input debug printing is removed from the candidate boot
  arguments. Error logging is retained.
- Five guest Metal compute runs verified all 4,096 values each. The pinned
  queue-burst and texture-lifetime probes passed three runs each: 64 completed
  buffers per burst and 100 checked texture-reuse rounds per lifetime run.
- This is **not** a stability pass: the same session still logged six texture
  lookup faults and six guest GPU hang/restart requests, and the user reported
  approximately 10 FPS and visible latency. Their causal relationship is not
  yet established.
- The next boot reports an actual 1920x1080 mode, EFI presentation disabled,
  and binary version 6. The library window's mode constraint must be changed
  along with OpenCore's output resolution. GPU diagnostic captures remain
  scaled to 1280x800; their dimensions do not identify the guest's resolution.
- `native/MetalProbe/DisplayProbe.m` is a guest CAMetalLayer timing probe. Its
  command-completion rate must be compared with host present counters; neither
  alone establishes the screen's delivered FPS.

## ASTC crash reproduction

The FHD candidate's longer observation failed while multiple system apps,
including Books and Music, were being used. The host worker terminated on
`MTLPixelFormatASTC_8x8_LDR` (212), rejected because the Vulkan device lacks
`VK_FORMAT_ASTC_8x8_UNORM_BLOCK` sampling. This was a VM process failure,
not a successful long-run result. A separate page-table-hole exec fault and
one guest GPU hang/restart request preceded the fatal texture creation.

A trial using the runtime's strict Apple-family audit made the desktop very
slow and was rejected. The original family reporting and fast hardware
rendering path are restored. The next candidate uses `-reimsnoastc` in the
guest compatibility bridge to refuse known ASTC allocation records before
the driver publishes host objects. Application fallback and continued GPU
rendering were tested at FHD: ASTC allocation returned nil, compute verified 4,096 values, and the display probe completed 2,875 frames in 20.006 seconds (143.71 FPS). Eight system-app launches each completed a following compute check. The user confirmed three fast lock/unlock transitions. These checks do not establish full application compatibility or long-term stability.
Unsupported commands must remain explicit failures; they must not be turned
into no-op draws or successful fake completions.

## Reproducing the compatibility build

The source is Reims commit `7f37f7654e441dee0f468954a96d8f94cb7e2ff4`,
`guest/metal-compat`, with `patches/reims-metal-compat-astc.patch` applied.
Commit the patched guest sources before export. The tested local snapshot
revision is recorded in vm/dependencies.json; its file hashes are preserved
in docs/verification/metal-compat-source-manifest.json.
Export using its `source_snapshot.py` from a clean
committed source directory. On Windows, set Git's `core.autocrlf=false` and
`core.eol=lf` for the export process: the snapshot's shell scripts require LF.
Keep its `source-manifest.json` with the signed kext.

On a Mac, use Lilu source `e4748cc081bf060302c7d3c44a643ce1d11b7e1d` and
MacKernelSDK `3f750085caa17ec3a7880f11c11bf4f48cd6a164`, then run the exported
`build.sh LILU_SOURCE MAC_KERNEL_SDK OUTPUT_DIRECTORY`. The result must be an
x86_64 kext. Place the bundle at `artifacts/metal-compat/ReimsMetalCompat.kext`
on Windows. No kext needs to be installed on the build Mac.

`vm/defaults.json` selects `gpuTransport: compat`; use
`Start-VM.ps1 -Gpu -MetalTransport legacy` to select the previous transport.
The compatibility bridge's upstream qualification does not cover this exact
guest OS version; this repository's tests above are the available evidence.

Build the authored display timing probe on a Mac with:

```sh
clang -arch x86_64 -fobjc-arc -framework AppKit -framework Metal -framework QuartzCore DisplayProbe.m -o display-probe-x64
```

Run it inside the logged-in x86_64 guest, passing a duration in seconds.
For RFB command entry, use `Guest-Input.py --keyboard-layout jis` when the
guest interprets physical keys as JIS. The helper defaults to US.

## Acceptance criteria

Keep hardware GPU acceleration, WHP execution, no QEMU, no CPU instruction translation, with the tested 12 GiB / 8-core allocation unchanged. The user later raised the configurable bounds to 256 GiB / 64 cores; these bounds are not an allocation or a validation claim.

A candidate must pass repeated guest Metal compute/readback, at least three lock/unlock transitions, normal desktop window/scroll operations, and a continuous 30-minute rendering/interaction observation. Check for new GPU hangs, failed resource lookups, device loss and kernel panics. Present counters alone are insufficient; visible changes and guest application responsiveness must also be checked. Report exactly what was tested, including remaining limitations.

Do not hide a failed test by suppressing error logs, returning fake successful completions, skipping GPU commands or falling back to software rendering. Do not treat one successful boot or one compute dispatch as completion.

## Metal 3D benchmark and display settings

GravityMark 1.89 was downloaded from its official Tellusim site into the guest's own lab directory. Its universal executable contains x86_64, and the guest ran that architecture. The first FHD windowed rasterization run (20,000 asteroids, temporal AA, vsync off) aborted the host GPU worker during compute pipeline creation: `llvm.bitreverse.i32` is not recognized by the pinned AIR decoder. No benchmark score or 3D compatibility pass was produced. The source-only bitreverse repair is in progress; no benchmark result was submitted to a leaderboard.

The frontend and boot preparation now accept 1920x1080, 2560x1440 and 3840x2160 as the display's maximum mode. The WinUI selector, launcher and GPU mode constraint use the same setting; smaller guest modes remain available. FHD remains the default. The release backend built and six frontend tests passed. A 4K guest boot and GPU performance measurement are still pending.

RAM and CPU settings apply at the next startup. Their configurable bounds are 256 GiB and 64 virtual processors, as requested by the user after the initial 24 GiB / 8-core cap. The current allocation remains 12 GiB / 8 virtual processors. Larger settings are not qualified and require sufficient host resources.

The user prioritizes FHD instruction compatibility before further 4K tests. The first 4K trial reached macOS userland but kept a black display at 1920x1200; it is not qualified. A subsequent FHD trial logged three empty-resource faults, three GPU hangs and a pmap_recycle_page panic. The panic stack includes pageout/storage completion and does not establish a shader-decoder cause. Returning to the prior library restored a responsive FHD desktop, idle CPU, and checked Metal compute. The bitreverse candidate is being retested after the reproduction apps were closed and guest writes synchronized.
