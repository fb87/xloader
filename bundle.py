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

        cmd = dom["cmdline"][:XEN_BUNDLE_CMDLINE_LEN - 1]
        pad = XEN_BUNDLE_CMDLINE_LEN - len(cmd) - 1
        npt = len(dom["passthrough"])
        passthrough_off = f"_domain_{i}_passthrough - _bundle_desc" if npt else "0"

        parts.append(TEMPLATE_DOMAIN_ENTRY.substitute(
            KADDR=f"{kaddr:x}",
            KSIZE=str(ksize),
            IADDR=f"{iaddr:x}",
            ISIZE=str(isize),
            DADDR="0",
            DSIZE="0",
            MEM_KB=str(dom.get("memory_kb", 131072)),
            CMDLINE=cmd,
            CMDLINE_PAD=str(pad),
            NPT=str(npt),
            PASSTHROUGH_OFF=passthrough_off,
        ))
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


def generate_payload_dtbs(domains):
    lines = []
    for i, dom in enumerate(domains):
        dtb_path = dom.get("dtb_path")
        if dtb_path:
            lines.append(f".section .payload_{i}_dtb, \"ax\"")
            lines.append(f".globl _payload_{i}_dtb_start")
            lines.append(f"_payload_{i}_dtb_start:")
            lines.append(f'.incbin "{dtb_path}"')
            lines.append(f"_payload_{i}_dtb_end:")
    return "\n".join(lines)


_FDT_STRUCT_CACHE = {}


def _parse_fdt(data):
    if id(data) not in _FDT_STRUCT_CACHE:
        hdr = {
            "off_struct": struct.unpack_from(">I", data, 8)[0],
            "off_strings": struct.unpack_from(">I", data, 12)[0],
            "size_struct": struct.unpack_from(">I", data, 28)[0],
            "size_strings": struct.unpack_from(">I", data, 32)[0],
        }
        _FDT_STRUCT_CACHE[id(data)] = hdr
    return _FDT_STRUCT_CACHE[id(data)]


