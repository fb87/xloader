# Validation — xloader v6

## Static validation completed here

- PASS: guest AArch64 kernels are handled as raw payloads; domain kernel paths are never passed to the ELF parser.
- PASS: `kernel_format = "linux-image"` validates the 64-byte AArch64 Linux Image header and `ARM\x64` magic at offset `0x38`.
- PASS: descriptor kernel size remains the exact input file byte size required by Xen's dom0less module description.
- PASS: multiple-domain descriptor and passthrough path tables are bounded by ABI sanity limits.
- PASS: passthrough paths must be absolute FDT paths.
- PASS: `boot_magic` pointless discard remains removed.
- PASS: no Zig identifier named `align` is used.
- PASS: AArch64 startup uses PC-relative references.
- PASS: x86 32-bit entry has been converted to runtime-base-relative references before its long-mode transition; 64-bit code uses RIP-relative references.
- PASS: shell scripts parse with `bash -n`.

## Runtime validation required

This execution environment has no Nix/Zig/QEMU, so the boot gate must be run in the project dev shell:

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
```

Acceptance is two dom0less guests reaching Linux (`Linux version` appears at least twice).
Do not call v6 boot-validated until that succeeds.
