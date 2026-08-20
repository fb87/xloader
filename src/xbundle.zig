const std = @import("std");
const toml = @import("toml");
const abi = @import("abi/bundle.zig");
const manifest = @import("manifest.zig");

const PT_LOAD: u32 = 1;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;
const EM_AARCH64: u16 = 183;
const max_segments: usize = 160;
const ARM64_IMAGE_MAGIC: u32 = 0x644d5241; // "ARM\x64"

const usage =
    \\xbundle - compile a static Xen system manifest into one ELF bundle
    \\
    \\Usage:
    \\  xbundle abi
    \\  xbundle probe <elf>
    \\  xbundle check <system.toml>
    \\  xbundle plan <system.toml>
    \\  xbundle build <system.toml> [-o <output.elf>]
    \\
;

const Mode = enum { check, plan, build };

const Load = struct {
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,
};

const Elf64 = struct {
    path: []const u8,
    data: []const u8,
    elf_type: u16,
    machine: u16,
    entry: u64,
    flags: u32,
    phoff: u64,
    phentsize: u16,
    phnum: u16,
    shoff: u64,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,

    fn parse(path: []const u8, data: []const u8) Elf64 {
        if (data.len < 64) fatal("{s}: too small for ELF64\n", .{path});
        if (!std.mem.eql(u8, data[0..4], "\x7fELF")) fatal("{s}: not an ELF file\n", .{path});
        if (data[4] != 2) fatal("{s}: expected ELF64\n", .{path});
        if (data[5] != 1) fatal("{s}: expected little-endian ELF\n", .{path});
        const result: Elf64 = .{
            .path = path,
            .data = data,
            .elf_type = readU16(data, 16),
            .machine = readU16(data, 18),
            .entry = readU64(data, 24),
            .phoff = readU64(data, 32),
            .shoff = readU64(data, 40),
            .flags = readU32(data, 48),
            .phentsize = readU16(data, 54),
            .phnum = readU16(data, 56),
            .shentsize = readU16(data, 58),
            .shnum = readU16(data, 60),
            .shstrndx = readU16(data, 62),
        };
        if (result.phentsize < 56) fatal("{s}: invalid ELF64 program-header size\n", .{path});
        result.validateProgramHeaders();
        return result;
    }

    fn validateProgramHeaders(self: Elf64) void {
        const file_len: u64 = @intCast(self.data.len);
        var i: usize = 0;
        while (i < @as(usize, self.phnum)) : (i += 1) {
            const off = self.phoff + @as(u64, self.phentsize) * @as(u64, @intCast(i));
            if (off > file_len or off + @as(u64, self.phentsize) > file_len)
                fatal("{s}: program header outside file\n", .{self.path});
            const o: usize = @intCast(off);
            if (readU32(self.data, o) != PT_LOAD) continue;
            const p_offset = readU64(self.data, o + 8);
            const p_filesz = readU64(self.data, o + 32);
            const p_memsz = readU64(self.data, o + 40);
            if (p_memsz < p_filesz) fatal("{s}: PT_LOAD memsz smaller than filesz\n", .{self.path});
            if (p_offset > file_len or p_offset + p_filesz > file_len)
                fatal("{s}: PT_LOAD file range outside ELF\n", .{self.path});
        }
    }

    fn phOffset(self: Elf64, i: usize) usize {
        return @intCast(self.phoff + @as(u64, self.phentsize) * @as(u64, @intCast(i)));
    }

    fn loadAt(self: Elf64, i: usize) Load {
        const o = self.phOffset(i);
        return .{
            .flags = readU32(self.data, o + 4),
            .offset = readU64(self.data, o + 8),
            .vaddr = readU64(self.data, o + 16),
            .paddr = readU64(self.data, o + 24),
            .filesz = readU64(self.data, o + 32),
            .memsz = readU64(self.data, o + 40),
            .alignment = readU64(self.data, o + 48),
        };
    }

    fn loadCount(self: Elf64) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < @as(usize, self.phnum)) : (i += 1) {
            if (readU32(self.data, self.phOffset(i)) == PT_LOAD) count += 1;
        }
        return count;
    }

    fn sectionFileRange(self: Elf64, wanted: []const u8) struct { off: usize, size: usize, addr: u64 } {
        if (self.shoff == 0 or self.shnum == 0 or self.shentsize < 64)
            fatal("{s}: section table required to locate {s}\n", .{ self.path, wanted });
        if (self.shstrndx >= self.shnum) fatal("{s}: invalid shstrndx\n", .{self.path});
        const file_len: u64 = @intCast(self.data.len);
        const table_end = self.shoff + @as(u64, self.shentsize) * @as(u64, self.shnum);
        if (table_end > file_len) fatal("{s}: section table outside file\n", .{self.path});
        const str_sh = self.shOffset(self.shstrndx);
        const str_off = readU64(self.data, str_sh + 24);
        const str_size = readU64(self.data, str_sh + 32);
        if (str_off + str_size > file_len) fatal("{s}: shstrtab outside file\n", .{self.path});
        const strings = self.data[@intCast(str_off)..@intCast(str_off + str_size)];
        var i: usize = 0;
        while (i < @as(usize, self.shnum)) : (i += 1) {
            const o = self.shOffset(@intCast(i));
            const name_off: usize = @intCast(readU32(self.data, o));
            if (name_off >= strings.len) continue;
            const name = zSlice(strings[name_off..]);
            if (!std.mem.eql(u8, name, wanted)) continue;
            const off = readU64(self.data, o + 24);
            const size = readU64(self.data, o + 32);
            const addr = readU64(self.data, o + 16);
            if (off + size > file_len) fatal("{s}: {s} section outside file\n", .{ self.path, wanted });
            return .{ .off = @intCast(off), .size = @intCast(size), .addr = addr };
        }
        fatal("{s}: required section {s} not found\n", .{ self.path, wanted });
    }

    fn symbolFileRange(self: Elf64, wanted: []const u8) struct { off: usize, size: usize } {
        const symtab = self.sectionFileRange(".symtab");
        const symtab_idx = self.sectionIndex(".symtab") orelse fatal("{s}: .symtab not found\n", .{self.path});
        const sym_sh = self.shOffset(symtab_idx);
        const entsize = readU64(self.data, sym_sh + 56);
        const link = readU32(self.data, sym_sh + 40);
        if (entsize < 24) fatal("{s}: invalid symbol table entry size\n", .{self.path});
        if (link >= self.shnum) fatal("{s}: invalid symbol string table link\n", .{self.path});
        const str_sh = self.shOffset(@intCast(link));
        const str_off = readU64(self.data, str_sh + 24);
        const str_size = readU64(self.data, str_sh + 32);
        const file_len: u64 = @intCast(self.data.len);
        if (str_off + str_size > file_len) fatal("{s}: symbol string table outside file\n", .{self.path});
        const strings = self.data[@intCast(str_off)..@intCast(str_off + str_size)];
        const count: usize = @intCast(symtab.size / entsize);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const o = symtab.off + i * @as(usize, @intCast(entsize));
            const name_off: usize = @intCast(readU32(self.data, o));
            if (name_off >= strings.len) continue;
            const name = zSlice(strings[name_off..]);
            if (!std.mem.eql(u8, name, wanted)) continue;
            const shndx = readU16(self.data, o + 6);
            const value = readU64(self.data, o + 8);
            const size = readU64(self.data, o + 16);
            const sec = self.shOffset(shndx);
            const sec_addr = readU64(self.data, sec + 16);
            const sec_off = readU64(self.data, sec + 24);
            if (value < sec_addr) fatal("{s}: symbol {s} value outside section\n", .{ self.path, wanted });
            const file_off = sec_off + (value - sec_addr);
            if (file_off + size > file_len) fatal("{s}: symbol {s} outside file\n", .{ self.path, wanted });
            return .{ .off = @intCast(file_off), .size = @intCast(size) };
        }
        fatal("{s}: required symbol {s} not found\n", .{ self.path, wanted });
    }

    fn sectionIndex(self: Elf64, wanted: []const u8) ?u16 {
        if (self.shoff == 0 or self.shnum == 0 or self.shentsize < 64) return null;
        if (self.shstrndx >= self.shnum) return null;
        const file_len: u64 = @intCast(self.data.len);
        const table_end = self.shoff + @as(u64, self.shentsize) * @as(u64, self.shnum);
        if (table_end > file_len) return null;
        const str_sh = self.shOffset(self.shstrndx);
        const str_off = readU64(self.data, str_sh + 24);
        const str_size = readU64(self.data, str_sh + 32);
        if (str_off + str_size > file_len) return null;
        const strings = self.data[@intCast(str_off)..@intCast(str_off + str_size)];
        var i: usize = 0;
        while (i < @as(usize, self.shnum)) : (i += 1) {
            const o = self.shOffset(@intCast(i));
            const name_off: usize = @intCast(readU32(self.data, o));
            if (name_off >= strings.len) continue;
            const name = zSlice(strings[name_off..]);
            if (std.mem.eql(u8, name, wanted)) return @intCast(i);
        }
        return null;
    }

    fn shOffset(self: Elf64, i: u16) usize {
        return @intCast(self.shoff + @as(u64, self.shentsize) * @as(u64, i));
    }

    fn printLoads(self: Elf64) void {
        std.debug.print("ELF: {s}\n  type: {d}\n  machine: {d}\n  entry: 0x{x}\n", .{ self.path, self.elf_type, self.machine, self.entry });
        var n: usize = 0;
        var i: usize = 0;
        while (i < @as(usize, self.phnum)) : (i += 1) {
            if (readU32(self.data, self.phOffset(i)) != PT_LOAD) continue;
            const l = self.loadAt(i);
            std.debug.print("  LOAD[{d}]: off=0x{x} vaddr=0x{x} paddr=0x{x} filesz=0x{x} memsz=0x{x} alignment=0x{x}\n",
                .{ n, l.offset, l.vaddr, l.paddr, l.filesz, l.memsz, l.alignment });
            n += 1;
        }
    }
};

