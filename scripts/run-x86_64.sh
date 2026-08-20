#!/usr/bin/env bash
set -euo pipefail
make x86-iso
exec qemu-system-x86_64 \
  -machine q35 -m 256M \
  -cdrom build/xloader-x86_64.iso -boot d \
  -display none -serial stdio -no-reboot
