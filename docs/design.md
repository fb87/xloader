# Xen Bundle Loader (xloader)

## Overview

A baremetal ELF application for AArch64 that bundles Xen and all domains (Dom0 + DomUs) into a single ELF file. At boot, the loader patches the machine DTB to add a `chosen` node describing all domains' kernels and initrds, then jumps to Xen.

## Boot Flow

```
QEMU -kernel bundle.elf
  ↓ x0 = DTB ptr, EL2, MMU off, D-cache off, I-cache off
start.S → save x0, set SP, clear BSS
  ↓
main():
  1. Parse xen_bundle_desc from .rodata section
  2. Locate all payloads at their auto-calculated addresses
  3. Parse host DTB (saved from x0)
  4. Patch DTB chosen node with domain descriptions:
     - Dom0 kernel/initrd as "xen,multiboot-module" entries
     - DomU domains as "xen,domain" subnodes
       - Nested modules for kernel/initrd
       - Copied device nodes for passthrough
  5. Update DTB header (totalsize, etc.)
  6. Jump to Xen entry point (x0 = patched DTB, same EL2)
  ↓
Xen boots, reads DTB modules, starts Dom0/DomUs
```

## Memory Layout (Auto-Calculated)

Only one address is user-specified: the bundle base load address (e.g. `--base 0x40000000`). All payload addresses are page-aligned offsets computed by the bundle tool.

```
Base: 0x40000000
  0x40000000  Loader (.text/.data/.bss)          ~64KB
  0x40010000  Bundle descriptor (.rodata.desc)    ~4KB
  0x40020000  Xen binary                          ~8MB
  0x40200000  Dom0 kernel                         ~24MB
  0x42000000  Dom0 initrd                         ~8MB
  0x42800000  DomU1 kernel                        ~8MB
  0x43000000  DomU1 initrd                        ~16MB
  ...
```

No copying is needed — the ELF loader (QEMU) places everything at the right addresses. The loader merely patches the DTB and jumps.

## Data Structures

### Bundle Descriptor (`include/bundle.h`)

```c
#define XEN_BUNDLE_MAGIC  0x58454E42554E444C  /* "XENBNDL" */
#define XEN_BUNDLE_VERSION     1
#define XEN_BUNDLE_MAX_DOMAINS 16

struct xen_domain_passthrough {
    uint32_t path_offset;  // offset into string table (relative to bundle desc)
};

struct xen_domain_desc {
    uint64_t kernel_addr;      // absolute address
    uint64_t kernel_size;
    uint64_t initrd_addr;
    uint64_t initrd_size;
    char     cmdline[256];
    uint32_t num_passthrough;
    uint32_t passthrough_offset; // offset to xen_domain_passthrough array
};

struct xen_bundle_desc {
    uint64_t magic;               // XEN_BUNDLE_MAGIC
    uint64_t version;
    uint64_t bundle_addr;         // bundle base address in memory
    uint64_t xen_addr;            // Xen absolute address
    uint64_t xen_size;
    uint64_t xen_entry;           // Xen entry point (extracted by bundle tool)
    uint64_t num_domains;         // entries in domains[]
    uint64_t dom0_idx;            // index of Dom0 domain, ~0UL for dom0less
    struct xen_domain_desc domains[XEN_BUNDLE_MAX_DOMAINS];
};
```

### Payload Section Layout (.rodata.bundle)

```
.rodata.bundle:
  ┌─────────────────────────────────┐
  │ struct xen_bundle_desc          │  fixed-size header
  ├─────────────────────────────────┤
  │ struct xen_bundle_payload[]     │  {offset_in_bundle, size} for each payload
  ├─────────────────────────────────┤
  │ passthrough path strings        │  null-terminated, concatenated
  ├─────────────────────────────────┤
  │ Xen binary (raw)                │
  │ Dom0 kernel (raw)               │
  │ Dom0 initrd (raw)               │
  │ DomU1 kernel (raw)              │
  │ DomU1 initrd (raw)              │
  │ ...                             │
  └─────────────────────────────────┘
```

## DTB Patching (Manual, No libfdt)

### FDT Format Summary

```
struct fdt_header {
    uint32_t magic;              // 0xD00DFEED
    uint32_t totalsize;
    uint32_t off_dt_struct;
    uint32_t off_dt_strings;
    uint32_t off_mem_rsvmap;
    uint32_t version;
    uint32_t last_comp_version;
    uint32_t boot_cpuid_phys;
    uint32_t size_dt_strings;
    uint32_t size_dt_struct;
};
```

Structure block tokens:
- `FDT_BEGIN_NODE = 0x00000001` (followed by null-padded name)
- `FDT_END_NODE   = 0x00000002`
- `FDT_PROP       = 0x00000003` (followed by len, nameoff, value)
- `FDT_NOP        = 0x00000004`
- `FDT_END        = 0x00000009`

All values big-endian. Aligned to 4 bytes.

