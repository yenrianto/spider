const std = @import("std");
const builtin = @import("builtin");
const spider = @import("spider");
// const mysql = @import("spider").mysql;

const World = struct {
    id: i32,
    randomnumber: i32,
};

const Fortune = struct {
    id: i32,
    message: []const u8,
};

fn plaintextHandler(c: *spider.Ctx) !spider.Response {
    return c.text("Hello, World!", .{});
}

fn jsonHandler(c: *spider.Ctx) !spider.Response {
    return c.json(.{ .message = "Hello, World!" }, .{});
}

fn dbHandler(c: *spider.Ctx) !spider.Response {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Thread.getCurrentId()));
    const rand = prng.random();
    const id: i32 = @intCast(rand.intRangeAtMost(u32, 1, 10000));

    const sql = try std.fmt.allocPrint(c.arena, "SELECT id, randomnumber FROM world WHERE id = {d}", .{id});
    const rows = try spider.mysql.query(World, c.arena, sql, .{});
    return c.json(if (rows.len > 0) rows[0] else World{ .id = id, .randomnumber = 0 }, .{});
}

fn queriesHandler(c: *spider.Ctx) !spider.Response {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Thread.getCurrentId()));
    const rand = prng.random();
    const n_str = c.query("queries") orelse "1";
    const n_raw = std.fmt.parseInt(usize, n_str, 10) catch 1;
    const n = @min(@max(n_raw, 1), 500);

    const worlds = try c.arena.alloc(World, n);
    for (worlds) |*w| {
        const id: i32 = @intCast(rand.intRangeAtMost(u32, 1, 10000));
        const sql = try std.fmt.allocPrint(c.arena, "SELECT id, randomnumber FROM world WHERE id = {d}", .{id});
        const rows = spider.mysql.query(World, c.arena, sql, .{}) catch {
            w.* = World{ .id = id, .randomnumber = 0 };
            continue;
        };
        w.* = if (rows.len > 0) rows[0] else World{ .id = id, .randomnumber = 0 };
    }

    return c.json(worlds, .{});
}

fn dbPgHandler(c: *spider.Ctx) !spider.Response {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Thread.getCurrentId()));
    const rand = prng.random();
    const id: i32 = @intCast(rand.intRangeAtMost(u32, 1, 10000));

    const sql_s = try std.fmt.allocPrint(c.arena, "SELECT id, randomnumber FROM world WHERE id = {d}", .{id});
    const sql: [:0]const u8 = try c.arena.dupeZ(u8, sql_s);
    const rows = try spider.pg.query(World, c.arena, sql, .{});
    return c.json(if (rows.len > 0) rows[0] else World{ .id = id, .randomnumber = 0 }, .{});
}

fn queriesPgHandler(c: *spider.Ctx) !spider.Response {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Thread.getCurrentId()));
    const rand = prng.random();
    const n_str = c.query("queries") orelse "1";
    const n_raw = std.fmt.parseInt(usize, n_str, 10) catch 1;
    const n = @min(@max(n_raw, 1), 500);

    const worlds = try c.arena.alloc(World, n);
    for (worlds) |*w| {
        const id: i32 = @intCast(rand.intRangeAtMost(u32, 1, 10000));
        const sql_s = try std.fmt.allocPrint(c.arena, "SELECT id, randomnumber FROM world WHERE id = {d}", .{id});
        const sql: [:0]const u8 = try c.arena.dupeZ(u8, sql_s);
        const rows = spider.pg.query(World, c.arena, sql, .{}) catch {
            w.* = World{ .id = id, .randomnumber = 0 };
            continue;
        };
        w.* = if (rows.len > 0) rows[0] else World{ .id = id, .randomnumber = 0 };
    }

    return c.json(worlds, .{});
}

fn fortunesPgHandler(c: *spider.Ctx) !spider.Response {
    const fortunes_src = try spider.pg.query(Fortune, c.arena, "SELECT id, message FROM fortune", .{});

    var all = try c.arena.alloc(Fortune, fortunes_src.len + 1);
    all[0] = Fortune{ .id = 0, .message = "Additional fortune added at request time." };
    @memcpy(all[1..], fortunes_src);
    const fortunes = all;

    std.sort.heap(Fortune, fortunes, {}, struct {
        fn lessThan(_: void, a: Fortune, b: Fortune) bool {
            return std.mem.lessThan(u8, a.message, b.message);
        }
    }.lessThan);

    var aw: std.Io.Writer.Allocating = .init(c.arena);
    defer aw.deinit();
    for (fortunes) |f| {
        try aw.writer.print("<tr><td>{d}</td><td>{s}</td></tr>\n", .{ f.id, f.message });
    }
    const rows_html = try aw.toOwnedSlice();

    const html = try std.fmt.allocPrint(c.arena,
        \\<!DOCTYPE html>
        \\<html><head><title>Fortunes</title></head>
        \\<body><table>
        \\<tr><th>id</th><th>message</th></tr>
        \\{s}
        \\</table></body></html>
    , .{rows_html});

    return c.html(html, .{});
}

