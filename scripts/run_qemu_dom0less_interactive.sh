#!/usr/bin/env bash
set -euo pipefail

: "${QEMU:=qemu-system-aarch64}"
: "${BUNDLE:?BUNDLE is required}"
: "${LOG_DIR:=build/logs}"
: "${QEMU_MEM:=1G}"
: "${QEMU_CPU:=cortex-a57}"
: "${QEMU_BASE:=0x40000000}"

case "${BUNDLE}" in
  *.elf) KERNEL_ARG=("-kernel" "${BUNDLE}") ;;
  *)     KERNEL_ARG=("-device" "loader,file=${BUNDLE},addr=${QEMU_BASE},cpu-num=0,force-raw=on") ;;
esac

mkdir -p "${LOG_DIR}"
combined="${LOG_DIR}/qemu-interactive.log"

rm -f "${combined}"

printf 'starting interactive dom0less QEMU; log: %s\n' "${combined}"
printf 'Xen serial input starts on DOM1; type Ctrl-a three times to switch Xen console input.\n'

"${QEMU}" \
  -M virt,virtualization=on,secure=off,gic-version=3 \
  -cpu "${QEMU_CPU}" \
  -m "${QEMU_MEM}" \
  "${KERNEL_ARG[@]}" \
  -nographic \
  -no-reboot \
  -serial mon:stdio \
  2>&1 | tee "${combined}"
