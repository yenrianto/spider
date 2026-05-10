const std = @import("std");
const posix = std.posix;
const net = std.Io.net;

pub const Hub = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    connections: std.ArrayListUnmanaged(Connection) = .empty,

    pub const Connection = struct {
        id: u64,
        stream: net.Stream,
        channel: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Hub {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = std.Io.Mutex.init,
            .connections = .empty,
        };
    }

    pub fn deinit(self: *Hub) void {
        self.connections.deinit(self.allocator);
    }

    pub fn add(self: *Hub, conn: Connection) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |c| {
            if (c.id == conn.id) return error.DuplicateId;
        }
        try self.connections.append(self.allocator, conn);
    }

    pub fn remove(self: *Hub, conn_id: u64) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (self.connections.items, 0..) |conn, i| {
            if (conn.id == conn_id) {
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    pub fn count(self: *Hub) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.connections.items.len;
    }

    pub fn broadcast(self: *Hub, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            snapshot.append(self.allocator, conn) catch {};
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            self.sendText(conn.stream, message) catch {
                dead.append(self.allocator, conn.id) catch {};
            };
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    pub fn broadcastToChannel(self: *Hub, channel: []const u8, message: []const u8) void {
        self.mutex.lock(self.io) catch return;
        var snapshot: std.ArrayListUnmanaged(Connection) = .empty;
        defer snapshot.deinit(self.allocator);
        for (self.connections.items) |conn| {
            if (std.mem.eql(u8, conn.channel, channel)) {
                snapshot.append(self.allocator, conn) catch {};
            }
        }
        self.mutex.unlock(self.io);

        var dead: std.ArrayListUnmanaged(u64) = .empty;
        defer dead.deinit(self.allocator);

        for (snapshot.items) |conn| {
            self.sendText(conn.stream, message) catch {
                dead.append(self.allocator, conn.id) catch {};
            };
        }

        if (dead.items.len == 0) return;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        for (dead.items) |id| {
            for (self.connections.items, 0..) |conn, i| {
                if (conn.id == id) {
                    _ = self.connections.orderedRemove(i);
                    break;
                }
            }
        }
    }

    fn sendText(self: *Hub, stream: net.Stream, text: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(stream, self.io, &write_buf);
        const writer = &sw.interface;

        var header_buf: [10]u8 = undefined;
        var header_len: usize = 2;
        header_buf[0] = 0x81;

        if (text.len < 126) {
            header_buf[1] = @intCast(text.len);
        } else if (text.len < 65536) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(text.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], text.len, .big);
            header_len = 10;
        }

        try writer.writeAll(header_buf[0..header_len]);
        try writer.writeAll(text);
        try writer.flush();
    }
};

fn makeSocketPair() ![2]net.Socket {
    var fds: [2]posix.fd_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
    if (rc != 0) return error.Unexpected;
    return .{
        net.Socket{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{0} ** 4, .port = 0 } } },
        net.Socket{ .handle = fds[1], .address = .{ .ip4 = .{ .bytes = .{0} ** 4, .port = 0 } } },
    };
}

const testing = std.testing;

test "Hub: init and deinit" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: add increases count" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });
    try testing.expectEqual(@as(usize, 1), hub.count());
}

test "Hub: remove decreases count" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 99, .stream = .{ .socket = sockets[0] } });
    hub.remove(99);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: remove nonexistent id does not crash" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    hub.remove(404);
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: broadcast writes valid WS frame" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });

    const msg = "hello";
    hub.broadcast(msg);

    var buf: [64]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf[0]);
    try testing.expectEqual(@as(u8, msg.len), buf[1]);
    try reader.interface.readSliceAll(buf[0..msg.len]);
    try testing.expectEqualStrings(msg, buf[0..msg.len]);
}

test "Hub: broadcast removes dead connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] } });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.broadcast("anything");
    try testing.expectEqual(@as(usize, 0), hub.count());
}

test "Hub: broadcast delivers to all connections" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    defer sockets_a[0].close(io);
    defer sockets_a[1].close(io);
    defer sockets_b[0].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();
    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] } });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] } });

    const msg = "ping";
    hub.broadcast(msg);

    var buf_a: [64]u8 = undefined;
    var read_buf_a: [256]u8 = undefined;
    var reader_a = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf_a);
    try reader_a.interface.readSliceAll(buf_a[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_a[0]);
    try testing.expectEqual(@as(u8, msg.len), buf_a[1]);

    var buf_b: [64]u8 = undefined;
    var read_buf_b: [256]u8 = undefined;
    var reader_b = net.Stream.Reader.init(.{ .socket = sockets_b[1] }, io, &read_buf_b);
    try reader_b.interface.readSliceAll(buf_b[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_b[0]);
    try testing.expectEqual(@as(u8, msg.len), buf_b[1]);
}

test "Hub: add duplicate id returns error" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    defer sockets_a[0].close(io);
    defer sockets_a[1].close(io);
    defer sockets_b[0].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 7, .stream = .{ .socket = sockets_a[0] } });
    try testing.expectError(
        error.DuplicateId,
        hub.add(.{ .id = 7, .stream = .{ .socket = sockets_b[0] } }),
    );
    try testing.expectEqual(@as(usize, 1), hub.count());
}

test "Hub: broadcastToChannel delivers only to matching channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    defer sockets_a[0].close(io);
    defer sockets_a[1].close(io);
    defer sockets_b[0].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1" });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2" });

    hub.broadcastToChannel("room:1", "hello");

    var buf: [64]u8 = undefined;
    var read_buf: [256]u8 = undefined;
    var reader = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf);
    try reader.interface.readSliceAll(buf[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf[0]);

    try (net.Stream{ .socket = sockets_b[0] }).shutdown(io, .send);
}

test "Hub: broadcast still delivers to all regardless of channel" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets_a = try makeSocketPair();
    const sockets_b = try makeSocketPair();
    defer sockets_a[0].close(io);
    defer sockets_a[1].close(io);
    defer sockets_b[0].close(io);
    defer sockets_b[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets_a[0] }, .channel = "room:1" });
    try hub.add(.{ .id = 2, .stream = .{ .socket = sockets_b[0] }, .channel = "room:2" });

    hub.broadcast("global");

    var buf_a: [64]u8 = undefined;
    var read_buf_a: [256]u8 = undefined;
    var reader_a = net.Stream.Reader.init(.{ .socket = sockets_a[1] }, io, &read_buf_a);
    try reader_a.interface.readSliceAll(buf_a[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_a[0]);

    var buf_b: [64]u8 = undefined;
    var read_buf_b: [256]u8 = undefined;
    var reader_b = net.Stream.Reader.init(.{ .socket = sockets_b[1] }, io, &read_buf_b);
    try reader_b.interface.readSliceAll(buf_b[0..2]);
    try testing.expectEqual(@as(u8, 0x81), buf_b[0]);
}

test "Hub: broadcastToChannel removes dead connection" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const sockets = try makeSocketPair();
    defer sockets[0].close(io);
    defer sockets[1].close(io);
    var hub = Hub.init(testing.allocator, io);
    defer hub.deinit();

    try hub.add(.{ .id = 1, .stream = .{ .socket = sockets[0] }, .channel = "room:1" });
    try testing.expectEqual(@as(usize, 1), hub.count());

    try (net.Stream{ .socket = sockets[0] }).shutdown(io, .send);
    hub.broadcastToChannel("room:1", "msg");
    try testing.expectEqual(@as(usize, 0), hub.count());
}
