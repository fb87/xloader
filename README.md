# xloader v6

Configuration-driven Xen bundle loader and host packer implemented primarily in Zig 0.16.

## v6 architecture

- `xloader` is a position-independent component (`ET_DYN`); `xbundle` chooses its final physical placement.
- `xbundle` and the target share a compact binary descriptor ABI.
- `system.toml` is parsed only by the host-side `xbundle` tool.
- Multiple `[[domain]]` entries are supported.
- Each domain may list `[[domain.passthrough]]` host-FDT paths.
- xloader validates passthrough paths against the boot-time machine DT. Actual Xen hardware assignment/partial guest-DT generation is a later passthrough milestone.
- xloader and Xen are ELF components.
- Guest kernels and initrds are payloads, **not ELF components**.
- AArch64 Linux `Image` is validated from its 64-byte Linux boot header and packed byte-for-byte as a raw `PT_LOAD` payload.

## Development

The flake is pinned to `nixos-26.05-small`.

```sh
nix develop
make clean
make all
make test
```

## Bootable AArch64 sample

The checked-in sample is `configs/qemu-aarch64.toml`. It boots two dom0less Linux guests with a tiny BusyBox initramfs.

```sh
nix develop
make prepare-sample-aarch64
make check-sample-aarch64
make plan-sample-aarch64
make sample-aarch64
make inspect-sample-aarch64
make smoke-sample-aarch64
```

`prepare-sample-aarch64` creates stable project-local input links:

```text
build/inputs/aarch64/xen
build/inputs/aarch64/linux       # raw arm64 Linux Image
build/inputs/aarch64/initramfs.cpio
```

The manifest therefore does not contain unstable `/nix/store/<hash>` strings.

## Manifest example

```toml
format = 1

[bundle]
output = "build/qemu-aarch64.xbundle.elf"

[platform]
arch = "aarch64"

[loader]
image = "build/xloader-aarch64.elf"

[xen]
image = "build/inputs/aarch64/xen"
cmdline = "console=dtuart dtuart=serial0"

[[domain]]
name = "guest0"
kernel = "build/inputs/aarch64/linux"
kernel_format = "linux-image"
initrd = "build/inputs/aarch64/initramfs.cpio"
memory = "256M"
vcpus = 1
cmdline = "console=ttyAMA0 rdinit=/init"
vpl011 = true

[[domain.passthrough]]
path = "/soc/i2c@12340000"
```

For the QEMU sample the passthrough entry is left commented because it is board-specific.

## Kernel payload formats

For AArch64:

```toml
kernel_format = "linux-image"   # raw Linux Image, validated by ARM64 header
```

`auto` currently resolves to the same validation on AArch64. `raw` disables format-specific validation for special payloads.

`xbundle` never calls the ELF parser for `domain.kernel` or `domain.initrd`.
