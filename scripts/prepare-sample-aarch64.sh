#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/inputs/aarch64 build/initramfs-aarch64

eval "$(./scripts/nix-inputs.sh aarch64 env)"
busybox=$(nix build --no-link --max-jobs 0 --print-out-paths '.#packages.aarch64-linux.busybox-input')/bin/busybox

ln -sfn "$LINUX_IMAGE" build/inputs/aarch64/linux

# Normalize executable inputs once, outside xbundle. xbundle consumes only
# raw bytes plus metadata sidecars.
./scripts/normalize-elf.sh \
  --kind loader --arch aarch64 \
  --input build/xloader-aarch64.elf \
  --output build/inputs/aarch64/xloader.bin \
  --metadata build/inputs/aarch64/xloader.meta.toml \
  --descriptor-symbol xbundle_storage

./scripts/normalize-elf.sh \
  --kind xen --arch aarch64 \
  --input "$XEN_IMAGE" \
  --output build/inputs/aarch64/xen.bin \
  --metadata build/inputs/aarch64/xen.meta.toml

root=build/initramfs-aarch64/root
rm -rf "$root"
mkdir -p "$root/bin" "$root/dev" "$root/proc" "$root/sys"
cp "$busybox" "$root/bin/busybox"
ln -s busybox "$root/bin/sh"
cat > "$root/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
domain=unknown
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        xloader.domain=*) domain=${arg#xloader.domain=} ;;
    esac
done
echo "$domain: xloader sample userspace reached"
exec /bin/sh
EOF
chmod +x "$root/init"
(
  cd "$root"
  find . -print0 | sort -z | cpio --null -o --format=newc --quiet
) > build/inputs/aarch64/initramfs.cpio

echo "sample inputs prepared:"
file build/inputs/aarch64/xloader.bin build/inputs/aarch64/xen.bin build/inputs/aarch64/linux build/inputs/aarch64/initramfs.cpio
cat build/inputs/aarch64/xloader.meta.toml
cat build/inputs/aarch64/xen.meta.toml
