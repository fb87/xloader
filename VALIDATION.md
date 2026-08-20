# v7 validation status

## Completed in this environment

- PASS: AArch64 entry assembly parses with Clang's AArch64 assembler.
- PASS: AArch64 Xen-entry assembly parses with Clang's AArch64 assembler.
- PASS: x86_64 Multiboot/long-mode assembly parses with Clang's x86_64 assembler.
- PASS: all shell scripts pass `bash -n`.
- PASS: owned Zig files contain no identifier named `align`.
- PASS: the prior `boot_magic` pointless-discard regression is not present.
- PASS: canonical sample contains two distinct domains and distinct `xloader.domain=` identity arguments.
- PASS: v7 source includes host bundle inspection, duplicate-domain/path validation, and per-domain passthrough partial-DT construction.

## Not executable in this environment

This runtime does not provide Nix, Zig, QEMU, or the pinned Nix store inputs. Therefore the following are **acceptance commands**, not claimed-passed results here:

```sh
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

## Required AArch64 acceptance

`make smoke-sample-aarch64` must observe:

```text
xloader: domains 2
xloader: entering Xen
(XEN) ...
guest0: xloader sample userspace reached
guest1: xloader sample userspace reached
```

`make smoke-pic-aarch64` must boot the relocated bundle built from the exact same `xloader-aarch64.elf` and observe both guest userspace markers again.

## Passthrough acceptance level

The v7 runtime creates `multiboot,device-tree` partial FDT modules from configured host-DT paths. The implementation intentionally rejects common external-phandle properties instead of attempting dependency closure.

Hardware resource assignment itself is **not yet claimed**: MMIO host/guest mappings (`xen,reg`), IOMMU ownership, IRQ assignment policy, and force-assignment semantics are deferred to the next passthrough milestone.
