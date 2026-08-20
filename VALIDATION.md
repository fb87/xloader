# v10 Validation Status

v10 introduces explicit Arm dom0less passthrough resource assignment and a
QEMU PL031 MMIO/IRQ acceptance derivation.

## Static validation completed in this environment

- A/B source tree migration from v9 completed.
- Bundle ABI bumped to v5.
- Passthrough ABI offsets reviewed: path/flags, host IPA, guest IPA, size,
  IRQ type/number/flags.
- TOML sample includes explicit PL031 MMIO and SPI resources.
- `align` is not used as a Zig identifier.
- No operational repository shell scripts or Makefile were introduced.
- Nix remains the orchestration layer.
- Canonical design document updated for v10.

## Runtime acceptance required

This execution environment does not provide Nix, Zig, or QEMU, therefore the
following are **required gates and are not claimed as passed here**:

```bash
nix flake lock
nix build .#xbundle
nix build .#xloader-aarch64
nix build .#sample-bundle-aarch64
nix build .#smoke-sample-aarch64
nix build .#smoke-passthrough-aarch64
nix build .#smoke-pic-aarch64
```

The dedicated passthrough acceptance must contain all of:

```text
xloader: passthrough guest0 <- /pl031@9010000 MMIO
guest0: passthrough pl031 MMIO PASS
guest0: passthrough pl031 IRQ PASS
```

The PL031 IRQ acceptance additionally requires the matching `rtc-pl031`
kernel driver. The cached `aarch64-linux` kernel in this environment is built
without `CONFIG_RTC_DRV_PL031`, so the loader-side passthrough generation and
the guest MMIO grant are validated (MMIO PASS), while IRQ acceptance requires
rebuilding the kernel with `rtc-pl031` enabled.
