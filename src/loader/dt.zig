//! Small Zig wrapper around upstream libfdt.
//! No code outside this module should call libfdt directly.

pub const workspace_size: usize = 2 * 1024 * 1024;
pub const passthrough_slot_size: usize = 32 * 1024;

pub const Error = error{
    BadHeader,
    NoSpace,
    NotFound,
    AlreadyExists,
    LibFdt,
    InvalidTree,
    ExternalDependency,
    PathTooLong,
};

const FDT_ERR_NOTFOUND: c_int = 1;
const FDT_ERR_EXISTS: c_int = 2;
const FDT_ERR_NOSPACE: c_int = 3;
const max_c_int: usize = 0x7fff_ffff;

extern fn fdt_check_header(fdt: *const anyopaque) c_int;
extern fn fdt_open_into(fdt: *const anyopaque, buf: *anyopaque, bufsize: c_int) c_int;
extern fn fdt_create_empty_tree(buf: *anyopaque, bufsize: c_int) c_int;
extern fn fdt_path_offset(fdt: *const anyopaque, path: [*:0]const u8) c_int;
extern fn fdt_subnode_offset(fdt: *const anyopaque, parentoffset: c_int, name: [*:0]const u8) c_int;
extern fn fdt_add_subnode(fdt: *anyopaque, parentoffset: c_int, name: [*:0]const u8) c_int;
extern fn fdt_setprop(fdt: *anyopaque, nodeoffset: c_int, name: [*:0]const u8, val: *const anyopaque, len: c_int) c_int;
extern fn fdt_pack(fdt: *anyopaque) c_int;
extern fn fdt_first_property_offset(fdt: *const anyopaque, nodeoffset: c_int) c_int;
extern fn fdt_next_property_offset(fdt: *const anyopaque, offset: c_int) c_int;
extern fn fdt_getprop_by_offset(fdt: *const anyopaque, offset: c_int, namep: *?[*:0]const u8, lenp: *c_int) ?*const anyopaque;
extern fn fdt_first_subnode(fdt: *const anyopaque, offset: c_int) c_int;
extern fn fdt_next_subnode(fdt: *const anyopaque, offset: c_int) c_int;
extern fn fdt_get_name(fdt: *const anyopaque, nodeoffset: c_int, lenp: *c_int) ?[*:0]const u8;

pub const Node = struct { offset: c_int };

pub const PassthroughSpec = struct {
    path: [*:0]const u8,
    host_addr: u64,
    guest_addr: u64,
    size: u64,
    force_assign_without_iommu: bool,
    strip_external_dependencies: bool,
    has_irq: bool,
    irq_type: u32,
    irq_number: u32,
    irq_flags: u32,
};

