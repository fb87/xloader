#!/usr/bin/env bash
set -euo pipefail

: "${BUSYBOX_SRC:?BUSYBOX_SRC is required}"
: "${OUT_DIR:?OUT_DIR is required}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"

build_dir="${OUT_DIR}/busybox-build"
rootfs="${OUT_DIR}/rootfs"
initramfs="${OUT_DIR}/initramfs.cpio"
jobs="${PARALLEL_JOBS:-${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}}"

mkdir -p "${build_dir}" "${rootfs}"

make -C "${BUSYBOX_SRC}" O="${build_dir}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" defconfig
if grep -q '^# CONFIG_STATIC is not set' "${build_dir}/.config"; then
  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "${build_dir}/.config"
elif ! grep -q '^CONFIG_STATIC=y' "${build_dir}/.config"; then
  printf '\nCONFIG_STATIC=y\n' >> "${build_dir}/.config"
fi
set +o pipefail
yes "" | make -C "${BUSYBOX_SRC}" O="${build_dir}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" oldconfig
set -o pipefail
make -C "${BUSYBOX_SRC}" O="${build_dir}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" -j"${jobs}" busybox
make -C "${BUSYBOX_SRC}" O="${build_dir}" ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" install CONFIG_PREFIX="${rootfs}"

mkdir -p "${rootfs}/proc" "${rootfs}/sys" "${rootfs}/dev" "${rootfs}/tmp"
cat > "${rootfs}/init" <<'INIT'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

console=/dev/ttyAMA0
[ -e "${console}" ] || console=/dev/hvc0
console_name="${console#/dev/}"

echo "XLOADER_DOMAIN_READY" >"${console}" 2>/dev/null || true
for pt in /proc/device-tree/passthrough/*; do
  [ -d "$pt" ] && echo "XLOADER_PASSTHROUGH_DEV=${pt##*/}" >"${console}" 2>/dev/null || true
done
echo "XLOADER_DOMAIN_INTERACTIVE console=${console_name}" >"${console}" 2>/dev/null || true
(setsid sh -c 'exec sh </dev/ttyAMA0 >/dev/ttyAMA0 2>&1' 2>/dev/null || \
  setsid sh -c 'exec sh </dev/hvc0 >/dev/hvc0 2>&1') &

while true; do
  sleep 60
done
INIT
chmod +x "${rootfs}/init"

(cd "${rootfs}" && find . -print | LC_ALL=C sort | cpio --reproducible -H newc -o) > "${initramfs}"
printf 'wrote %s\n' "${initramfs}"
