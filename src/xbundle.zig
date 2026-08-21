const std = @import("std");
const toml = @import("toml");
const abi = @import("abi/bundle.zig");
const manifest = @import("manifest.zig");

const PT_LOAD: u32 = 1;
const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;
const EM_AARCH64: u16 = 183;
const ARM64_IMAGE_MAGIC: u32 = 0x644d5241;
const max_segments: usize = 96;

const usage =
    \\xbundle - compile raw normalized Xen systems into one ELF bundle
    \\
    \\Usage:
    \\  xbundle abi
    \\  xbundle check <system.toml>
    \\  xbundle plan <system.toml>
    \\  xbundle build <system.toml> [-o <output.elf>]
    \\  xbundle inspect <bundle.elf>
    \\
    \\Inputs are raw blobs. xbundle does not parse loader/Xen ELF files.
    \\Executable layout comes from *.meta.toml normalization sidecars.
    \\
;

const Mode = enum { check, plan, build };

const Executable = struct {
    image_path: []const u8,
    meta_path: []const u8,
    data: []const u8,
    kind: []const u8,
    arch: []const u8,
    entry_offset: u64,
    memory_size: u64,
    load_alignment: u64,
    descriptor_offset: ?u64,
};

const DomainBuild = struct {
    cfg: manifest.DomainConfig,
    kernel: []const u8,
    initrd: ?[]const u8,
    memory_kb: u64,
    kernel_addr: u64 = 0,
    initrd_addr: u64 = 0,
};

const OutSeg = struct {
    src: []const u8,
    flags: u32,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    section_alignment: u64,
    out_off: u64 = 0,
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
        std.debug.print("xbundle ABI v{d}: header={d} domain={d} passthrough={d} capacity={d}\n", .{ abi.version, @sizeOf(abi.Header), @sizeOf(abi.Domain), @sizeOf(abi.Passthrough), abi.descriptor_capacity });
        return;
    }
    if (std.mem.eql(u8, args[1], "inspect")) {
        if (args.len != 3) fatal("usage: xbundle inspect <bundle.elf>\n", .{});
        inspectBundle(args[2], try readFile(io, arena, args[2]));
        return;
    }

    const mode: Mode = blk: {
        if (std.mem.eql(u8, args[1], "check")) break :blk .check;
        if (std.mem.eql(u8, args[1], "plan")) break :blk .plan;
        if (std.mem.eql(u8, args[1], "build")) break :blk .build;
        fatal("unknown command: {s}\n", .{args[1]});
    };

    if (args.len < 3) fatal("{s} requires <system.toml>\n", .{args[1]});
    var output_override: ?[]const u8 = null;
    if (args.len > 3) {
        if (args.len != 5 or !std.mem.eql(u8, args[3], "-o"))
            fatal("usage: xbundle {s} <system.toml> [-o output.elf]\n", .{args[1]});
        output_override = args[4];
    }

    var parser = toml.Parser(manifest.SystemConfig).init(init.gpa);
    defer parser.deinit();
    var parsed = parser.parseFile(io, args[2]) catch |err| fatal("cannot parse {s}: {s}\n", .{ args[2], @errorName(err) });
    defer parsed.deinit();
    try compileManifest(init, arena, parsed.value, mode, output_override);
}

