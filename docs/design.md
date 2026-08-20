# xloader Design

## 1. Purpose

`xloader` boots a statically described Xen system from one combined ELF image.
The system definition is compiled on the host from TOML. The target loader is
small, position independent, architecture specific only where required, and
contains no filesystem, TOML, ELF parser, allocator, or dynamic loader.

The central design rule is:

> **All xbundle inputs are raw byte images. ELF normalization is outside
> xbundle. xbundle owns physical placement and emits the only ELF used at boot.**

## 2. Components

```text
                         HOST

 source/build artifacts
   xloader.elf    Xen ELF       Linux Image      initrd
       |             |               |              |
       |             |               |              |
       +-- normalize +               |              |
       |             |               |              |
       v             v               v              v
 xloader.bin      xen.bin         Image        initrd.cpio
 xloader.meta     xen.meta
       \             /               |              /
        \           /                |             /
         +--------- system.toml -----+------------+
                         |
                         v
                    +---------+
                    | xbundle |
                    +---------+
                    | TOML    |
                    | validate|
                    | layout  |
                    | ABI desc|
                    | ELF emit|
                    +----+----+
                         |
                         v
                system.xbundle.elf

                         TARGET

 firmware / QEMU ELF loader
            |
            v
         xloader
            |
       prepare DTB
            |
            v
           Xen
       /     |      \
    DomU0  DomU1   DomU...
```

## 3. Host/target boundary

### 3.1 Host responsibilities

The host side owns all expensive or format-rich work:

- parse `system.toml`;
- normalize executable source artifacts into raw bytes;
- validate normalized metadata;
- validate raw AArch64 Linux `Image` headers;
- calculate physical layout and alignment;
- detect overlap/overflow;
- compile the variable-length binary xbundle descriptor;
- emit the final boot ELF;
- inspect the final xbundle image.

### 3.2 Target responsibilities

The target `xloader` only:

- starts in the architecture-defined boot environment;
- locates its embedded xbundle descriptor using position-independent code;
- validates descriptor bounds and counts;
- copies the machine DTB into a private workspace;
- adds Xen bootargs and static domain modules with libfdt;
- constructs partial DT modules for configured passthrough paths;
- performs architecture-specific cache/state preparation;
- enters Xen.

`xloader` does **not** parse TOML or ELF.

## 4. Raw executable normalization

`xbundle` never consumes an ELF executable directly. A normalization step
converts an executable source artifact to:

```text
component.bin
component.meta.toml
```

Example metadata:

```toml
format = 1
kind = "loader"
arch = "aarch64"
entry_offset = "0x0"
memory_size = "0x52000"
load_alignment = "0x1000"
descriptor_offset = "0x18000"
source = "build/xloader-aarch64.elf"
```

Xen metadata does not contain `descriptor_offset`:

```toml
format = 1
kind = "xen"
arch = "aarch64"
entry_offset = "0x200000"
memory_size = "0xa00000"
load_alignment = "0x200000"
source = "/nix/store/...-xen"
```

The normalization stage may use `readelf`, `nm`, and `objcopy`. This ELF
knowledge is deliberately outside `xbundle` and outside the target runtime.

### 4.1 Why metadata is required

A flat file alone cannot represent all executable memory semantics. In
particular, trailing BSS/stack space is not necessarily present in the raw
file. The sidecar therefore records `memory_size` separately from file size.
The final ELF uses:

```text
p_filesz = raw file size
p_memsz  = metadata.memory_size
```

The previous-stage ELF loader zero-fills `p_memsz - p_filesz`.

### 4.2 Position-independent loader

The normalized xloader is position independent. Its metadata contains only
relative values:

```text
entry_offset
descriptor_offset
memory_size
```

It never records a fixed physical base. `xbundle` chooses the base from the
system manifest/layout policy.

## 5. Input classes

`xbundle` recognizes three conceptual raw input classes:

### 5.1 Normalized executable

Examples:

- xloader;
- Xen.

Representation:

```text
raw bytes + metadata sidecar
```

### 5.2 Validated raw boot payload

Example:

- AArch64 Linux `Image`.

`xbundle` validates its 64-byte Linux Image header and magic, but otherwise
copies the bytes unchanged.

### 5.3 Opaque raw payload

Examples:

- initramfs;
- firmware blob;
- future domain-specific data.

No executable parsing is performed.

## 6. System TOML

TOML is host-only. The target never sees it.

Canonical form:

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
path = "/soc/i2c@12340000"
```

Multiple `[[domain]]` entries are supported. Domain names must be unique.

## 7. Layout policy

The manifest describes boot intent. Physical placement is a host-side policy.

Normal layout:

```text
loader base
   |
   +-- raw loader bytes
   +-- zero-filled loader BSS/stack through p_memsz

