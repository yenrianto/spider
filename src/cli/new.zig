const std = @import("std");
const downloader = @import("downloader.zig");
const chmod = @import("chmod.zig");

// Embedded templates
const build_zig_tmpl = @embedFile("templates/build.zig.template");
const build_zon_tmpl = @embedFile("templates/build.zig.zon.template");
const spider_config_tmpl = @embedFile("templates/spider.config.zig.template");
const main_zig_tmpl = @embedFile("templates/main.zig.template");
const layout_html_tmpl = @embedFile("templates/layout.html.template");
const home_index_tmpl = @embedFile("templates/home_index.html.template");
const home_controller_tmpl = @embedFile("templates/home_controller.zig.template");
const dockerfile_tmpl = @embedFile("templates/Dockerfile.template");
const docker_compose_tmpl = @embedFile("templates/docker-compose.yml.template");
const env_example_tmpl = @embedFile("templates/.env.example.template");
const gitignore_tmpl = @embedFile("templates/.gitignore.template");
const core_mod_tmpl = @embedFile("templates/core_mod.zig.template");
const features_mod_tmpl = @embedFile("templates/features_mod.zig.template");
const home_mod_tmpl = @embedFile("templates/home_mod.zig.template");
const styles_css_tmpl = @embedFile("templates/styles.css.template");
const nav_bar_tmpl = @embedFile("templates/nav-bar.html.template");
const side_bar_tmpl = @embedFile("templates/side-bar.html.template");
const mobile_nav_tmpl = @embedFile("templates/mobile-nav.html.template");
const toast_tmpl = @embedFile("templates/toast.html.template");
const spider_logo_png = @embedFile("assets/spider_logo.png");
const favicon_png = @embedFile("assets/favicon.png");
const favicon_ico = @embedFile("assets/favicon.ico");
const layout_daisyui_html_tmpl = @embedFile("templates/layout_daisyui.html.template");
const home_daisyui_index_tmpl = @embedFile("templates/home_daisyui_index.html.template");

fn getTailwindUrl() []const u8 {
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;
    if (os == .windows) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-windows-x64.exe";
    if (os == .macos and arch == .aarch64) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-arm64";
    if (os == .macos) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-x64";
    if (arch == .aarch64) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-arm64";
    return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-x64";
}

fn runZigFetch(io: std.Io, app_name: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fetch", "--save=spider", "git+https://github.com/llllOllOOll/spider#main" },
        .cwd = .{ .path = app_name },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ZigFetchFailed,
        else => return error.ZigFetchFailed,
    }
}

fn runZigInit(io: std.Io, app_name: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "init", "-m" },
        .cwd = .{ .path = app_name },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ZigInitFailed,
        else => return error.ZigInitFailed,
    }
}

fn extractFingerprint(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const prefix = ".fingerprint = ";
    const idx = std.mem.indexOf(u8, content, prefix) orelse return error.FingerprintNotFound;
    const rest = content[idx + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",\n") orelse rest.len;
    return allocator.dupe(u8, std.mem.trim(u8, rest[0..end], " "));
}

fn readFingerprint(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    const file = try dir.openFile(io, "build.zig.zon", .{});
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var reader: std.Io.File.Reader = .init(file, io, &buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(8192));
    defer allocator.free(content);
    return extractFingerprint(allocator, content);
}

