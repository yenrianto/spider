const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("spider_r2", .{
        .root_source_file = b.path("src/r2.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // spider and pacman injected by parent build.zig
    });
}
