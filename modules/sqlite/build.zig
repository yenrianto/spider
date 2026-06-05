const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{ .target = target, .optimize = optimize };

    const zqlite_dep = b.dependency("zqlite", dep_opts);
    const zqlite_lib = zqlite_dep.module("zqlite");

    const spider_sqlite = b.addModule("spider_sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zqlite", .module = zqlite_lib },
        },
    });
    _ = spider_sqlite;
}
