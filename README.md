# xloader

`xloader` bundles Xen and dom0less ARM64 Linux domains into one ELF image, patches the QEMU virt DTB at boot, and jumps to Xen.

## Reproducible CMake Build

Configure without fetching external projects when Xen, Linux, and initramfs artifacts already exist:

```bash
cmake -S . -B build/cmake \
  -DXLOADER_XEN_IMAGE=/path/to/xen \
  -DXLOADER_DOMAIN0_KERNEL=/path/to/Image \
  -DXLOADER_DOMAIN1_KERNEL=/path/to/Image \
  -DXLOADER_DOMAIN0_INITRD=/path/to/initramfs.cpio \
  -DXLOADER_DOMAIN1_INITRD=/path/to/initramfs.cpio
cmake --build build/cmake --target bundle
```

Configure with pinned source fetches for Xen, Linux, and BusyBox:

```bash
cmake -S . -B build/cmake -DXLOADER_FETCH_EXTERNALS=ON
cmake --build build/cmake --target bundle
```

The default pinned inputs are release tarballs verified by SHA-256:

- Xen: `https://downloads.xenproject.org/release/xen/4.21.1/xen-4.21.1.tar.gz`
- Linux: `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.36.tar.xz`
- BusyBox: `https://busybox.net/downloads/busybox-1.36.1.tar.bz2`
- musl: `https://musl.libc.org/releases/musl-1.2.5.tar.gz`

Override the `XLOADER_*_URL` and matching `XLOADER_*_SHA256` cache variables to pin different release artifacts.

## Domain Configuration

`bundle.py` accepts a TOML domain configuration with `--config`. CMake generates a default two-domU config at `build/cmake/domains.toml`; pass `-DXLOADER_DOMAIN_CONFIG=/path/to/domains.toml` to use a custom one.

```toml
[[domains]]
type = "domU"
kernel = "/path/to/Image"
initrd = "/path/to/initramfs.cpio"
memory_kb = 131072
cmdline = "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init"
passthrough = [
  "/pl031@9010000",
]

[[domains]]
type = "domU"
kernel = "/path/to/Image"
initrd = "/path/to/initramfs.cpio"
memory_kb = 131072
cmdline = "console=ttyAMA0 earlycon=pl011,0x22000000 loglevel=8 ignore_loglevel rdinit=/init"
passthrough = []
```

`type` is either `domU` or `dom0`. At most one `dom0` is allowed. Passthrough is only supported for `domU`; a `dom0` entry with `passthrough` is rejected.

Each passthrough item is a path to a node in the source QEMU DTB. The loader copies the node into the Xen domain node in the host DTB. For Xen to propagate the node into the guest device tree, the domain node must use Xen's DOMU passthrough bindings (e.g., `xen,reg`, `iommu`); this requires Xen-side support beyond the current scope.

The smoke test includes a `/pl031@9010000` passthrough entry for the first domain to validate the data flow (visible in boot logs as `xloader: passthrough /pl031@9010000`).

## QEMU Dom0less Test

Run the two-domain dom0less smoke test:

```bash
cmake --build build/cmake --target run-qemu-dom0less
```

Run an interactive dom0less session without the smoke-test timeout:

```bash
cmake --build build/cmake --target run-qemu-dom0less-interactive
```

QEMU starts with Xen serial input attached to the first Linux domain. Type `Ctrl-a` three times to switch Xen console input. Stop the session from the QEMU monitor or by interrupting the build command.

The test writes:

- `build/cmake/logs/qemu-combined.log`: xloader, Xen, and both Linux domain consoles
- `build/cmake/logs/xen.log`: Xen-prefixed lines
- `build/cmake/logs/domains.log`: per-domain readiness and interactive-console markers
- `build/cmake/logs/summary.log`: paths and QEMU exit status

The BusyBox initramfs prints `XLOADER_DOMAIN_READY` and `XLOADER_DOMAIN_INTERACTIVE` markers. The test fails if xloader does not jump to Xen, Xen logs are absent, or either Linux domain does not reach userspace.
