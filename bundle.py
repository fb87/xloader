#!/usr/bin/env python3
"""Xen Bundle Source Generator.

Calculates payload offsets, renders assembly and linker script from
templates, and writes metadata JSON for the CMake build.
"""

import argparse
import json
import os
import string
import struct
import sys

PAGE_SIZE = 0x10000
MAX_DOMAINS = 16
MAX_PASSTHROUGH = 32
XEN_BUNDLE_MAGIC = 0x58454E42554E444C
XEN_BUNDLE_VERSION = 2
XEN_BUNDLE_CMDLINE_LEN = 256
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def align(x, a=PAGE_SIZE):
    return (x + a - 1) & ~(a - 1)


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def load_template(name):
    path = os.path.join(SCRIPT_DIR, name)
    with open(path) as f:
        return string.Template(f.read())


TEMPLATE_PAYLOADS = load_template("bundle_payloads.S.in")
TEMPLATE_LDS = load_template("bundle_xloader.lds.in")
TEMPLATE_DOMAIN_ENTRY = load_template("bundle_domain_entry.S.in")


def elf_read_entry(path):
    data = read_file(path)
    if len(data) < 64:
        return None
    if data[:4] != b"\x7fELF":
        return None
    cls = data[4]
    if cls == 2:
        return struct.unpack_from("<Q", data, 24)[0]
    return struct.unpack_from("<I", data, 28)[0]


def normalize_domain(raw, idx):
    dtype = raw.get("type", "domU")
    if dtype not in ("dom0", "domU"):
        raise ValueError(f"domain {idx}: type must be 'dom0' or 'domU'")

    passthrough = raw.get("passthrough", [])
    if passthrough is None:
        passthrough = []
    if not isinstance(passthrough, list) or not all(
        isinstance(p, str) for p in passthrough
    ):
        raise ValueError(f"domain {idx}: passthrough must be a string array")
    if dtype == "dom0" and passthrough:
        raise ValueError(
            f"domain {idx}: passthrough is only supported for domU domains"
        )
    if len(passthrough) > MAX_PASSTHROUGH:
        raise ValueError(f"domain {idx}: too many passthrough nodes")

    try:
        memory_kb = int(raw.get("memory_kb", raw.get("memory", 0)) or 0)
    except ValueError as exc:
        raise ValueError(f"domain {idx}: invalid memory_kb") from exc

    return {
        "type": dtype,
        "kernel": raw.get("kernel"),
        "initrd": raw.get("initrd"),
        "cmdline": raw.get("cmdline", ""),
        "memory_kb": memory_kb,
        "passthrough": passthrough,
    }


def load_config(path):
    try:
        import tomllib
    except ModuleNotFoundError as exc:
        raise RuntimeError("--config requires Python 3.11+ tomllib") from exc

    with open(path, "rb") as f:
        cfg = tomllib.load(f)

    raw_domains = cfg.get("domains", [])
    if not isinstance(raw_domains, list):
        raise ValueError("config: domains must be an array of tables")
    domains = [normalize_domain(d, i) for i, d in enumerate(raw_domains)]

    dom0_indexes = [i for i, d in enumerate(domains) if d["type"] == "dom0"]
    if len(dom0_indexes) > 1:
        raise ValueError("config: only one dom0 domain is allowed")
    dom0_idx = dom0_indexes[0] if dom0_indexes else None
    return domains, dom0_idx


def generate_domain_entries(domains, payload_addrs, payload_sizes):
    parts = []
    pi = 1
    for i, dom in enumerate(domains):
        kaddr = payload_addrs[pi] if dom["kernel"] else 0
        ksize = payload_sizes[pi] if dom["kernel"] else 0
        pi += 1 if dom["kernel"] else 0
        iaddr = payload_addrs[pi] if dom["initrd"] else 0
        isize = payload_sizes[pi] if dom["initrd"] else 0
        pi += 1 if dom["initrd"] else 0

        cmd = dom["cmdline"][: XEN_BUNDLE_CMDLINE_LEN - 1]
        pad = XEN_BUNDLE_CMDLINE_LEN - len(cmd) - 1
        npt = len(dom["passthrough"])
        passthrough_off = f"_domain_{i}_passthrough - _bundle_desc" if npt else "0"

        parts.append(
            TEMPLATE_DOMAIN_ENTRY.substitute(
                KADDR=f"{kaddr:x}",
                KSIZE=str(ksize),
                IADDR=f"{iaddr:x}",
                ISIZE=str(isize),
                MEM_KB=str(dom.get("memory_kb", 131072)),
                CMDLINE=cmd,
                CMDLINE_PAD=str(pad),
                NPT=str(npt),
                PASSTHROUGH_OFF=passthrough_off,
            )
        )
    return "\n".join(parts)


