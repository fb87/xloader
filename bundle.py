#!/usr/bin/env python3
"""Xen Bundle Loader — post-build bundling tool.

Reads the loader stub ELF, Xen ELF, and domain payloads,
auto-calculates page-aligned addresses from a single base address,
generates assembly + linker script, and invokes the toolchain
to produce bundle.elf.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

PAGE_SIZE = 0x10000
MAX_DOMAINS = 16
MAX_PASSTHROUGH = 32
XEN_BUNDLE_MAGIC = 0x58454E42554E444C
XEN_BUNDLE_VERSION = 2
XEN_BUNDLE_CMDLINE_LEN = 256


def align(x, a=PAGE_SIZE):
    return (x + a - 1) & ~(a - 1)


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def xen_total_size(path):
    """Return Xen's total memory footprint from PE/ELF image."""
    data = read_file(path)
    if len(data) >= 2 and data[:2] == b'MZ':
        pe_off = struct.unpack_from('<I', data, 0x3c)[0]
        if pe_off + 4 <= len(data) and data[pe_off:pe_off+4] == b'PE\x00\x00':
            opt_hdr_sz = struct.unpack_from('<H', data, pe_off + 20)[0]
            magic = struct.unpack_from('<H', data, pe_off + 24)[0]
            if magic == 0x20b:  # PE32+
                return struct.unpack_from('<I', data, pe_off + 24 + 56)[0]
    # ELF: find max vaddr + memsz from PT_LOAD
    if data[:4] == b'\x7fELF' and data[4] == 2:
        endian = '<' if data[5] == 1 else '>'
        phoff = struct.unpack_from(endian + 'Q', data, 32)[0]
        phnum = struct.unpack_from(endian + 'H', data, 56)[0]
        phentsize = struct.unpack_from(endian + 'H', data, 54)[0]
        max_end = 0
        for i in range(phnum):
            off = phoff + i * phentsize
            p_type = struct.unpack_from(endian + 'I', data, off)[0]
            if p_type == 1:
                vaddr = struct.unpack_from(endian + 'Q', data, off + 16)[0]
                memsz = struct.unpack_from(endian + 'Q', data, off + 48)[0]
                end = vaddr + memsz
                if end > max_end:
                    max_end = end
        return max_end
    return len(data)


def elf_read_entry(path):
    data = read_file(path)
    if len(data) < 64:
        return None
    if data[:4] != b"\x7fELF":
        return None
    cls = data[4]
    if cls == 2:
        entry = struct.unpack_from("<Q", data, 24)[0]
    else:
        entry = struct.unpack_from("<I", data, 28)[0]
    return entry


def elf_read_load_segments(path):
    """Return list of (vaddr, memsz) for PT_LOAD segments."""
    data = read_file(path)
    if data[:4] != b"\x7fELF":
        return []
    cls = data[4]
    endian = "<" if data[5] == 1 else ">"
    if cls == 2:
        phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        phnum = struct.unpack_from(endian + "H", data, 56)[0]
        phentsize = struct.unpack_from(endian + "H", data, 54)[0]
        segments = []
        for i in range(phnum):
            off = phoff + i * phentsize
            p_type = struct.unpack_from(endian + "I", data, off)[0]
            if p_type == 1:
                vaddr = struct.unpack_from(endian + "Q", data, off + 16)[0]
                memsz = struct.unpack_from(endian + "Q", data, off + 48)[0]
                segments.append((vaddr, memsz))
        return segments
    else:
        phoff = struct.unpack_from(endian + "I", data, 28)[0]
        phnum = struct.unpack_from(endian + "H", data, 44)[0]
        phentsize = struct.unpack_from(endian + "H", data, 42)[0]
        segments = []
        for i in range(phnum):
            off = phoff + i * phentsize
            p_type = struct.unpack_from(endian + "I", data, off)[0]
            if p_type == 1:
                vaddr = struct.unpack_from(endian + "I", data, off + 12)[0]
                memsz = struct.unpack_from(endian + "I", data, off + 28)[0]
                segments.append((vaddr, memsz))
        return segments


