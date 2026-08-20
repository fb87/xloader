{
  description = "xloader - minimal Xen bundle loader and host packer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";
  inputs.zig-toml.url = "github:sam701/zig-toml/zig-0.16";
  inputs.zig-toml.flake = false;

  outputs = { self, nixpkgs, zig-toml }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs { inherit system; }));

      targetPkgs = nixpkgs.lib.genAttrs systems (system:
        import nixpkgs { inherit system; });

      mkBundleInputInfo = system:
        let
          pkgs = targetPkgs.${system};
          kernel = pkgs.linuxPackages.kernel;
          linuxTarget = if (system == "x86_64-linux") then "bzImage" else "Image";
          common = {
            inherit system linuxTarget;
            linuxDrv = kernel.drvPath;
            linuxStore = kernel.outPath;
            linuxPath = "${kernel}/${linuxTarget}";
            linuxVersion = kernel.version;
            busyboxStore = pkgs.pkgsStatic.busybox.outPath;
            busyboxPath = "${pkgs.pkgsStatic.busybox}/bin/busybox";
          };
        in common // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          xenDrv = pkgs.xen.drvPath;
          xenStore = pkgs.xen.boot.outPath;
          xenPath = "${pkgs.xen.boot}/${pkgs.xen.multiboot}";
          xenVersion = pkgs.xen.version;
        };
    in {
      bundleInputs = nixpkgs.lib.genAttrs systems mkBundleInputInfo;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            zig
            gnumake
            qemu
            dtc
            grub2
            xorriso
            file
            binutils
            coreutils
            gnugrep
            gnused
            curl
            dpkg
            cpio
            nix
          ];

          shellHook = ''
            export LIBFDT_SRC=${pkgs.dtc.src}/libfdt
            export ZIG_TOML_SRC=${zig-toml}
            echo "xloader dev shell"
            echo "  nixpkgs: nixos-26.05-small"
            echo "  Zig:     $(zig version)"
            echo "  libfdt:  $LIBFDT_SRC"
            echo "  zig-toml: $ZIG_TOML_SRC"
            echo ""
            echo "Build loaders/tools: make all"
            echo "AArch64 cached/prebuilt inputs: make nix-inputs-aarch64"
            echo "AArch64 sample bundle: make sample-aarch64"
          '';
        };
      });

      packages = forAllSystems (pkgs:
        let kernel = pkgs.linuxPackages.kernel;
        in {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "xloader";
            version = "0.0.8";
            src = self;
            nativeBuildInputs = with pkgs; [
              zig gnumake file binutils dtc grub2 xorriso qemu cpio
            ];
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export LIBFDT_SRC=${pkgs.dtc.src}/libfdt
            export ZIG_TOML_SRC=${zig-toml}
              make all
              make test
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/xloader
              cp build/xbundle $out/bin/
              cp build/xloader-aarch64.elf $out/share/xloader/
              cp build/xloader-x86_64-mb1.elf $out/share/xloader/
              runHook postInstall
            '';
          };

          linux-input = kernel;
          busybox-input = pkgs.pkgsStatic.busybox;
        } // nixpkgs.lib.optionalAttrs (pkgs.system == "x86_64-linux") {
          xen-input = pkgs.xen;
          xen-boot-input = pkgs.xen.boot;
        });

      checks = forAllSystems (pkgs: {
        build = self.packages.${pkgs.system}.default;
      });
    };
}