def generate_passthrough_block(domains):
    labels = []
    strings = []
    for i, dom in enumerate(domains):
        if dom["passthrough"]:
            labels.append(f"_domain_{i}_passthrough:")
        for p in dom["passthrough"]:
            strings.append(f'\t.asciz "{p}"')
    if not labels and not strings:
        return "\t.byte 0"
    block = '.section .rodata.bundle_passthrough, "a"\n.balign 4\n'
    if labels:
        block += "\n".join(labels) + "\n"
    if strings:
        block += "\n".join(strings) + "\n"
    block += "\t.byte 0"
    return block


def generate_dtb_block(dtb_data, build_dir):
    if not dtb_data:
        return ""
    dtb_bin = os.path.join(build_dir, "bundle_dtb.bin")
    with open(dtb_bin, "wb") as df:
        df.write(dtb_data)
    return (
        '.section .bundle_dtb, "a"\n'
        ".balign 4\n"
        ".globl _bundle_dtb_start\n"
        "_bundle_dtb_start:\n"
        f'.incbin "{dtb_bin}"\n'
        "_bundle_dtb_end:\n"
    )


def generate_payload_sections(domains, field, kind):
    lines = []
    for i, dom in enumerate(domains):
        path = dom.get(field)
        if path:
            lines.append(f'.section .payload_{i}_{kind}, "ax"')
            lines.append(f".globl _payload_{i}_{kind}_start")
            lines.append(f"_payload_{i}_{kind}_start:")
            lines.append(f'.incbin "{path}"')
            lines.append(f"_payload_{i}_{kind}_end:")
    return "\n".join(lines)


def generate_payload_xen(xen_path):
    return (
        '.section .payload_xen, "ax"\n'
        ".globl _payload_xen_start\n"
        "_payload_xen_start:\n"
        f'.incbin "{xen_path}"\n'
        "_payload_xen_end:\n"
    )


def render_payloads(
    path,
    base,
    payload_addrs,
    payload_sizes,
    xen_entry,
    domains,
    dom0_idx,
    xen_path,
    dtb_data,
    ram_size,
):
    build_dir = os.path.dirname(path)
    dom0_idx_val = dom0_idx if dom0_idx is not None else "~0"

    dtb_ptr_line = "\t.quad _bundle_dtb_start" if dtb_data else "\t.quad 0"
    dtb_size_line = f"\t.quad {len(dtb_data)}" if dtb_data else "\t.quad 0"

    content = TEMPLATE_PAYLOADS.substitute(
        MAGIC=f"{XEN_BUNDLE_MAGIC:016x}",
        VERSION=str(XEN_BUNDLE_VERSION),
        BASE_ADDR=f"{base:x}",
        XEN_ADDR=f"{payload_addrs[0]:x}",
        XEN_SIZE=str(payload_sizes[0]),
        XEN_ENTRY=f"{xen_entry:x}",
        NUM_DOMAINS=str(len(domains)),
        DOM0_IDX=str(dom0_idx_val),
        DTB_PTR_LINE=dtb_ptr_line,
        DTB_SIZE_LINE=dtb_size_line,
        RAM_SIZE=f"{ram_size:x}",
        DOMAIN_ENTRIES=generate_domain_entries(domains, payload_addrs, payload_sizes),
        PASSTHROUGH_BLOCK=generate_passthrough_block(domains),
        DTB_BLOCK=generate_dtb_block(dtb_data, build_dir),
        PAYLOAD_XEN=generate_payload_xen(xen_path),
        PAYLOAD_KERNELS=generate_payload_sections(domains, "kernel", "kernel"),
        PAYLOAD_INITRDS=generate_payload_sections(domains, "initrd", "initrd"),
    )

    with open(path, "w") as f:
        f.write(content)


def render_linker_script(path, base, payload_addrs, domains, dtb_size=0):
    phdrs = []
    sections = []
    pi = 1

    for i, dom in enumerate(domains):
        if dom["kernel"]:
            phdrs.append(f"  kernel{i} PT_LOAD;")
            sections.append(
                f"  .payload_{i}_kernel 0x{payload_addrs[pi]:x} : "
                f"{{ *(.payload_{i}_kernel) }} :kernel{i}"
            )
            pi += 1
        if dom["initrd"]:
            phdrs.append(f"  initrd{i} PT_LOAD;")
            sections.append(
                f"  .payload_{i}_initrd 0x{payload_addrs[pi]:x} : "
                f"{{ *(.payload_{i}_initrd) }} :initrd{i}"
            )
            pi += 1

    dtb_phdr_line = (
        "  .bundle_dtb : ALIGN(16) { *(.bundle_dtb) } :rodata" if dtb_size else ""
    )

    content = TEMPLATE_LDS.substitute(
        BASE_ADDR=f"{base:x}",
        XEN_ADDR=f"{payload_addrs[0]:x}",
        DOMAIN_PHDRS="\n".join(phdrs),
        DTB_PHDR_LINE=dtb_phdr_line,
        DOMAIN_SECTIONS="\n".join(sections),
    )

    with open(path, "w") as f:
        f.write(content)


