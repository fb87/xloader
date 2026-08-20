const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const toml_mod = b.addModule("toml", .{
        .root_source_file = b.path("build/zig-toml-src/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.addModule("xbundle", .{
        .root_source_file = b.path("src/xbundle.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("toml", toml_mod);

    const exe = b.addExecutable(.{
        .name = "xbundle",
        .root_module = root_mod,
    });
    b.installArtifact(exe);
}
