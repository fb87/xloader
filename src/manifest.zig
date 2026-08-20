const std = @import("std");
const toml = @import("toml");

pub const BundleConfig = struct {
    output: []const u8,
};

pub const PlatformConfig = struct {
    arch: []const u8,
};

pub const LoaderConfig = struct {
    image: []const u8,
};

pub const XenConfig = struct {
    image: []const u8,
    cmdline: []const u8 = "console=dtuart dtuart=serial0",
};

pub const LayoutConfig = struct {
    loader_base: ?[]const u8 = null,
    xen_base: ?[]const u8 = null,
    payload_alignment: []const u8 = "2M",
};

pub const PassthroughConfig = struct {
    path: []const u8,
};

pub const DomainConfig = struct {
    name: []const u8,
    kernel: []const u8,
    kernel_format: []const u8 = "auto",
    initrd: ?[]const u8 = null,
    memory: []const u8,
    vcpus: u32 = 1,
    cmdline: []const u8 = "console=ttyAMA0 earlycon=xen",
    vpl011: bool = true,
    passthrough: []const PassthroughConfig = &.{},
};

pub const SystemConfig = struct {
    format: u32,
    bundle: *BundleConfig,
    platform: *PlatformConfig,
    loader: *LoaderConfig,
    xen: *XenConfig,
    layout: ?*LayoutConfig = null,
    domain: []const DomainConfig = &.{},
};


