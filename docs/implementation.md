> **Historical milestone document.** For the current build and orchestration model, use `docs/design.md` and the flake outputs.

# Implementation status

> **Historical note:** This document describes earlier milestones. The canonical current architecture is [`design.md`](design.md), which uses raw executable inputs plus metadata sidecars and no ELF input parsing in `xbundle`.


## M0

- architecture entry stubs
- freestanding Zig core
- serial hello

## M1

- x86_64 Multiboot1 32-bit entry
- 1 GiB identity map with 2 MiB pages
- transition into long mode
- common `xloader_main(boot_info, boot_magic)` Zig entry
- AArch64 and x86_64 QEMU smoke definitions

## M2

### AArch64 DT preparation

The Arm boot ABI supplies the machine DTB in `x0`.

```text
x0 = source DTB
      |
      v
fdt_check_header
      |
      v
fdt_open_into
      |
      v
256 KiB xloader DT workspace
      |
      +-- ensure /chosen
      +-- set xloader,stage = "m2"
      |
      v
fdt_pack
```

The source DTB is never expanded in place.

### libfdt

The loader compiles upstream libfdt directly from the Nix-provided dtc source.
Only `src/loader/dt.zig` exposes libfdt operations to xloader.

### Freestanding compatibility

libfdt uses a small subset of libc memory/string routines. xloader exports
minimal allocator-free implementations from `src/runtime/minic.zig`.

### x86_64

No DT modification is performed in M2. x86 continues to preserve its
Multiboot state while entering the common 64-bit Zig runtime.

## M3 plan

AArch64 first:

```text
xbundle
  |
  +-- xloader
  +-- Xen image
  |
  v
combined boot artifact
  |
  v
xloader
  |
  +-- copy/patch machine DTB
  +-- Xen boot arguments
  +-- architecture handoff
  |
  v
Xen console
```

x86_64 needs a distinct handoff because Xen's normal MB1/MB2 entry is a
32-bit protocol. xloader must construct the required Multiboot information and
return to the Xen entry state instead of attempting an AArch64-style direct
64-bit jump.
