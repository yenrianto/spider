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

fn downloadIfMissing(io: std.Io, allocator: std.mem.Allocator, url: []const u8, project_dir: std.Io.Dir, dest: []const u8) !void {
    project_dir.access(io, dest, .{}) catch {
        try downloader.download(io, allocator, url, project_dir, dest);
        return;
    };
    std.debug.print("  already installed: {s}\n", .{dest});
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, project_dir: std.Io.Dir) !void {
    std.debug.print("Downloading frontend assets...\n", .{});

    downloadIfMissing(io, allocator, getTailwindUrl(), project_dir, "bin/tailwindcss") catch |err| {
        std.debug.print("  warning: tailwindcss download failed: {s}\n", .{@errorName(err)});
    };

    downloadIfMissing(io, allocator, "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui.mjs", project_dir, "bin/daisyui.mjs") catch |err| {
        std.debug.print("  warning: daisyui download failed: {s}\n", .{@errorName(err)});
    };
    downloadIfMissing(io, allocator, "https://github.com/saadeghi/daisyui/releases/latest/download/daisyui-theme.mjs", project_dir, "bin/daisyui-theme.mjs") catch |err| {
        std.debug.print("  warning: daisyui-theme download failed: {s}\n", .{@errorName(err)});
    };

    downloadIfMissing(io, allocator, "https://cdn.jsdelivr.net/npm/alpinejs@latest/dist/cdn.min.js", project_dir, "public/js/alpine.min.js") catch |err| {
        std.debug.print("  warning: alpine download failed: {s}\n", .{@errorName(err)});
    };

    downloadIfMissing(io, allocator, "https://unpkg.com/htmx.org@latest/dist/htmx.min.js", project_dir, "public/js/htmx.min.js") catch |err| {
        std.debug.print("  warning: htmx download failed: {s}\n", .{@errorName(err)});
    };

    downloadIfMissing(io, allocator, "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/tabler-icons.min.css", project_dir, "public/css/tabler-icons.min.css") catch |err| {
        std.debug.print("  warning: tabler-icons css download failed: {s}\n", .{@errorName(err)});
    };
    downloadIfMissing(io, allocator, "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/fonts/tabler-icons.woff2", project_dir, "public/fonts/tabler-icons.woff2") catch |err| {
        std.debug.print("  warning: tabler-icons font download failed: {s}\n", .{@errorName(err)});
    };

    const tailwind_path = std.fmt.allocPrint(allocator, "{s}/bin/tailwindcss", .{"."}) catch |err| {
        std.debug.print("  warning: path allocation failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(tailwind_path);
    chmod.makeExecutable(io, tailwind_path) catch |err| {
        std.debug.print("  warning: chmod tailwindcss failed: {s}\n", .{@errorName(err)});
    };

    std.debug.print("Done. Assets downloaded to bin/ and public/.\n", .{});
}