const ImageLayout = struct {
    source_base: u64,
    source_end: u64,
    runtime_base: u64,
    runtime_end: u64,
    runtime_entry: u64,
    size: u64,
};

const OutSeg = struct {
    src: []const u8,
    src_off: u64,
    flags: u32,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,
    out_off: u64 = 0,
};

const DomainBuild = struct {
    cfg: manifest.DomainConfig,
    kernel: []const u8,
    kernel_kind: KernelKind,
    initrd: ?[]const u8,
    kernel_addr: u64 = 0,
    initrd_addr: u64 = 0,
    memory_kb: u64,
    first_passthrough: u32 = 0,
};

const KernelKind = enum {
    arm64_linux_image,
    raw,
};

const XenInput = union(enum) {
    elf: Elf64,
    raw: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try std.Io.File.stdout().writeStreamingAll(io, usage);
        return;
    }

    if (std.mem.eql(u8, args[1], "abi")) {
        std.debug.print("xbundle ABI v{d}: header={d} domain={d} passthrough={d} capacity={d}\n",
            .{ abi.version, @sizeOf(abi.Header), @sizeOf(abi.Domain), @sizeOf(abi.Passthrough), abi.descriptor_capacity });
        return;
    }
    if (std.mem.eql(u8, args[1], "probe")) {
        if (args.len != 3) fatal("usage: xbundle probe <elf>\n", .{});
        const elf = try loadElf64(io, arena, args[2]);
        elf.printLoads();
        return;
    }

    var mode: Mode = undefined;
    if (std.mem.eql(u8, args[1], "check")) mode = .check
    else if (std.mem.eql(u8, args[1], "plan")) mode = .plan
    else if (std.mem.eql(u8, args[1], "build")) mode = .build
    else fatal("unknown command: {s}\n", .{args[1]});

    if (args.len < 3) fatal("{s} requires <system.toml>\n", .{args[1]});
    var output_override: ?[]const u8 = null;
    if (args.len > 3) {
        if (args.len != 5 or !std.mem.eql(u8, args[3], "-o"))
            fatal("usage: xbundle {s} <system.toml> [-o output.elf]\n", .{args[1]});
        output_override = args[4];
    }

    var parser = toml.Parser(manifest.SystemConfig).init(init.gpa);
    defer parser.deinit();
    var parsed = parser.parseFile(io, args[2]) catch |err| {
        fatal("cannot parse {s}: {s}\n", .{ args[2], @errorName(err) });
    };
    defer parsed.deinit();

    try compileManifest(init, arena, parsed.value, mode, output_override);
}

