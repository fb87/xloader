# xloader Design

## 1. Purpose

`xloader` is a small position-independent boot adapter for static Xen systems.
A host-side Zig tool, `xbundle`, compiles a TOML system definition and raw
binary inputs into one ELF that can be loaded by QEMU or firmware.

The architectural boundary is:

> `xbundle` decides what is loaded and where. `xloader` adapts that already
> loaded state to Xen's architecture-specific boot interface.

## 2. Components

### 2.1 `xbundle` host tool

Responsibilities:

- parse `system.toml`;
- validate normalized loader/Xen metadata;
- validate raw Linux `Image` payloads;
- calculate physical layout;
- compile domain and passthrough resources into the binary descriptor;
- emit the final ELF program headers and raw data;
- inspect completed bundles.

`xbundle` does **not** parse input loader or Xen ELF files.

### 2.2 `xloader` target runtime

Common responsibilities:

- validate the binary descriptor;
- copy the machine DT into a private libfdt workspace on Arm;
- create Dom0less domain nodes and boot modules;
- create partial device trees for configured passthrough devices;
- establish the architecture-specific Xen entry state;
- enter Xen.

Architecture-specific code owns entry registers, cache/MMU transition, and the
final hypervisor jump.

## 3. Raw input pipeline

```text
xloader.elf                  xen.elf
    |                           |
Nix normalization          Nix normalization
    |                           |
    v                           v
xloader.bin                 xen.bin
xloader.meta.toml           xen.meta.toml
        \                     /
         \                   /
        Linux Image + initramfs
                 |
             system.toml
                 |
              xbundle
                 |
         system.xbundle.elf
```

Executable metadata contains only the information the raw packer needs:

```toml
format = 1
kind = "loader"
arch = "aarch64"
entry_offset = "0x..."
memory_size = "0x..."
load_alignment = "0x..."
descriptor_offset = "0x..." # loader only
```

The normalizer translates an ELF virtual entry through its containing
`PT_LOAD` to obtain the physical entry offset. `objcopy` output is padded back
to the complete file-backed load span so reserved zero-filled file sections,
including the xbundle descriptor, are retained.

## 4. Position independence

The standalone loader has no fixed physical load address. Its internal code
uses position-independent references. `xbundle` chooses the final loader base
from the manifest/layout policy.

The exact same normalized xloader image is therefore usable at multiple
physical locations without recompilation.

## 5. System manifest

The canonical input is TOML:

```toml
format = 1

[loader]
image = ".../xloader.bin"
metadata = ".../xloader.meta.toml"

[xen]
image = ".../xen.bin"
metadata = ".../xen.meta.toml"
cmdline = "console=dtuart dtuart=serial0"

[[domain]]
name = "guest0"
kernel = ".../Image"
kernel_format = "linux-image"
initrd = ".../initramfs.cpio"
memory = "256M"
vcpus = 1
vpl011 = true
```

TOML is host-only. xloader sees only the compact binary descriptor.

## 6. Multiple domains

The descriptor has a variable-length `Domain[]` table and string table. Each
domain records:

- name;
- command line;
- memory in KiB;
- vCPU count;
- kernel physical address and exact byte size;
- optional initrd physical address and exact byte size;
- zero or more passthrough-resource records.

xloader converts each record into a `/chosen/domU<N>` node using Xen's Arm
Dom0less binding.

## 7. Passthrough resource model

### 7.1 Principle

A Device Tree path alone is not a hardware grant. v10 therefore separates:

1. **guest-visible description**: copied from the actual boot-time machine DT;
2. **resource assignment**: explicit values compiled from `system.toml`.

The manifest is the reviewable authority for the MMIO/IRQ grant.

### 7.2 v10 TOML

```toml
[[domain.passthrough]]
path = "/pl031@9010000"
force_assign_without_iommu = true
strip_external_dependencies = true
mmio = { host = "0x09010000", guest = "same", size = "4K" }
irq = { type = "spi", number = 2, flags = 4 }
```

`guest = "same"` requests an identity host-PA to guest-IPA mapping.

### 7.3 v10 binary ABI

Each passthrough record contains:

```text
path_offset
flags
host_addr
 guest_addr
size
irq_type
irq_number
irq_flags
```

v10 intentionally supports exactly one MMIO range and zero/one GIC interrupt
per selected node. A later ABI should replace these fixed fields with variable
resource tables.

### 7.4 Arm partial DT generation

For each passthrough entry xloader:

1. resolves `path` in the machine DT;
2. copies the selected subtree under `/passthrough` in a private partial DT;
3. emits:

```dts
xen,reg = <HOST_HI HOST_LO SIZE_HI SIZE_LO GUEST_HI GUEST_LO>;
```

4. overrides `interrupts` from explicit manifest IRQ data when configured;
5. optionally emits `xen,force-assign-without-iommu`;
6. marks the source machine node with `xen,passthrough`;
7. attaches the partial DT to the domain as a
   `multiboot,device-tree` module.

### 7.5 External dependencies

Selected nodes can refer to clocks, resets, IOMMUs, power domains, DMA
controllers, and other nodes by phandle. v10 has no automatic dependency
closure.

Default behavior is fail-closed. If
`strip_external_dependencies = true`, known externally-referenced properties
are omitted from the partial tree. This option is intended for simple test
hardware where those bindings are not required by the guest driver.

## 8. QEMU passthrough acceptance

The canonical v10 QEMU sample assigns the `virt` machine PL031 RTC to
`guest0`:

```text
host path: /pl031@9010000
MMIO:     0x09010000 + 0x1000
guest IPA: identity
IRQ:      GIC SPI 2, level-high
```

The sample explicitly opts into assignment without an IOMMU because the QEMU
sysbus test device is not SMMU protected. This is not a general hardware
policy.

Acceptance occurs inside Linux rather than stopping at DT generation:

1. BusyBox `devmem` reads the PL031 MMIO register;
2. Linux's matching `rtc-pl031` driver is used (built-in or the module from the
   exact cached kernel package);
3. `/sys/class/rtc/.../wakealarm` arms an RTC alarm;
4. `/proc/interrupts` must increase.

Required log markers:

```text
guest0: passthrough pl031 MMIO PASS
guest0: passthrough pl031 IRQ PASS
```

## 9. Nix development model

Nix is the only orchestration layer. The repository has no operational Bash
scripts or Makefile.

Important derivations include:

```text
xbundle
xloader-aarch64
xloader-aarch64-raw
xen-aarch64-raw
sample-initramfs-aarch64
sample-config-aarch64
sample-bundle-aarch64
smoke-sample-aarch64
smoke-passthrough-aarch64
smoke-pic-aarch64
```

The Linux kernel and Xen are consumed as prebuilt inputs; the sample pipeline
does not rebuild them.

## 10. Future passthrough ABI

The next resource model should support arrays such as:

```toml
[[domain.passthrough]]
path = "/device@..."

[[domain.passthrough.mmio]]
host = "..."
guest = "..."
size = "..."

[[domain.passthrough.irq]]
type = "spi"
host = 42
guest = 42
flags = 4
```

and eventually explicit IOMMU stream IDs, MSI/MSI-X, reserved memory, clocks,
resets, and dependency nodes. Those capabilities must remain explicit rather
than being guessed from the host DT.

## 11. Core invariant

> xloader is a boot adapter, not a device-policy engine.

The manifest states the intended hardware grant, xbundle validates and compiles
it, xloader translates it into Xen's boot representation, and Xen enforces the
resulting domain resource mapping.