pub const DeviceTree = struct {
    buf: []u8,

    pub fn openInto(src_addr: usize, dst: []u8) Error!DeviceTree {
        if (src_addr == 0 or dst.len < 64) return error.InvalidTree;
        const src: *const anyopaque = @ptrFromInt(src_addr);
        try checkRc(fdt_check_header(src));
        if (dst.len > max_c_int) return error.NoSpace;
        try checkRc(fdt_open_into(src, @ptrCast(dst.ptr), @intCast(dst.len)));
        return .{ .buf = dst };
    }

    pub fn createEmpty(dst: []u8) Error!DeviceTree {
        if (dst.len < 256 or dst.len > max_c_int) return error.NoSpace;
        try checkRc(fdt_create_empty_tree(@ptrCast(dst.ptr), @intCast(dst.len)));
        return .{ .buf = dst };
    }

    pub fn findNode(self: *DeviceTree, path: [*:0]const u8) Error!Node {
        const off = fdt_path_offset(@ptrCast(self.buf.ptr), path);
        if (off == -FDT_ERR_NOTFOUND) return error.NotFound;
        try checkRc(off);
        return .{ .offset = off };
    }

    pub fn findChild(self: *DeviceTree, parent: Node, name: [*:0]const u8) Error!Node {
        const off = fdt_subnode_offset(@ptrCast(self.buf.ptr), parent.offset, name);
        if (off == -FDT_ERR_NOTFOUND) return error.NotFound;
        try checkRc(off);
        return .{ .offset = off };
    }

    pub fn ensureChosen(self: *DeviceTree) Error!Node {
        return self.findNode("/chosen") catch |err| {
            switch (err) {
                error.NotFound => return self.addNode(.{ .offset = 0 }, "chosen"),
                else => return err,
            }
        };
    }

    pub fn ensureChild(self: *DeviceTree, parent: Node, name: [*:0]const u8) Error!Node {
        return self.findChild(parent, name) catch |err| {
            switch (err) {
                error.NotFound => return self.addNode(parent, name),
                else => return err,
            }
        };
    }

    pub fn addNode(self: *DeviceTree, parent: Node, name: [*:0]const u8) Error!Node {
        const off = fdt_add_subnode(@ptrCast(self.buf.ptr), parent.offset, name);
        if (off == -FDT_ERR_EXISTS) return error.AlreadyExists;
        try checkRc(off);
        return .{ .offset = off };
    }

    pub fn setBytes(self: *DeviceTree, node: Node, name: [*:0]const u8, value: []const u8) Error!void {
        if (value.len > max_c_int) return error.NoSpace;
        const ptr: *const anyopaque = if (value.len == 0) @ptrCast(&empty_byte) else @ptrCast(value.ptr);
        try checkRc(fdt_setprop(@ptrCast(self.buf.ptr), node.offset, name, ptr, @intCast(value.len)));
    }

    pub fn setString(self: *DeviceTree, node: Node, name: [*:0]const u8, value: [*:0]const u8) Error!void {
        const len = cStringLen(value) + 1;
        try self.setBytes(node, name, value[0..len]);
    }

    pub fn setU32(self: *DeviceTree, node: Node, name: [*:0]const u8, value: u32) Error!void {
        var be = @byteSwap(value);
        try self.setBytes(node, name, @as([*]const u8, @ptrCast(&be))[0..4]);
    }

    pub fn setU32Pair(self: *DeviceTree, node: Node, name: [*:0]const u8, first: u32, second: u32) Error!void {
        var cells = [2]u32{ @byteSwap(first), @byteSwap(second) };
        try self.setBytes(node, name, @as([*]const u8, @ptrCast(&cells))[0..8]);
    }

    pub fn setXenReg(self: *DeviceTree, node: Node, host_addr: u64, size: u64, guest_addr: u64) Error!void {
        var cells = [6]u32{
            @byteSwap(@as(u32, @truncate(host_addr >> 32))),
            @byteSwap(@as(u32, @truncate(host_addr))),
            @byteSwap(@as(u32, @truncate(size >> 32))),
            @byteSwap(@as(u32, @truncate(size))),
            @byteSwap(@as(u32, @truncate(guest_addr >> 32))),
            @byteSwap(@as(u32, @truncate(guest_addr))),
        };
        try self.setBytes(node, "xen,reg", @as([*]const u8, @ptrCast(&cells))[0..24]);
    }

    pub fn setInterrupt(self: *DeviceTree, node: Node, irq_type: u32, number: u32, flags: u32) Error!void {
        var cells = [3]u32{ @byteSwap(irq_type), @byteSwap(number), @byteSwap(flags) };
        try self.setBytes(node, "interrupts", @as([*]const u8, @ptrCast(&cells))[0..12]);
    }

    pub fn setEmpty(self: *DeviceTree, node: Node, name: [*:0]const u8) Error!void {
        try self.setBytes(node, name, &[_]u8{});
    }

    /// Build a trusted partial DT in `dst` using resource grants compiled
    /// from system.toml. The selected host subtree supplies the guest-visible
    /// binding while xen,reg carries the explicit host-MMIO -> guest-IPA map.
    pub fn buildPassthroughTree(self: *DeviceTree, specs: []const PassthroughSpec, dst: []u8) Error![]u8 {
        var out = try DeviceTree.createEmpty(dst);
        const passthrough = try out.addNode(.{ .offset = 0 }, "passthrough");

        for (specs) |spec| {
            const source = try self.findNode(spec.path);

            var parent = passthrough;
            var cursor: usize = 1; // skip leading '/'
            var name_buf: [128]u8 = undefined;
            while (spec.path[cursor] != 0) {
                const component_start = cursor;
                while (spec.path[cursor] != 0 and spec.path[cursor] != '/') : (cursor += 1) {}
                const n = cursor - component_start;
                if (n == 0 or n + 1 > name_buf.len) return error.PathTooLong;
                var j: usize = 0;
                while (j < n) : (j += 1) name_buf[j] = spec.path[component_start + j];
                name_buf[n] = 0;
                parent = try out.ensureChild(parent, @ptrCast(&name_buf[0]));
                if (spec.path[cursor] == '/') cursor += 1;
            }

            try self.copySubtree(source, &out, parent, spec.strip_external_dependencies);
            try out.setXenReg(parent, spec.host_addr, spec.size, spec.guest_addr);
            if (spec.force_assign_without_iommu)
                try out.setEmpty(parent, "xen,force-assign-without-iommu");
            if (spec.has_irq)
                try out.setInterrupt(parent, spec.irq_type, spec.irq_number, spec.irq_flags);

            // Mark the source machine-DT node only after it has been copied;
            // libfdt mutations can change later structure-block offsets.
            const source_again = try self.findNode(spec.path);
            try self.setEmpty(source_again, "xen,passthrough");
        }

        return try out.finish();
    }

    fn copySubtree(self: *DeviceTree, source: Node, out: *DeviceTree, dest: Node, strip_external_dependencies: bool) Error!void {
        try self.copyProperties(source, out, dest, strip_external_dependencies);

        var child_off = fdt_first_subnode(@ptrCast(self.buf.ptr), source.offset);
        while (child_off >= 0) {
            var name_len: c_int = 0;
            const child_name = fdt_get_name(@ptrCast(self.buf.ptr), child_off, &name_len) orelse return error.LibFdt;
            if (name_len <= 0) return error.InvalidTree;
            const out_child = try out.ensureChild(dest, child_name);
            try self.copySubtree(.{ .offset = child_off }, out, out_child, strip_external_dependencies);
            child_off = fdt_next_subnode(@ptrCast(self.buf.ptr), child_off);
        }
        if (child_off != -FDT_ERR_NOTFOUND) try checkRc(child_off);
    }

    fn copyProperties(self: *DeviceTree, source: Node, out: *DeviceTree, dest: Node, strip_external_dependencies: bool) Error!void {
        var prop_off = fdt_first_property_offset(@ptrCast(self.buf.ptr), source.offset);
        while (prop_off >= 0) {
            var prop_name: ?[*:0]const u8 = null;
            var prop_len: c_int = 0;
            const prop = fdt_getprop_by_offset(@ptrCast(self.buf.ptr), prop_off, &prop_name, &prop_len) orelse return error.LibFdt;
            if (prop_len < 0 or prop_name == null) return error.LibFdt;
            const name = prop_name.?;
            if (hasUnsupportedExternalDependency(name)) {
                if (!strip_external_dependencies) return error.ExternalDependency;
            } else {
                const bytes = @as([*]const u8, @ptrCast(prop))[0..@intCast(prop_len)];
                try out.setBytes(dest, name, bytes);
            }
            prop_off = fdt_next_property_offset(@ptrCast(self.buf.ptr), prop_off);
        }
        if (prop_off != -FDT_ERR_NOTFOUND) try checkRc(prop_off);
    }

    pub fn finish(self: *DeviceTree) Error![]u8 {
        try checkRc(fdt_pack(@ptrCast(self.buf.ptr)));
        const n = totalSize(self.buf) orelse return error.InvalidTree;
        if (n > self.buf.len) return error.InvalidTree;
        return self.buf[0..n];
    }
};

