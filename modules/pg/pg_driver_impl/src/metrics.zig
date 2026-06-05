const std = @import("std");

var metrics = Metrics{
    .queries = Counter.init("pg_query"),
    .pool_empty = Counter.init("pg_pool_empty"),
    .pool_dirty = Counter.init("pg_pool_dirty"),
    .alloc_params = Counter.init("pg_alloc_params"),
    .alloc_columns = Counter.init("pg_alloc_columns"),
    .alloc_reader = Counter.init("pg_alloc_reader"),
};

const Metrics = struct {
    queries: Counter,
    pool_empty: Counter,
    pool_dirty: Counter,
    alloc_params: Counter,
    alloc_columns: Counter,
    alloc_reader: Counter,
};

pub fn write(writer: *std.Io.Writer) !void {
    try metrics.queries.write(writer);
    try metrics.pool_empty.write(writer);
    try metrics.pool_dirty.write(writer);
    try metrics.alloc_params.write(writer);
    try metrics.alloc_columns.write(writer);
    try metrics.alloc_reader.write(writer);
}

pub fn query() void {
    metrics.queries.incr();
}

pub fn poolEmpty() void {
    metrics.pool_empty.incr();
}

pub fn poolDirty() void {
    metrics.pool_dirty.incr();
}

pub fn allocParams(count: usize) void {
    metrics.alloc_params.incrBy(count);
}

pub fn allocColumns(count: usize) void {
    metrics.alloc_columns.incrBy(count);
}

pub fn allocReader(size: usize) void {
    metrics.alloc_reader.incrBy(size);
}

const Counter = struct {
    count: usize,
    preamble: []const u8,

    fn init(comptime name: []const u8) Counter {
        return .{
            .count = 0,
            .preamble = "# TYPE " ++ name ++ " counter\n" ++ name ++ " ",
        };
    }

    fn incr(self: *Counter) void {
        self.incrBy(1);
    }

    fn incrBy(self: *Counter, n: usize) void {
        _ = @atomicRmw(usize, &self.count, .Add, n, .monotonic);
    }

    fn write(self: *const Counter, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.preamble);
        const count = @atomicLoad(usize, &self.count, .monotonic);
        try writer.printInt(count, 10, .lower, .{});
        try writer.writeByte('\n');
    }
};
