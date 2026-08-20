# xloader v7

Configuration-driven Xen bundle loader and host packer implemented primarily in Zig 0.16.

## Architecture

`xbundle` is the host-side system-image compiler. `xloader` is a small position-independent target-side Xen boot adapter.

```text
system.toml
    |
    v
 xbundle
    |
    +-- position-independent xloader
    +-- Xen ELF PT_LOADs
    +-- raw guest kernel/initrd payloads
    +-- compact binary descriptor
    |
    v
system.xbundle.elf
    |
    v
 xloader
    |
    +-- prepare host DT
    +-- create static DomU nodes
    +-- create per-domain passthrough partial DT modules
    |
    v
   Xen
```

The flake is pinned to `nixos-26.05-small`.

## v7 features

- Zig 0.16 is the primary implementation language.
- `xloader` is linked as position-independent `ET_DYN`; the host `xbundle` tool chooses final placement.
- No owned Zig identifier uses the reserved word `align`.
- TOML is parsed only by host-side `xbundle`; target xloader never parses text configuration.
- Multiple `[[domain]]` entries are supported through a variable-length binary descriptor.
- AArch64 guest `Image` files are treated as raw Linux boot images, not ELF files.
- Optional initramfs payloads are raw byte payloads.
- Per-domain `[[domain.passthrough]] path = "/..."` entries are carried in the descriptor.
- On AArch64, xloader builds a `multiboot,device-tree` partial DT for domains that request passthrough paths.
- Passthrough subtree copying is conservative in v7: common external-phandle dependency properties are rejected rather than silently emitting an invalid guest DT.
- `xbundle inspect` decodes a completed bundle without requiring the original manifest.
- The checked-in QEMU sample boots two named dom0less guests to a static BusyBox `/init` acceptance marker.
- A second sample places the exact same PIC xloader at a different physical address for relocation acceptance testing.

## Development

```sh
nix develop
make clean
make all
make test
```

## Bootable AArch64 sample

The canonical sample is:

```text
configs/qemu-aarch64.toml
```

Prepare its prebuilt/cached inputs:

```sh
make prepare-sample-aarch64
```

This creates stable project-local links instead of putting Nix store hashes in the checked-in TOML:

```text
build/inputs/aarch64/xen
build/inputs/aarch64/linux
build/inputs/aarch64/initramfs.cpio
```

Then:

```sh
make check-sample-aarch64
make plan-sample-aarch64
make sample-aarch64
make inspect-sample-aarch64
make smoke-sample-aarch64
```

The smoke test requires both guests to reach userspace independently:

```text
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

## Position-independence acceptance

The relocated manifest is:

```text
configs/qemu-aarch64-relocated.toml
```

It uses the exact same `build/xloader-aarch64.elf`, but xbundle assigns a different loader/Xen physical layout.

```sh
make smoke-pic-aarch64
```

Success means both bundles boot their two userspaces without rebuilding xloader.

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
cmdline = "console=dtuart dtuart=serial0 conswitch=ax"

[layout]
loader_base = "0x40080000"
xen_base = "0x40400000"
payload_alignment = "2M"

[[domain]]
name = "guest0"
kernel = "build/inputs/aarch64/linux"
kernel_format = "linux-image"
initrd = "build/inputs/aarch64/initramfs.cpio"
memory = "256M"
vcpus = 1
cmdline = "console=ttyAMA0 rdinit=/init xloader.domain=guest0"
vpl011 = true

[[domain.passthrough]]
path = "/abba/i2c0"
```

The QEMU acceptance sample intentionally leaves passthrough entries commented because real device ownership and MMIO/IOMMU policy are board-specific.

## Passthrough behavior in v7

For a configured path such as:

```toml
[[domain.passthrough]]
path = "/abba/i2c0"
```

xloader:

1. resolves the path against the actual boot-time machine DTB;
2. builds a per-domain partial FDT under `/passthrough`, preserving the configured path hierarchy;
3. copies the selected node and child subtree;
4. rejects known properties that require unresolved external phandles, such as `clocks`, `resets`, `iommus`, `power-domains`, `dmas`, and `interrupt-parent`;
5. adds the resulting FDT as a `multiboot,device-tree` module under the domain's `xen,domain` node.

v7 does **not** infer MMIO guest IPA mapping, IOMMU ownership, IRQ routing policy, or `xen,force-assign-without-iommu`. Those need explicit configuration semantics and are intentionally deferred.

## xbundle commands

```text
xbundle abi
xbundle probe <elf>
xbundle check <system.toml>
xbundle plan <system.toml>
xbundle build <system.toml> [-o output.elf]
xbundle inspect <bundle.elf>
```

`check` validates manifest and input formats. `plan` also displays the calculated physical layout. `build` emits the final ELF. `inspect` decodes the embedded binary descriptor from the finished ELF.

## Kernel formats

AArch64 Linux kernels use the raw boot `Image`:

```toml
kernel_format = "linux-image"
```

`xbundle` validates the Arm64 Image header and then packs the file byte-for-byte. It never sends `domain.kernel` or `domain.initrd` through the ELF parser.