fn compileManifest(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    cfg: manifest.SystemConfig,
    mode: Mode,
    output_override: ?[]const u8,
) !void {
    const io = init.io;
    if (cfg.format != 1) fatal("unsupported system.toml format {d}; supported: 1\n", .{cfg.format});
    const expected_machine = machineForArch(cfg.platform.arch);
    if (cfg.domain.len == 0) fatal("configuration must contain at least one [[domain]]\n", .{});
    if (cfg.domain.len > abi.sanity_max_domains) fatal("too many domains: {d}\n", .{cfg.domain.len});

    const loader_data = try readFile(io, allocator, cfg.loader.image);
    const xen_data = try readFile(io, allocator, cfg.xen.image);
    const loader_in = Elf64.parse(cfg.loader.image, loader_data);
    const xen: XenInput = if (isElf64(xen_data)) .{ .elf = Elf64.parse(cfg.xen.image, xen_data) } else .{ .raw = xen_data };
    if (loader_in.machine != expected_machine or !xenMachineMatches(xen, expected_machine))
        fatal("manifest architecture '{s}' does not match loader/Xen ELF machine\n", .{cfg.platform.arch});
    if (loader_in.elf_type != ET_DYN)
        fatal("{s}: xloader must be position-independent ET_DYN in v6\n", .{loader_in.path});

    const layout_cfg = cfg.layout;
    const loader_base = if (layout_cfg) |l| if (l.loader_base) |s| parseAddress(s) else defaultLoaderBase(expected_machine) else defaultLoaderBase(expected_machine);
    const xen_base = if (layout_cfg) |l| if (l.xen_base) |s| parseAddress(s) else defaultXenBase(expected_machine) else defaultXenBase(expected_machine);
    const payload_alignment = if (layout_cfg) |l| parseSize(l.payload_alignment) else 2 * 1024 * 1024;
    if (!isPowerOfTwo(payload_alignment)) fatal("payload_alignment must be a power of two\n", .{});

    const loader_layout = elfImageLayout(loader_in, loader_base);
    const xen_layout = xenLayout(xen, xen_base);
    if (rangesOverlap(loader_layout.runtime_base, loader_layout.size, xen_layout.runtime_base, xen_layout.size))
        fatal("loader and Xen runtime layouts overlap\n", .{});

    const domains = try allocator.alloc(DomainBuild, cfg.domain.len);
    var passthrough_total: usize = 0;
    for (cfg.domain, 0..) |d, i| {
        validateDomainConfig(d, i);
        const kernel = try readFile(io, allocator, d.kernel);
        if (kernel.len == 0) fatal("domain '{s}' kernel is empty\n", .{d.name});
        const kernel_kind = validateDomainKernel(d, kernel, expected_machine);
        const initrd_data = if (d.initrd) |p| try readFile(io, allocator, p) else null;
        const mem_bytes = parseSize(d.memory);
        if (mem_bytes == 0 or mem_bytes % 1024 != 0) fatal("domain '{s}': memory must be non-zero and KiB aligned\n", .{d.name});
        domains[i] = .{
            .cfg = d,
            .kernel = kernel,
            .kernel_kind = kernel_kind,
            .initrd = initrd_data,
            .memory_kb = mem_bytes / 1024,
            .first_passthrough = @intCast(passthrough_total),
        };
        passthrough_total += d.passthrough.len;
        if (passthrough_total > abi.sanity_max_passthrough) fatal("too many passthrough entries\n", .{});
    }

    var payload_cursor = roundUp(@max(loader_layout.runtime_end, xen_layout.runtime_end), payload_alignment);
    for (domains) |*d| {
        d.kernel_addr = payload_cursor;
        payload_cursor = roundUp(checkedEnd(payload_cursor, @intCast(d.kernel.len)), payload_alignment);
        if (d.initrd) |initrd_data| {
            d.initrd_addr = payload_cursor;
            payload_cursor = roundUp(checkedEnd(payload_cursor, @intCast(initrd_data.len)), payload_alignment);
        }
    }

    std.debug.print("xbundle {s}: {s}\n", .{ @tagName(mode), cfg.platform.arch });
    std.debug.print("  loader: {s} -> 0x{x} entry=0x{x}\n", .{ cfg.loader.image, loader_layout.runtime_base, loader_layout.runtime_entry });
    std.debug.print("  Xen:    {s} -> 0x{x} entry=0x{x}\n", .{ cfg.xen.image, xen_layout.runtime_base, xen_layout.runtime_entry });
    std.debug.print("  domains: {d}, passthrough paths: {d}\n", .{ domains.len, passthrough_total });
    for (domains, 0..) |d, i| {
        std.debug.print("  domain[{d}] {s}: kernel=0x{x} kind={s} memory={d} KiB vcpus={d} passthrough={d}\n",
            .{ i, d.cfg.name, d.kernel_addr, @tagName(d.kernel_kind), d.memory_kb, d.cfg.vcpus, d.cfg.passthrough.len });
        if (d.initrd) |r| std.debug.print("    initrd=0x{x} size=0x{x}\n", .{ d.initrd_addr, r.len });
        for (d.cfg.passthrough) |pt| std.debug.print("    passthrough: {s}\n", .{pt.path});
    }

    if (mode == .check) {
        std.debug.print("  validation: PASS\n", .{});
        return;
    }
    if (mode == .plan) {
        std.debug.print("  planned payload end: 0x{x}\n", .{payload_cursor});
        return;
    }

    const output_path = output_override orelse cfg.bundle.output;
    try buildCombined(io, allocator, loader_in, loader_layout, xen, xen_layout, domains, passthrough_total, cfg.xen.cmdline, payload_alignment, output_path);
}

