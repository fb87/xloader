#!/usr/bin/env bash
set -euo pipefail
exec qemu-system-aarch64 \
  -machine virt -cpu cortex-a57 -m 256M \
  -kernel build/xloader-aarch64.elf \
  -nographic -no-reboot
