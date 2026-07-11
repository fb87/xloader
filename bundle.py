#!/usr/bin/env python3
"""Xen Bundle Builder.

Reads bundle.toml, xloader.elf, and domain payloads, then produces
bundle.elf with correct PT_LOAD segments for each payload.
"""

import argparse
import os
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
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
XEN_GAP = 0x100000
E = "<"  # ELF endianness (little)


def align(x, a=PAGE_SIZE):
    return (x + a - 1) & ~(a - 1)


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def elf_read_entry(path):
    data = read_file(path)
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    endian = "<" if data[5] == 1 else ">"
    return struct.unpack_from(endian + "Q" if data[4] == 2 else endian + "I", data, 24)[0]


def elf_extract_binary(path):
    """Extract loader binary: PT_LOAD data at their vaddrs."""
    data = read_file(path)
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not a valid ELF")
    endian = "<" if data[5] == 1 else ">"
    phoff = struct.unpack_from(endian + "Q", data, 32)[0]
    phnum = struct.unpack_from(endian + "H", data, 56)[0]
    phentsize = struct.unpack_from(endian + "H", data, 54)[0]
    segments = []
    min_vaddr = None
    for i in range(phnum):
        off = phoff + i * phentsize
        p_type = struct.unpack_from(endian + "I", data, off)[0]
        if p_type == 1:
            p_offset = struct.unpack_from(endian + "Q", data, off + 8)[0]
            p_vaddr = struct.unpack_from(endian + "Q", data, off + 16)[0]
            p_filesz = struct.unpack_from(endian + "Q", data, off + 32)[0]
            p_memsz = struct.unpack_from(endian + "Q", data, off + 40)[0]
            if min_vaddr is None or p_vaddr < min_vaddr:
                min_vaddr = p_vaddr
            segments.append((p_vaddr, p_offset, p_filesz, p_memsz))
    if not segments:
        raise ValueError(f"{path}: no PT_LOAD segments")
    max_end = max(s[0] + s[2] for s in segments)
    buf = bytearray(max_end - min_vaddr)
    for vaddr, offset, filesz, memsz in segments:
        start = vaddr - min_vaddr
        buf[start:start + filesz] = data[offset:offset + filesz]
    return min_vaddr, bytes(buf), segments


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


def build_passthrough_dtb(src_dtb, paths, dtc_path, output_path):
    if not paths or not dtc_path:
        return False
    dts = subprocess.check_output([dtc_path, "-I", "dtb", "-O", "dts", src_dtb], text=True)

    def extract_node(text, path):
        target = path.strip("/").split("/")[-1]
        in_target = False
        brace_count = 0
        result = []
        for line in text.split("\n"):
            s = line.strip()
            if not in_target:
                if s.startswith(target + " {"):
                    in_target = True
                    result.append(line)
                    brace_count = s.count("{") - s.count("}")
            else:
                result.append(line)
                brace_count += s.count("{") - s.count("}")
                if brace_count <= 0:
                    break
        return "\n".join(result) if result else None

    passthrough_dts = "/dts-v1/;\n/ {\n\t#address-cells = <0x02>;\n\t#size-cells = <0x02>;\n\tpassthrough {\n"
    for p in paths:
        node = extract_node(dts, p)
        if not node:
            continue
        lines = node.split("\n")
        reg_line = ""
        for line in lines:
            s = line.strip()
            if s.startswith("reg ="):
                reg_line = s
                break
        xen_reg_val = ""
        if reg_line:
            core = reg_line.split("=", 1)[-1].strip().rstrip(";").strip().strip("<>")
            parts = core.split()
            if len(parts) >= 4:
                xen_reg_val = "<" + " ".join(parts) + " " + " ".join(parts[:2]) + ">"
        for i in range(len(lines) - 1, -1, -1):
            if lines[i].strip() == "};":
                lines.insert(i, f'\t\txen,reg = {xen_reg_val};' if xen_reg_val else "")
                lines.insert(i, f'\t\txen,path = "{p}";')
                lines.insert(i, "\t\txen,force-assign-without-iommu;")
                break
        passthrough_dts += "\t\t" + "\n\t\t".join(lines) + "\n"
    passthrough_dts += "\t};\n};\n"

    with tempfile.NamedTemporaryFile(mode="w", suffix=".dts", delete=False) as f:
        f.write(passthrough_dts)
        fn = f.name
    try:
        subprocess.check_call([dtc_path, "-I", "dts", "-O", "dtb", "-o", output_path, fn])
    finally:
        os.unlink(fn)
    return True


