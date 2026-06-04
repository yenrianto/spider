const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{ .target = target, .optimize = optimize };

    const pg_dep = b.dependency("pg", dep_opts);
    const pg_lib = pg_dep.module("pg");

    const spider_pg = b.addModule("spider_pg", .{
        .root_source_file = b.path("src/pg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pg", .module = pg_lib },
        },
    });
    _ = spider_pg;
}
