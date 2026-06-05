const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_pg = b.option(bool, "pg", "Enable PostgreSQL support") orelse false;
    const with_r2 = b.option(bool, "r2", "Enable Cloudflare R2 support") orelse false;
    const with_sqlite = b.option(bool, "sqlite", "Enable SQLite support") orelse false;

    const pacman_dep = b.dependency("pacman", .{});
    const pg_dep = b.dependency("pg", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("spider", .{
        .root_source_file = b.path("src/spider.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "pacman", .module = pacman_dep.module("pacman") },
            .{ .name = "pg", .module = pg_dep.module("pg") },
        },
    });

    if (with_pg) {
        const pg_module_dep = b.lazyDependency("spider_pg", .{
            .target = target,
            .optimize = optimize,
        }) orelse unreachable;
        const spider_pg = pg_module_dep.module("spider_pg");
        spider_pg.addImport("spider", mod);
        mod.addImport("spider_pg", spider_pg);
    }

    if (with_sqlite) {
        if (b.lazyDependency("spider_sqlite", .{ .target = target, .optimize = optimize })) |dep| {
            const spider_sqlite = dep.module("spider_sqlite");
            spider_sqlite.addImport("spider", mod);
            mod.addImport("spider_sqlite", spider_sqlite);
        }
    }

    if (with_r2) {
        if (b.lazyDependency("spider_r2", .{ .target = target, .optimize = optimize })) |dep| {
            const spider_r2 = dep.module("spider_r2");
            spider_r2.addImport("spider", mod);
            spider_r2.addImport("pacman", pacman_dep.module("pacman"));
            mod.addImport("spider_r2", spider_r2);
        }
    }

    // Default spider_config fallback for projects without spider.config.zig
    const default_cfg = b.addWriteFiles();
    const default_cfg_file = default_cfg.add("spider_config.zig",
        \\const spider = @import("spider");
        \\pub const is_default = true;
        \\pub const config = spider.Config{};
    );
    const default_cfg_mod = b.createModule(.{
        .root_source_file = default_cfg_file,
        .imports = &.{
            .{ .name = "spider", .module = mod },
        },
    });
    mod.addImport("spider_config", default_cfg_mod);

    // spider CLI — `spider new <app_name>`
    const cli_exe = b.addExecutable(.{
        .name = "spider",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_dep.module("pg") },
            },
        }),
    });
    b.installArtifact(cli_exe);

    // generate-templates — CLI tool used by dev projects
    const gen_exe = b.addExecutable(.{
        .name = "generate-templates",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_templates.zig"),
            .target = target,
        }),
    });
    b.installArtifact(gen_exe);

    // spider_build — build helpers for dev projects
    _ = b.addModule("spider_build", .{
        .root_source_file = b.path("src/build_helpers.zig"),
    });

    // // spider-dev — test server
    // const test_exe = b.addExecutable(.{
    //     .name = "spider-dev",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "spider", .module = mod },
    //         },
    //     }),
    // });
    // b.installArtifact(test_exe);
    //
    // const run_dev = b.addRunArtifact(test_exe);
    // run_dev.step.dependOn(b.getInstallStep());
    // const run_step = b.step("run", "Run dev test server");
    // run_step.dependOn(&run_dev.step);

    // tests — existing module tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // test-pg — pg wrapper integration tests (requires PostgreSQL)
    const pg_lib_mod = pg_dep.module("pg");

    const spider_core_mod = b.createModule(.{
        .root_source_file = b.path("src/spider_core_for_pg.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const pg_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("pg_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pg", .module = pg_lib_mod },
                .{ .name = "spider", .module = spider_core_mod },
            },
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_pg_tests = b.addRunArtifact(pg_test);
    run_pg_tests.has_side_effects = true;
    const test_pg_step = b.step("test-pg", "Run pg wrapper integration tests");
    test_pg_step.dependOn(&run_pg_tests.step);

    // test-sqlite — sqlite wrapper tests (uses :memory:, no external DB needed)
    const zqlite_dep = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const zqlite_mod = zqlite_dep.module("zqlite");

        const sqlite_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("modules/sqlite/src/sqlite.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zqlite", .module = zqlite_mod },
            },
        }),
    });
    const run_sqlite_tests = b.addRunArtifact(sqlite_test);
    const test_sqlite_step = b.step("test-sqlite", "Run sqlite tests");
    test_sqlite_step.dependOn(&run_sqlite_tests.step);
}
