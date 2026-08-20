# Binary inputs and Nix store policy

The project avoids rebuilding Xen and Linux while iterating on xloader.

## Linux

Both target architectures use the kernel derivation from the pinned
`nixos-26.05-small` input. `scripts/nix-inputs.sh` resolves the kernel output
name (`Image`/`bzImage`) from Nixpkgs rather than hard-coding it.

## Xen x86_64

The x86_64 Xen boot output is taken from `pkgs.xen.boot`. Fetch commands use
`nix build --max-jobs 0`, so a missing binary substitute is an error rather
than an unexpected local Xen build.

## Xen AArch64

NixOS currently restricts its Xen integration to x86_64. Therefore we do not
claim `pkgs.xen` is a reliable cached AArch64 source.

For QEMU Arm development:

```bash
make nix-xen-aarch64
```

The helper:

1. downloads Ubuntu 26.04's prebuilt Xen 4.20 ARM64 `.deb` with
   `nix store prefetch-file`;
2. extracts it with `dpkg-deb`;
3. finds the AArch64 Xen ELF;
4. imports that exact binary with `nix store add-file`;
5. records its store path in `build/xen-aarch64.storepath`.

No Xen compilation occurs.

The URL can be overridden:

```bash
XEN_AARCH64_DEB_URL=https://... make nix-xen-aarch64
```