fn compileManifest(init: std.process.Init, allocator: std.mem.Allocator, cfg: manifest.SystemConfig, mode: Mode, output_override: ?[]const u8) !void {
    const io = init.io;
    if (cfg.format != 1) fatal("unsupported system.toml format {d}; supported: 1\n", .{cfg.format});
    const machine = machineForArch(cfg.platform.arch);
    if (cfg.domain.len == 0) fatal("configuration must contain at least one [[domain]]\n", .{});
    if (cfg.domain.len > abi.sanity_max_domains) fatal("too many domains: {d}\n", .{cfg.domain.len});

    const loader = try loadExecutable(init, allocator, cfg.loader.image, cfg.loader.metadata, "loader", cfg.platform.arch);
    const xen = try loadExecutable(init, allocator, cfg.xen.image, cfg.xen.metadata, "xen", cfg.platform.arch);
    if (loader.descriptor_offset == null) fatal("loader metadata must contain descriptor_offset\n", .{});
    if (loader.descriptor_offset.? + @as(u64, abi.descriptor_capacity) > @as(u64, @intCast(loader.data.len)))
        fatal("loader descriptor range exceeds raw loader file; descriptor must be file-backed\n", .{});

    const layout_cfg = cfg.layout;
    const loader_base = if (layout_cfg) |l| parseLoaderBase(l, machine) else defaultLoaderBase(machine);
    const xen_base = if (layout_cfg) |l| parseXenBase(l, loader_base, loader.memory_size, xen.load_alignment) else roundUp(loader_base + loader.memory_size, xen.load_alignment);
    const payload_alignment = if (layout_cfg) |l| parseSize(l.payload_alignment) else 2 * 1024 * 1024;
    if (!isPowerOfTwo(payload_alignment)) fatal("payload_alignment must be a power of two\n", .{});
    if ((loader_base & (loader.load_alignment - 1)) != 0) fatal("loader_base violates loader metadata alignment\n", .{});
    if ((xen_base & (xen.load_alignment - 1)) != 0) fatal("xen_base violates Xen metadata alignment\n", .{});
    if (rangesOverlap(loader_base, loader.memory_size, xen_base, xen.memory_size)) fatal("loader and Xen memory ranges overlap\n", .{});

    const domains = try allocator.alloc(DomainBuild, cfg.domain.len);
    var passthrough_total: usize = 0;
    for (cfg.domain, 0..) |d, i| {
        validateDomainConfig(d, i, cfg.domain);
        const kernel = try readFile(io, allocator, d.kernel);
        validateDomainKernel(d, kernel, machine);
        const initrd = if (d.initrd) |p| try readFile(io, allocator, p) else null;
        const mem = parseSize(d.memory);
        if (mem == 0 or mem % 1024 != 0) fatal("domain '{s}': memory must be non-zero and KiB aligned\n", .{d.name});
        domains[i] = .{ .cfg = d, .kernel = kernel, .initrd = initrd, .memory_kb = mem / 1024 };
        passthrough_total += d.passthrough.len;
        if (passthrough_total > abi.sanity_max_passthrough) fatal("too many passthrough entries\n", .{});
    }

    var cursor = roundUp(@max(loader_base + loader.memory_size, xen_base + xen.memory_size), payload_alignment);
    for (domains) |*d| {
        d.kernel_addr = cursor;
        cursor = roundUp(checkedEnd(cursor, @intCast(d.kernel.len)), payload_alignment);
        if (d.initrd) |r| {
            d.initrd_addr = cursor;
            cursor = roundUp(checkedEnd(cursor, @intCast(r.len)), payload_alignment);
        }
    }

    std.debug.print("xbundle {s}: {s} raw-input mode\n", .{ @tagName(mode), cfg.platform.arch });
    std.debug.print("  loader: {s} + {s} -> 0x{x} entry=0x{x} mem=0x{x}\n", .{ cfg.loader.image, cfg.loader.metadata, loader_base, loader_base + loader.entry_offset, loader.memory_size });
    std.debug.print("  Xen:    {s} + {s} -> 0x{x} entry=0x{x} mem=0x{x}\n", .{ cfg.xen.image, cfg.xen.metadata, xen_base, xen_base + xen.entry_offset, xen.memory_size });
    for (domains, 0..) |d, i| {
        std.debug.print("  domain[{d}] {s}: kernel=0x{x}+0x{x} memory={d}KiB vcpus={d}\n", .{ i, d.cfg.name, d.kernel_addr, d.kernel.len, d.memory_kb, d.cfg.vcpus });
        if (d.initrd) |r| std.debug.print("    initrd=0x{x}+0x{x}\n", .{ d.initrd_addr, r.len });
        for (d.cfg.passthrough) |pt| {
            const mmio = pt.mmio.?;
            const host_addr = parseAddress(mmio.host);
            const guest_addr = if (std.mem.eql(u8, mmio.guest, "same")) host_addr else parseAddress(mmio.guest);
            const mmio_size = parseSizeOrAddress(mmio.size);
            std.debug.print("    passthrough: {s} mmio=0x{x}->0x{x}+0x{x}", .{ pt.path, host_addr, guest_addr, mmio_size });
            if (pt.irq) |irq| std.debug.print(" irq={s}:{d} flags=0x{x}", .{ irq.type, irq.number, irq.flags });
            if (pt.force_assign_without_iommu) std.debug.print(" force-no-iommu", .{});
            if (pt.strip_external_dependencies) std.debug.print(" strip-external-deps", .{});
            std.debug.print("\n", .{});
        }
    }

    if (mode == .check) {
        std.debug.print("  validation: PASS\n", .{});
        return;
    }
    if (mode == .plan) {
        std.debug.print("  planned payload end: 0x{x}\n", .{cursor});
        return;
    }

    const output = output_override orelse cfg.bundle.output;
    try buildCombined(io, allocator, machine, loader, loader_base, xen, xen_base, domains, passthrough_total, cfg.xen.cmdline, payload_alignment, output);
}

