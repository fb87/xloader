# v9 Validation Status

## What changed

v9 replaces repository shell-script and Makefile orchestration with a Nix
build graph.

Nix derivations now own:

- xbundle build;
- AArch64 and x86_64 xloader builds;
- extraction of the prebuilt AArch64 Xen ELF;
- ELF-to-raw normalization;
- static sample initramfs generation;
- bootable TOML manifest materialization;
- bundle check/plan/build/inspect;
- GRUB ISO construction;
- loader QEMU smokes;
- Xen + two-DomU QEMU smoke;
- PIC relocation smoke.

`docs/design.md` is updated to make this the canonical pipeline.

## Static checks performed in this environment

This execution environment does not contain Nix, Zig, or QEMU, therefore Nix
evaluation and full boot acceptance cannot be claimed here.

Performed here:

- repository `scripts/` directory removed;
- repository Makefile removed;
- checked-in operational flow contains no `.sh` files;
- active README/design/Nix-input documentation converted to `nix build` flow;
- GRUB ISO path checked against the Nix-installed x86 loader filename;
- all checked-in AArch64 TOML templates contain only Nix substitution
  placeholders for external artifacts;
- `boot_magic` pointless discard remains absent;
- Zig identifiers do not use `align` as a variable/field name;
- raw-input xbundle architecture remains unchanged.

## Required acceptance on a Nix machine

First lock the inputs if this checkout does not yet have `flake.lock`:

```bash
nix flake lock
```

Build the core graph:

```bash
nix build .#xbundle
nix build .#xloader-aarch64
nix build .#xloader-x86_64
nix build .#xloader-aarch64-raw
nix build .#xen-aarch64-raw
```

Materialize and inspect the concrete bootable configuration:

```bash
nix build .#sample-config-aarch64
cat result
```

Build the system bundle:

```bash
nix build .#sample-bundle-aarch64
cat result/inspect.txt
```

Run acceptance derivations:

```bash
nix build .#smoke-loader-aarch64
nix build .#smoke-loader-x86_64
nix build .#smoke-sample-aarch64
nix build .#smoke-pic-aarch64
```

Expected full-system guest markers:

```text
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

Finally:

```bash
nix flake check
```

## Important normalization invariant

For a normalized executable:

```text
raw file size <= metadata.memory_size
entry_offset < metadata.memory_size
```

For xloader specifically:

```text
descriptor_offset + 64 KiB <= raw file size
```

The final bundle ELF uses raw file size for `p_filesz` and metadata memory size
for `p_memsz`.
