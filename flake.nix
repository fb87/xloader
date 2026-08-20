{
  description = "xloader - Nix-native Xen bundle pipeline";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";

    zig-toml = {
      url = "github:sam701/zig-toml/zig-0.16";
      flake = false;
    };

    # Prebuilt ARM64 Xen.  The flake lock records the exact fetched content;
    # xloader never builds Xen from source as part of the sample pipeline.
    xen-aarch64-deb = {
      url = "file+https://mirrors.qlu.edu.cn/ubuntu/ubuntu/pool/universe/x/xen/xen-hypervisor-4.20-arm64_4.20.2%2B7-g1badcf5035-2build2_arm64.deb";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, zig-toml, xen-aarch64-deb, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          p = import ./nix/pipeline.nix {
            inherit pkgs nixpkgs self;
            zigToml = zig-toml;
            xenAarch64Deb = xen-aarch64-deb;
          };
        in {
          default = p.xbundle;
          xbundle = p.xbundle;
          xloader-aarch64 = p.xloaderAarch64;
          xloader-x86_64 = p.xloaderX86_64;
          xloader-x86_64-iso = p.x86Iso;

          xen-aarch64-elf = p.xenAarch64Elf;
          xloader-aarch64-raw = p.normalizedLoaderAarch64;
          xen-aarch64-raw = p.normalizedXenAarch64;
          sample-initramfs-aarch64 = p.sampleInitramfsAarch64;
          sample-config-aarch64 = p.sampleConfigAarch64;
          sample-config-aarch64-relocated = p.sampleConfigAarch64Relocated;
          sample-bundle-aarch64 = p.sampleBundleAarch64;
          sample-bundle-aarch64-relocated = p.sampleBundleAarch64Relocated;

          smoke-loader-aarch64 = p.loaderSmokeAarch64;
          smoke-loader-x86_64 = p.loaderSmokeX86_64;
          smoke-sample-aarch64 = p.sampleSmokeAarch64;
          smoke-pic-aarch64 = p.picSmokeAarch64;
        });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          p = import ./nix/pipeline.nix {
            inherit pkgs nixpkgs self;
            zigToml = zig-toml;
            xenAarch64Deb = xen-aarch64-deb;
          };
        in {
          xbundle = p.xbundle;
          xloader-aarch64 = p.xloaderAarch64;
          xloader-x86_64 = p.xloaderX86_64;
          loader-smoke-aarch64 = p.loaderSmokeAarch64;
          loader-smoke-x86_64 = p.loaderSmokeX86_64;
          sample-bundle-aarch64 = p.sampleBundleAarch64;
        });

      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ nix zig qemu file binutils ];
            shellHook = ''
              echo "xloader v9 Nix-native development shell"
              echo "Build host tool:        nix build .#xbundle"
              echo "Build AArch64 loader:   nix build .#xloader-aarch64"
              echo "Materialize sample:     nix build .#sample-config-aarch64"
              echo "Build bootable sample:  nix build .#sample-bundle-aarch64"
              echo "Run Xen/Linux smoke:    nix build .#smoke-sample-aarch64"
            '';
          };
        });
    };
}