fn loadExecutable(init: std.process.Init, allocator: std.mem.Allocator, image_path: []const u8, meta_path: []const u8, expected_kind: []const u8, expected_arch: []const u8) !Executable {
    const io = init.io;
    const data = try readFile(io, allocator, image_path);
    if (data.len == 0) fatal("{s}: raw image is empty\n", .{image_path});

    var parser = toml.Parser(manifest.ExecutableMetadata).init(init.gpa);
    defer parser.deinit();
    var parsed = parser.parseFile(io, meta_path) catch |err| fatal("cannot parse {s}: {s}\n", .{ meta_path, @errorName(err) });
    defer parsed.deinit();
    const m = parsed.value;
    if (m.format != 1) fatal("{s}: unsupported metadata format {d}\n", .{ meta_path, m.format });
    if (!std.mem.eql(u8, m.kind, expected_kind)) fatal("{s}: expected kind={s}, got {s}\n", .{ meta_path, expected_kind, m.kind });
    if (!std.mem.eql(u8, m.arch, expected_arch)) fatal("{s}: expected arch={s}, got {s}\n", .{ meta_path, expected_arch, m.arch });
    const entry_offset = parseAddress(m.entry_offset);
    const memory_size = parseSizeOrAddress(m.memory_size);
    const load_alignment = parseSizeOrAddress(m.load_alignment);
    if (memory_size < @as(u64, @intCast(data.len))) fatal("{s}: metadata memory_size is smaller than raw file\n", .{meta_path});
    if (entry_offset >= memory_size) fatal("{s}: entry_offset outside memory image\n", .{meta_path});
    if (!isPowerOfTwo(load_alignment)) fatal("{s}: load_alignment must be power of two\n", .{meta_path});
    return .{
        .image_path = image_path,
        .meta_path = meta_path,
        .data = data,
        .kind = m.kind,
        .arch = m.arch,
        .entry_offset = entry_offset,
        .memory_size = memory_size,
        .load_alignment = load_alignment,
        .descriptor_offset = if (m.descriptor_offset) |s| parseAddress(s) else null,
    };
}

