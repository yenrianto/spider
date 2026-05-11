const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const NextFn = @import("../core/context.zig").NextFn;
const Response = @import("../core/context.zig").Response;

const reset = "\x1b[0m";
const green = "\x1b[32m";
const blue = "\x1b[34m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";

fn statusColor(status: u16) []const u8 {
    if (status >= 100 and status < 200) return blue;
    if (status >= 200 and status < 300) return green;
    if (status >= 300 and status < 400) return blue;
    if (status >= 400 and status < 500) return yellow;
    if (status >= 500) return red;
    return reset;
}

fn formatLatency(ns: u64, buf: []u8) []const u8 {
    if (ns < 1000) {
        return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "0ns";
    }
    if (ns < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d}µs", .{ns / 1000}) catch "0µs";
    }
    if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d}ms", .{ns / 1_000_000}) catch "0ms";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{ns / 1_000_000_000}) catch "0s";
}

pub fn middleware(c: *Ctx, next: NextFn) anyerror!Response {
    const method = @tagName(c.request.head.method);
    const path = c.getPath();

    const start = std.Io.Clock.now(.real, c._io);
    const resp = next(c) catch |err| {
        const end = std.Io.Clock.now(.real, c._io);
        const ns_diff = end.nanoseconds - start.nanoseconds;
        const ns: u64 = if (ns_diff < 0) 0 else @intCast(ns_diff);
        var lat_buf: [32]u8 = undefined;
        const lat = formatLatency(ns, &lat_buf);
        std.debug.print("{s: <7} {s}  {s}500\x1b[0m  {s}\n", .{ method, path, red, lat });
        return err;
    };

    const end = std.Io.Clock.now(.real, c._io);
    const status_int: u16 = @intFromEnum(resp.status);
    const sc = statusColor(status_int);

    const ns_diff = end.nanoseconds - start.nanoseconds;
    const ns: u64 = if (ns_diff < 0) 0 else @intCast(ns_diff);

    if (resp.raw) {
        std.debug.print("{s: <7} {s}  {s}{d}\x1b[0m  open\n", .{ method, path, sc, status_int });
    } else {
        var lat_buf: [32]u8 = undefined;
        const lat = formatLatency(ns, &lat_buf);
        std.debug.print("{s: <7} {s}  {s}{d}\x1b[0m  {s}\n", .{ method, path, sc, status_int, lat });
    }

    return resp;
}
