const std = @import("std");
const ctx_mod = @import("../core/context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;

var boot_time: i64 = 0;

pub fn init() void {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    boot_time = ts.sec;
}

pub fn up(c: *Ctx) !Response {
    return c.text("OK", .{});
}

pub fn health(c: *Ctx) !Response {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    const uptime = ts.sec - boot_time;

    return c.json(.{
        .status = "ok",
        .uptime_seconds = uptime,
    }, .{});
}