fn buildCombined(io: std.Io, allocator: std.mem.Allocator, machine: u16, loader_in: Executable, loader_base: u64, xen: Executable, xen_base: u64, domains: []DomainBuild, passthrough_total: usize, xen_cmdline: []const u8, payload_alignment: u64, output_path: []const u8) !void {
    const loader_data = try allocator.dupe(u8, loader_in.data);
    const descriptor_offset: usize = @intCast(loader_in.descriptor_offset.?);
    const descriptor = loader_data[descriptor_offset .. descriptor_offset + abi.descriptor_capacity];

    var segs: [max_segments]OutSeg = undefined;
    var count: usize = 0;
    appendSegment(loader_data, loader_base, @intCast(loader_data.len), loader_in.memory_size, loader_in.load_alignment, 7, &segs, &count);
    appendSegment(xen.data, xen_base, @intCast(xen.data.len), xen.memory_size, xen.load_alignment, 7, &segs, &count);
    for (domains) |d| {
        appendSegment(d.kernel, d.kernel_addr, @intCast(d.kernel.len), @intCast(d.kernel.len), payload_alignment, 5, &segs, &count);
        if (d.initrd) |r| appendSegment(r, d.initrd_addr, @intCast(r.len), @intCast(r.len), payload_alignment, 4, &segs, &count);
    }

    const phnum: u16 = @intCast(count);
    var cursor: u64 = 64 + @as(u64, phnum) * 56;
    for (segs[0..count]) |*seg| {
        cursor = congruentOffset(cursor, seg.section_alignment, seg.paddr);
        seg.out_off = cursor;
        cursor = checkedEnd(cursor, seg.filesz);
    }
    const image_size = cursor;
    patchDescriptor(descriptor, image_size, xen_base, xen.memory_size, xen_base + xen.entry_offset, domains, passthrough_total, xen_cmdline);

    const out = try allocator.alloc(u8, @intCast(image_size));
    @memset(out, 0);
    writeElfHeader(out, machine, loader_base + loader_in.entry_offset, phnum);
    for (segs[0..count], 0..) |seg, i| {
        writeProgramHeader(out, i, seg);
        if (seg.filesz != 0) {
            const dst: usize = @intCast(seg.out_off);
            @memcpy(out[dst .. dst + @as(usize, @intCast(seg.filesz))], seg.src[0..@intCast(seg.filesz)]);
        }
    }
    var f = std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true }) catch |err| fatal("cannot create {s}: {s}\n", .{ output_path, @errorName(err) });
    defer f.close(io);
    try f.writeStreamingAll(io, out);
    std.debug.print("  output: {s}\n  entry: 0x{x}\n  image bytes: 0x{x}\n", .{ output_path, loader_base + loader_in.entry_offset, image_size });
}

fn appendSegment(data: []const u8, paddr: u64, filesz: u64, memsz: u64, section_alignment: u64, flags: u32, out: *[max_segments]OutSeg, count: *usize) void {
    if (count.* >= max_segments) fatal("too many output segments\n", .{});
    out[count.*] = .{ .src = data, .flags = flags, .paddr = paddr, .filesz = filesz, .memsz = memsz, .section_alignment = section_alignment };
    count.* += 1;
}