var empty_byte: u8 = 0;

fn hasUnsupportedExternalDependency(name: [*:0]const u8) bool {
    const unsupported = [_][*:0]const u8{
        "clocks",
        "clock-names",
        "resets",
        "power-domains",
        "iommus",
        "phys",
        "dmas",
        "memory-region",
        "interconnects",
        "interrupt-parent",
        "msi-parent",
        "iommu-map",
        "iommu-map-mask",
        "interrupt-map",
        "interrupt-map-mask",
    };
    for (unsupported) |item| if (cStringEq(name, item)) return true;
    return false;
}

fn cStringEq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return a[i] == b[i];
}

fn totalSize(buf: []const u8) ?usize {
    if (buf.len < 8) return null;
    const n: u32 = (@as(u32, buf[4]) << 24) |
        (@as(u32, buf[5]) << 16) |
        (@as(u32, buf[6]) << 8) |
        @as(u32, buf[7]);
    return @intCast(n);
}

fn cStringLen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

fn checkRc(rc: c_int) Error!void {
    if (rc >= 0) return;
    switch (-rc) {
        FDT_ERR_NOTFOUND => return error.NotFound,
        FDT_ERR_EXISTS => return error.AlreadyExists,
        FDT_ERR_NOSPACE => return error.NoSpace,
        else => return error.LibFdt,
    }
}
