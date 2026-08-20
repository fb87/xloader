const abi = @import("abi/bundle.zig");
const dt = @import("loader/dt.zig");
const builtin = @import("builtin");
const minic = @import("runtime/minic.zig");
comptime { _ = minic; }

const pl011_base: usize = 0x0900_0000;
const kernel_compatible = "multiboot,kernel\x00multiboot,module\x00";
const ramdisk_compatible = "multiboot,ramdisk\x00multiboot,module\x00";
const devicetree_compatible = "multiboot,device-tree\x00multiboot,module\x00";

extern fn arch_console_putc(ch: u8) void;
extern fn arch_enter_xen(entry: usize, dtb: usize) noreturn;

pub export var xbundle_storage: abi.Storage linksection(".xbundle") = .{
    .header = .{
        .magic = abi.magic,
        .version = abi.version,
        .header_size = @sizeOf(abi.Header),
        .descriptor_size = @sizeOf(abi.Header),
        .flags = 0,
        .image_size = 0,
        .xen_entry = 0,
        .xen_addr = 0,
        .xen_size = 0,
        .xen_cmdline_offset = 0,
        .domain_count = 0,
        .domain_offset = 0,
        .passthrough_count = 0,
        .passthrough_offset = 0,
        .string_offset = 0,
        .string_size = 0,
        .reserved0 = 0,
    },
    .rest = [_]u8{0} ** (abi.descriptor_capacity - @sizeOf(abi.Header)),
};

var dtb_workspace_words: [dt.workspace_size / @sizeOf(u64)]u64 = undefined;
var passthrough_workspace_words: [(abi.sanity_max_domains * dt.passthrough_slot_size) / @sizeOf(u64)]u64 = undefined;

fn dtbWorkspace() []u8 {
    const ptr: [*]u8 = @ptrCast(&dtb_workspace_words);
    return ptr[0..dt.workspace_size];
}

fn passthroughSlot(index: usize) []u8 {
    if (index >= abi.sanity_max_domains) panicMessage("passthrough slot index out of range");
    const ptr: [*]u8 = @ptrCast(&passthrough_workspace_words);
    const start = index * dt.passthrough_slot_size;
    return ptr[start .. start + dt.passthrough_slot_size];
}

fn putc(ch: u8) void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            const dr: *volatile u8 = @ptrFromInt(pl011_base);
            dr.* = ch;
        },
        .x86_64 => arch_console_putc(ch),
        else => @compileError("unsupported xloader architecture"),
    }
}

fn puts(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') putc('\r');
        putc(ch);
    }
}

fn putsZ(s: [*:0]const u8) void {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) putc(s[i]);
}

fn putDec(value: usize) void {
    var buf: [24]u8 = undefined;
    var pos: usize = buf.len;
    var v = value;
    if (v == 0) {
        putc('0');
        return;
    }
    while (v != 0) {
        pos -= 1;
        buf[pos] = @intCast('0' + (v % 10));
        v /= 10;
    }
    puts(buf[pos..]);
}

fn putHex(value: usize) void {
    const digits = "0123456789abcdef";
    puts("0x");
    var shift: usize = @bitSizeOf(usize);
    while (shift != 0) {
        shift -= 4;
        const nibble: usize = (value >> @intCast(shift)) & 0xf;
        putc(digits[nibble]);
    }
}

fn halt() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile ("wfe"),
            .x86_64 => asm volatile ("hlt"),
            else => unreachable,
        }
    }
}

fn panicMessage(msg: []const u8) noreturn {
    puts("xloader: ERROR: ");
    puts(msg);
    puts("\n");
    halt();
}

fn bundle() *const abi.Header {
    if (!xbundle_storage.header.validBasic()) panicMessage("invalid or unpatched xbundle descriptor");
    return &xbundle_storage.header;
}

fn descriptorBase() usize {
    return @intFromPtr(&xbundle_storage);
}

fn domainAt(b: *const abi.Header, index: usize) *const volatile abi.Domain {
    if (index >= b.domain_count) panicMessage("domain index out of range");
    const off = @as(usize, b.domain_offset) + index * @sizeOf(abi.Domain);
    if (off + @sizeOf(abi.Domain) > b.descriptor_size) panicMessage("domain table outside descriptor");
    return @ptrFromInt(descriptorBase() + off);
}