fn patchDescriptor(dst: []u8, image_size: u64, xen_addr: u64, xen_size: u64, xen_entry: u64, domains: []DomainBuild, passthrough_total: usize, xen_cmdline: []const u8) void {
    @memset(dst, 0);
    const header_size: u32 = @intCast(@sizeOf(abi.Header));
    const domain_offset = roundUpU32(header_size, 8);
    const passthrough_offset = roundUpU32(domain_offset + @as(u32, @intCast(domains.len * @sizeOf(abi.Domain))), 8);
    const string_offset = passthrough_offset + @as(u32, @intCast(passthrough_total * @sizeOf(abi.Passthrough)));
    var string_cursor = string_offset;

    writeU32(dst, 0, abi.magic);
    writeU16(dst, 4, abi.version);
    writeU16(dst, 6, @intCast(@sizeOf(abi.Header)));
    writeU32(dst, 8, 0);
    writeU32(dst, 12, 0);
    writeU64(dst, 16, image_size);
    writeU64(dst, 24, xen_entry);
    writeU64(dst, 32, xen_addr);
    writeU64(dst, 40, xen_size);
    writeU32(dst, 48, putString(dst, &string_cursor, xen_cmdline));
    writeU32(dst, 52, @intCast(domains.len));
    writeU32(dst, 56, domain_offset);
    writeU32(dst, 60, @intCast(passthrough_total));
    writeU32(dst, 64, passthrough_offset);
    writeU32(dst, 68, string_offset);

    var pt_index: usize = 0;
    for (domains, 0..) |d, i| {
        const off: usize = @intCast(domain_offset + @as(u32, @intCast(i * @sizeOf(abi.Domain))));
        const flags: u32 = (if (d.initrd != null) abi.domain_flag_has_initrd else 0) | (if (d.cfg.vpl011) abi.domain_flag_vpl011 else 0);
        writeU32(dst, off + 0, abi.domain_type_domu);
        writeU32(dst, off + 4, flags);
        writeU32(dst, off + 8, putString(dst, &string_cursor, d.cfg.name));
        writeU32(dst, off + 12, putString(dst, &string_cursor, d.cfg.cmdline));
        writeU64(dst, off + 16, d.memory_kb);
        writeU32(dst, off + 24, d.cfg.vcpus);
        writeU32(dst, off + 28, @intCast(d.cfg.passthrough.len));
        writeU32(dst, off + 32, passthrough_offset + @as(u32, @intCast(pt_index * @sizeOf(abi.Passthrough))));
        writeU32(dst, off + 36, 0);
        writeU64(dst, off + 40, d.kernel_addr);
        writeU64(dst, off + 48, @intCast(d.kernel.len));
        writeU64(dst, off + 56, d.initrd_addr);
        writeU64(dst, off + 64, if (d.initrd) |r| @intCast(r.len) else 0);
        for (d.cfg.passthrough) |pt| {
            const poff: usize = @intCast(passthrough_offset + @as(u32, @intCast(pt_index * @sizeOf(abi.Passthrough))));
            const mmio = pt.mmio.?;
            const host_addr = parseAddress(mmio.host);
            const guest_addr = if (std.mem.eql(u8, mmio.guest, "same")) host_addr else parseAddress(mmio.guest);
            const mmio_size = parseSizeOrAddress(mmio.size);
            var pt_flags: u32 = abi.passthrough_flag_has_mmio;
            if (pt.force_assign_without_iommu) pt_flags |= abi.passthrough_flag_force_assign_without_iommu;
            if (pt.strip_external_dependencies) pt_flags |= abi.passthrough_flag_strip_external_dependencies;
            var irq_type: u32 = 0;
            var irq_number: u32 = 0;
            var irq_flags: u32 = 0;
            if (pt.irq) |irq| {
                pt_flags |= abi.passthrough_flag_has_irq;
                irq_type = parseIrqType(irq.type);
                irq_number = irq.number;
                irq_flags = irq.flags;
            }
            writeU32(dst, poff + 0, putString(dst, &string_cursor, pt.path));
            writeU32(dst, poff + 4, pt_flags);
            writeU64(dst, poff + 8, host_addr);
            writeU64(dst, poff + 16, guest_addr);
            writeU64(dst, poff + 24, mmio_size);
            writeU32(dst, poff + 32, irq_type);
            writeU32(dst, poff + 36, irq_number);
            writeU32(dst, poff + 40, irq_flags);
            writeU32(dst, poff + 44, 0);
            pt_index += 1;
        }
    }
    if (@as(usize, string_cursor) > abi.descriptor_capacity) fatal("bundle descriptor exceeds {d} bytes\n", .{abi.descriptor_capacity});
    writeU32(dst, 72, string_cursor - string_offset);
    writeU32(dst, 8, string_cursor);
}

fn validateDomainConfig(d: manifest.DomainConfig, index: usize, all: []const manifest.DomainConfig) void {
    if (d.name.len == 0 or d.name.len > 63) fatal("domain[{d}]: invalid name length\n", .{index});
    if (d.vcpus == 0 or d.vcpus > 256) fatal("domain '{s}': invalid vcpus={d}\n", .{ d.name, d.vcpus });
    for (all[0..index]) |other| if (std.mem.eql(u8, d.name, other.name)) fatal("duplicate domain name '{s}'\n", .{d.name});
    for (d.passthrough, 0..) |pt, i| {
        validatePassthroughPath(d.name, pt.path);
        for (d.passthrough[0..i]) |other| if (std.mem.eql(u8, pt.path, other.path)) fatal("domain '{s}': duplicate passthrough path {s}\n", .{ d.name, pt.path });
        const mmio = pt.mmio orelse fatal("domain '{s}': passthrough {s} requires mmio in ABI v5\n", .{ d.name, pt.path });
        const host_addr = parseAddress(mmio.host);
        const guest_addr = if (std.mem.eql(u8, mmio.guest, "same")) host_addr else parseAddress(mmio.guest);
        const mmio_size = parseSizeOrAddress(mmio.size);
        if (mmio_size == 0) fatal("domain '{s}': passthrough {s} MMIO size must be non-zero\n", .{ d.name, pt.path });
        _ = checkedEnd(host_addr, mmio_size);
        _ = checkedEnd(guest_addr, mmio_size);
        if (pt.irq) |irq| {
            _ = parseIrqType(irq.type);
            if (irq.number >= 1020) fatal("domain '{s}': passthrough {s} IRQ number out of range\n", .{ d.name, pt.path });
        }
    }
}

