const std = @import("std");

pub fn makeExecutable(io: std.Io, path: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    try dir.setFilePermissions(io, path, .executable_file, .{});
}
