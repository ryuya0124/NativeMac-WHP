# Resume checkpoint

The user requested restarting Windows because the host became very slow. The development VM was stopped first. The GitHub repository is private.

Confirmed: Intel macOS 26.6.2 build 25G83 boots using OpenVMM WHP. Guest Metal compute verified all 4096 values on the RTX 5080, and the GPU displayed Setup Assistant. No QEMU or CPU instruction translation. Tested resources: 12 GiB / 8 cores; caps: 24 GiB / 8 cores.

Pending: live verification of the mouse-wheel fix. The VMBus HID descriptor now declares a signed 8-bit wheel and a reserved byte in a 7-byte packet. All 3 mouse protocol tests passed and the release backend built successfully. Live scrolling has not yet been verified.

Start `artifacts/app/TahoeVm.exe --start-vm --memory 12 --processors 8`, then select NativeMac in OpenCore if necessary. The user was completing account setup. After login, verify scrolling in a scrollable guest view. Do not overwrite account preferences or request/store the guest password.

The guest display uses a separate GPU window. The temporary HTTP lab server is stopped. Some iconservicesagent GPU tasks can report empty resource entries; broader application compatibility and long-term stability remain unverified. Boot resolution is 1280x800.

Evidence is in docs/verification. Detailed local logs are under artifacts and excluded from Git.