fn validateDomainKernel(d: manifest.DomainConfig, data: []const u8, machine: u16) void {
    if (std.mem.eql(u8, d.kernel_format, "raw")) return;
    if (std.mem.eql(u8, d.kernel_format, "linux-image") or (std.mem.eql(u8, d.kernel_format, "auto") and machine == EM_AARCH64)) {
        if (machine != EM_AARCH64) fatal("domain '{s}': linux-image only supported on aarch64\n", .{d.name});
        if (data.len < 64) fatal("domain '{s}': Linux Image smaller than 64-byte header\n", .{d.name});
        if (readU32(data, 56) != ARM64_IMAGE_MAGIC) fatal("domain '{s}': invalid raw AArch64 Linux Image magic\n", .{d.name});
        return;
    }
    fatal("domain '{s}': unsupported kernel_format '{s}'\n", .{ d.name, d.kernel_format });
}

fn parseIrqType(s: []const u8) u32 {
    if (std.mem.eql(u8, s, "spi")) return abi.irq_type_spi;
    if (std.mem.eql(u8, s, "ppi")) return abi.irq_type_ppi;
    fatal("unsupported IRQ type '{s}'; expected spi or ppi\n", .{s});
}

fn validatePassthroughPath(domain_name: []const u8, path: []const u8) void {
    if (path.len < 2 or path[0] != '/') fatal("domain '{s}': passthrough path must be absolute: {s}\n", .{ domain_name, path });
    if (std.mem.indexOf(u8, path, "//") != null) fatal("domain '{s}': malformed passthrough path: {s}\n", .{ domain_name, path });
}

fn writeElfHeader(out: []u8, machine: u16, entry: u64, phnum: u16) void {
    @memset(out[0..64], 0);
    out[0] = 0x7f;
    out[1] = 'E';
    out[2] = 'L';
    out[3] = 'F';
    out[4] = 2;
    out[5] = 1;
    out[6] = 1;
    writeU16(out, 16, ET_EXEC);
    writeU16(out, 18, machine);
    writeU32(out, 20, 1);
    writeU64(out, 24, entry);
    writeU64(out, 32, 64);
    writeU16(out, 52, 64);
    writeU16(out, 54, 56);
    writeU16(out, 56, phnum);
}

fn writeProgramHeader(out: []u8, idx: usize, seg: OutSeg) void {
    const o = 64 + idx * 56;
    writeU32(out, o, PT_LOAD);
    writeU32(out, o + 4, seg.flags);
    writeU64(out, o + 8, seg.out_off);
    writeU64(out, o + 16, seg.paddr);
    writeU64(out, o + 24, seg.paddr);
    writeU64(out, o + 32, seg.filesz);
    writeU64(out, o + 40, seg.memsz);
    writeU64(out, o + 48, seg.section_alignment);
}