fn validateDomainKernel(d: manifest.DomainConfig, data: []const u8, machine: u16) KernelKind {
    if (std.mem.eql(u8, d.kernel_format, "raw")) return .raw;

    if (std.mem.eql(u8, d.kernel_format, "linux-image")) {
        if (machine != EM_AARCH64)
            fatal("domain '{s}': kernel_format=linux-image is only valid for aarch64\n", .{d.name});
        validateArm64LinuxImage(d.name, data);
        return .arm64_linux_image;
    }

    if (!std.mem.eql(u8, d.kernel_format, "auto"))
        fatal("domain '{s}': unsupported kernel_format '{s}' (expected auto, linux-image, or raw)\n", .{ d.name, d.kernel_format });

    if (machine == EM_AARCH64) {
        validateArm64LinuxImage(d.name, data);
        return .arm64_linux_image;
    }

    // x86 guest-kernel format handling (bzImage/PVH) is a later milestone.
    // Until then, generic raw payloads must be requested explicitly.
    fatal("domain '{s}': kernel_format=auto is not implemented for this architecture; use kernel_format=raw explicitly\n", .{d.name});
}

fn validateArm64LinuxImage(name: []const u8, data: []const u8) void {
    if (data.len < 64)
        fatal("domain '{s}': AArch64 Linux Image is smaller than its 64-byte header\n", .{name});
    const magic = readU32(data, 56);
    if (magic != ARM64_IMAGE_MAGIC) {
        if (std.mem.eql(u8, data[0..4], "\x7fELF"))
            fatal("domain '{s}': expected raw AArch64 Linux Image, got ELF; use the kernel Image artifact, not vmlinux\n", .{name});
        fatal("domain '{s}': invalid AArch64 Linux Image magic 0x{x}; expected 0x{x}\n", .{ name, magic, ARM64_IMAGE_MAGIC });
    }

    const text_offset = readU64(data, 8);
    const effective_size = readU64(data, 16);
    const flags = readU64(data, 24);
    if ((flags & 1) != 0)
        fatal("domain '{s}': big-endian AArch64 Linux Image is not supported\n", .{name});

    std.debug.print("    Linux Image header: text_offset=0x{x} image_size=0x{x} flags=0x{x} file_size=0x{x}\n",
        .{ text_offset, effective_size, flags, data.len });
}