def elf_estimate_loader_end(loader_objects, base):
    """Quick estimate of loader end by reading .o section headers."""
    end = base
    for path in loader_objects:
        data = read_file(path)
        if data[:4] != b"\x7fELF":
            continue
        cls = data[4]
        endian = "<" if data[5] == 1 else ">"
        if cls == 2:
            shoff = struct.unpack_from(endian + "Q", data, 40)[0]
            shnum = struct.unpack_from(endian + "H", data, 60)[0]
            shentsize = struct.unpack_from(endian + "H", data, 58)[0]
            shstrndx = struct.unpack_from(endian + "H", data, 62)[0]
            for i in range(shnum):
                soff = shoff + i * shentsize
                s_flags = struct.unpack_from(endian + "Q", data, soff + 8)[0]
                s_size = struct.unpack_from(endian + "Q", data, soff + 32)[0]
                if s_flags & 0x2:  # SHF_ALLOC
                    s_addr = struct.unpack_from(endian + "Q", data, soff + 16)[0]
                    # .o files have sh_addr = 0 for non-section-specified
                if s_flags & 0x2 and s_size:
                    end = align(end, 16) + s_size
        else:
            shoff = struct.unpack_from(endian + "I", data, 32)[0]
            shnum = struct.unpack_from(endian + "H", data, 48)[0]
            shentsize = struct.unpack_from(endian + "H", data, 46)[0]
            for i in range(shnum):
                soff = shoff + i * shentsize
                s_flags = struct.unpack_from(endian + "I", data, soff + 8)[0]
                s_size = struct.unpack_from(endian + "I", data, soff + 20)[0]
                if s_flags & 0x2 and s_size:
                    end = align(end, 16) + s_size
    return align(end, PAGE_SIZE)


def parse_domain_str(s):
    """Parse domain config string: 'kernel=path;initrd=path;cmdline=str;passthrough=p1,p2'"""
    cfg = {"kernel": None, "initrd": None, "cmdline": "",
           "memory_kb": 0, "passthrough": []}
    for part in s.split(";"):
        part = part.strip()
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        k = k.strip()
        v = v.strip()
        if k == "kernel":
            cfg["kernel"] = v
        elif k == "initrd":
            cfg["initrd"] = v
        elif k == "cmdline":
            cfg["cmdline"] = v
        elif k == "memory" or k == "mem":
            try:
                cfg["memory_kb"] = int(v)
            except ValueError:
                print(f"bundle: invalid memory value '{v}', using 128MB", file=sys.stderr)
                cfg["memory_kb"] = 131072
        elif k == "passthrough":
            cfg["passthrough"] = [p.strip() for p in v.split(",") if p.strip()]
    return cfg


