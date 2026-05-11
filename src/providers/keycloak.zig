const std = @import("std");
const pacman = @import("pacman");
const Ctx = @import("../core/context.zig").Ctx;
const Response = @import("../core/context.zig").Response;
const MiddlewareFn = @import("../core/context.zig").MiddlewareFn;
const Handler = @import("../routing/router.zig").Handler;
const JwksAuth = @import("jwks.zig").JwksAuth;

pub const KeycloakConfig = struct {
    base_url: []const u8,
    realm: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8 = "http://localhost:3000/auth/callback",
    after_callback_path: []const u8 = "/",
};

pub const Keycloak = struct {
    jwks: JwksAuth,
    config: KeycloakConfig,
    issuer: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: KeycloakConfig) !Keycloak {
        const issuer = try std.fmt.allocPrint(allocator, "{s}/realms/{s}", .{ config.base_url, config.realm });
        const jwks_url = try std.fmt.allocPrint(allocator, "{s}/protocol/openid-connect/certs", .{issuer});
        defer allocator.free(jwks_url);
        const jwks_auth = try JwksAuth.init(allocator, io, .{
            .jwks_url = jwks_url,
            .issuer = issuer,
            .after_callback_path = config.after_callback_path,
        });
        return Keycloak{
            .jwks = jwks_auth,
            .config = config,
            .issuer = issuer,
        };
    }

    pub fn deinit(self: *Keycloak) void {
        self.jwks.deinit();
    }

    pub fn middleware(self: *Keycloak) MiddlewareFn {
        return self.jwks.middleware();
    }

    pub fn authUrl(self: *const Keycloak, state: []const u8) ![]u8 {
        return try std.fmt.allocPrint(
            self.jwks.allocator,
            "{s}/protocol/openid-connect/auth?client_id={s}&redirect_uri={s}&response_type=code&scope=openid+email+profile&state={s}",
            .{ self.issuer, self.config.client_id, self.config.redirect_uri, state },
        );
    }

    pub fn callbackHandler(self: *Keycloak) Handler {
        const S = struct {
            var instance: ?*Keycloak = null;
            fn h(c: *Ctx) anyerror!Response {
                return instance.?.callbackFn(c);
            }
        };
        S.instance = self;
        return S.h;
    }

    fn callbackFn(self: *Keycloak, c: *Ctx) !Response {
        const code = c.query("code") orelse
            return c.text("Missing authorization code", .{ .status = .bad_request });

        const token_url = try std.fmt.allocPrint(c.arena, "{s}/protocol/openid-connect/token", .{self.issuer});

        var res = try pacman.post(c._io, c.arena, token_url, .{
            .body = .{ .form = &.{
                .{ "grant_type", "authorization_code" },
                .{ "code", code },
                .{ "client_id", self.config.client_id },
                .{ "client_secret", self.config.client_secret },
                .{ "redirect_uri", self.config.redirect_uri },
            } },
        });
        defer res.deinit();

        const parsed = try res.json(struct {
            access_token: []const u8 = "",
            id_token: []const u8 = "",
        });
        defer parsed.deinit();

        const jwt = if (parsed.value.id_token.len > 0) parsed.value.id_token else parsed.value.access_token;
        if (jwt.len == 0)
            return c.text("No token received from Keycloak", .{ .status = .bad_gateway });

        const cookie_str = try c.setCookie("__session", jwt, .{
            .http_only = true,
            .secure = true,
            .same_site = "Lax",
            .path = "/",
            .max_age = 86400 * 7,
        });

        return Response{
            .status = .found,
            .headers = &.{
                .{ "Location", self.config.after_callback_path },
                .{ "Set-Cookie", cookie_str },
            },
        };
    }
};