def main():
    parser = argparse.ArgumentParser(description="Xen Bundle Builder")
    parser.add_argument("--config", default="bundle.toml")
    parser.add_argument("--dtc-path", default=None)
    parser.add_argument("-o", "--output", default="bundle.elf")
    args = parser.parse_args()

    try:
        xl_cfg, xen_cfg, domains, dom0_idx = load_config(args.config)
    except (RuntimeError, ValueError) as exc:
        print(f"bundle: {exc}", file=sys.stderr); sys.exit(1)
    if not domains:
        print("bundle: at least one domain required", file=sys.stderr); sys.exit(1)

    xl_path = xl_cfg.get("elf") or xl_cfg.get("path", "xloader.elf")
    base, xl_binary, xl_segs = elf_extract_binary(xl_path)
    print(f"bundle: xloader base=0x{base:x} size=0x{len(xl_binary):x}", file=sys.stderr)

    xen_path = xen_cfg.get("path") or "xen.elf"
    xen_data = read_file(xen_path)
    for i, dom in enumerate(domains):
        for f in ("kernel", "initrd"):
            p = dom.get(f)
            if p and not os.path.exists(p):
                print(f"bundle: domain[{i}] {f} not found: {p}", file=sys.stderr); sys.exit(1)

    payload_blobs = [xen_data]
    payload_tags = ["xen"]

    build_dir = os.path.dirname(args.output) or "."
    for i, dom in enumerate(domains):
        if dom["passthrough"] and args.dtc_path:
            qemu = os.environ.get("QEMU", "qemu-system-aarch64")
            dtb_src = os.path.join(build_dir, f".ps_{i}.dtb")
            try:
                subprocess.check_call([qemu, "-M", "virt,virtualization=on,secure=off,gic-version=3",
                    "-cpu", os.environ.get("QEMU_CPU", "cortex-a57"), "-m", "1G",
                    "-machine", f"dumpdtb={dtb_src}"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            except Exception as exc:
                print(f"bundle: DTB failed: {exc}", file=sys.stderr); sys.exit(1)
            out_dtb = os.path.join(build_dir, f"domain_{i}_passthrough.dtb")
            if build_passthrough_dtb(dtb_src, dom["passthrough"], args.dtc_path, out_dtb):
                dom["dtb_path"] = out_dtb
                print(f"bundle: domain[{i}] passthrough → {out_dtb}", file=sys.stderr)
            os.unlink(dtb_src)

    for dom in domains:
        if dom.get("kernel"):
            payload_blobs.append(read_file(dom["kernel"]))
            payload_tags.append("kernel")
        if dom.get("initrd"):
            payload_blobs.append(read_file(dom["initrd"]))
            payload_tags.append("initrd")
        if dom.get("dtb_path"):
            payload_blobs.append(read_file(dom["dtb_path"]))
            payload_tags.append("dtb")

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
    pi = 1  # payload_blobs index for current domain's first payload
    for i, dom in enumerate(domains):
        ka = addrs[pi + 1] if dom.get("kernel") else 0  # addrs[0]=xloader, addrs[1]=xen
        ks = len(payload_blobs[pi]) if dom.get("kernel") else 0
        pi += 1 if dom.get("kernel") else 0
        ia = addrs[pi + 1] if dom.get("initrd") else 0
        it = len(payload_blobs[pi]) if dom.get("initrd") else 0
        pi += 1 if dom.get("initrd") else 0
        da = addrs[pi + 1] if dom.get("dtb_path") else 0
        ds = len(payload_blobs[pi]) if dom.get("dtb_path") else 0
        pi += 1 if dom.get("dtb_path") else 0
        domain_blob += struct.pack("<Q", ka) + struct.pack("<Q", ks)
        domain_blob += struct.pack("<Q", ia) + struct.pack("<Q", it)
        domain_blob += struct.pack("<Q", da) + struct.pack("<Q", ds)
        domain_blob += struct.pack("<Q", dom.get("memory_kb", 0))
        cmd = dom["cmdline"][:XEN_BUNDLE_CMDLINE_LEN - 1].encode()
        domain_blob += cmd + b"\0" * (XEN_BUNDLE_CMDLINE_LEN - len(cmd))
        domain_blob += struct.pack("<I", len(dom["passthrough"]))
        domain_blob += struct.pack("<I", 0)
        domain_blob += struct.pack("<I", 0) + struct.pack("<I", 0)

    ram_size = int(os.environ.get("QEMU_MEM", "1G").rstrip("G")) * 0x40000000
    xen_entry = elf_read_entry(xen_path)
    desc = bytearray()
    desc += struct.pack("<Q", XEN_BUNDLE_MAGIC) + struct.pack("<Q", XEN_BUNDLE_VERSION)
    desc += struct.pack("<Q", base)
    desc += struct.pack("<Q", addrs[1]) + struct.pack("<Q", len(xen_data))
    desc += struct.pack("<Q", xen_entry if xen_entry else addrs[1])
    desc += struct.pack("<Q", len(domains))
    desc += struct.pack("<Q", dom0_idx if dom0_idx is not None else 0xFFFFFFFFFFFFFFFF)
    desc += struct.pack("<Q", 0) + struct.pack("<Q", 0) + struct.pack("<Q", ram_size)
    desc += domain_blob + passthrough_data

    # --- Assemble ELF ---
    # Collect all segments: (vaddr, data)
    segments = [(s[0], read_file(xl_path)[s[1]:s[1] + s[2]]) for s in xl_segs if s[2] > 0]
    # Add desc segment
    segments.append((base + desc_off, bytes(desc)))
    # Add payloads
    for i in range(len(payload_blobs)):
        segments.append((addrs[1 + i], payload_blobs[i]))

    # Write file: ELF header + PHDRs + data
    phnum = len(segments)
    phentsize = 56
    # We'll place PHDRs at offset 0x40, header is 64 bytes
    phoff = 64
    # Data starts after PHDRs, aligned
    data_off = align(phoff + phnum * phentsize)

    # Build PHDRs and data
    phdrs = bytearray()
    data = bytearray()
    for vaddr, blob in segments:
        foff = data_off + len(data)  # file offset for this segment
        ph = struct.pack(E + "I", 1) + struct.pack(E + "I", 7)  # PT_LOAD, rwx
        ph += struct.pack(E + "Q", foff) + struct.pack(E + "Q", vaddr) + struct.pack(E + "Q", vaddr)
        ph += struct.pack(E + "Q", len(blob)) + struct.pack(E + "Q", len(blob)) + struct.pack(E + "Q", 0x10000)
        phdrs += ph
        data += blob
        # Align data for next segment
        pad = align(len(data)) - len(data)
        if pad:
            data.extend(b"\0" * pad)

    # ELF header — pack as a single structure
    elf = struct.pack("<4sBBBB", b"\x7fELF", 2, 1, 1, 0)  # magic, ELF64, LE, ver1, OS/ABI=0
    elf += struct.pack("<8B", 0, 0, 0, 0, 0, 0, 0, 0)  # ABIVersion + padding
    elf += struct.pack("<HHI", 2, 0xB7, 1)  # EXEC, AArch64, version 1
    elf += struct.pack("<QQ", base, phoff)  # entry, phoff
    elf += struct.pack("<Q", 0)  # shoff=0
    elf += struct.pack("<IHH", 0, 64, phentsize)  # flags=0, ehsize=64, phentsize
    elf += struct.pack("<HHHH", phnum, 0, 0, 0)  # phnum, shnum=0, shstrndx=0, padding=0

    elf += phdrs
    # Pad to data_off
    if len(elf) < data_off:
        elf += b"\0" * (data_off - len(elf))
    elf += data

    with open(args.output, "wb") as f:
        f.write(elf)
    print(f"bundle: done → {args.output} (0x{len(elf):x})", file=sys.stderr)


if __name__ == "__main__":
    main()