def write_payloads_s(path, base, payload_addrs, payload_sizes, xen_entry,
                     domains, dom0_idx, xen_path, dtb_data=None,
                     ram_size=0x40000000):
    """Generate payloads.S assembly file."""

    with open(path, "w") as f:
        f.write(".section .rodata.bundle_desc, \"a\"\n")
        f.write(".balign 8\n")
        f.write(".globl _bundle_desc\n")
        f.write("_bundle_desc:\n")

        f.write(f"\t.quad 0x{XEN_BUNDLE_MAGIC:016x}ULL\n")
        f.write(f"\t.quad {XEN_BUNDLE_VERSION}\n")
        f.write(f"\t.quad 0x{base:x}\n")
        f.write(f"\t.quad 0x{payload_addrs[0]:x}\n")
        f.write(f"\t.quad {payload_sizes[0]}\n")
        f.write(f"\t.quad 0x{xen_entry:x}\n")
        f.write(f"\t.quad {len(domains)}\n")
        dom0_idx_val = dom0_idx if dom0_idx is not None else "~0"
        f.write(f"\t.quad {dom0_idx_val}\n")
        if dtb_data:
            f.write("\t.quad _bundle_dtb_start\n")
            f.write(f"\t.quad {len(dtb_data)}\n")
        else:
            f.write("\t.quad 0\n")
            f.write("\t.quad 0\n")
        f.write(f"\t.quad 0x{ram_size:x}\n")

        pi = 1
        for i, dom in enumerate(domains):
            kaddr = payload_addrs[pi] if dom["kernel"] else 0
            ksize = payload_sizes[pi] if dom["kernel"] else 0
            pi += 1 if dom["kernel"] else 0
            iaddr = payload_addrs[pi] if dom["initrd"] else 0
            isize = payload_sizes[pi] if dom["initrd"] else 0
            pi += 1 if dom["initrd"] else 0

            f.write(f"\t.quad 0x{kaddr:x}\n")
            f.write(f"\t.quad {ksize}\n")
            f.write(f"\t.quad 0x{iaddr:x}\n")
            f.write(f"\t.quad {isize}\n")
            f.write(f"\t.quad 0\n")
            f.write(f"\t.quad 0\n")
            mem_kb = dom.get("memory_kb", 131072)
            f.write(f"\t.quad {mem_kb}\n")

            cmd = dom["cmdline"][:XEN_BUNDLE_CMDLINE_LEN - 1]
            f.write(f"\t.asciz \"{cmd}\"\n")
            pad = XEN_BUNDLE_CMDLINE_LEN - len(cmd) - 1
            if pad > 0:
                f.write(f"\t.fill {pad},1,0\n")

            npt = len(dom["passthrough"])
            f.write(f"\t.long {npt}\n")
            f.write(f"\t.long 0\n")
            f.write(f"\t.long 0\n")
            f.write(f"\t.long 0\n")

        f.write(".section .rodata.bundle_passthrough, \"a\"\n")
        f.write(".balign 4\n")
        for dom in domains:
            for p in dom["passthrough"]:
                f.write(f"\t.asciz \"{p}\"\n")
        f.write("\t.byte 0\n")

        # Embedded DTB (used when x0 is not set by bootloader)
        # Must be in its own section (not .rodata*) to avoid VMA collision
        # with payload sections in the linker script.
        if dtb_data:
            build_dir = os.path.dirname(path)
            dtb_bin = os.path.join(build_dir, "bundle_dtb.bin")
            with open(dtb_bin, "wb") as df:
                df.write(dtb_data)
            f.write(".section .bundle_dtb, \"a\"\n")
            f.write(".balign 4\n")
            f.write(".globl _bundle_dtb_start\n")
            f.write("_bundle_dtb_start:\n")
            f.write(f".incbin \"{dtb_bin}\"\n")
            f.write("_bundle_dtb_end:\n")

        # Xen binary payload section
        f.write(".section .payload_xen, \"ax\"\n")
        f.write(".globl _payload_xen_start\n")
        f.write("_payload_xen_start:\n")
        f.write(f".incbin \"{xen_path}\"\n")
        f.write("_payload_xen_end:\n")

        pi = 1
        for i, dom in enumerate(domains):
            if dom["kernel"]:
                f.write(f".section .payload_{i}_kernel, \"ax\"\n")
                f.write(f".globl _payload_{i}_kernel_start\n")
                f.write(f"_payload_{i}_kernel_start:\n")
                f.write(f".incbin \"{dom['kernel']}\"\n")
                f.write(f"_payload_{i}_kernel_end:\n")
                pi += 1
            if dom["initrd"]:
                f.write(f".section .payload_{i}_initrd, \"ax\"\n")
                f.write(f".globl _payload_{i}_initrd_start\n")
                f.write(f"_payload_{i}_initrd_start:\n")
                f.write(f".incbin \"{dom['initrd']}\"\n")
                f.write(f"_payload_{i}_initrd_end:\n")
                pi += 1


