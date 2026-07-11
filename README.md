# xloader

`xloader` is a minimal ARM64 boot stub that patches the QEMU virt DTB at
runtime (adds Xen bootargs, domU domain nodes, and passthrough device nodes)
then jumps to Xen in dom0less mode.

## Quick Start

```bash
# 1. Build the loader stub
cmake -S . -B build
cmake --build build --target xloader
# → build/xloader.elf, build/xloader.bin

# 2. Create a bundle.toml with your artifacts
cat > bundle.toml << 'EOF'
[xloader]
elf = "build/xloader.elf"

[xen]
path = "path/to/xen"

[[domains]]
type = "domU"
kernel = "path/to/Image"
initrd = "path/to/initramfs.cpio"
memory_kb = 131072
cmdline = "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init"
passthrough = []

[[domains]]
type = "domU"
kernel = "path/to/Image"
initrd = "path/to/initramfs.cpio"
memory_kb = 131072
cmdline = "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init"
passthrough = []
EOF

# 3. Generate bundle.elf (standalone, no cmake needed)
bundle.py --config bundle.toml -o bundle.elf

# 4. Run
qemu-system-aarch64 -M virt,virtualization=on,secure=off,gic-version=3 \
  -cpu cortex-a57 -m 1G -kernel bundle.elf \
  -nographic -no-reboot -serial mon:stdio
```

Controls: type `Ctrl-a` three times to switch between Xen and domain consoles.
`Ctrl-a x` to exit.

## Architecture

```
xloader/                  # Core project
├── CMakeLists.txt         # Builds xloader.elf + release tarball
├── bundle.py              # Standalone bundler (no compiler needed)
├── xloader.lds            # Linker script for the loader stub
├── src/                   # Loader source (start.S, main.c, string.c)
├── include/               # bundle.h (descriptor struct)
└── scripts/               # QEMU runner scripts
```

**Build flow:**

```
xloader.elf  ──objcopy──→  xloader.bin     (cmake target)
xloader.elf + bundle.py + bundle.toml → bundle.elf   (bundler)
bundle.elf  ──QEMU -kernel──→  boots Xen + domains
```

## Project Structure

### Core Build (`cmake -S . -B build`)

Only builds the loader stub — no external dependencies:

```bash
cmake --build build --target xloader        # → build/xloader.elf
cmake --build build --target release        # → build/release/xloader-bundle.tar.gz
```

The release tarball packages `xloader.elf`, `bundle.py`, QEMU scripts, and README.
Users take these files and supply their own `bundle.toml` with `xen`, kernel,
initrd paths.

### Standalone Bundler (`bundle.py`)

Reads `bundle.toml` and produces `bundle.elf` with correct ELF PT_LOAD segments
for each payload. No toolchain needed — uses `struct.pack` for ELF headers.

```bash
bundle.py --config bundle.toml -o bundle.elf
```

### Test Subproject (`test/` — optional)

Fetches and builds Xen, Linux, musl, BusyBox from pinned release tarballs, then
runs the full integration test:

```bash
cmake -S test -B build/test -DXLOADER_FETCH_EXTERNALS=ON
cmake --build build/test --target run-qemu-test
```

## Domain Configuration (`bundle.toml`)

```toml
[xloader]
elf = "build/xloader.elf"

[xen]
path = "xen.elf"

[[domains]]
type = "domU"
kernel = "Image"
initrd = "initramfs.cpio"
memory_kb = 131072
cmdline = "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init"
passthrough = ['/pl031@9010000']

[[domains]]
type = "domU"
kernel = "Image"
initrd = "initramfs.cpio"
memory_kb = 131072
cmdline = "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init"
passthrough = []
```

- `type` is `domU` or `dom0`. At most one `dom0` allowed.
- `passthrough` is only supported for `domU`. Each entry is a DTB path
  (e.g., `/pl031@9010000`). The loader builds a passthrough FDT at runtime
  using libfdt, adds `xen,reg`, `xen,path`, and
  `xen,force-assign-without-iommu` properties, then registers it with Xen
  as a `multiboot,device-tree` boot module.

## How It Works

1. **QEMU** loads `bundle.elf` — ELF segments place the xloader stub at
   `0x40000000` and all payloads (Xen, kernels, initrds) at their respective
   VMAs.
2. **xloader** receives the QEMU DTB via x0, copies it to BSS, patches it:
   - Adds `xen,xen-bootargs` to `/chosen`
   - For each domU domain: creates a `domain@X` node with kernel/initrd
     modules, memory, vpl011, and passthrough DTB module
   - For passthrough: builds a minimal FDT in BSS slack space, copies
     device nodes from the host DTB, wraps in a `passthrough` container
3. **Xen** receives the patched DTB, finds the domain nodes,
   processes the `multiboot,device-tree` modules (which are recognized via
   dual compatible `"multiboot,device-tree\0multiboot,module"`), and
   assigns passthrough devices (MMIO mapping + interrupt routing).
4. **Domains** boot with their assigned devices.

## Release Packaging

```bash
cmake --build build --target release
# → build/release/xloader-bundle.tar.gz
#   Contents: xloader.elf, bundle.py, README.md, scripts/
```

Users can then:
```bash
tar xzf xloader-bundle.tar.gz
# Write bundle.toml with their paths
bundle.py --config bundle.toml
qemu-system-aarch64 -M virt,virtualization=on -kernel bundle.elf ...
```

## QEMU Interactive Session

```bash
qemu-system-aarch64 -M virt,virtualization=on,secure=off,gic-version=3 \
  -cpu cortex-a57 -m 1G -kernel bundle.elf \
  -nographic -no-reboot -serial mon:stdio
```

Or via CMake (after placing `bundle.elf` in the build directory):
```bash
cmake -D XLOADER_BUNDLE=/path/to/bundle.elf build
cmake --build build --target run-qemu-dom0less-interactive
```

## Smoke Test

The `test/` subproject provides a full integration build including Xen,
Linux, musl, and BusyBox:

```bash
cmake -S test -B build/test -DXLOADER_FETCH_EXTERNALS=ON
cmake --build build/test --target run-qemu-test
```

Asserts:
- xloader jumps to Xen
- Both Xen and guest console output appear
- Passthrough device `/pl031@9010000` visible in the second guest
