const std = @import("std");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const websocket = @import("websocket.zig");
const Hub = @import("hub.zig").Hub;

pub const Message = struct {
    data: []const u8,
    type: enum { text, binary },
};

pub const Ws = struct {
    _server: websocket.Server,
    _hub: *Hub,
    _conn_id: u64,
    channel: []const u8 = "",
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    arena: std.mem.Allocator,
    io: std.Io,

    pub fn next(self: *Ws) !?Message {
        const frame = self._server.readFrame(self.arena) catch {
            return null;
        };
        const f = frame orelse {
            return null;
        };
        return switch (f.opcode) {
            .text => Message{ .data = f.payload, .type = .text },
            .binary => Message{ .data = f.payload, .type = .binary },
            .ping, .pong => self.next(),
            .close => null,
            .continuation => null,
        };
    }

    pub fn joinUser(self: *Ws, user_id: u64) !void {
        var ch_buf: [32]u8 = undefined;
        const channel = try std.fmt.bufPrint(&ch_buf, "user:{d}", .{user_id});
        try self.join(channel);
    }

    pub fn join(self: *Ws, channel: []const u8) !void {
        self.channel = channel;
        try self._hub.updateChannel(self._conn_id, channel);
    }

    pub fn send(self: *Ws, text: []const u8) !void {
        try self._server.sendText(text);
    }

    pub fn broadcast(self: *Ws, text: []const u8) void {
        self._hub.broadcast(text);
    }

    pub fn broadcastFmt(self: *Ws, comptime fmt: []const u8, args: anytype) void {
        self._hub.broadcastFmt(fmt, args);
    }

    pub fn broadcastTo(self: *Ws, channel: []const u8, text: []const u8) void {
        self._hub.broadcastToChannel(channel, text);
    }

    pub fn broadcastToFmt(self: *Ws, channel: []const u8, comptime fmt: []const u8, args: anytype) void {
        self._hub.broadcastToChannelFmt(channel, fmt, args);
    }

    pub fn param(self: *Ws, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }
};
