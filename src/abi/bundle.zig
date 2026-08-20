//! Shared on-image ABI between host xbundle and target xloader.
//! No std dependency: the target imports this freestanding.

pub const magic: u32 = 0x584c4452; // "XLDR"
pub const version: u16 = 4;
pub const descriptor_capacity: usize = 64 * 1024;
pub const sanity_max_domains: usize = 32;
pub const sanity_max_passthrough: usize = 128;

pub const domain_type_domu: u32 = 1;
pub const domain_flag_has_initrd: u32 = 1 << 0;
pub const domain_flag_vpl011: u32 = 1 << 1;

pub const Payload = extern struct {
    addr: u64,
    size: u64,
};

pub const Header = extern struct {
    magic: u32,
    version: u16,
    header_size: u16,
    descriptor_size: u32,
    flags: u32,

    image_size: u64,
    xen_entry: u64,
    xen_addr: u64,
    xen_size: u64,

    xen_cmdline_offset: u32,
    domain_count: u32,
    domain_offset: u32,
    passthrough_count: u32,
    passthrough_offset: u32,
    string_offset: u32,
    string_size: u32,
    reserved0: u32,

    pub fn validBasic(self: *const Header) bool {
        if (self.magic != magic or self.version != version) return false;
        if (@as(usize, self.header_size) < @sizeOf(Header)) return false;
        if (self.descriptor_size < self.header_size or self.descriptor_size > descriptor_capacity) return false;
        if (self.domain_count > sanity_max_domains) return false;
        if (self.passthrough_count > sanity_max_passthrough) return false;
        if (self.xen_entry == 0 or self.xen_addr == 0 or self.xen_size == 0) return false;
        return true;
    }
};

pub const Domain = extern struct {
    domain_type: u32,
    flags: u32,
    name_offset: u32,
    cmdline_offset: u32,

    memory_kb: u64,
    vcpus: u32,
    passthrough_count: u32,
    passthrough_offset: u32,
    reserved0: u32,

    kernel: Payload,
    initrd: Payload,
};

pub const Passthrough = extern struct {
    path_offset: u32,
    flags: u32,
};

pub const Storage = extern struct {
    header: Header,
    rest: [descriptor_capacity - @sizeOf(Header)]u8,
};

test "ABI layout" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Payload));
    try std.testing.expect(@sizeOf(Header) % 8 == 0);
    try std.testing.expect(@sizeOf(Domain) % 8 == 0);
    try std.testing.expectEqual(descriptor_capacity, @sizeOf(Storage));
}