### Patching Strategy

1. **Find chosen node**: walk tokens tracking depth until `FDT_BEGIN_NODE("chosen")`
2. **Find insertion point**: the `FDT_END_NODE` of chosen, or before `FDT_END` if chosen doesn't exist
3. **Expand DTB**: `memmove` tail, update `totalsize`, `size_dt_struct`
4. **Insert new content**:
   - Dom0 modules (if dom0 exists):
     ```
     module@0 { compatible="xen,multiboot-module"; reg=<addr size>; }
     module@1 { compatible="xen,multiboot-module"; reg=<addr size>; }
     ```
   - For each non-Dom0 domain:
     ```
     domU@<i> {
         compatible = "xen,domain";
         #address-cells = <2>;
         #size-cells = <1>;
         cpus = <1>;
         memory = <0x0 size 0x0 0x0>;
         bootargs = "...";
         module@0 {
             compatible = "xen,multiboot-module";
             reg = <kernel_addr kernel_size>;
         };
         if initrd:
             module@1 { reg = <initrd_addr initrd_size>; };
         for each passthrough path:
             <copied-node> { ... };
     };
     ```
5. **Fix up header**: write new `FDT_END`, update `totalsize`, `size_dt_struct`, optionally `size_dt_strings`
6. **Passthrough node copy**: `dtb_copy_node_by_path(src_dtb, dest_dtb, path)` walks the source DTB to find the node, then duplicates its tokens (BEGIN_NODE, PROPs, subnodes, END_NODE) into the destination DTB at the current insertion point.

## Bundle Tool (`bundle.c`)

A host-compiled C program that:
1. Parses CLI arguments
2. Reads all payload files
3. Auto-calculates page-aligned addresses from `--base`
4. Extracts Xen ELF entry point via ELF header parsing
5. Generates `payloads.S` with `.incbin` directives at correct VMAs
6. Generates `xloader.lds` linker script with section placement
7. Invokes `aarch64-linux-gnu-as` and `aarch64-linux-gnu-ld`

### CLI

```
bundle --base 0x40000000 \
       --xen xen.elf \
       [--dom0 "kernel=Image initrd=initrd.cpio"] \
       [--domU "kernel=domu1_Image initrd=domu1_initrd.cpio passthrough=/path1,/path2"] \
       [--domU "kernel=domu2_Image ..."] \
       -o bundle.elf
```

### Auto-Address Calculation

```
offset = 0  // base + 0x00000 = loader (from ELF itself)
offset = page_align(offset + loader_size)

// Bundle descriptor
desc_addr = base + offset
offset = page_align(offset + sizeof_bundle_desc)

// Xen binary
xen_addr = base + offset
offset = page_align(offset + xen_size)

// Dom0 kernel (if present)
dom0_kernel_addr = base + offset
offset = page_align(offset + dom0_kernel_size)

// Dom0 initrd
dom0_initrd_addr = base + offset
offset = page_align(offset + dom0_initrd_size)

// DomU kernels/initrds — same pattern
```

## File Structure

```
xloader/
├── Makefile
├── docs/
│   └── design.md              ← this document
├── include/
│   └── bundle.h               ← shared bundle structs
├── src/
│   ├── start.S                ← AArch64 entry point
│   ├── main.c                 ← main() orchestration
│   ├── dtb.h                  ← DTB format + prototypes
│   └── dtb.c                  ← DTB parsing/patching
├── xloader.lds.in             ← linker script template (BASE_ADDR + sections)
├── bundle.c                   ← post-build bundling tool (host-compiled)
└── build/                     ← generated files
    ├── payloads.S
    └── xloader.lds
```

## Build Process

```bash
# 1. Cross-compile loader stub
aarch64-linux-gnu-gcc -ffreestanding -nostdlib -c src/start.S -o build/start.o
aarch64-linux-gnu-gcc -ffreestanding -nostdlib -c src/main.c -o build/main.o
aarch64-linux-gnu-gcc -ffreestanding -nostdlib -c src/dtb.c -o build/dtb.o

# 2. Link loader stub into an intermediate ELF
aarch64-linux-gnu-ld -T xloader.lds.in -o build/xloader_stub.elf \
    build/start.o build/main.o build/dtb.o

# 3. Compile host bundle tool
gcc -o bundle bundle.c

# 4. Run bundle tool to produce final ELF
./bundle --base 0x40000000 \
    --xen xen.elf \
    --dom0 "kernel=Image initrd=initrd.cpio" \
    --domU "kernel=domu1_Image ..." \
    -o bundle.elf

# 5. Run in QEMU
qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1G \
    -kernel bundle.elf -nographic -serial stdio
```

## QEMU Test Plan

1. Build bundle with Xen + Dom0 + one DomU
2. Run under QEMU virt machine
3. Verify:
   - Loader boots and patches DTB
   - Xen starts successfully (console output)
   - Dom0 boots
   - Passthrough devices are visible/assigned correctly
