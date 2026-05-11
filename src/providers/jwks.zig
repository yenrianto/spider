const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const NextFn = @import("../core/context.zig").NextFn;

const rsa = std.crypto.Certificate.rsa;
const b64 = std.base64.url_safe_no_pad;

const JwkEntry = struct {
    n: []const u8,
    e: []const u8,
};

pub const JwksConfig = struct {
    jwks_url: []const u8,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    cookie_name: []const u8 = "__session",
    login_path: []const u8 = "/login",
    after_callback_path: []const u8 = "/",
    auth_skip_paths: []const []const u8 = &.{},
};

pub const Claims = struct {
    sub: []const u8,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    iss: ?[]const u8 = null,
    exp: i64,
    nbf: ?i64 = null,
    extra: std.StringHashMapUnmanaged([]const u8) = .{},
};

pub const JwksAuth = struct {
    config: JwksConfig,
    allocator: std.mem.Allocator,
    io: std.Io,
    keys: std.StringHashMapUnmanaged(JwkEntry),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: JwksConfig) !JwksAuth {
        var self = JwksAuth{
            .config = config,
            .allocator = allocator,
            .io = io,
            .keys = .{},
        };
        try self.fetchJwks();
        return self;
    }

    pub fn deinit(self: *JwksAuth) void {
        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.n);
            self.allocator.free(entry.value_ptr.*.e);
        }
        self.keys.deinit(self.allocator);
    }

    pub fn fetchJwks(self: *JwksAuth) !void {
        var res = try pacman.get(self.io, self.allocator, self.config.jwks_url, .{});
        defer res.deinit();

        const parsed = try res.json(struct {
            keys: []const struct {
                kid: []const u8,
                n: []const u8,
                e: []const u8,
            },
        });
        defer parsed.deinit();

        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.n);
            self.allocator.free(entry.value_ptr.*.e);
        }
        self.keys.deinit(self.allocator);
        self.keys = .{};

        for (parsed.value.keys) |key| {
            const kid = try self.allocator.dupe(u8, key.kid);
            errdefer self.allocator.free(kid);
            const n = try self.allocator.dupe(u8, key.n);
            errdefer self.allocator.free(n);
            const e = try self.allocator.dupe(u8, key.e);
            errdefer self.allocator.free(e);
            try self.keys.put(self.allocator, kid, .{ .n = n, .e = e });
        }
    }

    pub fn verifyToken(self: *JwksAuth, allocator: std.mem.Allocator, token: []const u8) !Claims {
        const parts = splitToken(token) orelse return error.InvalidToken;

        const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parts.header, parts.payload });
        defer allocator.free(signing_input);

        const hdr_len = try b64.Decoder.calcSizeForSlice(parts.header);
        const hdr_buf = try allocator.alloc(u8, hdr_len);
        defer allocator.free(hdr_buf);
        try b64.Decoder.decode(hdr_buf, parts.header);

        const parsed_hdr = try std.json.parseFromSlice(struct {
            kid: []const u8 = "",
        }, allocator, hdr_buf[0..hdr_len], .{ .ignore_unknown_fields = true });
        defer parsed_hdr.deinit();

        const kid = parsed_hdr.value.kid;

        const jwk = if (self.keys.get(kid)) |entry|
            entry
        else blk: {
            try self.fetchJwks();
            break :blk self.keys.get(kid) orelse return error.UnknownKey;
        };

        try verifyRsaSha256(parts.sig, signing_input, jwk.n, jwk.e);

        const payload_len = try b64.Decoder.calcSizeForSlice(parts.payload);
        const payload_buf = try allocator.alloc(u8, payload_len);
        defer allocator.free(payload_buf);
        try b64.Decoder.decode(payload_buf, parts.payload);

        const RawClaims = struct {
            sub: []const u8,
            exp: i64,
            nbf: ?i64 = null,
            iss: ?[]const u8 = null,
            email: ?[]const u8 = null,
            name: ?[]const u8 = null,
        };

        const parsed = try std.json.parseFromSlice(RawClaims, allocator, payload_buf[0..payload_len], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (self.config.issuer) |expected_iss| {
            const actual_iss = parsed.value.iss orelse return error.MissingIssuer;
            if (!std.mem.eql(u8, actual_iss, expected_iss)) return error.InvalidIssuer;
        }

        return Claims{
            .sub = try allocator.dupe(u8, parsed.value.sub),
            .email = if (parsed.value.email) |e| try allocator.dupe(u8, e) else null,
            .name = if (parsed.value.name) |n| try allocator.dupe(u8, n) else null,
            .iss = if (parsed.value.iss) |i| try allocator.dupe(u8, i) else null,
            .exp = parsed.value.exp,
            .nbf = parsed.value.nbf,
        };
    }

    pub fn middleware(self: *JwksAuth) MiddlewareFn {
        const S = struct {
            var instance: ?*JwksAuth = null;
            fn mw(c: *Ctx, next: NextFn) anyerror!Response {
                return instance.?.middlewareFn(c, next);
            }
        };
        S.instance = self;
        return S.mw;
    }

    fn middlewareFn(self: *JwksAuth, c: *Ctx, next: NextFn) !Response {
        const full_path = c.getPath();
        const path = if (std.mem.indexOfScalar(u8, full_path, '?')) |q|
            full_path[0..q]
        else
            full_path;
        for (self.config.auth_skip_paths) |skip| {
            if (std.mem.eql(u8, path, skip)) return next(c);
        }

        const token = extractToken(c, self.config.cookie_name) orelse
            return redirect(c, self.config.login_path);

        const claims = self.verifyToken(c.arena, token) catch |err| switch (err) {
            error.InvalidToken,
            error.UnknownKey,
            error.InvalidIssuer,
            error.MissingIssuer,
            error.UnsupportedKeySize,
            error.InvalidSignature,
            => return c.text(@errorName(err), .{ .status = .unauthorized }),
            else => |e| return c.text(@errorName(e), .{ .status = .unauthorized }),
        };

        const now_sec: i64 = @intCast(@divFloor(
            std.Io.Clock.now(.real, c._io).nanoseconds,
            1_000_000_000,
        ));
        if (claims.exp < now_sec)
            return c.text("Token expired", .{ .status = .unauthorized });
        if (claims.nbf) |nbf| {
            if (nbf > now_sec)
                return c.text("Token not yet valid", .{ .status = .unauthorized });
        }

        try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_sub"), try c.arena.dupe(u8, claims.sub));
        if (claims.email) |email| {
            try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_email"), try c.arena.dupe(u8, email));
        }
        if (claims.name) |name| {
            try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_name"), try c.arena.dupe(u8, name));
        }
        if (claims.iss) |iss| {
            try c.params.put(c.arena, try c.arena.dupe(u8, "_auth_iss"), try c.arena.dupe(u8, iss));
        }

        return next(c);
    }
};

