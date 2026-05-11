const std = @import("std");
const net = std.Io.net;
const Hub = @import("hub.zig").Hub;

pub const Sse = struct {
    _stream: net.Stream,
    _hub: *Hub,
    _conn_id: u64,
    channel: []const u8 = "",
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator,
    io: std.Io,

    pub fn send(self: *Sse, event: []const u8, data: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.arena, data, .{});
        defer self.arena.free(json);

        var write_buf: [4096]u8 = undefined;
        var sw = net.Stream.Writer.init(self._stream, self.io, &write_buf);
        const writer = &sw.interface;
        try writer.writeAll("event: ");
        try writer.writeAll(event);
        try writer.writeAll("\ndata: ");
        try writer.writeAll(json);
        try writer.writeAll("\n\n");
        try writer.flush();
    }

    pub fn join(self: *Sse, channel: []const u8) !void {
        self.channel = channel;
        try self._hub.updateChannel(self._conn_id, channel);
    }

    pub fn joinUser(self: *Sse, user_id: u64) !void {
        var ch_buf: [32]u8 = undefined;
        const channel = try std.fmt.bufPrint(&ch_buf, "user:{d}", .{user_id});
        try self.join(channel);
    }

    pub fn param(self: *Sse, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    pub fn wait(self: *Sse) void {
        var buf: [1]u8 = undefined;
        var read_buf: [256]u8 = undefined;
        var reader = net.Stream.Reader.init(self._stream, self.io, &read_buf);
        _ = reader.interface.readSliceAll(&buf) catch {};
    }
};
