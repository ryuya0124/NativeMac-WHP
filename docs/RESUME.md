# Current checkpoint

The Windows restart is complete. The WinUI VM is running with 12 GiB RAM and 8 virtual processors, within the 24 GiB / 8-core limits.

Confirmed: Intel macOS 26.6.2 build 25G83 boots using OpenVMM WHP. Guest Metal compute verified all 4096 values on the RTX 5080, and the GPU displayed Setup Assistant. No QEMU or CPU instruction translation is used. Original recovery media is read without disk-image conversion.

The mouse-wheel fix is verified: all three mouse protocol tests passed, the release backend built, and the guest logged the 73-byte HID descriptor with signed 8-bit wheel packets. The user confirmed scrolling works after this boot. Initial setup and guest-account preferences are managed by the user; do not request/store the password.

The private GitHub repository is https://github.com/ryuya0124/NativeMac-WHP. Source, patches, build prerequisites and validation evidence are committed. OS media, VM disks and compiled dependency binaries are excluded.

Remaining limitations: the guest display uses a separate GPU window. Some iconservicesagent GPU tasks can report empty resource entries; broad application compatibility and long-term stability remain unverified. Boot resolution is 1280x800. The temporary HTTP lab server is stopped.

Evidence is in docs/verification and vm/progress.json. Detailed local logs are under artifacts and excluded from Git.