fn inspectBundle(path: []const u8, data: []const u8) void {
    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF")) fatal("{s}: not an xbundle ELF output\n", .{path});
    const machine = readU16(data, 18);
    const phoff = readU64(data, 32);
    const phentsize = readU16(data, 54);
    const phnum = readU16(data, 56);
    if (phentsize < 56) fatal("{s}: malformed program-header table\n", .{path});
    var desc: ?[]const u8 = null;
    var i: usize = 0;
    while (i < @as(usize, phnum)) : (i += 1) {
        const po: usize = @intCast(phoff + @as(u64, phentsize) * @as(u64, @intCast(i)));
        if (po + 56 > data.len or readU32(data, po) != PT_LOAD) continue;
        const off = readU64(data, po + 8);
        const filesz = readU64(data, po + 32);
        if (off + filesz > @as(u64, @intCast(data.len))) continue;
        const bytes = data[@intCast(off)..@intCast(off + filesz)];
        var p: usize = 0;
        while (p + @sizeOf(abi.Header) <= bytes.len) : (p += 4) {
            if (readU32(bytes, p) == abi.magic and readU16(bytes, p + 4) == abi.version) {
                const size: usize = @intCast(readU32(bytes, p + 8));
                if (size >= @sizeOf(abi.Header) and size <= abi.descriptor_capacity and p + size <= bytes.len) {
                    desc = bytes[p .. p + size];
                    break;
                }
            }
        }
        if (desc != null) break;
    }
    const d = desc orelse fatal("{s}: xbundle descriptor not found\n", .{path});
    std.debug.print("xbundle inspect: {s}\n  machine: {s}\n  Xen: 0x{x}+0x{x} entry=0x{x}\n", .{ path, machineName(machine), readU64(d, 32), readU64(d, 40), readU64(d, 24) });
    const domains = readU32(d, 52);
    const domain_offset = readU32(d, 56);
    std.debug.print("  domains: {d}\n", .{domains});
    for (0..@as(usize, domains)) |idx| {
        const off: usize = @intCast(domain_offset + @as(u32, @intCast(idx * @sizeOf(abi.Domain))));
        std.debug.print("  domain[{d}] {s}: memory={d}KiB vcpus={d} kernel=0x{x}+0x{x}\n", .{ idx, descriptorString(d, readU32(d, off + 8)), readU64(d, off + 16), readU32(d, off + 24), readU64(d, off + 40), readU64(d, off + 48) });
        const pt_count = readU32(d, off + 28);
        const pt_offset = readU32(d, off + 32);
        for (0..@as(usize, pt_count)) |pt_idx| {
            const po: usize = @intCast(pt_offset + @as(u32, @intCast(pt_idx * @sizeOf(abi.Passthrough))));
            const flags = readU32(d, po + 4);
            std.debug.print("    passthrough {s}: MMIO 0x{x}->0x{x}+0x{x}", .{ descriptorString(d, readU32(d, po)), readU64(d, po + 8), readU64(d, po + 16), readU64(d, po + 24) });
            if ((flags & abi.passthrough_flag_has_irq) != 0)
                std.debug.print(" IRQ type={d} number={d} flags=0x{x}", .{ readU32(d, po + 32), readU32(d, po + 36), readU32(d, po + 40) });
            if ((flags & abi.passthrough_flag_force_assign_without_iommu) != 0) std.debug.print(" force-no-iommu", .{});
            std.debug.print("\n", .{});
        }
    }
}

fn descriptorString(desc: []const u8, offset: u32) []const u8 {
    const start: usize = @intCast(offset);
    if (start >= desc.len) fatal("descriptor string offset outside descriptor\n", .{});
    const tail = desc[start..];
    const end = std.mem.indexOfScalar(u8, tail, 0) orelse fatal("unterminated descriptor string\n", .{});
    return tail[0..end];
}

fn machineForArch(s: []const u8) u16 {
    if (std.mem.eql(u8, s, "aarch64")) return EM_AARCH64;
    if (std.mem.eql(u8, s, "x86_64")) return EM_X86_64;
    fatal("unsupported platform.arch '{s}'\n", .{s});
}

fn machineName(m: u16) []const u8 {
    if (m == EM_AARCH64) return "aarch64";
    if (m == EM_X86_64) return "x86_64";
    return "unknown";
}

fn defaultLoaderBase(m: u16) u64 {
    if (m == EM_AARCH64) return 0x4008_0000;
    if (m == EM_X86_64) return 0x0100_0000;
    unreachable;
}

fn parseSizeOrAddress(s: []const u8) u64 {
    return if (std.mem.startsWith(u8, s, "0x")) parseAddress(s) else parseSize(s);
}

fn parseLoaderBase(l: *const manifest.LayoutConfig, machine: u16) u64 {
    return if (l.loader_base) |s| parseAddress(s) else defaultLoaderBase(machine);
}

fn parseXenBase(l: *const manifest.LayoutConfig, loader_base: u64, loader_mem: u64, xen_alignment: u64) u64 {
    return if (l.xen_base) |s| parseAddress(s) else roundUp(loader_base + loader_mem, xen_alignment);
}

