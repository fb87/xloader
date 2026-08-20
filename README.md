# xloader v10

`xloader` packages a small position-independent loader, Xen, and static DomU
payloads into a single ELF image. The host pipeline is Nix-native and the
system definition is TOML.

v10 focuses on **functional Arm dom0less device passthrough**. Passthrough is
no longer just a host-FDT path: every grant carries explicit MMIO and optional
GIC interrupt resources in the bundle ABI.

## Architecture

```text
Nix store inputs
  xloader ELF -> normalize -> xloader.bin + meta.toml
  Xen ELF     -> normalize -> xen.bin     + meta.toml
  Linux Image ---------------------------+
  initramfs -----------------------------+
                                          |
                                  system.toml
                                          |
                                      xbundle
                                          |
                                 system.xbundle.elf
                                          |
                                  QEMU / firmware
                                          |
                                       xloader
                                          |
                           machine DT -> Xen launch DT
                                          |
                                         Xen
                                     /          \
                                  guest0       guest1
                              PL031 passthrough
```

`xbundle` does not parse input ELF files. ELF normalization is a Nix build
stage; the packer consumes raw images plus metadata and emits one final ELF.

## Passthrough manifest

The bootable QEMU sample passes the `virt` machine PL031 RTC to `guest0`:

```toml
[[domain.passthrough]]
path = "/pl031@9010000"
force_assign_without_iommu = true
strip_external_dependencies = true
mmio = { host = "0x09010000", guest = "same", size = "4K" }
irq = { type = "spi", number = 2, flags = 4 }
```

v10 supports one explicit MMIO range and one optional GIC IRQ per passthrough
node. The ABI is versioned so this can become variable resource tables later.

At runtime xloader:

1. locates the selected node in the actual machine DT;
2. copies it into a per-domain partial DT;
3. emits `xen,reg` from the explicit MMIO grant;
4. emits/overrides `interrupts` when an IRQ is configured;
5. emits `xen,force-assign-without-iommu` only when explicitly requested;
6. marks the source machine node `xen,passthrough`;
7. attaches the partial DT as `multiboot,device-tree` to the static DomU.

`strip_external_dependencies = true` removes known external phandle
properties such as clocks, resets, IOMMU links, and power domains. The default
is `false`, which fails instead of silently creating an invalid partial DT.

## QEMU passthrough acceptance

The sample uses PL031 because it has a small MMIO aperture and a single SPI.
The sample initramfs tests both paths independently:

```text
guest0: passthrough pl031 MMIO PASS
guest0: passthrough pl031 IRQ PASS
```

MMIO is checked with BusyBox `devmem`. IRQ delivery is checked by arming the
Linux PL031 RTC wake alarm and verifying that its `/proc/interrupts` count
increases. If the cached Nix kernel provides PL031 as a module, the Nix
initramfs derivation extracts the matching `rtc-pl031.ko`; the Linux kernel is
still not rebuilt.

The QEMU sample intentionally uses `force_assign_without_iommu = true`
because the emulated sysbus PL031 is not protected by an SMMU. This is a test
policy and is not a default for real DMA-capable devices.

## Build

The project is pinned to `nixos-26.05-small`.

```bash
nix flake lock

nix build .#xbundle
nix build .#xloader-aarch64
nix build .#sample-config-aarch64
nix build .#sample-bundle-aarch64
```

Inspect the compiled grant:

```bash
cat result/inspect.txt
```

Run the basic system smoke test:

```bash
nix build .#smoke-sample-aarch64
```

Run the dedicated passthrough acceptance test:

```bash
nix build .#smoke-passthrough-aarch64
```

Run the PIC placement test:

```bash
nix build .#smoke-pic-aarch64
```

## Important v10 limitation

The passthrough implementation currently models:

```text
one DT node
  + one MMIO range
  + zero/one GIC interrupt
```

It does not yet model multiple MMIO BARs, multiple interrupts, DMA/IOMMU
stream IDs, MSI, clocks/resets as assigned resources, or automatic phandle
dependency closure. Those should be explicit future ABI resource tables rather
than inferred silently from the host DT.