def write_linker_script(path, base, payload_addrs, domains, cross_prefix, dtb_size=0):
    """Generate xloader.lds."""
    with open(path, "w") as f:
        f.write("OUTPUT_FORMAT(elf64-littleaarch64)\n")
        f.write("OUTPUT_ARCH(aarch64)\n")
        f.write("ENTRY(_start)\n\n")

        f.write("PHDRS\n{\n")
        f.write("  text PT_LOAD;\n")
        f.write("  rodata PT_LOAD;\n")
        f.write("  data PT_LOAD;\n")
        f.write("  bss PT_LOAD;\n")
        f.write("  xen PT_LOAD;\n")
        phdr_idx = 5
        for i, dom in enumerate(domains):
            if dom["kernel"]:
                f.write(f"  kernel{i} PT_LOAD;\n")
                dom["_kernel_phdr"] = phdr_idx
                phdr_idx += 1
            if dom["initrd"]:
                f.write(f"  initrd{i} PT_LOAD;\n")
                dom["_initrd_phdr"] = phdr_idx
                phdr_idx += 1
        f.write("}\n\n")

        f.write("SECTIONS\n{\n")
        f.write(f"  . = 0x{base:x};\n\n")
        f.write("  .text : { *(.text.entry) *(.text*) } :text\n")
        f.write("  .rodata : { *(.rodata*) } :rodata\n")
        if dtb_size:
            f.write("  .bundle_dtb : ALIGN(16) { *(.bundle_dtb) } :rodata\n")
        f.write("  .data : { *(.data*) } :data\n")
        f.write("  .bss : ALIGN(16) {\n")
        f.write("    _bss_start = .;\n")
        f.write("    *(.bss*); *(COMMON);\n")
        f.write("    . = ALIGN(16);\n")
        f.write("    _bss_end = .;\n")
        f.write("    . = ALIGN(4096);\n")
        f.write("    _dtb_buffer = .;\n")
        f.write("    . = . + 0x20000;\n")
        f.write("  } :bss\n")
        f.write("  _stack_start = .;\n")
        f.write("  . = . + 0x4000;\n")
        f.write("  _stack_end = .;\n\n")

        f.write(f"  .payload_xen 0x{payload_addrs[0]:x} : ")
        f.write(f"{{ *(.payload_xen) }} :xen\n")

        pi = 1
        for i, dom in enumerate(domains):
            if dom["kernel"]:
                f.write(f"  .payload_{i}_kernel 0x{payload_addrs[pi]:x} : ")
                f.write(f"{{ *(.payload_{i}_kernel) }} :kernel{i}\n")
                pi += 1
            if dom["initrd"]:
                f.write(f"  .payload_{i}_initrd 0x{payload_addrs[pi]:x} : ")
                f.write(f"{{ *(.payload_{i}_initrd) }} :initrd{i}\n")
                pi += 1

        f.write("}\n")


