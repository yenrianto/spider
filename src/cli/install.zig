const std = @import("std");
const downloader = @import("downloader.zig");
const chmod = @import("chmod.zig");

fn getTailwindUrl() []const u8 {
    const os = @import("builtin").os.tag;
    const arch = @import("builtin").cpu.arch;
    if (os == .windows) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-windows-x64.exe";
    if (os == .macos and arch == .aarch64) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-arm64";
    if (os == .macos) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-x64";
    if (arch == .aarch64) return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-arm64";
    return "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-linux-x64";
}

fn downloadIfMissing(io: std.Io, allocator: std.mem.Allocator, url: []const u8, project_dir: std.Io.Dir, dest: []const u8) !bool {
    project_dir.access(io, dest, .{}) catch {
        std.debug.print("  downloading: {s}\n", .{dest});
        try downloader.download(io, allocator, url, project_dir, dest);
        return true;
    };
    return false;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) !void {
    var downloaded: usize = 0;

    const assets = .{
        .{ getTailwindUrl(), "bin/tailwindcss", "tailwindcss" },
        .{ "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui.mjs", "bin/daisyui.mjs", "daisyui" },
        .{ "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui-theme.mjs", "bin/daisyui-theme.mjs", "daisyui-theme" },
        .{ "https://cdn.jsdelivr.net/npm/alpinejs@latest/dist/cdn.min.js", "public/js/alpine.min.js", "alpine" },
        .{ "https://unpkg.com/htmx.org@latest/dist/htmx.min.js", "public/js/htmx.min.js", "htmx" },
        .{ "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/tabler-icons.min.css", "public/css/tabler-icons.min.css", "tabler-icons css" },
        .{ "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/fonts/tabler-icons.woff2", "public/fonts/tabler-icons.woff2", "tabler-icons font" },
    };

    inline for (assets) |asset| {
        const did_download = downloadIfMissing(io, allocator, asset[0], project_dir, asset[1]) catch |err| blk: {
            std.debug.print("  warning: {s} download failed: {s}\n", .{ asset[2], @errorName(err) });
            break :blk false;
        };
        if (did_download) downloaded += 1;
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
