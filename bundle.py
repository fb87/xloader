#!/usr/bin/env python3
"""Xen Bundle Builder.

Reads bundle.toml, xloader.bin, and domain payloads, then produces
bundle.bin — a flat binary with the Image header (if present in
xloader.bin), bundle descriptor, and all payloads.
"""

import argparse
import os
import struct
import sys

PAGE_SIZE = 0x10000
MAX_DOMAINS = 16
MAX_PASSTHROUGH = 32
XEN_BUNDLE_MAGIC = 0x58454E42554E444C
XEN_BUNDLE_VERSION = 2
XEN_BUNDLE_CMDLINE_LEN = 256
XEN_GAP = 0x100000

def align(x, a=PAGE_SIZE):
    return (x + a - 1) & ~(a - 1)

def read_file(path):
    with open(path, "rb") as f:
        return f.read()

def load_config(path):
    try:
        import tomllib
    except ModuleNotFoundError as exc:
        raise RuntimeError("--config requires Python 3.11+ tomllib") from exc
    with open(path, "rb") as f:
        cfg = tomllib.load(f)
    xl_cfg = cfg.get("xloader", {})
    xen_cfg = cfg.get("xen", {})
    raw_domains = cfg.get("domains", [])
    if not isinstance(raw_domains, list):
        raise ValueError("config: domains must be an array of tables")
    domains = []
    for idx, d in enumerate(raw_domains):
        dtype = d.get("type", "domU")
        if dtype not in ("dom0", "domU"):
            raise ValueError(f"domain {idx}: type must be 'dom0' or 'domU'")
        pt = d.get("passthrough", []) or []
        if dtype == "dom0" and pt:
            raise ValueError(f"domain {idx}: passthrough only for domU")
        if len(pt) > MAX_PASSTHROUGH:
            raise ValueError(f"domain {idx}: too many passthrough")
        try:
            mem_kb = int(d.get("memory_kb", d.get("memory", 0)) or 0)
        except ValueError as exc:
            raise ValueError(f"domain {idx}: invalid memory_kb") from exc
        domains.append({"type": dtype, "kernel": d.get("kernel"),
                        "initrd": d.get("initrd"), "cmdline": d.get("cmdline", ""),
                        "memory_kb": mem_kb, "passthrough": pt})
    dom0_idx = None
    for i, d in enumerate(domains):
        if d["type"] == "dom0":
            if dom0_idx is not None:
                raise ValueError("config: only one dom0")
            dom0_idx = i
    return xl_cfg, xen_cfg, domains, dom0_idx