fn validateDomainConfig(d: manifest.DomainConfig, index: usize) void {
    if (d.name.len == 0) fatal("domain[{d}]: name must not be empty\n", .{index});
    if (d.vcpus == 0 or d.vcpus > 256) fatal("domain '{s}': invalid vcpus={d}\n", .{ d.name, d.vcpus });
    for (d.passthrough) |pt| {
        if (pt.path.len == 0 or pt.path[0] != '/') fatal("domain '{s}': passthrough path must be absolute: {s}\n", .{ d.name, pt.path });
    }
}

fn buildCombined(
    io: std.Io,
    allocator: std.mem.Allocator,
    loader_in: Elf64,
    loader_layout: ImageLayout,
    xen: XenInput,
    xen_layout: ImageLayout,
    domains: []DomainBuild,
    passthrough_total: usize,
    xen_cmdline: []const u8,
    payload_alignment: u64,
    output_path: []const u8,
) !void {
    const loader_data = try allocator.dupe(u8, loader_in.data);
    const loader = Elf64.parse(loader_in.path, loader_data);
    const desc = loader.symbolFileRange("xbundle_storage");
    if (desc.size < abi.descriptor_capacity)
        fatal("{s}: .xbundle capacity is {d}, need {d}\n", .{ loader.path, desc.size, abi.descriptor_capacity });

    var segs: [max_segments]OutSeg = undefined;
    var seg_count: usize = 0;
    appendRelocatedSegments(loader, loader_layout, &segs, &seg_count);
    switch (xen) {
        .elf => |x| appendRelocatedSegments(x, xen_layout, &segs, &seg_count),
        .raw => |raw| appendRawPayload(raw, xen_layout.runtime_base, payload_alignment, &segs, &seg_count),
    }
    for (domains) |d| {
        appendRawPayload(d.kernel, d.kernel_addr, payload_alignment, &segs, &seg_count);
        if (d.initrd) |r| appendRawPayload(r, d.initrd_addr, payload_alignment, &segs, &seg_count);
    }

    const phnum: u16 = @intCast(seg_count);
    var cursor: u64 = 64 + @as(u64, phnum) * 56;
    for (segs[0..seg_count]) |*seg| {
        const alignment = if (seg.alignment > 1) seg.alignment else 1;
        seg.out_off = congruentOffset(cursor, alignment, seg.vaddr);
        cursor = checkedEnd(seg.out_off, seg.filesz);
    }
    const image_size = cursor;

    const descriptor = loader_data[desc.off .. desc.off + abi.descriptor_capacity];
    patchDescriptor(descriptor, image_size, xen_layout, domains, passthrough_total, xen_cmdline);

    if (image_size > 2 * 1024 * 1024 * 1024) fatal("combined ELF exceeds 2 GiB\n", .{});
    const out = try allocator.alloc(u8, @intCast(image_size));
    @memset(out, 0);
    writeElfHeader(out, loader, loader_layout.runtime_entry, phnum);
    for (segs[0..seg_count], 0..) |seg, idx| {
        writeProgramHeader(out, idx, seg);
        if (seg.filesz == 0) continue;
        const src_start: usize = @intCast(seg.src_off);
        const src_end: usize = @intCast(seg.src_off + seg.filesz);
        const dst_start: usize = @intCast(seg.out_off);
        @memcpy(out[dst_start .. dst_start + @as(usize, @intCast(seg.filesz))], seg.src[src_start..src_end]);
    }

    var file = std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true }) catch |err| {
        fatal("cannot create {s}: {s}\n", .{ output_path, @errorName(err) });
    };
    defer file.close(io);
    try file.writeStreamingAll(io, out);
    std.debug.print("  output: {s}\n  entry: 0x{x}\n  image bytes: 0x{x}\n", .{ output_path, loader_layout.runtime_entry, image_size });
}