def main():
    parser = argparse.ArgumentParser(description="Xen Bundle Loader")
    parser.add_argument("--base", default="0x40000000",
                        help="Bundle base load address (default: 0x40000000)")
    parser.add_argument("--xen", required=True, help="Xen ELF file")
    parser.add_argument("--dtb", help="Embedded DTB file (generated by QEMU dumpdtb)")
    parser.add_argument("--dom0", help="Dom0 config: kernel=path;initrd=path;cmdline=str")
    parser.add_argument("--domU", action="append", default=[],
                        help="DomU config: kernel=path;initrd=path;...")
    parser.add_argument("-o", "--output", default="bundle.elf",
                        help="Output bundle ELF")
    parser.add_argument("loader_objects", nargs="+",
                        help="Loader object files (.o)")
    parser.add_argument("--ram-size", default="1G",
                        help="Guest RAM size (default: 1G)")
    parser.add_argument("--cross-prefix", default="aarch64-linux-gnu-",
                        help="Cross toolchain prefix")

    args = parser.parse_args()

    base = int(args.base, 16)
    loader_objects = args.loader_objects
    cross = args.cross_prefix

    # Parse RAM size (e.g., "1G" -> 0x40000000)
    ram_size_str = args.ram_size.upper()
    if ram_size_str.endswith('G'):
        ram_size = int(ram_size_str[:-1]) * 0x40000000
    elif ram_size_str.endswith('M'):
        ram_size = int(ram_size_str[:-1]) * 0x100000
    elif ram_size_str.endswith('K'):
        ram_size = int(ram_size_str[:-1]) * 0x400
    else:
        ram_size = int(ram_size_str, 0)

    # Read Xen entry (use ELF entry if available, or fall back to load address)
    xen_entry = elf_read_entry(args.xen)

    # Collect domains
    domains = []
    if args.dom0:
        domains.append(parse_domain_str(args.dom0))
    for du in args.domU:
        domains.append(parse_domain_str(du))

    if not domains:
        print("bundle: at least one --dom0= or --domU= required", file=sys.stderr)
        sys.exit(1)

    # Determine which domain is Dom0 (first one with --dom0, or None)
    dom0_idx = 0 if args.dom0 else None

    # Build payload list (xen + kernel + initrd for each domain)
    payload_paths = [args.xen]
    payload_names = ["xen"]
    for dom in domains:
        if dom["kernel"]:
            payload_paths.append(dom["kernel"])
            payload_names.append("kernel")
        if dom["initrd"]:
            payload_paths.append(dom["initrd"])
            payload_names.append("initrd")

    # Read all payloads
    payload_data = []
    for p in payload_paths:
        data = read_file(p)
        payload_data.append(data)

    # Read embedded DTB (if provided) and trim to true content size
    # QEMU pads the DTB to a fixed buffer size in RAM, but the actual content
    # ends at max(off_dt_struct+size_dt_struct, off_dt_strings+size_dt_strings).
    dtb_data = None
    if args.dtb:
        raw = read_file(args.dtb)
        if len(raw) >= 40:
            off_dt_struct = struct.unpack_from(">I", raw, 8)[0]
            off_dt_strings = struct.unpack_from(">I", raw, 12)[0]
            size_dt_struct = struct.unpack_from(">I", raw, 28)[0]
            size_dt_strings = struct.unpack_from(">I", raw, 32)[0]
            true_end = max(off_dt_struct + size_dt_struct,
                           off_dt_strings + size_dt_strings)
            if 0 < true_end <= len(raw):
                dtb_data = bytearray(raw[:true_end])
                # Fix totalsize in header (big-endian at offset 4)
                struct.pack_into(">I", dtb_data, 4, true_end)
            else:
                dtb_data = raw
        else:
            dtb_data = raw

    # Estimate loader end address (including dtb_buffer + stack from linker script)
    loader_end = elf_estimate_loader_end(loader_objects, base)
    loader_end += 0x20000 + 0x4000  # dtb_buffer (128K) + stack (16K)
    if dtb_data:
        loader_end += len(dtb_data)
    loader_end = align(loader_end)
    print(f"bundle: loader estimated end: 0x{loader_end:x}", file=sys.stderr)

    # Auto-calculate payload addresses (page-aligned, sequential)
    # Use Xen's total memory footprint (from PE/ELF headers) for the gap
    # after Xen to avoid overlapping with Xen's runtime (BSS, pagetables, etc.)
    xen_footprint = xen_total_size(args.xen)
    next_addr = align(loader_end)
    payload_addrs = []
    payload_sizes = []
    for i, data in enumerate(payload_data):
        payload_addrs.append(next_addr)
        payload_sizes.append(len(data))
        gap_size = xen_footprint if i == 0 else len(data)
        next_addr = align(next_addr + gap_size)

    # If we couldn't read the ELF entry, use the load address
    if not xen_entry:
        xen_entry = payload_addrs[0]
        print(f"bundle: using Xen load address as entry: 0x{xen_entry:x}", file=sys.stderr)

    print(f"bundle: {len(payload_data)} payloads", file=sys.stderr)
    for i, (name, addr, size) in enumerate(zip(payload_names, payload_addrs, payload_sizes)):
        print(f"  {i}: {name} @ 0x{addr:x} ({size} bytes)", file=sys.stderr)

    # Create build directory
    build_dir = "build"
    os.makedirs(build_dir, exist_ok=True)

    # Generate payloads.S
    payloads_s = os.path.join(build_dir, "payloads.S")
    write_payloads_s(payloads_s, base, payload_addrs, payload_sizes, xen_entry,
                     domains, dom0_idx, args.xen, dtb_data, ram_size)

    # Generate linker script
    lds_path = os.path.join(build_dir, "xloader.lds")
    dtb_size = len(dtb_data) if dtb_data else 0
    write_linker_script(lds_path, base, payload_addrs, domains, cross, dtb_size)

    # Assemble payloads.S
    payloads_o = os.path.join(build_dir, "payloads.o")
    subprocess.check_call([
        cross + "gcc", "-x", "assembler", "-c",
        payloads_s, "-o", payloads_o
    ])

    # Link final bundle
    ld_cmd = [cross + "ld", "-T", lds_path, "-o", args.output,
              "-Map", os.path.join(build_dir, "xloader.map")]
    ld_cmd += loader_objects
    ld_cmd += [payloads_o]

    print(f"bundle: linking {args.output}", file=sys.stderr)
    subprocess.check_call(ld_cmd)
    print(f"bundle: done → {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