def main():
    parser = argparse.ArgumentParser(description="Xen Bundle Builder")
    parser.add_argument("--config", default="bundle.toml")
    parser.add_argument("--base", required=True, help="Bundle base load address (hex)")
    parser.add_argument("-o", "--output", default="bundle.bin")
    args = parser.parse_args()
    base = int(args.base, 16)

    try:
        xl_cfg, xen_cfg, domains, dom0_idx = load_config(args.config)
    except (RuntimeError, ValueError) as exc:
        print(f"bundle: {exc}", file=sys.stderr); sys.exit(1)
    if not domains:
        print("bundle: at least one domain required", file=sys.stderr); sys.exit(1)

    xl_path = xl_cfg.get("path", "xloader.bin")
    xl_binary = read_file(xl_path)
    print(f"bundle: xloader size=0x{len(xl_binary):x} base=0x{base:x}", file=sys.stderr)

    xen_path = xen_cfg.get("path") or "xen.elf"
    xen_data = read_file(xen_path)
    for i, dom in enumerate(domains):
        for f in ("kernel", "initrd"):
            p = dom.get(f)
            if p and not os.path.exists(p):
                print(f"bundle: domain[{i}] {f} not found: {p}", file=sys.stderr); sys.exit(1)

    payload_blobs = [xen_data]
    payload_tags = ["xen"]

    for dom in domains:
        if dom.get("kernel"):
            payload_blobs.append(read_file(dom["kernel"]))
            payload_tags.append("kernel")
        if dom.get("initrd"):
            payload_blobs.append(read_file(dom["initrd"]))
            payload_tags.append("initrd")

    # Calculate addresses
    desc_off = align(len(xl_binary), 4096) + 0x200000 + 0x4000
    DOMAIN_ENTRY_SIZE = 8 * 7 + XEN_BUNDLE_CMDLINE_LEN + 4 * 4
    passthrough_data = bytearray()
    for dom in domains:
        for pt in dom["passthrough"]:
            passthrough_data.extend(pt.encode() + b"\0")
        passthrough_data.extend(b"\0")
    payload_off = align(desc_off + 80 + MAX_DOMAINS * DOMAIN_ENTRY_SIZE + len(passthrough_data))
    xen_footprint = len(xen_data) + XEN_GAP

    addrs = [base, base + payload_off]
    for i, blob in enumerate(payload_blobs[1:], 1):
        gap = xen_footprint if i == 1 else len(payload_blobs[i - 1])
        addrs.append(align(addrs[-1] + gap))

    print("bundle: payloads", file=sys.stderr)
    for i, (tag, addr, blob) in enumerate(zip(["xloader"] + payload_tags, [base] + addrs[1:], [xl_binary] + payload_blobs)):
        print(f"  [{i}] {tag} @ 0x{addr:x} (0x{len(blob):x})", file=sys.stderr)

    # Build bundle descriptor
    domain_blob = bytearray()
    passthrough_offsets = []
    pt_cumulative = 0
    for dom in domains:
        passthrough_offsets.append(pt_cumulative)
        for _ in dom["passthrough"]:
            pt_cumulative += len(_) + 1
        pt_cumulative += 1

    pi = 1
    for i, dom in enumerate(domains):
        ka = addrs[pi + 1] if dom.get("kernel") else 0
        ks = len(payload_blobs[pi]) if dom.get("kernel") else 0
        pi += 1 if dom.get("kernel") else 0
        ia = addrs[pi + 1] if dom.get("initrd") else 0
        it = len(payload_blobs[pi]) if dom.get("initrd") else 0
        pi += 1 if dom.get("initrd") else 0
        domain_blob += struct.pack("<Q", ka) + struct.pack("<Q", ks)
        domain_blob += struct.pack("<Q", ia) + struct.pack("<Q", it)
        domain_blob += struct.pack("<Q", 0) + struct.pack("<Q", 0)
        domain_blob += struct.pack("<Q", dom.get("memory_kb", 0))
        cmd = dom["cmdline"][:XEN_BUNDLE_CMDLINE_LEN - 1].encode()
        domain_blob += cmd + b"\0" * (XEN_BUNDLE_CMDLINE_LEN - len(cmd))
        pt_abs_off = 88 + len(domains) * (8 * 7 + XEN_BUNDLE_CMDLINE_LEN + 16) + passthrough_offsets[i]
        domain_blob += struct.pack("<I", len(dom["passthrough"]))
        domain_blob += struct.pack("<I", pt_abs_off if dom["passthrough"] else 0)
        domain_blob += struct.pack("<I", 0) + struct.pack("<I", 0)

    passthrough_data = bytearray()
    for dom in domains:
        for pt in dom["passthrough"]:
            passthrough_data.extend(pt.encode() + b"\0")
        passthrough_data.extend(b"\0")

    ram_size = int(os.environ.get("QEMU_MEM", "1G").rstrip("G")) * 0x40000000
    desc = bytearray()
    desc += struct.pack("<Q", XEN_BUNDLE_MAGIC) + struct.pack("<Q", XEN_BUNDLE_VERSION)
    desc += struct.pack("<Q", base)
    desc += struct.pack("<Q", addrs[1]) + struct.pack("<Q", len(xen_data))
    desc += struct.pack("<Q", addrs[1])  # xen_entry = load address
    desc += struct.pack("<Q", len(domains))
    desc += struct.pack("<Q", dom0_idx if dom0_idx is not None else 0xFFFFFFFFFFFFFFFF)
    desc += struct.pack("<Q", 0) + struct.pack("<Q", 0) + struct.pack("<Q", ram_size)
    desc += domain_blob + passthrough_data

    # Build flat binary output
    out = bytearray(xl_binary)
    # Pad to desc
    pad_desc = (base + desc_off) - (base + len(out))
    if pad_desc > 0:
        out.extend(b"\0" * pad_desc)
    out.extend(bytes(desc))
    # Pad to first payload
    pad_payload = addrs[1] - (base + len(out))
    if pad_payload > 0:
        out.extend(b"\0" * pad_payload)
    # Append payloads
    for blob in payload_blobs:
        out.extend(blob)

    with open(args.output, "wb") as f:
        f.write(out)
    print(f"bundle: done → {args.output} (0x{len(out):x})", file=sys.stderr)

if __name__ == "__main__":
    main()
