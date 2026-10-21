# Upstream sources

Own source is under the root MIT license. Third-party code, patches and binaries retain their upstream licenses; the root license does not replace them. No Apple OS media or compiled third-party binaries are included in this repository.

- [Microsoft OpenVMM](https://github.com/microsoft/openvmm), MIT. Changes in patches/openvmm-nativemac.patch. The upstream license and notices remain in a source checkout.
- [Reims vGPU](https://github.com/tqmane/reims-vgpu), GPL-2.0-or-later OR LGPL-3.0-or-later (see its LICENSE and LICENSES directory). MSVC build changes in patches/reims-msvc.patch. Its separate C library is dynamically loaded; QEMU code is not linked or used.
- [metal2vulkan](https://github.com/tqmane/metal2vulkan), transitive Reims dependency; retain the pinned source and its license when distributing its binaries.
- [MacHyperVSupport](https://github.com/acidanthera/MacHyperVSupport), retain its original license and copyright notices. Changes in patches/machyperv-native-pci.patch.
- [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg), [Lilu](https://github.com/acidanthera/Lilu), [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK), [AMD_Vanilla](https://github.com/AMD-OSX/AMD_Vanilla), [Hyper-V EFI](https://github.com/qonfused/Hyper-V-AMD-Hackintosh), LLVM and ACPICA are build or local boot dependencies, each under its respective upstream license.

The dependency revisions used in this environment are recorded in vm/dependencies.json. Screenshots and validation reports in docs/verification record the development VM; they are not installation media.
