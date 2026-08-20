# xloader v8

`xloader` packages a static Xen system into one bootable ELF. v8 switches the
host pipeline to **raw inputs only**: `xbundle` no longer parses loader or Xen
ELF files.

See [docs/design.md](docs/design.md) for the canonical architecture.

## Development environment

```bash
nix develop
```

The flake is pinned to `nixos-26.05-small` and provides Zig 0.16, QEMU,
binutils, libfdt sources, cpio, BusyBox inputs, and the TOML parser source.

## Build

```bash
make clean
make all
make test
```

`make all` still creates intermediate executable ELFs because the compiler and
linker naturally produce them. They are **normalization inputs**, not xbundle
inputs.

## Raw normalization

The sample preparation performs:

```text
xloader-aarch64.elf
    -> xloader.bin + xloader.meta.toml

prebuilt Xen ELF
    -> xen.bin + xen.meta.toml

Linux Image
    -> already raw, no conversion
```

The normalizer is:

```bash
scripts/normalize-elf.sh
```

It uses `readelf`, `nm`, and `objcopy`. ELF knowledge ends there.

## Bootable AArch64 sample

The dedicated checked-in sample is:

```text
configs/qemu-aarch64.toml
```

It defines two static DomUs and uses the pinned Nix-store Linux `Image` plus a
small generated static initramfs.

Run:

```bash
make prepare-sample-aarch64
make check-sample-aarch64
make plan-sample-aarch64
make sample-aarch64
make inspect-sample-aarch64
make smoke-sample-aarch64
```

The smoke acceptance is:

```text
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

## Raw-input manifest

```toml
format = 1

[bundle]
output = "build/qemu-aarch64.xbundle.elf"

[platform]
arch = "aarch64"

[loader]
image = "build/inputs/aarch64/xloader.bin"
metadata = "build/inputs/aarch64/xloader.meta.toml"

[xen]
image = "build/inputs/aarch64/xen.bin"
metadata = "build/inputs/aarch64/xen.meta.toml"
cmdline = "console=dtuart dtuart=serial0 conswitch=ax"

[[domain]]
name = "guest0"
kernel = "build/inputs/aarch64/linux"
kernel_format = "linux-image"
initrd = "build/inputs/aarch64/initramfs.cpio"
memory = "256M"
vcpus = 1
cmdline = "console=ttyAMA0 rdinit=/init xloader.domain=guest0"
```

`xbundle` parses TOML and raw metadata only. It writes the final boot ELF
itself.

## Commands

```text
xbundle abi
xbundle check system.toml
xbundle plan system.toml
xbundle build system.toml
xbundle inspect system.xbundle.elf
```

There is deliberately no `xbundle probe <elf>` command anymore.
