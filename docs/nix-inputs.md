# Binary inputs and Nix-store policy

The project uses Nix derivations for all external boot inputs and intermediate
artifacts. There are no repository fetch/preparation scripts.

## Linux AArch64

The sample kernel comes from the `aarch64-linux` package set of the pinned
`nixos-26.05-small` input:

```nix
linuxAarch64 = aarch64Pkgs.linuxPackages.kernel;
linuxImage = "${linuxAarch64}/${linuxAarch64.target}";
```

The kernel output is consumed directly as the raw Arm64 `Image`. `xbundle`
does not parse it as ELF.

## Xen AArch64

The ARM64 Xen sample is a prebuilt distribution package declared as a flake
`file+https` input. Once `flake.lock` exists, Nix pins the exact input content.

The derivation graph is:

```text
xen-aarch64-deb flake input
        |
        v
xen-aarch64-elf
  dpkg-deb extraction
  architecture validation
        |
        v
xen-aarch64-raw
  readelf/nm/objcopy normalization
        |
        +-- image.bin
        `-- meta.toml
```

No Xen source build occurs in this path.

Build the normalized Xen input with:

```bash
nix build .#xen-aarch64-raw
```

## Input inspection

Each normalization result is a normal Nix output and can be inspected without
running the rest of the pipeline:

```bash
nix build .#xloader-aarch64-raw
cat result/meta.toml

nix build .#xen-aarch64-raw
cat result/meta.toml
```

## Cache behavior

Nix naturally reuses store objects and configured binary caches. The project
source no longer maintains mutable `build/*.storepath` files or symlink farms.
Inputs are connected through derivation dependencies instead.