fn redirect(c: *Ctx, url: []const u8) Response {
    const headers = c.arena.alloc([2][]const u8, 1) catch
        return Response{ .status = .found, .body = url, .content_type = "text/plain" };
    headers[0] = .{ "Location", url };
    return Response{ .status = .found, .body = null, .content_type = "text/plain", .headers = headers };
}

fn extractToken(c: *Ctx, cookie_name: []const u8) ?[]const u8 {
    if (c.header("Authorization")) |auth| {
        if (std.mem.startsWith(u8, auth, "Bearer ")) {
            return auth["Bearer ".len..];
        }
    }
    return c.cookie(cookie_name);
}

fn splitToken(token: []const u8) ?struct { header: []const u8, payload: []const u8, sig: []const u8 } {
    var it = std.mem.splitScalar(u8, token, '.');
    const header = it.next() orelse return null;
    const payload = it.next() orelse return null;
    const sig = it.next() orelse return null;
    if (it.next() != null) return null;
    return .{ .header = header, .payload = payload, .sig = sig };
}

fn verifyRsaSha256(sig_b64url: []const u8, msg: []const u8, n_b64url: []const u8, e_b64url: []const u8) !void {
    const aa = std.heap.page_allocator;

    const sig_len = try b64.Decoder.calcSizeForSlice(sig_b64url);
    const sig_buf = try aa.alloc(u8, sig_len);
    defer aa.free(sig_buf);
    try b64.Decoder.decode(sig_buf, sig_b64url);

    const n_len = try b64.Decoder.calcSizeForSlice(n_b64url);
    const n_buf = try aa.alloc(u8, n_len);
    defer aa.free(n_buf);
    try b64.Decoder.decode(n_buf, n_b64url);

    const e_len = try b64.Decoder.calcSizeForSlice(e_b64url);
    const e_buf = try aa.alloc(u8, e_len);
    defer aa.free(e_buf);
    try b64.Decoder.decode(e_buf, e_b64url);

    try verifyRsaSha256Raw(sig_buf[0..sig_len], msg, n_buf[0..n_len], e_buf[0..e_len]);
}

fn verifyRsaSha256Raw(sig: []const u8, msg: []const u8, n: []const u8, e: []const u8) !void {
    const public_key = try rsa.PublicKey.fromBytes(e, n);
    switch (sig.len) {
        inline 128, 256, 384, 512 => |modulus_len| {
            var sig_arr: [modulus_len]u8 = undefined;
            @memcpy(&sig_arr, sig[0..modulus_len]);
            try rsa.PKCS1v1_5Signature.verify(modulus_len, sig_arr, msg, public_key, std.crypto.hash.sha2.Sha256);
        },
        else => return error.UnsupportedKeySize,
    }
}
