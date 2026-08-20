# v8 Validation Status

## What changed

v8 changes the bundle input architecture:

- `xbundle` no longer parses xloader or Xen ELF inputs;
- executable source artifacts are normalized outside xbundle to `*.bin` plus
  `*.meta.toml`;
- Linux AArch64 `Image` remains a raw payload;
- initramfs remains a raw payload;
- `xbundle` still emits the final bootable ELF directly;
- `docs/design.md` is the canonical design document.

## Checks performed in this environment

The available environment does not contain Zig, Nix, or QEMU, therefore full
build/boot acceptance cannot be claimed here.

Performed successfully:

- shell syntax check for every script;
- TOML syntax check for all checked-in sample manifests;
- source check that `src/xbundle.zig` no longer contains the previous generic
  `Elf64` input parser or `xbundle probe` command;
- Zig-source check that no identifier uses the reserved word `align`;
- `normalize-elf.sh` smoke-tested with a locally generated ELF;
- normalization entry offset translated through the containing `PT_LOAD`;
- normalization preserves the full PT_LOAD file-backed span even when
  `objcopy -O binary` trims trailing zero bytes;
- descriptor symbol offset confirmed to remain inside the padded raw loader;
- metadata `memory_size` confirmed to cover the raw file plus trailing BSS.

## Required acceptance on a Nix development machine

```bash
nix develop

make clean
make all
make test

make prepare-sample-aarch64
make check-sample-aarch64
make plan-sample-aarch64
make sample-aarch64
make inspect-sample-aarch64
make smoke-sample-aarch64
make smoke-pic-aarch64
```

Expected final guest markers:

```text
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

`smoke-pic-aarch64` must build two bundles at different loader bases from the
same normalized `build/inputs/aarch64/xloader.bin` and boot both.

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

The final bundle ELF uses the raw file size for `p_filesz` and metadata memory
size for `p_memsz`.
