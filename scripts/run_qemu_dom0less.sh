#!/usr/bin/env bash
set -euo pipefail

: "${QEMU:=qemu-system-aarch64}"
: "${BUNDLE:?BUNDLE is required}"
: "${LOG_DIR:=build/logs}"
: "${QEMU_MEM:=1G}"
: "${QEMU_CPU:=cortex-a57}"
: "${QEMU_TIMEOUT:=120}"

mkdir -p "${LOG_DIR}"
combined="${LOG_DIR}/qemu-combined.log"
xen_log="${LOG_DIR}/xen.log"
domain_log="${LOG_DIR}/domains.log"
summary="${LOG_DIR}/summary.log"

rm -f "${combined}" "${xen_log}" "${domain_log}" "${summary}"

set +e
timeout "${QEMU_TIMEOUT}" "${QEMU}" \
  -M virt,virtualization=on,secure=off,gic-version=3 \
  -cpu "${QEMU_CPU}" \
  -m "${QEMU_MEM}" \
  -kernel "${BUNDLE}" \
  -nographic \
  -no-reboot \
  -serial mon:stdio \
  2>&1 | tee "${combined}"
status=${PIPESTATUS[0]}
set -e

grep '^(XEN)' "${combined}" > "${xen_log}" || true
grep 'XLOADER_DOMAIN_' "${combined}" > "${domain_log}" || true

{
  printf 'qemu_status=%s\n' "${status}"
  printf 'combined_log=%s\n' "${combined}"
  printf 'xen_log=%s\n' "${xen_log}"
  printf 'domain_log=%s\n' "${domain_log}"
} > "${summary}"

grep -q 'xloader: jumping to Xen' "${combined}"
grep -q '^(XEN)' "${combined}"
grep -q 'CMDLINE\[.*domain@0 .*xloader.domain=domu0' "${combined}"
grep -q 'CMDLINE\[.*domain@1 .*xloader.domain=domu1' "${combined}"
grep -q 'XLOADER_DOMAIN_READY unknown' "${combined}"
grep -q 'DOM2: XLOADER_DOMAIN_READY unknown' "${combined}"
grep -q '~ #' "${combined}"
grep -q 'DOM2: XLOADER_DOMAIN_INTERACTIVE unknown console=ttyAMA0' "${combined}"

printf 'dom0less smoke test passed; logs in %s\n' "${LOG_DIR}"