def write_bundle_json(path, xen_entry, payload_addrs, payload_sizes, payload_names):
    data = {
        "xen_entry": xen_entry,
        "payload_addrs": [f"0x{a:x}" for a in payload_addrs],
        "payload_sizes": [f"0x{s:x}" for s in payload_sizes],
        "payload_names": payload_names,
    }
    with open(path, "w") as f:
        json.dump(data, f)


def main():
    parser = argparse.ArgumentParser(description="Xen Bundle Source Generator")
    parser.add_argument(
        "--base",
        default="0x40000000",
        help="Bundle base load address (default: 0x40000000)",
    )
    parser.add_argument("--xen", required=True, help="Xen ELF file")
    parser.add_argument("--dtb", help="Embedded DTB file (generated by QEMU dumpdtb)")
    parser.add_argument("--config", required=True, help="TOML domain config file")
    parser.add_argument(
        "--gen-dir",
        default="build",
        help="Output directory for generated assembly and linker script",
    )
    parser.add_argument("--ram-size", default="1G", help="Guest RAM size (default: 1G)")
    parser.add_argument(
        "--loader-size",
        default="0x40000",
        help="Estimated loader code size in bytes (hex), default 0x40000",
    )

    args = parser.parse_args()
    base = int(args.base, 16)

    ram_size_str = args.ram_size.upper()
    if ram_size_str.endswith("G"):
        ram_size = int(ram_size_str[:-1]) * 0x40000000
    elif ram_size_str.endswith("M"):
        ram_size = int(ram_size_str[:-1]) * 0x100000
    elif ram_size_str.endswith("K"):
        ram_size = int(ram_size_str[:-1]) * 0x400
    else:
        ram_size = int(ram_size_str, 0)

    xen_entry = elf_read_entry(args.xen)

    try:
        domains, dom0_idx = load_config(args.config)
    except (RuntimeError, ValueError) as exc:
        print(f"bundle: {exc}", file=sys.stderr)
        sys.exit(1)

    if not domains:
        print("bundle: at least one configured domain is required", file=sys.stderr)
        sys.exit(1)

    payload_paths = [args.xen]
    payload_names = ["xen"]
    for dom in domains:
        if dom["kernel"]:
            payload_paths.append(dom["kernel"])
            payload_names.append("kernel")
        if dom["initrd"]:
            payload_paths.append(dom["initrd"])
            payload_names.append("initrd")

    payload_data = []
    for p in payload_paths:
        data = read_file(p)
        payload_data.append(data)

    dtb_data = None
    if args.dtb:
        raw = read_file(args.dtb)
        if len(raw) >= 40:
            off_dt_struct = struct.unpack_from(">I", raw, 8)[0]
            off_dt_strings = struct.unpack_from(">I", raw, 12)[0]
            size_dt_struct = struct.unpack_from(">I", raw, 28)[0]
            size_dt_strings = struct.unpack_from(">I", raw, 32)[0]
            true_end = max(
                off_dt_struct + size_dt_struct, off_dt_strings + size_dt_strings
            )
            if 0 < true_end <= len(raw):
                dtb_data = bytearray(raw[:true_end])
                struct.pack_into(">I", dtb_data, 4, true_end)
            else:
                dtb_data = raw
        else:
            dtb_data = raw

    loader_size = int(args.loader_size, 16)
    loader_end = align(base + loader_size) + 0x20000 + 0x4000
    if dtb_data:
        loader_end += len(dtb_data)
    loader_end = align(loader_end)
    print(f"bundle: loader estimated end: 0x{loader_end:x}", file=sys.stderr)

    next_addr = align(loader_end)
    payload_addrs = []
    payload_sizes = []
    for i, data in enumerate(payload_data):
        payload_addrs.append(next_addr)
        payload_sizes.append(len(data))
        gap_size = len(data) + (0x100000 if i == 0 else 0)
        next_addr = align(next_addr + gap_size)

    if not xen_entry:
        xen_entry = payload_addrs[0]
        print(
            f"bundle: using Xen load address as entry: 0x{xen_entry:x}", file=sys.stderr
        )

    print(f"bundle: {len(payload_data)} payloads", file=sys.stderr)
    for i, (name, addr, size) in enumerate(
        zip(payload_names, payload_addrs, payload_sizes)
    ):
        print(f"  {i}: {name} @ 0x{addr:x} ({size} bytes)", file=sys.stderr)

    build_dir = args.gen_dir
    os.makedirs(build_dir, exist_ok=True)

    payloads_s = os.path.join(build_dir, "payloads.S")
    render_payloads(
        payloads_s,
        base,
        payload_addrs,
        payload_sizes,
        xen_entry,
        domains,
        dom0_idx,
        args.xen,
        dtb_data,
        ram_size,
    )

    lds_path = os.path.join(build_dir, "xloader.lds")
    dtb_size = len(dtb_data) if dtb_data else 0
    render_linker_script(lds_path, base, payload_addrs, domains, dtb_size)

    meta_path = os.path.join(build_dir, "bundle.json")
    write_bundle_json(meta_path, xen_entry, payload_addrs, payload_sizes, payload_names)

    print(f"bundle: sources → {build_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