fn patchDescriptor(
    dst: []u8,
    image_size: u64,
    xen_layout: ImageLayout,
    domains: []DomainBuild,
    passthrough_total: usize,
    xen_cmdline: []const u8,
) void {
    @memset(dst, 0);
    const header_size: u32 = @intCast(@sizeOf(abi.Header));
    const domain_offset: u32 = roundUpU32(header_size, 8);
    const passthrough_offset: u32 = roundUpU32(domain_offset + @as(u32, @intCast(domains.len * @sizeOf(abi.Domain))), 8);
    const string_offset: u32 = passthrough_offset + @as(u32, @intCast(passthrough_total * @sizeOf(abi.Passthrough)));
    var string_cursor: u32 = string_offset;

    writeU32(dst, 0, abi.magic);
    writeU16(dst, 4, abi.version);
    writeU16(dst, 6, @intCast(@sizeOf(abi.Header)));
    writeU32(dst, 8, 0); // descriptor_size, patched last
    writeU32(dst, 12, 0);
    writeU64(dst, 16, image_size);
    writeU64(dst, 24, xen_layout.runtime_entry);
    writeU64(dst, 32, xen_layout.runtime_base);
    writeU64(dst, 40, xen_layout.size);

    const xen_cmdline_offset = putString(dst, &string_cursor, xen_cmdline);
    writeU32(dst, 48, xen_cmdline_offset);
    writeU32(dst, 52, @intCast(domains.len));
    writeU32(dst, 56, domain_offset);
    writeU32(dst, 60, @intCast(passthrough_total));
    writeU32(dst, 64, passthrough_offset);
    writeU32(dst, 68, string_offset);
    // string_size is patched after all strings.

    var pt_index: usize = 0;
    for (domains, 0..) |d, i| {
        const doff: usize = @intCast(domain_offset + @as(u32, @intCast(i * @sizeOf(abi.Domain))));
        const name_offset = putString(dst, &string_cursor, d.cfg.name);
        const cmdline_offset = putString(dst, &string_cursor, d.cfg.cmdline);
        const flags: u32 = (if (d.initrd != null) abi.domain_flag_has_initrd else 0) |
            (if (d.cfg.vpl011) abi.domain_flag_vpl011 else 0);
        writeU32(dst, doff + 0, abi.domain_type_domu);
        writeU32(dst, doff + 4, flags);
        writeU32(dst, doff + 8, name_offset);
        writeU32(dst, doff + 12, cmdline_offset);
        writeU64(dst, doff + 16, d.memory_kb);
        writeU32(dst, doff + 24, d.cfg.vcpus);
        writeU32(dst, doff + 28, @intCast(d.cfg.passthrough.len));
        const first_pt_off: u32 = passthrough_offset + @as(u32, @intCast(pt_index * @sizeOf(abi.Passthrough)));
        writeU32(dst, doff + 32, first_pt_off);
        writeU32(dst, doff + 36, 0);
        writeU64(dst, doff + 40, d.kernel_addr);
        writeU64(dst, doff + 48, @intCast(d.kernel.len));
        writeU64(dst, doff + 56, d.initrd_addr);
        writeU64(dst, doff + 64, if (d.initrd) |r| @intCast(r.len) else 0);

        for (d.cfg.passthrough) |pt| {
            const poff: usize = @intCast(passthrough_offset + @as(u32, @intCast(pt_index * @sizeOf(abi.Passthrough))));
            const path_offset = putString(dst, &string_cursor, pt.path);
            writeU32(dst, poff, path_offset);
            writeU32(dst, poff + 4, 0);
            pt_index += 1;
        }
    }

    if (string_cursor > abi.descriptor_capacity) fatal("bundle descriptor exceeds {d} bytes\n", .{abi.descriptor_capacity});
    writeU32(dst, 72, string_cursor - string_offset);
    writeU32(dst, 8, string_cursor);
}

fn putString(dst: []u8, cursor: *u32, s: []const u8) u32 {
    const start = cursor.*;
    const end64 = @as(u64, start) + @as(u64, @intCast(s.len)) + 1;
    if (end64 > dst.len) fatal("bundle descriptor string table overflow\n", .{});
    const start_usize: usize = @intCast(start);
    @memcpy(dst[start_usize .. start_usize + s.len], s);
    dst[start_usize + s.len] = 0;
    cursor.* = @intCast(end64);
    return start;
}

