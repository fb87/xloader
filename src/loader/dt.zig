//! Small Zig wrapper around upstream libfdt.
//! No code outside this module should call libfdt directly.

pub const workspace_size: usize = 2 * 1024 * 1024;

pub const Error = error{
    BadHeader,
    NoSpace,
    NotFound,
    LibFdt,
    InvalidTree,
};

const FDT_ERR_NOTFOUND: c_int = 1;
const FDT_ERR_NOSPACE: c_int = 3;
const max_c_int: usize = 0x7fff_ffff;

extern fn fdt_check_header(fdt: *const anyopaque) c_int;
extern fn fdt_open_into(fdt: *const anyopaque, buf: *anyopaque, bufsize: c_int) c_int;
extern fn fdt_path_offset(fdt: *const anyopaque, path: [*:0]const u8) c_int;
extern fn fdt_add_subnode(fdt: *anyopaque, parentoffset: c_int, name: [*:0]const u8) c_int;
extern fn fdt_setprop(fdt: *anyopaque, nodeoffset: c_int, name: [*:0]const u8, val: *const anyopaque, len: c_int) c_int;
extern fn fdt_pack(fdt: *anyopaque) c_int;

pub const Node = struct { offset: c_int };

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

    pub fn findNode(self: *DeviceTree, path: [*:0]const u8) Error!Node {
        const off = fdt_path_offset(@ptrCast(self.buf.ptr), path);
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

    pub fn addNode(self: *DeviceTree, parent: Node, name: [*:0]const u8) Error!Node {
        const off = fdt_add_subnode(@ptrCast(self.buf.ptr), parent.offset, name);
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

    pub fn setEmpty(self: *DeviceTree, node: Node, name: [*:0]const u8) Error!void {
        try self.setBytes(node, name, &[_]u8{});
    }

    pub fn finish(self: *DeviceTree) Error![]u8 {
        try checkRc(fdt_pack(@ptrCast(self.buf.ptr)));
        const n = totalSize(self.buf) orelse return error.InvalidTree;
        if (n > self.buf.len) return error.InvalidTree;
        return self.buf[0..n];
    }
};

var empty_byte: u8 = 0;

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
        FDT_ERR_NOSPACE => return error.NoSpace,
        else => return error.LibFdt,
    }
}