fn passthroughAt(b: *const abi.Header, byte_offset: u32, index: usize) *const volatile abi.Passthrough {
    const off = @as(usize, byte_offset) + index * @sizeOf(abi.Passthrough);
    if (off + @sizeOf(abi.Passthrough) > b.descriptor_size) panicMessage("passthrough table outside descriptor");
    return @ptrFromInt(descriptorBase() + off);
}

fn stringAt(b: *const abi.Header, offset: u32) [*:0]const u8 {
    if (offset < b.string_offset or offset >= b.descriptor_size) panicMessage("string offset outside descriptor");
    const base: [*]const u8 = @ptrFromInt(descriptorBase());
    var i: usize = offset;
    while (i < b.descriptor_size and base[i] != 0) : (i += 1) {}
    if (i >= b.descriptor_size) panicMessage("unterminated descriptor string");
    return @ptrFromInt(descriptorBase() + offset);
}

fn makeDomuName(index: usize, buf: *[16]u8) [*:0]const u8 {
    const prefix = "domU";
    @memcpy(buf[0..prefix.len], prefix);
    var digits: [10]u8 = undefined;
    var n = index;
    var count: usize = 0;
    if (n == 0) {
        digits[0] = '0';
        count = 1;
    } else {
        while (n != 0) : (n /= 10) {
            digits[count] = @intCast('0' + (n % 10));
            count += 1;
        }
    }
    var p = prefix.len;
    while (count != 0) {
        count -= 1;
        buf[p] = digits[count];
        p += 1;
    }
    buf[p] = 0;
    return @ptrCast(buf);
}

fn buildDomuPath(index: usize, buf: *[32]u8) [*:0]const u8 {
    const chosen = "/chosen/";
    @memcpy(buf[0..chosen.len], chosen);
    var p = chosen.len;
    const suffix = "domU";
    @memcpy(buf[p .. p + suffix.len], suffix);
    p += suffix.len;
    var n = index;
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    if (n == 0) {
        digits[0] = '0';
        count = 1;
    } else {
        while (n != 0) : (n /= 10) {
            digits[count] = @intCast('0' + (n % 10));
            count += 1;
        }
    }
    while (count != 0) {
        count -= 1;
        buf[p] = digits[count];
        p += 1;
    }
    buf[p] = 0;
    return @ptrCast(buf);
}