fn elfImageLayout(elf: Elf64, runtime_base: u64) ImageLayout {
    var source_base: u64 = std.math.maxInt(u64);
    var source_end: u64 = 0;
    var have = false;
    var entry_phys: ?u64 = null;
    var i: usize = 0;
    while (i < @as(usize, elf.phnum)) : (i += 1) {
        if (readU32(elf.data, elf.phOffset(i)) != PT_LOAD) continue;
        const l = elf.loadAt(i);
        if (l.memsz == 0) continue;
        have = true;
        if (l.paddr < source_base) source_base = l.paddr;
        const end = checkedEnd(l.paddr, l.memsz);
        if (end > source_end) source_end = end;
    }
    if (!have) fatal("{s}: no PT_LOAD segments\n", .{elf.path});
    i = 0;
    while (i < @as(usize, elf.phnum)) : (i += 1) {
        if (readU32(elf.data, elf.phOffset(i)) != PT_LOAD) continue;
        const l = elf.loadAt(i);
        if (elf.entry >= l.vaddr and elf.entry < checkedEnd(l.vaddr, l.memsz)) {
            entry_phys = runtime_base + (l.paddr - source_base) + (elf.entry - l.vaddr);
            break;
        }
    }
    if (entry_phys == null) fatal("{s}: entry not inside PT_LOAD\n", .{elf.path});
    const size = source_end - source_base;
    return .{
        .source_base = source_base,
        .source_end = source_end,
        .runtime_base = runtime_base,
        .runtime_end = checkedEnd(runtime_base, size),
        .runtime_entry = entry_phys.?,
        .size = size,
    };
}

fn rawImageLayout(data: []const u8, runtime_base: u64) ImageLayout {
    return .{
        .source_base = 0,
        .source_end = @intCast(data.len),
        .runtime_base = runtime_base,
        .runtime_end = checkedEnd(runtime_base, @intCast(data.len)),
        .runtime_entry = runtime_base,
        .size = @intCast(data.len),
    };
}

fn xenLayout(xen: XenInput, runtime_base: u64) ImageLayout {
    return switch (xen) {
        .elf => |e| elfImageLayout(e, runtime_base),
        .raw => |data| rawImageLayout(data, runtime_base),
    };
}

fn appendRelocatedSegments(elf: Elf64, layout: ImageLayout, out: *[max_segments]OutSeg, count: *usize) void {
    var i: usize = 0;
    while (i < @as(usize, elf.phnum)) : (i += 1) {
        if (readU32(elf.data, elf.phOffset(i)) != PT_LOAD) continue;
        if (count.* == max_segments) fatal("too many PT_LOAD segments\n", .{});
        const l = elf.loadAt(i);
        const runtime = layout.runtime_base + (l.paddr - layout.source_base);
        out[count.*] = .{
            .src = elf.data,
            .src_off = l.offset,
            .flags = l.flags,
            .vaddr = runtime,
            .paddr = runtime,
            .filesz = l.filesz,
            .memsz = l.memsz,
            .alignment = l.alignment,
        };
        count.* += 1;
    }
}

fn appendRawPayload(data: []const u8, paddr: u64, section_alignment: u64, out: *[max_segments]OutSeg, count: *usize) void {
    if (count.* == max_segments) fatal("too many PT_LOAD segments\n", .{});
    out[count.*] = .{
        .src = data,
        .src_off = 0,
        .flags = 4,
        .vaddr = paddr,
        .paddr = paddr,
        .filesz = @intCast(data.len),
        .memsz = @intCast(data.len),
        .alignment = section_alignment,
    };
    count.* += 1;
}

fn writeElfHeader(out: []u8, loader: Elf64, runtime_entry: u64, phnum: u16) void {
    @memset(out[0..64], 0);
    @memcpy(out[0..16], loader.data[0..16]);
    writeU16(out, 16, 2); // ET_EXEC final system image
    writeU16(out, 18, loader.machine);
    writeU32(out, 20, 1);
    writeU64(out, 24, runtime_entry);
    writeU64(out, 32, 64);
    writeU64(out, 40, 0);
    writeU32(out, 48, loader.flags);
    writeU16(out, 52, 64);
    writeU16(out, 54, 56);
    writeU16(out, 56, phnum);
}

fn writeProgramHeader(out: []u8, idx: usize, seg: OutSeg) void {
    const o = 64 + idx * 56;
    writeU32(out, o, PT_LOAD);
    writeU32(out, o + 4, seg.flags);
    writeU64(out, o + 8, seg.out_off);
    writeU64(out, o + 16, seg.vaddr);
    writeU64(out, o + 24, seg.paddr);
    writeU64(out, o + 32, seg.filesz);
    writeU64(out, o + 40, seg.memsz);
    writeU64(out, o + 48, seg.alignment);
}

