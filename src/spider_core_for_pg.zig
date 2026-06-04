// Minimal spider core for pg wrapper — exposes only what pg.zig needs.
const std = @import("std");
pub const env = @import("internal/env.zig");

/// Minimal Database type for PgDriver bridge.
pub const DriverType = enum { postgresql, mysql };
pub const Database = struct {
    ptr: *anyopaque,
    exec_fn: *const fn (ptr: *anyopaque, sql: []const u8) anyerror!void,
    deinit_fn: *const fn (ptr: *anyopaque) void,
    driver_type: DriverType,

    pub fn exec(self: Database, sql: []const u8) !void {
        return self.exec_fn(self.ptr, sql);
    }

    pub fn deinit(self: Database) void {
        self.deinit_fn(self.ptr);
    }
};