fn addPassthroughModule(tree: *dt.DeviceTree, b: *const abi.Header, d: *const volatile abi.Domain, index: usize, domain_name: [*:0]const u8) void {
    if (d.passthrough_count == 0) return;
    if (d.passthrough_count > abi.sanity_max_passthrough) panicMessage("invalid passthrough count");

    // The descriptor sits at an 8-mod-16 offset; this QEMU aborts on 16-byte
    // accesses there, so read item fields as scalars and write the spec copy
    // through a volatile (aligned) pointer to avoid fused wide accesses.
    var specs: [abi.sanity_max_passthrough]dt.PassthroughSpec align(16) = undefined;
    var i: usize = 0;
    while (i < d.passthrough_count) : (i += 1) {
        const item = passthroughAt(b, d.passthrough_offset, i);
        const path = stringAt(b, item.path_offset);
        _ = tree.findNode(path) catch {
            puts("xloader: passthrough node not found for ");
            putsZ(domain_name);
            puts(": ");
            putsZ(path);
            puts("\n");
            panicMessage("invalid passthrough FDT path");
        };
        if ((item.flags & abi.passthrough_flag_has_mmio) == 0 or item.size == 0)
            panicMessage("passthrough resource lacks MMIO grant");

        const sv: *volatile dt.PassthroughSpec = @ptrCast(&specs[i]);
        sv.* = .{
            .path = path,
            .host_addr = item.host_addr,
            .guest_addr = item.guest_addr,
            .size = item.size,
            .force_assign_without_iommu = (item.flags & abi.passthrough_flag_force_assign_without_iommu) != 0,
            .strip_external_dependencies = (item.flags & abi.passthrough_flag_strip_external_dependencies) != 0,
            .has_irq = (item.flags & abi.passthrough_flag_has_irq) != 0,
            .irq_type = item.irq_type,
            .irq_number = item.irq_number,
            .irq_flags = item.irq_flags,
        };

        puts("xloader: passthrough ");
        putsZ(domain_name);
        puts(" <- ");
        putsZ(path);
        puts(" MMIO ");
        putHex(@intCast(item.host_addr));
        puts(" -> ");
        putHex(@intCast(item.guest_addr));
        puts(" size ");
        putHex(@intCast(item.size));
        if ((item.flags & abi.passthrough_flag_has_irq) != 0) {
            puts(" IRQ ");
            putDec(item.irq_number);
        }
        puts("\n");
    }

    const partial = tree.buildPassthroughTree(specs[0..d.passthrough_count], passthroughSlot(index)) catch |err| switch (err) {
        error.ExternalDependency => panicMessage("passthrough subtree has external dependency; opt in to stripping or include dependency"),
        error.NoSpace => panicMessage("passthrough partial DT exceeds per-domain workspace"),
        else => panicMessage("cannot build passthrough partial DT"),
    };
    const partial_addr = @intFromPtr(partial.ptr);
    if (partial_addr > 0xffff_ffff or partial.len > 0xffff_ffff)
        panicMessage("passthrough partial DT must be below 4 GiB in v10");

    // libfdt mutations in buildPassthroughTree can shift later structure-block
    // offsets, so re-resolve the DomU node before adding module@2.
    var path_buf: [32]u8 = undefined;
    const dom_path = buildDomuPath(index, &path_buf);
    const domu_now = tree.findNode(dom_path) catch panicMessage("cannot re-resolve passthrough DomU node");
    const module = tree.addNode(domu_now, "module@2") catch panicMessage("cannot create passthrough DT module");
    tree.setBytes(module, "compatible", devicetree_compatible) catch panicMessage("cannot set passthrough module compatible");
    tree.setU32Pair(module, "reg", @intCast(partial_addr), @intCast(partial.len)) catch panicMessage("cannot set passthrough module reg");

    puts("xloader: passthrough DT ");
    putsZ(domain_name);
    puts(" @ ");
    putHex(partial_addr);
    puts(" size ");
    putHex(partial.len);
    puts("\n");
}

fn addDomu(tree: *dt.DeviceTree, chosen: dt.Node, b: *const abi.Header, d: *const volatile abi.Domain, index: usize) void {
    if (d.domain_type != abi.domain_type_domu) panicMessage("unsupported domain type");
    if (d.kernel.addr > 0xffff_ffff or d.kernel.size > 0xffff_ffff) panicMessage("DomU kernel must be below 4 GiB in v10");
    if (d.memory_kb == 0 or d.memory_kb > 0xffff_ffff) panicMessage("invalid DomU memory size");
    if (d.vcpus == 0) panicMessage("invalid DomU vCPU count");

    var node_buf: [16]u8 = undefined;
    const node_name = makeDomuName(index, &node_buf);
    const domu = tree.addNode(chosen, node_name) catch panicMessage("cannot create DomU node");
    tree.setU32(domu, "#address-cells", 1) catch panicMessage("cannot set DomU address cells");
    tree.setU32(domu, "#size-cells", 1) catch panicMessage("cannot set DomU size cells");
    tree.setString(domu, "compatible", "xen,domain") catch panicMessage("cannot set DomU compatible");
    tree.setU32Pair(domu, "memory", 0, @intCast(d.memory_kb)) catch panicMessage("cannot set DomU memory");
    tree.setU32(domu, "cpus", d.vcpus) catch panicMessage("cannot set DomU vCPUs");
    if ((d.flags & abi.domain_flag_vpl011) != 0) tree.setEmpty(domu, "vpl011") catch panicMessage("cannot enable vpl011");

    const kernel = tree.addNode(domu, "module@0") catch panicMessage("cannot create kernel module");
    tree.setBytes(kernel, "compatible", kernel_compatible) catch panicMessage("cannot set kernel compatible");
    tree.setU32Pair(kernel, "reg", @intCast(d.kernel.addr), @intCast(d.kernel.size)) catch panicMessage("cannot set kernel reg");
    tree.setString(kernel, "bootargs", stringAt(b, d.cmdline_offset)) catch panicMessage("cannot set kernel bootargs");

    if ((d.flags & abi.domain_flag_has_initrd) != 0) {
        if (d.initrd.addr > 0xffff_ffff or d.initrd.size > 0xffff_ffff) panicMessage("DomU initrd must be below 4 GiB in v10");
        const ramdisk = tree.addNode(domu, "module@1") catch panicMessage("cannot create initrd module");
        tree.setBytes(ramdisk, "compatible", ramdisk_compatible) catch panicMessage("cannot set initrd compatible");
        tree.setU32Pair(ramdisk, "reg", @intCast(d.initrd.addr), @intCast(d.initrd.size)) catch panicMessage("cannot set initrd reg");
    }

    addPassthroughModule(tree, b, d, index, stringAt(b, d.name_offset));
}

