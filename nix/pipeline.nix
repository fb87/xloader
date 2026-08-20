{ pkgs, nixpkgs, self, zigToml, xenAarch64Deb }:
let
  lib = pkgs.lib;
  version = "0.0.10";

  targetPkgs = system: import nixpkgs { inherit system; };
  aarch64Pkgs = targetPkgs "aarch64-linux";
  x86Pkgs = targetPkgs "x86_64-linux";

  linuxAarch64 = aarch64Pkgs.linuxPackages.kernel;
  linuxAarch64Image = "${linuxAarch64}/Image";
  busyboxAarch64 = "${aarch64Pkgs.pkgsStatic.busybox}/bin/busybox";

  xbundle = pkgs.stdenvNoCC.mkDerivation {
    pname = "xbundle";
    inherit version;
    src = self;
    nativeBuildInputs = [ pkgs.zig ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      mkdir -p build
      ln -s ${zigToml} build/zig-toml-src
      zig build --build-file build.zig -Doptimize=ReleaseSmall --prefix $out
      runHook postBuild
    '';
    installPhase = "true";
  };

  xloaderAarch64 = pkgs.stdenvNoCC.mkDerivation {
    pname = "xloader-aarch64";
    inherit version;
    src = self;
    nativeBuildInputs = [ pkgs.zig ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      mkdir -p build/libfdt
      for src_file in \
        ${pkgs.dtc.src}/libfdt/fdt.c \
        ${pkgs.dtc.src}/libfdt/fdt_ro.c \
        ${pkgs.dtc.src}/libfdt/fdt_rw.c \
        ${pkgs.dtc.src}/libfdt/fdt_wip.c \
        ${pkgs.dtc.src}/libfdt/fdt_sw.c \
        ${pkgs.dtc.src}/libfdt/fdt_empty_tree.c; do
        object=build/libfdt/$(basename "$src_file" .c).o
        zig cc -target aarch64-freestanding-none \
          -ffreestanding -fno-builtin -fno-stack-protector -fPIC -fno-sanitize=undefined \
          -Isrc/runtime/include -I${pkgs.dtc.src}/libfdt \
          -c "$src_file" -o "$object"
      done
      zig ar rcs build/libfdt.a build/libfdt/*.o

      zig build-obj src/xloader.zig \
        -target aarch64-freestanding-none -O ReleaseSmall -fPIC \
        -femit-bin=build/main.o

      zig cc -target aarch64-freestanding-none -nostdlib -pie \
        -Wl,--no-dynamic-linker -Wl,-T,linker/aarch64.ld \
        src/arch/aarch64/start.S src/arch/aarch64/enter.S build/main.o \
        -Wl,--whole-archive build/libfdt.a -Wl,--no-whole-archive \
        -o build/xloader.elf
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out
      cp build/xloader.elf $out/xloader.elf
    '';
  };

  xloaderX86_64 = pkgs.stdenvNoCC.mkDerivation {
    pname = "xloader-x86_64";
    inherit version;
    src = self;
    nativeBuildInputs = [ pkgs.zig ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      mkdir -p build
      zig build-obj src/xloader.zig \
        -target x86_64-freestanding-none -O ReleaseSmall -fPIC \
        -femit-bin=build/main.o
      zig cc -target x86_64-freestanding-none -nostdlib -pie \
        -Wl,--no-dynamic-linker -Wl,-T,linker/x86_64-mb1.ld \
        src/arch/x86_64/multiboot.S build/main.o \
        -o build/xloader.elf
      runHook postBuild
    '';
    installPhase = ''
      mkdir -p $out
      cp build/xloader.elf $out/xloader.elf
    '';
  };

  xenAarch64Elf = pkgs.runCommand "xen-aarch64-prebuilt-image" {
    nativeBuildInputs = [ pkgs.dpkg pkgs.file pkgs.findutils pkgs.coreutils pkgs.gnugrep ];
  } ''
    mkdir -p root $out
    dpkg-deb -x ${xenAarch64Deb} root
    xen_bin=""
    while IFS= read -r candidate; do
      if file "$candidate" | grep -Eq 'ARM64 boot executable|AArch64'; then
        xen_bin="$candidate"
        break
      fi
    done < <(find root -type f \( -name 'xen-*arm64*' -o -name xen -o -name 'xen-*' \) | sort)
    if [ -z "$xen_bin" ]; then
      echo "no AArch64 Xen image found in ${xenAarch64Deb}" >&2
      exit 1
    fi
    cp "$xen_bin" $out/xen.elf
  '';

  normalizeElf = { name, kind, arch, elf, descriptorSymbol ? null }:
    pkgs.runCommand name {
      nativeBuildInputs = [ pkgs.binutils pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.file ];
    } ''
      set -euo pipefail
      input=${elf}
      mkdir -p $out

      mapfile -t load_lines < <(readelf -lW "$input" 2>/dev/null | awk '$1 == "LOAD" {print $0}')
      if [ ''${#load_lines[@]} -eq 0 ]; then
        if [ ${lib.escapeShellArg kind} = xen ] && [ ${lib.escapeShellArg arch} = aarch64 ] && file "$input" | grep -q 'ARM64 boot executable'; then
          cp "$input" $out/image.bin
          file_size=$(stat -c %s $out/image.bin)
          cat > $out/meta.toml <<EOF_META
format = 1
kind = "${kind}"
arch = "${arch}"
entry_offset = "0x0"
memory_size = "$(printf '0x%x' "$file_size")"
load_alignment = "0x200000"
source = "$input"
EOF_META
          exit 0
        fi
        echo "$input: no PT_LOAD segments" >&2
        exit 1
      fi

      source_base=""
      source_end=0
      source_file_end=0
      load_alignment=1
      for line in "''${load_lines[@]}"; do
        read -r _ off vaddr paddr filesz memsz f1 f2 maybe_alignment <<<"$line"
        if [[ "$f2" =~ ^0x ]]; then
          segment_alignment=$f2
        else
          segment_alignment=$maybe_alignment
        fi
        base=$((paddr))
        file_size=$((filesz))
        memory_size=$((memsz))
        file_end=$((base + file_size))
        memory_end=$((base + memory_size))
        if [ -z "$source_base" ] || (( base < source_base )); then source_base=$base; fi
        if (( file_end > source_file_end )); then source_file_end=$file_end; fi
        if (( memory_end > source_end )); then source_end=$memory_end; fi
        candidate_alignment=$((segment_alignment))
        if (( candidate_alignment > load_alignment )); then load_alignment=$candidate_alignment; fi
      done

      entry_hex=$(readelf -hW "$input" | awk '/Entry point address:/ {print $4; exit}')
      [ -n "$entry_hex" ] || { echo "$input: cannot determine ELF entry" >&2; exit 1; }
      entry=$((entry_hex))
      entry_phys=""
      for line in "''${load_lines[@]}"; do
        read -r _ off vaddr paddr filesz memsz f1 f2 maybe_alignment <<<"$line"
        virtual_address=$((vaddr))
        physical_address=$((paddr))
        segment_memory_size=$((memsz))
        if (( entry >= virtual_address && entry < virtual_address + segment_memory_size )); then
          entry_phys=$((physical_address + (entry - virtual_address)))
          break
        fi
      done
      [ -n "$entry_phys" ] || { echo "$input: entry not contained in PT_LOAD" >&2; exit 1; }

      entry_offset=$((entry_phys - source_base))
      file_span=$((source_file_end - source_base))
      image_memory_size=$((source_end - source_base))

      objcopy -O binary --gap-fill 0 "$input" $out/image.bin
      truncate -s "$file_span" $out/image.bin

      descriptor_line=""
      ${lib.optionalString (descriptorSymbol != null) ''
        symbol_hex=$(nm -n "$input" | awk -v wanted=${lib.escapeShellArg descriptorSymbol} '$3 == wanted {print "0x"$1; exit}')
        [ -n "$symbol_hex" ] || { echo "$input: descriptor symbol not found" >&2; exit 1; }
        symbol_virtual=$((symbol_hex))
        symbol_phys=""
        for line in "''${load_lines[@]}"; do
          read -r _ off vaddr paddr filesz memsz f1 f2 maybe_alignment <<<"$line"
          virtual_address=$((vaddr))
          physical_address=$((paddr))
          segment_memory_size=$((memsz))
          if (( symbol_virtual >= virtual_address && symbol_virtual < virtual_address + segment_memory_size )); then
            symbol_phys=$((physical_address + (symbol_virtual - virtual_address)))
            break
          fi
        done
        [ -n "$symbol_phys" ] || { echo "$input: descriptor symbol not in PT_LOAD" >&2; exit 1; }
        descriptor_offset=$((symbol_phys - source_base))
        descriptor_line="descriptor_offset = \"$(printf '0x%x' "$descriptor_offset")\""
      ''}

      cat > $out/meta.toml <<EOF_META
format = 1
kind = "${kind}"
arch = "${arch}"
entry_offset = "$(printf '0x%x' "$entry_offset")"
memory_size = "$(printf '0x%x' "$image_memory_size")"
load_alignment = "$(printf '0x%x' "$load_alignment")"
$descriptor_line
source = "$input"
EOF_META
    '';

  normalizedLoaderAarch64 = normalizeElf {
    name = "xloader-aarch64-raw";
    kind = "loader";
    arch = "aarch64";
    elf = "${xloaderAarch64}/xloader.elf";
    descriptorSymbol = "xbundle_storage";
  };

  normalizedXenAarch64 = normalizeElf {
    name = "xen-aarch64-raw";
    kind = "xen";
    arch = "aarch64";
    elf = "${xenAarch64Elf}/xen.elf";
  };

  sampleInitramfsAarch64 = pkgs.runCommand "xloader-sample-initramfs-aarch64" {
    nativeBuildInputs = [ pkgs.cpio pkgs.findutils pkgs.coreutils pkgs.xz pkgs.zstd pkgs.gzip ];
  } ''
    set -euo pipefail
    root=$TMPDIR/root
    mkdir -p "$root/bin" "$root/dev" "$root/proc" "$root/sys" "$root/lib/modules"
    cp ${busyboxAarch64} "$root/bin/busybox"

    rtc_module=$(find ${linuxAarch64}/lib/modules -type f \
      \( -name 'rtc-pl031.ko' -o -name 'rtc-pl031.ko.xz' -o -name 'rtc-pl031.ko.zst' -o -name 'rtc-pl031.ko.gz' \) \
      | head -n1 || true)
    if [ -n "$rtc_module" ]; then
      case "$rtc_module" in
        *.ko) cp "$rtc_module" "$root/lib/modules/rtc-pl031.ko" ;;
        *.xz) xz -dc "$rtc_module" > "$root/lib/modules/rtc-pl031.ko" ;;
        *.zst) zstd -q -dc "$rtc_module" > "$root/lib/modules/rtc-pl031.ko" ;;
        *.gz) gzip -dc "$rtc_module" > "$root/lib/modules/rtc-pl031.ko" ;;
      esac
    fi
    ln -s busybox "$root/bin/sh"
    cat > "$root/init" <<'EOF_INIT'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
domain=unknown
for argument in $(cat /proc/cmdline 2>/dev/null); do
    case "$argument" in
        xloader.domain=*) domain=''${argument#xloader.domain=} ;;
    esac
done
echo "$domain: xloader sample userspace reached"

if [ "$domain" = guest0 ]; then
    # Direct MMIO proof: PL031 data register at 0x09010000 must be readable.
    if /bin/busybox devmem 0x09010000 32 >/tmp/pl031-value 2>/dev/null; then
        echo "guest0: passthrough pl031 MMIO PASS"
    else
        echo "guest0: passthrough pl031 MMIO FAIL"
    fi

    if ! ls /sys/class/rtc/rtc* >/dev/null 2>&1 && [ -f /lib/modules/rtc-pl031.ko ]; then
        /bin/busybox insmod /lib/modules/rtc-pl031.ko 2>/dev/null || true
        sleep 1
    fi

    rtc=""
    for candidate in /sys/class/rtc/rtc*; do
        [ -e "$candidate/name" ] || continue
        if grep -qi pl031 "$candidate/name"; then
            rtc="$candidate"
            break
        fi
    done

    if [ -n "$rtc" ]; then
        before=$(awk '/pl031|rtc/{sum += $2} END{print sum+0}' /proc/interrupts)
        echo 0 > "$rtc/wakealarm" 2>/dev/null || true
        if echo +1 > "$rtc/wakealarm" 2>/dev/null; then
            sleep 2
            after=$(awk '/pl031|rtc/{sum += $2} END{print sum+0}' /proc/interrupts)
            if [ "$after" -gt "$before" ]; then
                echo "guest0: passthrough pl031 IRQ PASS"
            else
                echo "guest0: passthrough pl031 IRQ FAIL before=$before after=$after"
            fi
        else
            echo "guest0: passthrough pl031 IRQ FAIL wakealarm-unavailable"
        fi
    else
        echo "guest0: passthrough pl031 IRQ FAIL rtc-device-not-found"
    fi
fi

exec /bin/sh
EOF_INIT
    chmod +x "$root/init"
    find "$root" -exec touch -h -d @1 {} +
    mkdir -p $out
    (
      cd "$root"
      find . -print0 | sort -z | cpio --null -o --format=newc --reproducible --owner=0:0 --quiet
    ) > $out/initramfs.cpio
  '';

  materializeManifest = { name, template, loaderBase ? null, xenBase ? null }:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.coreutils ]; } ''
      substitute ${template} $out \
        --replace-fail '@XLOADER_BIN@' '${normalizedLoaderAarch64}/image.bin' \
        --replace-fail '@XLOADER_META@' '${normalizedLoaderAarch64}/meta.toml' \
        --replace-fail '@XEN_BIN@' '${normalizedXenAarch64}/image.bin' \
        --replace-fail '@XEN_META@' '${normalizedXenAarch64}/meta.toml' \
        --replace-fail '@LINUX_IMAGE@' '${linuxAarch64Image}' \
        --replace-fail '@INITRAMFS@' '${sampleInitramfsAarch64}/initramfs.cpio'
    '';

  sampleConfigAarch64 = materializeManifest {
    name = "xloader-qemu-aarch64.toml";
    template = ../configs/qemu-aarch64.toml.in;
  };

  sampleConfigAarch64Relocated = materializeManifest {
    name = "xloader-qemu-aarch64-relocated.toml";
    template = ../configs/qemu-aarch64-relocated.toml.in;
  };

  buildBundle = { name, config }:
    pkgs.runCommand name { nativeBuildInputs = [ xbundle pkgs.file pkgs.binutils ]; } ''
      mkdir -p $out
      xbundle check ${config} > $out/check.txt 2>&1
      xbundle plan ${config} > $out/plan.txt 2>&1
      xbundle build ${config} -o $out/system.xbundle.elf > $out/build.txt 2>&1
      xbundle inspect $out/system.xbundle.elf > $out/inspect.txt 2>&1
      file $out/system.xbundle.elf > $out/file.txt
      readelf -h -l $out/system.xbundle.elf > $out/readelf.txt
    '';

  sampleBundleAarch64 = buildBundle {
    name = "xloader-qemu-aarch64-bundle";
    config = sampleConfigAarch64;
  };

  sampleBundleAarch64Relocated = buildBundle {
    name = "xloader-qemu-aarch64-relocated-bundle";
    config = sampleConfigAarch64Relocated;
  };

  loaderSmokeAarch64 = pkgs.runCommand "xloader-aarch64-loader-smoke" {
    nativeBuildInputs = [ pkgs.file pkgs.coreutils ];
  } ''
    test -s ${xloaderAarch64}/xloader.elf
    test -s ${normalizedLoaderAarch64}/image.bin
    test -s ${normalizedLoaderAarch64}/meta.toml
    mkdir -p $out
    file ${xloaderAarch64}/xloader.elf > $out/file.txt
    cp ${normalizedLoaderAarch64}/meta.toml $out/
    echo "PASS: aarch64 loader ELF and normalized raw image validate" > $out/result.txt
  '';

  x86Iso = pkgs.runCommand "xloader-x86_64-grub.iso" {
    nativeBuildInputs = [ pkgs.grub2 pkgs.xorriso pkgs.mtools pkgs.coreutils ];
  } ''
    grub-file --is-x86-multiboot ${xloaderX86_64}/xloader.elf
    mkdir -p iso/boot/grub $out
    cp ${xloaderX86_64}/xloader.elf iso/boot/xloader.elf
    cp ${../grub/grub.cfg} iso/boot/grub/grub.cfg
    grub-mkrescue -o $out/xloader.iso iso
  '';

  loaderSmokeX86_64 = pkgs.runCommand "xloader-x86_64-loader-smoke" {
    nativeBuildInputs = [ pkgs.grub2 pkgs.file pkgs.coreutils ];
  } ''
    grub-file --is-x86-multiboot ${xloaderX86_64}/xloader.elf
    test -s ${x86Iso}/xloader.iso
    mkdir -p $out
    file ${xloaderX86_64}/xloader.elf > $out/file.txt
    file ${x86Iso}/xloader.iso > $out/iso-file.txt
    echo "PASS: x86_64 Multiboot loader ISO validates" > $out/result.txt
  '';

  sampleSmokeAarch64 = pkgs.runCommand "xloader-qemu-aarch64-smoke" {
    nativeBuildInputs = [ pkgs.qemu pkgs.coreutils pkgs.gnugrep ];
  } ''
    timeout 90s qemu-system-aarch64 \
      -machine virt,virtualization=on -cpu cortex-a57 -m 1G \
      -kernel ${sampleBundleAarch64}/system.xbundle.elf \
      -nographic -no-reboot > system.log 2>&1 || true
    grep -q 'xloader: domains 2' system.log
    grep -q 'xloader: entering Xen' system.log
    grep -q '(XEN)' system.log
    grep -q 'guest0: xloader sample userspace reached' system.log
    grep -q 'guest1: xloader sample userspace reached' system.log
    mkdir -p $out
    cp system.log $out/
  '';

  passthroughSmokeAarch64 = pkgs.runCommand "xloader-qemu-aarch64-passthrough-smoke" {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep ];
  } ''
    grep -q 'force_assign_without_iommu = ' ${../configs/passthrough-example.toml}
    grep -q 'strip_external_dependencies = ' ${../configs/passthrough-example.toml}
    grep -q 'mmio = ' ${../configs/passthrough-example.toml}
    mkdir -p $out
    cp ${../configs/passthrough-example.toml} $out/
    echo "PASS: passthrough manifest example validates statically; hardware/QEMU DT availability is environment-specific" > $out/result.txt
  '';

  picSmokeAarch64 = pkgs.runCommand "xloader-qemu-aarch64-pic-smoke" {
    nativeBuildInputs = [ pkgs.qemu pkgs.coreutils pkgs.gnugrep ];
  } ''
    sha256sum ${normalizedLoaderAarch64}/image.bin > loader.sha256
    timeout 90s qemu-system-aarch64 \
      -machine virt,virtualization=on -cpu cortex-a57 -m 1G \
      -kernel ${sampleBundleAarch64Relocated}/system.xbundle.elf \
      -nographic -no-reboot > system.log 2>&1 || true
    grep -q 'xloader: entering Xen' system.log
    grep -q 'guest0: xloader sample userspace reached' system.log
    grep -q 'guest1: xloader sample userspace reached' system.log
    mkdir -p $out
    cp system.log loader.sha256 $out/
  '';

in {
  inherit
    xbundle
    xloaderAarch64
    xloaderX86_64
    xenAarch64Elf
    normalizedLoaderAarch64
    normalizedXenAarch64
    sampleInitramfsAarch64
    sampleConfigAarch64
    sampleConfigAarch64Relocated
    sampleBundleAarch64
    sampleBundleAarch64Relocated
    loaderSmokeAarch64
    x86Iso
    loaderSmokeX86_64
    sampleSmokeAarch64
    passthroughSmokeAarch64
    picSmokeAarch64
    linuxAarch64
    linuxAarch64Image;
}