fn render(allocator: std.mem.Allocator, tmpl: []const u8, app_name: []const u8, fingerprint: []const u8) ![]const u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, tmpl, "{{app_name}}", app_name);
    defer allocator.free(step1);
    return std.mem.replaceOwned(u8, allocator, step1, "{{fingerprint}}", fingerprint);
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(io, parent) catch {};
    }
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer: std.Io.File.Writer = .init(file, io, &buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, app_name: []const u8, use_daisyui: bool, skip_downloads: bool) !void {
    const cwd = std.Io.Dir.cwd();

    cwd.createDir(io, app_name, .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("error: directory '{s}' already exists\n", .{app_name});
            return error.DirExists;
        }
        return err;
    };

    // Registered first → runs second (after error is logged)
    errdefer {
        std.debug.print("  Cleaning up {s}/...\n", .{app_name});
        cwd.deleteTree(io, app_name) catch {};
    }

    // Registered second → runs first (LIFO), prints before cleanup
    var current_step: []const u8 = "unknown";
    var fail_err: anyerror = error.Unknown;
    errdefer std.debug.print("error: failed at step '{s}' — {s}\n", .{ current_step, @errorName(fail_err) });

    current_step = "zig init";
    runZigInit(io, app_name) catch |err| { fail_err = err; return err; };

    var project_dir = cwd.openDir(io, app_name, .{}) catch |err| { fail_err = err; return err; };
    defer project_dir.close(io);

    project_dir.createDirPath(io, "bin") catch {};
    project_dir.createDirPath(io, "public/js") catch {};
    project_dir.createDirPath(io, "public/css") catch {};
    project_dir.createDirPath(io, "public/fonts") catch {};

    if (!skip_downloads) {
        current_step = "download tailwindcss";
        downloader.download(io, allocator, getTailwindUrl(), project_dir, "bin/tailwindcss") catch |err| { fail_err = err; return err; };

        current_step = "download daisyui";
        downloader.download(io, allocator, "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui.mjs", project_dir, "bin/daisyui.mjs") catch |err| { fail_err = err; return err; };
        downloader.download(io, allocator, "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui-theme.mjs", project_dir, "bin/daisyui-theme.mjs") catch |err| { fail_err = err; return err; };

        current_step = "download alpine";
        downloader.download(io, allocator, "https://cdn.jsdelivr.net/npm/alpinejs@latest/dist/cdn.min.js", project_dir, "public/js/alpine.min.js") catch |err| { fail_err = err; return err; };

        current_step = "download htmx";
        downloader.download(io, allocator, "https://unpkg.com/htmx.org@latest/dist/htmx.min.js", project_dir, "public/js/htmx.min.js") catch |err| { fail_err = err; return err; };

        current_step = "download icons";
        downloader.download(io, allocator, "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/tabler-icons.min.css", project_dir, "public/css/tabler-icons.min.css") catch |err| { fail_err = err; return err; };
        downloader.download(io, allocator, "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/fonts/tabler-icons.woff2", project_dir, "public/fonts/tabler-icons.woff2") catch |err| { fail_err = err; return err; };

        current_step = "chmod tailwindcss";
        const tailwind_path = std.fmt.allocPrint(allocator, "{s}/bin/tailwindcss", .{app_name}) catch |err| { fail_err = err; return err; };
        defer allocator.free(tailwind_path);
        chmod.makeExecutable(io, tailwind_path) catch |err| { fail_err = err; return err; };
    }

    current_step = "read fingerprint";
    const fingerprint = readFingerprint(io, allocator, project_dir) catch |err| { fail_err = err; return err; };
    defer allocator.free(fingerprint);

    std.debug.print("Creating {s}...\n", .{app_name});

    const selected_layout_tmpl = if (use_daisyui) layout_daisyui_html_tmpl else layout_html_tmpl;
    const selected_home_index_tmpl = if (use_daisyui) home_daisyui_index_tmpl else home_index_tmpl;

    const files = .{
        .{ "build.zig", build_zig_tmpl },
        .{ "build.zig.zon", build_zon_tmpl },
        .{ "spider.config.zig", spider_config_tmpl },
        .{ "src/main.zig", main_zig_tmpl },
        .{ "src/styles.css", styles_css_tmpl },
        .{ "src/embedded_templates.zig", "// Generated file - DO NOT EDIT MANUALLY\npub const EmbeddedTemplates = struct {};\n" },
        .{ "src/core/mod.zig", core_mod_tmpl },
        .{ "src/features/mod.zig", features_mod_tmpl },
        .{ "src/features/home/mod.zig", home_mod_tmpl },
        .{ "src/shared/templates/layout.html", selected_layout_tmpl },
        .{ "src/shared/templates/nav-bar.html", nav_bar_tmpl },
        .{ "src/shared/templates/side-bar.html", side_bar_tmpl },
        .{ "src/shared/templates/mobile-nav.html", mobile_nav_tmpl },
        .{ "src/shared/templates/toast.html", toast_tmpl },
        .{ "src/features/home/views/index.html", selected_home_index_tmpl },
        .{ "src/features/home/controller.zig", home_controller_tmpl },
        .{ "Dockerfile", dockerfile_tmpl },
        .{ "docker-compose.yml", docker_compose_tmpl },
        .{ ".env.example", env_example_tmpl },
        .{ ".gitignore", gitignore_tmpl },
    };

    const static_assets = .{
        .{ "public/images/logo.png", spider_logo_png },
        .{ "public/favicon.png", favicon_png },
        .{ "public/favicon.ico", favicon_ico },
    };

    current_step = "write files";
    inline for (files) |f| {
        const path = f[0];
        const tmpl = f[1];
        const content = render(allocator, tmpl, app_name, fingerprint) catch |err| { fail_err = err; return err; };
        defer allocator.free(content);
        writeFile(io, project_dir, path, content) catch |err| { fail_err = err; return err; };
        std.debug.print("  create  {s}/{s}\n", .{ app_name, path });
    }

    inline for (static_assets) |f| {
        const path = f[0];
        const content = f[1];
        writeFile(io, project_dir, path, content) catch |err| { fail_err = err; return err; };
        std.debug.print("  create  {s}/{s}\n", .{ app_name, path });
    }

    if (!skip_downloads) {
        current_step = "compile css";
        var css_child = std.process.spawn(io, .{
            .argv = &.{ "./bin/tailwindcss", "-i", "src/styles.css", "-o", "public/css/app.css" },
            .cwd = .{ .path = app_name },
        }) catch |err| { fail_err = err; return err; };
        const css_term = css_child.wait(io) catch |err| { fail_err = err; return err; };
        switch (css_term) {
            .exited => |code| if (code != 0) { fail_err = error.TailwindCompileFailed; return error.TailwindCompileFailed; },
            else => { fail_err = error.TailwindCompileFailed; return error.TailwindCompileFailed; },
        }
        std.debug.print("  CSS compiled → public/css/app.css\n", .{});
    }

    current_step = "fetch spider";
    std.debug.print("Fetching spider from main...\n", .{});
    runZigFetch(io, app_name) catch |err| { fail_err = err; return err; };

    std.debug.print("\nDone! Next steps:\n", .{});
    std.debug.print("  cd {s}\n", .{app_name});
    std.debug.print("  zig build run\n", .{});

    if (skip_downloads) {
        std.debug.print("\nwarning: downloads skipped, run `spider fetch-deps` to download missing binaries.\n", .{});
    }
}