fn machineForArch(s: []const u8) u16 {
    if (std.mem.eql(u8, s, "aarch64")) return EM_AARCH64;
    if (std.mem.eql(u8, s, "x86_64")) return EM_X86_64;
    fatal("unsupported platform.arch '{s}'\n", .{s});
}

fn defaultLoaderBase(machine: u16) u64 {
    if (machine == EM_AARCH64) return 0x4008_0000;
    if (machine == EM_X86_64) return 0x0100_0000;
    unreachable;
}

fn defaultXenBase(machine: u16) u64 {
    if (machine == EM_AARCH64) return 0x4040_0000;
    if (machine == EM_X86_64) return 0x0200_0000;
    unreachable;
}

fn parseSize(s: []const u8) u64 {
    if (s.len == 0) fatal("empty size\n", .{});
    var multiplier: u64 = 1;
    var digits = s;
    const last = s[s.len - 1];
    switch (last) {
        'K', 'k' => { multiplier = 1024; digits = s[0 .. s.len - 1]; },
        'M', 'm' => { multiplier = 1024 * 1024; digits = s[0 .. s.len - 1]; },
        'G', 'g' => { multiplier = 1024 * 1024 * 1024; digits = s[0 .. s.len - 1]; },
        else => {},
    }
    const n = std.fmt.parseUnsigned(u64, digits, 10) catch fatal("invalid size: {s}\n", .{s});
    return std.math.mul(u64, n, multiplier) catch fatal("size overflow: {s}\n", .{s});
}

fn parseAddress(s: []const u8) u64 {
    const hex = std.mem.startsWith(u8, s, "0x");
    const body = if (hex) s[2..] else s;
    return std.fmt.parseUnsigned(u64, body, if (hex) 16 else 10) catch fatal("invalid address: {s}\n", .{s});
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024)) catch |err| {
        fatal("cannot read {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn loadElf64(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Elf64 {
    return Elf64.parse(path, try readFile(io, allocator, path));
}

fn isElf64(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF");
}

fn xenMachineMatches(xen: XenInput, machine: u16) bool {
    return switch (xen) {
        .elf => |x| x.machine == machine,
        .raw => true,
    };
}

fn roundUp(value: u64, boundary: u64) u64 {
    if (!isPowerOfTwo(boundary)) fatal("invalid alignment 0x{x}\n", .{boundary});
    return checkedEnd(value, boundary - 1) & ~(boundary - 1);
}

fn roundUpU32(value: u32, boundary: u32) u32 {
    return (value + boundary - 1) & ~(boundary - 1);
}

fn isPowerOfTwo(v: u64) bool {
    return v != 0 and (v & (v - 1)) == 0;
}

fn congruentOffset(cursor: u64, input_alignment: u64, vaddr: u64) u64 {
    const alignment = if (input_alignment == 0) 1 else input_alignment;
    if (!isPowerOfTwo(alignment)) fatal("non-power-of-two PT_LOAD alignment 0x{x}\n", .{alignment});
    const want = vaddr & (alignment - 1);
    const have = cursor & (alignment - 1);
    const delta = (want + alignment - have) & (alignment - 1);
    return checkedEnd(cursor, delta);
}

fn rangesOverlap(a: u64, a_size: u64, b: u64, b_size: u64) bool {
    return a < checkedEnd(b, b_size) and b < checkedEnd(a, a_size);
}

fn checkedEnd(start: u64, size: u64) u64 {
    return std.math.add(u64, start, size) catch fatal("address overflow\n", .{});
}

fn zSlice(data: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, data, 0) orelse data.len;
    return data[0..end];
}

fn readU16(data: []const u8, off: usize) u16 {
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}
fn readU32(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) |
        (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) |
        (@as(u32, data[off + 3]) << 24);
}
fn readU64(data: []const u8, off: usize) u64 {
    return @as(u64, readU32(data, off)) | (@as(u64, readU32(data, off + 4)) << 32);
}
fn writeU16(data: []u8, off: usize, v: u16) void {
    data[off] = @truncate(v); data[off + 1] = @truncate(v >> 8);
}
fn writeU32(data: []u8, off: usize, v: u32) void {
    data[off] = @truncate(v); data[off + 1] = @truncate(v >> 8); data[off + 2] = @truncate(v >> 16); data[off + 3] = @truncate(v >> 24);
}
fn writeU64(data: []u8, off: usize, v: u64) void {
    writeU32(data, off, @truncate(v)); writeU32(data, off + 4, @truncate(v >> 32));
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("xbundle: error: " ++ fmt, args);
    std.process.exit(1);
}