fn armPrepareDtb(source_dtb: usize, b: *const abi.Header) usize {
    var tree = dt.DeviceTree.openInto(source_dtb, dtbWorkspace()) catch panicMessage("cannot open machine DTB with libfdt");
    const chosen = tree.ensureChosen() catch panicMessage("cannot create /chosen");
    tree.setString(chosen, "xloader,stage", "v10") catch panicMessage("cannot set xloader DT marker");
    tree.setString(chosen, "xen,xen-bootargs", stringAt(b, b.xen_cmdline_offset)) catch panicMessage("cannot set Xen bootargs");

    var i: usize = 0;
    while (i < b.domain_count) : (i += 1) {
        // libfdt mutations for domain[i-1] (passthrough marker) can shift later
        // structure-block offsets, so re-resolve /chosen per domain.
        const chosen_now = tree.findNode("/chosen") catch panicMessage("cannot re-resolve /chosen");
        addDomu(&tree, chosen_now, b, domainAt(b, i), i);
    }

    const final_dtb = tree.finish() catch panicMessage("cannot pack prepared DTB");
    puts("xloader: prepared DTB ");
    putHex(@intFromPtr(final_dtb.ptr));
    puts(" size ");
    putHex(final_dtb.len);
    puts("\n");
    return @intFromPtr(final_dtb.ptr);
}

fn looksLikeFdt(addr: usize) bool {
    if (addr == 0) return false;
    const p: [*]const u8 = @ptrFromInt(addr);
    return p[0] == 0xd0 and p[1] == 0x0d and p[2] == 0xfe and p[3] == 0xed;
}

fn selectArmDtb(arg0: usize, arg1: usize) usize {
    if (looksLikeFdt(arg0)) return arg0;
    if (looksLikeFdt(arg1)) return arg1;
    if (looksLikeFdt(0x4000_0000)) return 0x4000_0000;
    return if (arg0 != 0) arg0 else arg1;
}

fn armBootXen(source_dtb: usize) noreturn {
    const b = bundle();
    puts("xloader: domains ");
    putDec(b.domain_count);
    puts("\n");
    const final_dtb = armPrepareDtb(source_dtb, b);
    puts("xloader: Xen entry ");
    putHex(@intCast(b.xen_entry));
    puts("\n");
    puts("xloader: entering Xen\n");
    arch_enter_xen(@intCast(b.xen_entry), final_dtb);
}

pub export fn xloader_main(boot_info: usize, boot_magic: usize) noreturn {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            puts("xloader: hello from position-independent aarch64 Zig core\n");
            armBootXen(selectArmDtb(boot_info, boot_magic));
        },
        .x86_64 => {
            puts("xloader: hello from x86_64 Zig core\n");
            puts("xloader: Multiboot info ");
            putHex(boot_info);
            puts(" magic ");
            putHex(boot_magic);
            puts("\n");
            if (xbundle_storage.header.validBasic()) puts("xloader: v10 descriptor present; x86 Xen handoff deferred\n")
            else puts("xloader: no bundle descriptor\n");
        },
        else => unreachable,
    }
    halt();
}