fn fortunesHandler(c: *spider.Ctx) !spider.Response {
    const fortunes_src = try spider.mysql.query(Fortune, c.arena, "SELECT id, message FROM fortune", .{});

    var all = try c.arena.alloc(Fortune, fortunes_src.len + 1);
    all[0] = Fortune{ .id = 0, .message = "Additional fortune added at request time." };
    @memcpy(all[1..], fortunes_src);
    const fortunes = all;

    std.sort.heap(Fortune, fortunes, {}, struct {
        fn lessThan(_: void, a: Fortune, b: Fortune) bool {
            return std.mem.lessThan(u8, a.message, b.message);
        }
    }.lessThan);

    var aw: std.Io.Writer.Allocating = .init(c.arena);
    defer aw.deinit();
    for (fortunes) |f| {
        try aw.writer.print("<tr><td>{d}</td><td>{s}</td></tr>\n", .{ f.id, f.message });
    }
    const rows_html = try aw.toOwnedSlice();

    const html = try std.fmt.allocPrint(c.arena,
        \\<!DOCTYPE html>
        \\<html><head><title>Fortunes</title></head>
        \\<body><table>
        \\<tr><th>id</th><th>message</th></tr>
        \\{s}
        \\</table></body></html>
    , .{rows_html});

    return c.html(html, .{});
}

pub fn main(init: std.process.Init) void {
    const v = builtin.zig_version;
    const min_build = 304;
    if (v.major < 0 or v.minor < 17 or v.patch < min_build) {
        std.debug.print(
            "error: spider requires Zig 0.17.0-dev.304+9787df942 or higher, found {}\n",
            .{v},
        );
        std.process.exit(1);
    }

    // var threaded = std.Io.Threaded.init_single_threaded;
    // const io = threaded.io();
    const io = init.io;

    // mysql.init(std.heap.page_allocator, io, .{
    //     .host = "127.0.0.1",
    //     .port = 3306,
    //     .database = "hello_world",
    //     .user = "root",
    //     .password = "spider_root_password",
    //     .pool_size = 128,
    // }) catch |err| {
    //     std.debug.print("MySQL init failed: {s}\n", .{@errorName(err)});
    //     return;
    // };
    // defer mysql.deinit();

    spider.pg.init(std.heap.page_allocator, io, .{
        .host = "localhost",
        .port = 5434,
        .database = "spiderdb",
        .user = "spider",
        .password = "spider",
        .pool_size = 96,
    }) catch |err| {
        std.debug.print("PG init failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer spider.pg.deinit();

    var keycloak_auth = try spider.keycloak.Keycloak.init(allocator, io, .{
        .base_url      = spider.env.getOr("KEYCLOAK_BASE_URL", ""),
        .realm         = spider.env.getOr("KEYCLOAK_REALM", ""),
        .client_id     = spider.env.getOr("KEYCLOAK_CLIENT_ID", ""),
        .client_secret = spider.env.getOr("KEYCLOAK_CLIENT_SECRET", ""),
        .redirect_uri  = spider.env.getOr("KEYCLOAK_REDIRECT_URI", "http://localhost:3000/auth/callback"),
        .login_path    = "/auth/login",
        .after_callback_path = "/",
        .auth_skip_paths = &.{ "/auth/login", "/auth/callback", "/auth/logout", "/up" },
    });
    defer keycloak_auth.deinit();

    var keycloak_auth = try spider.keycloak.Keycloak.init(allocator, io, .{
        .base_url      = spider.env.getOr("KEYCLOAK_BASE_URL", ""),
        .realm         = spider.env.getOr("KEYCLOAK_REALM", ""),
        .client_id     = spider.env.getOr("KEYCLOAK_CLIENT_ID", ""),
        .client_secret = spider.env.getOr("KEYCLOAK_CLIENT_SECRET", ""),
        .redirect_uri  = spider.env.getOr("KEYCLOAK_REDIRECT_URI", "http://localhost:3000/auth/callback"),
        .login_path    = "/auth/login",
        .after_callback_path = "/",
        .auth_skip_paths = &.{ "/auth/login", "/auth/callback", "/auth/logout", "/up" },
    });
    defer keycloak_auth.deinit();

    var server = spider.app();
    defer server.deinit();
    server
        .get("/plaintext", plaintextHandler)
        .get("/json", jsonHandler)
        // .get("/db", dbHandler)
        // .get("/queries", queriesHandler)
        // .get("/fortunes", fortunesHandler)
        .get("/db-pg", dbPgHandler)
        .get("/queries-pg", queriesPgHandler)
        .get("/fortunes-pg", fortunesPgHandler)
        .listen(.{ .port = 3000 }) catch {};
}
