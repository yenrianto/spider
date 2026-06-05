const std = @import("std");
const zqlite = @import("zqlite");

// ── Global state ──────────────────────────────────────────
var db_pool: ?*zqlite.Pool = null;
var db_allocator: ?std.mem.Allocator = null;

// ── Config ────────────────────────────────────────────────
pub const DbConfig = struct {
    path: []const u8 = "db.sqlite",
    size: usize = 5,
};

// ── Init / Deinit ─────────────────────────────────────────
pub fn init(allocator: std.mem.Allocator, io: std.Io, overrides: DbConfig) !void {
    db_allocator = allocator;
    const path = try allocator.dupeZ(u8, overrides.path);
    db_pool = try zqlite.Pool.init(allocator, .{
        .size = overrides.size,
        .path = path,
        .flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
        .on_first_connection = runMigrations,
        .on_first_connection_context = null,
    });
    _ = io;
}

pub fn deinit() void {
    if (db_pool) |p| p.deinit();
    db_pool = null;
}

// ── QueryResult ───────────────────────────────────────────
fn QueryResult(comptime T: type) type {
    if (T == void) return void;
    if (T == i64) return i64;
    return []T;
}

// ── nullValue ─────────────────────────────────────────────
fn nullValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .optional => null,
        .int => 0,
        .float => 0.0,
        .bool => false,
        .pointer => &[_]u8{},
        else => undefined,
    };
}

// ── decodeField ───────────────────────────────────────────
fn decodeField(comptime T: type, row: zqlite.Row, col: usize, arena: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        if (row.columnType(col) == .Null) return null;
        return try decodeField(info.optional.child, row, col, arena);
    }
    if (info == .@"enum") {
        const text = row.text(col);
        return std.meta.stringToEnum(T, text) orelse error.InvalidEnumValue;
    }
    return switch (T) {
        []const u8  => try arena.dupe(u8, row.text(col)),
        bool        => row.boolean(col),
        i8, i16, i32, i64 => @intCast(row.int(col)),
        u8, u16, u32, u64 => @intCast(row.int(col)),
        f32, f64    => @floatCast(row.float(col)),
        else        => @compileError("decodeField: unsupported type " ++ @typeName(T)),
    };
}

// ── mapRow ────────────────────────────────────────────────
fn mapRow(comptime T: type, row: zqlite.Row, arena: std.mem.Allocator) !T {
    var item: T = undefined;
    const info = @typeInfo(T).@"struct";
    const col_count: usize = @intCast(row.columnCount());
    inline for (info.fields) |field| {
        var col_idx: ?usize = null;
        for (0..col_count) |i| {
            if (std.mem.eql(u8, row.columnName(i), field.name)) {
                col_idx = i;
                break;
            }
        }
        if (col_idx) |ci| {
            @field(item, field.name) = try decodeField(field.type, row, ci, arena);
        } else {
            @field(item, field.name) = nullValue(field.type);
        }
    }
    return item;
}

// ── query ─────────────────────────────────────────────────
pub fn query(comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !QueryResult(T) {
    const io = std.Io.Threaded.init_single_threaded;
    const conn = try db_pool.?.acquire(io.io());
    defer db_pool.?.release(io.io(), conn);

    if (T == void) {
        try conn.exec(sql, params);
        return;
    }

    var rows = try conn.rows(sql, params);
    defer rows.deinit();

    if (T == i64) {
        if (rows.next()) |row| return row.int(0);
        return 0;
    }

    var items = std.ArrayListUnmanaged(T).empty;
    while (rows.next()) |row| {
        try items.append(arena, try mapRow(T, row, arena));
    }
    if (rows.err) |err| return err;
    return try items.toOwnedSlice(arena);
}

// ── queryOne ──────────────────────────────────────────────
pub fn queryOne(comptime T: type, arena: std.mem.Allocator, sql: []const u8, params: anytype) !?T {
    const io = std.Io.Threaded.init_single_threaded;
    const conn = try db_pool.?.acquire(io.io());
    defer db_pool.?.release(io.io(), conn);

    const row = try conn.row(sql, params) orelse return null;
    defer row.deinit();
    return try mapRow(T, row, arena);
}

// ── Migrations placeholder ────────────────────────────────
fn runMigrations(_: zqlite.Conn, _: ?*anyopaque) !void {}