fn parseSize(s: []const u8) u64 {
    if (s.len == 0) fatal("empty size\n", .{});
    var mult: u64 = 1;
    var digits = s;
    switch (s[s.len - 1]) {
        'K', 'k' => {
            mult = 1024;
            digits = s[0 .. s.len - 1];
        },
        'M', 'm' => {
            mult = 1024 * 1024;
            digits = s[0 .. s.len - 1];
        },
        'G', 'g' => {
            mult = 1024 * 1024 * 1024;
            digits = s[0 .. s.len - 1];
        },
        else => {},
    }
    const n = std.fmt.parseUnsigned(u64, digits, 10) catch fatal("invalid size: {s}\n", .{s});
    return std.math.mul(u64, n, mult) catch fatal("size overflow\n", .{});
}

fn parseAddress(s: []const u8) u64 {
    const hex = std.mem.startsWith(u8, s, "0x");
    const body = if (hex) s[2..] else s;
    return std.fmt.parseUnsigned(u64, body, if (hex) 16 else 10) catch fatal("invalid address: {s}\n", .{s});
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 * 1024)) catch |err| fatal("cannot read {s}: {s}\n", .{ path, @errorName(err) });
}
fn roundUp(v: u64, b: u64) u64 {
    if (!isPowerOfTwo(b)) fatal("invalid alignment 0x{x}\n", .{b});
    return checkedEnd(v, b - 1) & ~(b - 1);
}

fn roundUpU32(v: u32, b: u32) u32 {
    return (v + b - 1) & ~(b - 1);
}

fn isPowerOfTwo(v: u64) bool {
    return v != 0 and (v & (v - 1)) == 0;
}

fn congruentOffset(cursor: u64, b: u64, paddr: u64) u64 {
    const a = if (b == 0) 1 else b;
    if (!isPowerOfTwo(a)) fatal("invalid segment alignment\n", .{});
    const want = paddr & (a - 1);
    const have = cursor & (a - 1);
    return checkedEnd(cursor, (want + a - have) & (a - 1));
}

fn rangesOverlap(a: u64, as: u64, b: u64, bs: u64) bool {
    return a < checkedEnd(b, bs) and b < checkedEnd(a, as);
}

fn checkedEnd(a: u64, b: u64) u64 {
    return std.math.add(u64, a, b) catch fatal("address overflow\n", .{});
}
fn putString(dst: []u8, cursor: *u32, s: []const u8) u32 {
    const start = cursor.*;
    const end64 = @as(u64, start) + @as(u64, @intCast(s.len)) + 1;
    if (end64 > @as(u64, @intCast(dst.len))) fatal("descriptor string overflow\n", .{});
    const st: usize = @intCast(start);
    @memcpy(dst[st .. st + s.len], s);
    dst[st + s.len] = 0;
    cursor.* = @intCast(end64);
    return start;
}

fn readU16(d: []const u8, o: usize) u16 {
    return @as(u16, d[o]) | (@as(u16, d[o + 1]) << 8);
}

fn readU32(d: []const u8, o: usize) u32 {
    return @as(u32, d[o]) | (@as(u32, d[o + 1]) << 8) | (@as(u32, d[o + 2]) << 16) | (@as(u32, d[o + 3]) << 24);
}

fn readU64(d: []const u8, o: usize) u64 {
    return @as(u64, readU32(d, o)) | (@as(u64, readU32(d, o + 4)) << 32);
}

fn writeU16(d: []u8, o: usize, v: u16) void {
    d[o] = @truncate(v);
    d[o + 1] = @truncate(v >> 8);
}

fn writeU32(d: []u8, o: usize, v: u32) void {
    d[o] = @truncate(v);
    d[o + 1] = @truncate(v >> 8);
    d[o + 2] = @truncate(v >> 16);
    d[o + 3] = @truncate(v >> 24);
}

fn writeU64(d: []u8, o: usize, v: u64) void {
    writeU32(d, o, @truncate(v));
    writeU32(d, o + 4, @truncate(v >> 32));
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("xbundle: error: " ++ fmt, args);
    std.process.exit(1);
}
