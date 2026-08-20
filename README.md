# xloader v9

`xloader` packages a statically described Xen system into one bootable ELF.
The runtime loader is small and position independent; the host-side system
compiler is `xbundle`.

v9 makes the development and image-construction pipeline **Nix-native**. There
are no repository shell scripts and no Makefile orchestration. Nix derivations
own compilation, ELF-to-raw normalization, initramfs generation, manifest
materialization, bundle construction, inspection, and QEMU acceptance checks.

See [`docs/design.md`](docs/design.md) for the canonical architecture.

## Development environment

```bash
nix develop
```

The flake is pinned to `nixos-26.05-small`.

## Build individual components

```bash
nix build .#xbundle
nix build .#xloader-aarch64
nix build .#xloader-x86_64
```

The target loader ELFs are build intermediates. `xbundle` never parses them.
Nix normalizes executable components into raw bytes plus metadata:

```bash
nix build .#xloader-aarch64-raw
nix build .#xen-aarch64-raw
```

Each normalized output contains:

```text
result/
├── image.bin
└── meta.toml
```

## Bootable AArch64 sample

The checked-in human-readable template is:

```text
configs/qemu-aarch64.toml.in
```

Nix substitutes exact store paths for the loader, Xen, Linux `Image`, and
initramfs to create the concrete bootable manifest:

```bash
nix build .#sample-config-aarch64
cat result
```

Build the final system image:

```bash
nix build .#sample-bundle-aarch64
```

The output contains:

```text
result/
├── system.xbundle.elf
├── check.txt
├── plan.txt
├── inspect.txt
├── file.txt
└── readelf.txt
```

Run the full Xen + two-DomU acceptance as a Nix derivation:

```bash
nix build .#smoke-sample-aarch64
cat result/system.log
```

Acceptance requires both guests to reach their static `/init`:

```text
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

## Position-independence acceptance

The relocated sample uses the exact same normalized `xloader.bin` but a
different loader base:

```bash
nix build .#sample-bundle-aarch64-relocated
nix build .#smoke-pic-aarch64
```

## Loader-only smoke tests

```bash
nix build .#smoke-loader-aarch64
nix build .#smoke-loader-x86_64
```

The x86_64 smoke derivation creates its GRUB ISO entirely inside Nix.

## Flake validation

```bash
nix flake check
```

The default checks build `xbundle`, both loader architectures, both loader
smokes, and the AArch64 sample bundle. The longer full Xen/Linux smoke remains
an explicit package so normal `nix flake check` does not always boot two VMs.

## Raw-input architecture

The core pipeline is:

```text
xloader ELF ──Nix normalize──> xloader.bin + meta.toml
Xen ELF    ──Nix normalize──> xen.bin     + meta.toml
Linux Image ─────────────────> raw Image
initramfs  ──Nix derivation─> raw cpio
                                  │
                                  v
                         concrete system.toml
                                  │
                                  v
                               xbundle
                                  │
                                  v
                         system.xbundle.elf
```

There is deliberately no generic ELF parser in `xbundle`.