next aligned region
   |
   +-- Xen raw bytes
   +-- zero-filled Xen tail through p_memsz

next payload alignment
   +-- DomU0 kernel
   +-- DomU0 initrd
   +-- DomU1 kernel
   +-- DomU1 initrd
   +-- ...
```

No guest or executable input supplies its own final physical address.

## 8. Final ELF

The final `system.xbundle.elf` is the only ELF required by the boot path.
`xbundle` writes it directly.

For AArch64, the first segments are typically:

```text
PT_LOAD  xloader.bin  p_filesz=file size  p_memsz=loader memory size
PT_LOAD  xen.bin      p_filesz=file size  p_memsz=Xen memory size
PT_LOAD  guest0 Image p_filesz=p_memsz=exact Image file size
PT_LOAD  guest0 initrd
PT_LOAD  guest1 Image
PT_LOAD  guest1 initrd
...
```

The ELF entry is:

```text
loader_base + loader.entry_offset
```

The xbundle descriptor stores:

```text
xen_addr  = xen_base
xen_entry = xen_base + xen.entry_offset
xen_size  = xen.memory_size
```

## 9. Binary descriptor

The descriptor is generated by `xbundle` and patched into the reserved raw
xloader range at:

```text
loader.descriptor_offset
```

The descriptor remains variable-length:

```text
Header
Domain[domain_count]
Passthrough[passthrough_count]
StringTable
```

It contains final physical addresses for Xen and raw guest payloads. These
addresses are deployment data generated by `xbundle`; xloader's own internal
references remain position independent.

## 10. Multiple domains

Each `[[domain]]` becomes one `abi.Domain` entry. At runtime xloader iterates
all entries and emits one Xen static-domain description per entry.

Conceptually:

```dts
/chosen {
    domU0 {
        compatible = "xen,domain";
        memory = <...>;
        cpus = <...>;

        module@... {
            compatible = "multiboot,kernel", "multiboot,module";
            reg = <...>;
        };

        module@... {
            compatible = "multiboot,ramdisk", "multiboot,module";
            reg = <...>;
        };
    };

    domU1 { ... };
};
```

## 11. Passthrough paths

A domain may select host-FDT nodes:

```toml
[[domain.passthrough]]
path = "/abba/i2c0"
```

The descriptor stores only the path string. xloader resolves it against the
actual machine DTB supplied at boot.

V8 remains conservative:

- copy selected node/subtree into a domain partial DT;
- reject known unsupported external phandle dependencies rather than silently
  producing an invalid guest tree;
- do not infer MMIO/IOMMU ownership merely from the path.

Explicit resource assignment is a later schema extension.

## 12. Architecture split

Common source owns:

- descriptor validation;
- domain iteration;
- DT construction policy;
- libfdt wrapper;
- logging.

Architecture code owns:

- initial CPU entry state;
- stack setup where required;
- cache and barrier operations;
- final Xen handoff ABI.

AArch64 uses the DT-based Xen handoff. x86_64 retains its Multiboot-specific
entry/transition and is developed independently from the Arm handoff.

## 13. Nix development model

The project uses the pinned `nixos-26.05-small` input.

Nix provides:

- Zig 0.16 toolchain;
- QEMU;
- binutils normalization tools;
- libfdt sources;
- Linux kernel `Image` from the store;
- static BusyBox for the sample initramfs;
- cached/prebuilt Xen input where available.

The project does not rebuild Linux for the QEMU sample.

AArch64 sample flow:

```text
make all
make prepare-sample-aarch64
make check-sample-aarch64
make plan-sample-aarch64
make sample-aarch64
make inspect-sample-aarch64
make smoke-sample-aarch64
```

`prepare-sample-aarch64` is responsible for normalization. Therefore by the
time `xbundle` runs, every executable input is already raw.

## 14. Acceptance criteria

AArch64 baseline acceptance requires:

```text
xloader starts from the combined ELF
xloader validates the descriptor
Xen starts
all configured static DomUs start
both sample guests reach /init
```

The checked-in sample must report:

```text
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

Position independence is verified by building two bundles with different
loader bases from the exact same normalized `xloader.bin` and booting both.

## 15. Future work

After the raw-input architecture is stable:

1. explicit passthrough MMIO/IRQ/IOMMU assignment;
2. x86_64 Xen handoff completion;
3. hashes and signatures;
4. A/B images and rollback metadata;
5. AVB-style verified deployment;
6. real-board platform constraints.

These features must not reintroduce ELF/TOML parsing into the target loader.
