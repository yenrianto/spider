const std = @import("std");
const builtin = @import("builtin");
const downloader = @import("downloader.zig");
const chmod = @import("chmod.zig");
const fs_utils = @import("fs_utils.zig");

// Asset versions — update when creating a new Spider release
const TAILWIND_VERSION = "4.3.0";
const DAISYUI_VERSION = "5.5.23";
const ALPINE_VERSION = "3.14.8";
const HTMX_VERSION = "2.0.4";
const TABLER_VERSION = "3.31.0";

fn getTailwindUrl() []const u8 {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    const base = "https://github.com/tailwindlabs/tailwindcss/releases/download/v" ++ TAILWIND_VERSION ++ "/tailwindcss-";
    if (os == .windows) return base ++ "windows-x64.exe";
    if (os == .macos and arch == .aarch64) return base ++ "macos-arm64";
    if (os == .macos) return base ++ "macos-x64";
    if (arch == .aarch64) return base ++ "linux-arm64";
    return base ++ "linux-x64";
}

fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |xdg| {
        const s = std.mem.span(xdg);
        if (s.len > 0) return std.fmt.allocPrint(allocator, "{s}/spider", .{s});
    }

    if (std.c.getenv("HOME")) |home| {
        const h = std.mem.span(home);
        if (h.len > 0) {
            if (builtin.os.tag == .macos) {
                return std.fmt.allocPrint(allocator, "{s}/Library/Caches/spider", .{h});
            }
            return std.fmt.allocPrint(allocator, "{s}/.cache/spider", .{h});
        }
    }

    if (std.c.getenv("LOCALAPPDATA")) |appdata| {
        const a = std.mem.span(appdata);
        if (a.len > 0) return std.fmt.allocPrint(allocator, "{s}/spider/cache", .{a});
    }

    return error.CacheDirNotFound;
}

fn downloadToProject(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    project_dir: std.Io.Dir,
    dest: []const u8,
    _: []const u8,
) !bool {
    project_dir.access(io, dest, .{}) catch {
        std.debug.print("  downloading: {s}\n", .{dest});
        try downloader.download(io, allocator, url, project_dir, dest);
        return true;
    };
    return false;
}

fn downloadWithCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    project_dir: std.Io.Dir,
    dest: []const u8,
    cache_dir: std.Io.Dir,
    cache_name: []const u8,
) !bool {
    // Already installed in project?
    if (project_dir.access(io, dest, .{})) |_| {
        return false;
    } else |_| {}

    // Check cache
    const from_cache = blk: {
        cache_dir.access(io, cache_name, .{}) catch break :blk false;
        break :blk true;
    };

    if (!from_cache) {
        std.debug.print("  downloading: {s}\n", .{dest});
        try downloader.download(io, allocator, url, cache_dir, cache_name);
    } else {
        std.debug.print("  from cache: {s}\n", .{dest});
    }

    // Copy from cache to project
    const content = try cache_dir.readFileAlloc(io, cache_name, allocator, .limited(200 * 1024 * 1024));
    defer allocator.free(content);

    if (std.fs.path.dirname(dest)) |dir_path| {
        project_dir.createDirPath(io, dir_path) catch {};
    }
    try fs_utils.writeFile(io, project_dir, dest, content);

    return true;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) !void {
    // verify we're in a Spider project before downloading anything
    project_dir.access(io, "spider.config.zig", .{}) catch {
        std.debug.print("error: spider.config.zig not found\n", .{});
        std.debug.print("Make sure you're in a Spider project directory.\n", .{});
        std.debug.print("Run 'spider new <app_name>' to create a new project.\n", .{});
        return error.NotASpiderProject;
    };

    // Asset definitions — URLs use hardcoded versions for reproducible builds and caching
    const assets = .{
        .{ getTailwindUrl(), "bin/tailwindcss", "tailwindcss-" ++ TAILWIND_VERSION },
        .{ "https://github.com/saadeghi/daisyui/releases/download/v" ++ DAISYUI_VERSION ++ "/daisyui.mjs", "bin/daisyui.mjs", "daisyui-" ++ DAISYUI_VERSION ++ ".mjs" },
        .{ "https://github.com/saadeghi/daisyui/releases/download/v" ++ DAISYUI_VERSION ++ "/daisyui-theme.mjs", "bin/daisyui-theme.mjs", "daisyui-theme-" ++ DAISYUI_VERSION ++ ".mjs" },
        .{ "https://cdn.jsdelivr.net/npm/alpinejs@" ++ ALPINE_VERSION ++ "/dist/cdn.min.js", "public/js/alpine.min.js", "alpine-" ++ ALPINE_VERSION ++ ".min.js" },
        .{ "https://unpkg.com/htmx.org@" ++ HTMX_VERSION ++ "/dist/htmx.min.js", "public/js/htmx.min.js", "htmx-" ++ HTMX_VERSION ++ ".min.js" },
        .{ "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@" ++ TABLER_VERSION ++ "/dist/tabler-icons.min.css", "public/css/tabler-icons.min.css", "tabler-icons-" ++ TABLER_VERSION ++ ".css" },
        .{ "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@" ++ TABLER_VERSION ++ "/dist/fonts/tabler-icons.woff2", "public/fonts/tabler-icons.woff2", "tabler-icons-" ++ TABLER_VERSION ++ ".woff2" },
    };

    // Try to setup global cache
    const cache_path = getCacheDir(allocator) catch null;

    const cache_dir: ?std.Io.Dir = if (cache_path) |cp| blk: {
        std.Io.Dir.cwd().createDirPath(io, cp) catch {};
        break :blk std.Io.Dir.openDirAbsolute(io, cp, .{}) catch null;
    } else null;

    var downloaded: usize = 0;

    inline for (assets) |asset| {
        if (cache_dir) |cd| {
            const did_download = downloadWithCache(io, allocator, asset[0], project_dir, asset[1], cd, asset[2]) catch |err| blk: {
                std.debug.print("  warning: {s} failed: {s}\n", .{ asset[2], @errorName(err) });
                break :blk false;
            };
            if (did_download) downloaded += 1;
        } else {
            const did_download = downloadToProject(io, allocator, asset[0], project_dir, asset[1], asset[2]) catch |err| blk: {
                std.debug.print("  warning: {s} download failed: {s}\n", .{ asset[2], @errorName(err) });
                break :blk false;
            };
            if (did_download) downloaded += 1;
        }
    }

    if (cache_dir) |cd| {
        cd.close(io);
    }
    if (cache_path) |cp| {
        allocator.free(cp);
    }

    if (downloaded > 0) {
        const tailwind_path = std.fmt.allocPrint(allocator, "{s}/bin/tailwindcss", .{"."}) catch return;
        defer allocator.free(tailwind_path);
        chmod.makeExecutable(io, tailwind_path) catch |err| {
            std.debug.print("  warning: chmod tailwindcss failed: {s}\n", .{@errorName(err)});
        };
        std.debug.print("Done. {d} asset(s) downloaded.\n", .{downloaded});
    }
}
