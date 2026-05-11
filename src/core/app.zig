const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const env = @import("../internal/env.zig");
const static_mod = @import("../modules/static.zig");
pub const StaticConfig = static_mod.StaticConfig;
const ctx_mod = @import("context.zig");
const Ctx = ctx_mod.Ctx;
const Response = ctx_mod.Response;
const MiddlewareFn = ctx_mod.MiddlewareFn;
const ErrorHandler = ctx_mod.ErrorHandler;
const ViewsConfig = ctx_mod.ViewsConfig;
const Database = @import("database.zig").Database;
const DriverType = @import("database.zig").DriverType;
const Router = @import("../routing/router.zig").Router;
const Handler = @import("../routing/router.zig").Handler;
const Config = @import("../internal/config.zig").Config;
const Env = @import("../internal/config.zig").Env;
const default_config = @import("../internal/config.zig").default;
const views_mod = @import("../render/views.zig");
const livereload = @import("../modules/livereload.zig");
const Hub = @import("../ws/hub.zig").Hub;
const Ws = @import("../ws/ws.zig").Ws;
const Sse = @import("../ws/sse.zig").Sse;
const websocket = @import("../ws/websocket.zig");

threadlocal var chain_middlewares: []const MiddlewareFn = &.{};
threadlocal var chain_handler: ?Handler = null;

fn nextFn(c: *Ctx) anyerror!Response {
    if (chain_middlewares.len == 0) {
        return chain_handler.?(c);
    }
    const m = chain_middlewares[0];
    chain_middlewares = chain_middlewares[1..];
    return m(c, nextFn);
}

fn runChain(c: *Ctx, middlewares: []const MiddlewareFn, handler: Handler) anyerror!Response {
    chain_middlewares = middlewares;
    chain_handler = handler;
    if (middlewares.len == 0) return handler(c);
    chain_middlewares = middlewares[1..];
    return middlewares[0](c, nextFn);
}

const RouteMiddlewareEntry = struct {
    path: []const u8,
    method: std.http.Method,
    middlewares: []const MiddlewareFn,
};

const PathMiddlewareEntry = struct {
    path: []const u8,
    middleware: MiddlewareFn,
};

fn collectMiddlewares(
    global_middlewares: []const MiddlewareFn,
    path_middlewares: []const PathMiddlewareEntry,
    path: []const u8,
    route_middlewares: []const MiddlewareFn,
    buf: []MiddlewareFn,
) usize {
    var count: usize = 0;

    for (global_middlewares) |m| {
        if (count < buf.len) {
            buf[count] = m;
            count += 1;
        }
    }

    for (path_middlewares) |entry| {
        const prefix = if (std.mem.endsWith(u8, entry.path, "*"))
            entry.path[0 .. entry.path.len - 1]
        else
            entry.path;
        if (std.mem.startsWith(u8, path, prefix)) {
            if (count < buf.len) {
                buf[count] = entry.middleware;
                count += 1;
            }
        }
    }

    for (route_middlewares) |m| {
        if (count < buf.len) {
            buf[count] = m;
            count += 1;
        }
    }

    return count;
}

const WorkerCtx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    listener: *Io.net.Server,
    router: *Router,
    static_config: StaticConfig,
    views_index: ?*const views_mod.ViewsIndex,
    config: Config,
    error_handler: ?ErrorHandler,
    _db: ?*const Database,
    _driver_type: DriverType,
    decorations: ?*const anyopaque,
    ws_hub: ?*Hub,
    sse_hub: ?*Hub,
    global_middlewares: []const MiddlewareFn,
    path_middlewares: []const PathMiddlewareEntry,
    route_middlewares: []const RouteMiddlewareEntry,
};

const ConnCtx = struct {
    stream: Io.net.Stream,
    io: Io,
    gpa: std.mem.Allocator,
    router: *Router,
    static_config: StaticConfig,
    views_index: ?*const views_mod.ViewsIndex,
    config: Config,
    error_handler: ?ErrorHandler,
    _db: ?*const Database,
    _driver_type: DriverType,
    decorations: ?*const anyopaque,
    ws_hub: ?*Hub,
    sse_hub: ?*Hub,
    global_middlewares: []const MiddlewareFn,
    path_middlewares: []const PathMiddlewareEntry,
    route_middlewares: []const RouteMiddlewareEntry,
};

fn workerLoop(wctx: WorkerCtx) void {
    var group: std.Io.Group = .init;

    while (true) {
        const stream = wctx.listener.accept(wctx.io) catch |err| {
            std.log.err("worker accept error: {s}", .{@errorName(err)});
            break;
        };

        group.concurrent(wctx.io, handleConnection, .{ConnCtx{
            .stream = stream,
            .io = wctx.io,
            .gpa = wctx.gpa,
            .router = wctx.router,
            .static_config = wctx.static_config,
            .views_index = wctx.views_index,
            .config = wctx.config,
            .error_handler = wctx.error_handler,
            ._db = wctx._db,
            ._driver_type = wctx._driver_type,
            .decorations = wctx.decorations,
            .ws_hub = wctx.ws_hub,
            .sse_hub = wctx.sse_hub,
            .global_middlewares = wctx.global_middlewares,
            .path_middlewares = wctx.path_middlewares,
            .route_middlewares = wctx.route_middlewares,
        }}) catch |err| {
            std.log.err("worker concurrent error: {s}", .{@errorName(err)});
            stream.close(wctx.io);
        };
    }

    group.await(wctx.io) catch {};
}

fn handleConnection(ctx: ConnCtx) error{Canceled}!void {
    defer ctx.stream.close(ctx.io);

    var req_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer req_arena.deinit();

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;

    var stream_reader = Io.net.Stream.Reader.init(ctx.stream, ctx.io, &read_buf);
    var stream_writer = Io.net.Stream.Writer.init(ctx.stream, ctx.io, &write_buf);

    var http = std.http.Server.init(
        &stream_reader.interface,
        &stream_writer.interface,
    );

    while (true) {
        _ = req_arena.reset(.{ .retain_with_limit = 8192 });
        const arena = req_arena.allocator();

        var request = http.receiveHead() catch break;

        const target = request.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

        var headers_map: std.StringHashMapUnmanaged([]const u8) = .{};
        {
            var hdr_iter = request.iterateHeaders();
            while (hdr_iter.next()) |h| {
                headers_map.put(arena, h.name, h.value) catch {};
            }
        }

        const body: ?[]const u8 = blk: {
            const cl = request.head.content_length orelse break :blk null;
            if (cl == 0) break :blk null;
            const target_copy = arena.dupe(u8, target) catch break :blk null;
            var body_io_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_io_buf);
            request.head.target = target_copy;
            break :blk body_reader.readAlloc(arena, cl) catch null;
        };

        {
            if ((static_mod.serve(ctx.io, arena, ctx.static_config, path) catch null)) |static_response| {
                var extra_hdrs_buf: [2]std.http.Header = undefined;
                extra_hdrs_buf[0] = .{ .name = "content-type", .value = static_response.content_type };
                request.respond(static_response.body orelse "", .{
                    .status = static_response.status,
                    .extra_headers = extra_hdrs_buf[0..1],
                }) catch {};
                if (!request.head.keep_alive) break;
                continue;
            }
        }

        const views_cfg: ?ViewsConfig = if (ctx.config.views_dir) |vd| ViewsConfig{
            .views_dir = vd,
            .layout = ctx.config.layout,
            .io = ctx.io,
            .arena = arena,
            .mode = .runtime,
            .index = ctx.views_index,
        } else null;

        const match = ctx.router.match(request.head.method, path, arena) catch null;
        const response = if (match) |m| blk: {
            var ctx_req = Ctx{
                .request = request,
                .arena = arena,
                .params = m.params,
                .body = body,
                ._db = ctx._db,
                ._driver_type = ctx._driver_type,
                ._views = views_cfg,
                ._io = ctx.io,
                ._stream = ctx.stream,
                ._headers = headers_map,
                ._decorations = ctx.decorations,
                ._ws_hub = ctx.ws_hub,
                ._sse_hub = ctx.sse_hub,
            };

            var route_mws: []const MiddlewareFn = &.{};
            for (ctx.route_middlewares) |entry| {
                if (entry.method == request.head.method and std.mem.eql(u8, entry.path, path)) {
                    route_mws = entry.middlewares;
                    break;
                }
            }

            var mw_buf: [64]MiddlewareFn = undefined;
            const mw_count = collectMiddlewares(ctx.global_middlewares, ctx.path_middlewares, path, route_mws, &mw_buf);

            break :blk runChain(&ctx_req, mw_buf[0..mw_count], m.handler) catch |err| r: {
                if (ctx.error_handler) |eh| {
                    break :r eh(&ctx_req, err) catch Response{
                        .status = .internal_server_error,
                        .body = "Internal Server Error",
                        .content_type = "text/plain",
                    };
                }
                std.log.err("unhandled error: {s}", .{@errorName(err)});
                break :r Response{ .status = .internal_server_error, .body = "Internal Server Error", .content_type = "text/plain" };
            };
        } else blk: {
            var ctx_req = Ctx{
                .request = request,
                .arena = arena,
                .params = .{},
                .body = body,
                ._db = ctx._db,
                ._driver_type = ctx._driver_type,
                ._views = views_cfg,
                ._io = ctx.io,
                ._stream = ctx.stream,
                ._headers = headers_map,
                ._decorations = ctx.decorations,
                ._ws_hub = ctx.ws_hub,
                ._sse_hub = ctx.sse_hub,
            };
            var mw_buf_404: [64]MiddlewareFn = undefined;
            const mw_count_404 = collectMiddlewares(ctx.global_middlewares, ctx.path_middlewares, path, &.{}, &mw_buf_404);
            const notFoundHandler: Handler = struct {
                fn h(c: *Ctx) anyerror!Response {
                    return c.text("404 Not Found", .{ .status = .not_found }) catch
                        Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
                }
            }.h;
            break :blk if (mw_count_404 > 0)
                runChain(&ctx_req, mw_buf_404[0..mw_count_404], notFoundHandler) catch |err| r: {
                    if (ctx.error_handler) |eh| {
                        break :r eh(&ctx_req, err) catch Response{
                            .status = .internal_server_error,
                            .body = "Internal Server Error",
                            .content_type = "text/plain",
                        };
                    }
                    break :r Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
                }
            else
                ctx_req.text("404 Not Found", .{ .status = .not_found }) catch
                    Response{ .status = .not_found, .body = "404 Not Found", .content_type = "text/plain" };
        };

        var extra_headers_buf: [32]std.http.Header = undefined;
        var header_count: usize = 0;
        extra_headers_buf[header_count] = .{ .name = "content-type", .value = response.content_type };
        header_count += 1;
        for (response.headers) |h| {
            if (header_count < 32) {
                extra_headers_buf[header_count] = .{ .name = h[0], .value = h[1] };
                header_count += 1;
            }
        }
        for (response.cookies) |c| {
            if (header_count < 32) {
                extra_headers_buf[header_count] = .{ .name = "Set-Cookie", .value = c[1] };
                header_count += 1;
            }
        }
        if (response.raw) {
            if (!request.head.keep_alive) break;
            continue;
        }

        const final_body = response.body orelse "";

        request.respond(final_body, .{
            .status = response.status,
            .extra_headers = extra_headers_buf[0..header_count],
        }) catch {};

        if (!request.head.keep_alive) break;
    }
}

pub const ListenOptions = struct {
    port: ?u16 = null,
    host: ?[]const u8 = null,
};

fn findFieldName(comptime T: type, comptime ParamType: type) []const u8 {
    const T_info = @typeInfo(T);
    inline for (T_info.@"struct".fields) |f| {
        if (f.type == ParamType) {
            return f.name;
        }
    }
    @compileError("field not found");
}

fn buildWrapper(comptime handler: anytype, comptime T: type) Handler {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    const extra = fn_info.params[1..];
    const extra_len = extra.len;

    if (extra_len == 0) return @as(Handler, handler);

    comptime {
        const T_info = @typeInfo(T);
        for (extra) |p| {
            const pt = p.type orelse @compileError("generic param not supported");
            var found = false;
            for (T_info.@"struct".fields) |f| {
                if (f.type == pt) found = true;
            }
            if (!found) {
                @compileError(std.fmt.comptimePrint(
                    "handler requires type `{s}` which was not provided to spider.app(). " ++
                        "Add a field of this type to the app() argument.",
                    .{@typeName(pt)},
                ));
            }
        }
    }

    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const decos: *const T = @as(*const T, @ptrCast(@alignCast(ctx._decorations.?)));

            if (extra_len == 1) {
                const f0 = comptime findFieldName(T, extra[0].type.?);
                return handler(ctx, @field(decos, f0));
            }
            if (extra_len == 2) {
                const f0 = comptime findFieldName(T, extra[0].type.?);
                const f1 = comptime findFieldName(T, extra[1].type.?);
                return handler(ctx, @field(decos, f0), @field(decos, f1));
            }
            if (extra_len == 3) {
                const f0 = comptime findFieldName(T, extra[0].type.?);
                const f1 = comptime findFieldName(T, extra[1].type.?);
                const f2 = comptime findFieldName(T, extra[2].type.?);
                return handler(ctx, @field(decos, f0), @field(decos, f1), @field(decos, f2));
            }
            if (extra_len == 4) {
                const f0 = comptime findFieldName(T, extra[0].type.?);
                const f1 = comptime findFieldName(T, extra[1].type.?);
                const f2 = comptime findFieldName(T, extra[2].type.?);
                const f3 = comptime findFieldName(T, extra[3].type.?);
                return handler(ctx, @field(decos, f0), @field(decos, f1), @field(decos, f2), @field(decos, f3));
            }
            @compileError("max 4 extra params supported");
        }
    };
    return W.call;
}

fn buildWsWrapper(comptime handler: fn (*Ws) anyerror!void) Handler {
    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const hub = ctx._ws_hub orelse return ctx.text("", .{});
            var ws_server = websocket.Server.init(ctx._stream, ctx._io, ctx.arena);
            if (!try ws_server.handshake(ctx.arena, &ctx._headers)) {
                return ctx.text("", .{});
            }

            var rand_buf: [8]u8 = undefined;
            std.Io.random(ctx._io, &rand_buf);
            const conn_id = std.mem.readInt(u64, &rand_buf, .little);
            try hub.add(.{ .id = conn_id, .stream = ctx._stream });
            defer hub.remove(conn_id);

            var ws = Ws{
                ._server = ws_server,
                ._hub = hub,
                ._conn_id = conn_id,
                .params = ctx.params,
                .arena = ctx.arena,
                .io = ctx._io,
            };

            try handler(&ws);
            return Response{ .raw = true, .status = .switching_protocols };
        }
    };
    return W.call;
}

fn buildSseWrapper(comptime handler: fn (*Sse) anyerror!void) Handler {
    const W = struct {
        pub fn call(ctx: *Ctx) anyerror!Response {
            const hub = ctx._sse_hub orelse return ctx.text("", .{});

            var write_buf: [512]u8 = undefined;
            var sw = Io.net.Stream.Writer.init(ctx._stream, ctx._io, &write_buf);
            const writer = &sw.interface;
            try writer.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "Content-Type: text/event-stream\r\n" ++
                    "Cache-Control: no-cache\r\n" ++
                    "Connection: keep-alive\r\n" ++
                    "Access-Control-Allow-Origin: *\r\n" ++
                    "\r\n",
            );
            try writer.flush();

            var rand_buf: [8]u8 = undefined;
            std.Io.random(ctx._io, &rand_buf);
            const conn_id = std.mem.readInt(u64, &rand_buf, .little);

            try hub.add(.{
                .id = conn_id,
                .stream = ctx._stream,
                .type = .sse,
            });
            defer hub.remove(conn_id);

            var sse = Sse{
                ._stream = ctx._stream,
                ._hub = hub,
                ._conn_id = conn_id,
                .params = ctx.params,
                .arena = ctx.arena,
                .io = ctx._io,
            };

            handler(&sse) catch {};
            return Response{ .raw = true };
        }
    };
    return W.call;
}

const IntervalEntry = struct {
    hub: *Hub,
    ms: u64,
    callback: *const fn (*Hub) void,
    io: std.Io,
};

fn intervalLoop(entry: IntervalEntry) void {
    while (true) {
        std.Io.sleep(
            entry.io,
            std.Io.Duration.fromMilliseconds(@as(i64, @intCast(entry.ms))),
            .real,
        ) catch {};
        entry.callback(entry.hub);
    }
}

pub fn Server(comptime T: type) type {
    return struct {
        const Self = @This();

        spider_arena: std.heap.ArenaAllocator,
        spider_gpa: std.heap.DebugAllocator(.{}),
        allocator: std.mem.Allocator,
        gpa: std.mem.Allocator,
        router: Router,
        decorations: T,
        global_middlewares: [16]MiddlewareFn = undefined,
        global_middleware_count: usize = 0,
        path_middlewares: [32]PathMiddlewareEntry = undefined,
        path_middleware_count: usize = 0,
        route_middlewares: std.ArrayList(RouteMiddlewareEntry),
        error_handler: ?ErrorHandler = null,
        _db: ?Database = null,
        _driver_type: DriverType = .postgresql,
        static_config: StaticConfig = .{ .dir = "./public", .prefix = "/" },
        config: Config = default_config,
        views_index: ?views_mod.ViewsIndex = null,
        ws_hub: ?Hub = null,
        ws_threaded: ?std.Io.Threaded = null,
        sse_hub: ?Hub = null,
        sse_threaded: ?std.Io.Threaded = null,
        interval_threads: std.ArrayListUnmanaged(IntervalEntry) = .empty,

        pub fn init() Self {
            env.autoLoad(std.heap.page_allocator);
            env.checkGitignore();

            var self: Self = .{
                .spider_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .spider_gpa = .init,
                .allocator = undefined,
                .gpa = undefined,
                .router = Router.init(std.heap.page_allocator) catch unreachable,
                .decorations = undefined,
                .global_middleware_count = 0,
                .path_middleware_count = 0,
                .route_middlewares = .empty,
            };
            self.allocator = std.heap.page_allocator;
            self.gpa = if (builtin.mode == .Debug)
                self.spider_gpa.allocator()
            else
                std.heap.smp_allocator;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.views_index) |*idx| idx.deinit();
            self.route_middlewares.deinit(std.heap.page_allocator);
            self.router.deinit();
            if (self.ws_hub) |*h| h.deinit();
            if (self.sse_hub) |*h| h.deinit();
            self.interval_threads.deinit(std.heap.smp_allocator);
            _ = self.spider_gpa.deinit();
            self.spider_arena.deinit();
        }

        pub fn use(self: *Self, m: MiddlewareFn) *Self {
            if (self.global_middleware_count < 16) {
                self.global_middlewares[self.global_middleware_count] = m;
                self.global_middleware_count += 1;
            }
            return self;
        }

        pub fn useAt(self: *Self, path: []const u8, m: MiddlewareFn) *Self {
            if (self.path_middleware_count < 32) {
                self.path_middlewares[self.path_middleware_count] = .{ .path = path, .middleware = m };
                self.path_middleware_count += 1;
            }
            return self;
        }

        pub fn onError(self: *Self, handler: ErrorHandler) *Self {
            self.error_handler = handler;
            return self;
        }

        pub fn db(self: *Self, database: Database) *Self {
            self._db = database;
            self._driver_type = database.driver_type;
            return self;
        }

        pub fn staticDir(self: *Self, dir: []const u8) *Self {
            self.static_config = .{ .dir = dir, .prefix = "/" };
            return self;
        }

        pub fn staticAt(self: *Self, dir: []const u8, prefix: []const u8) *Self {
            self.static_config = .{ .dir = dir, .prefix = prefix };
            return self;
        }

        pub fn get(self: *Self, path: []const u8, handler: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler) handler else buildWrapper(handler, T);
            self.router.add(.GET, path, H) catch unreachable;
            return self;
        }

        pub fn post(self: *Self, path: []const u8, handler: anytype) *Self {
            const H = if (@TypeOf(handler) == Handler) handler else buildWrapper(handler, T);
            self.router.add(.POST, path, H) catch unreachable;
            return self;
        }

        pub fn ws(self: *Self, path: []const u8, comptime handler: fn (*Ws) anyerror!void) *Self {
            if (self.ws_hub == null) {
                self.ws_threaded = std.Io.Threaded.init_single_threaded;
                self.ws_hub = Hub.init(std.heap.smp_allocator, self.ws_threaded.?.io());
            }
            const H = buildWsWrapper(handler);
            self.router.add(.GET, path, H) catch unreachable;
            return self;
        }

        pub fn wsInterval(self: *Self, path: []const u8, ms: u64, comptime callback: fn (*Hub) void) *Self {
            if (self.ws_hub == null) {
                self.ws_threaded = std.Io.Threaded.init_single_threaded;
                self.ws_hub = Hub.init(std.heap.smp_allocator, self.ws_threaded.?.io());
            }
            const H = buildWsWrapper(struct {
                fn handle(w: *Ws) anyerror!void {
                    while (try w.next()) |_| {}
                }
            }.handle);
            self.router.add(.GET, path, H) catch unreachable;
            self.interval_threads.append(std.heap.smp_allocator, .{
                .hub = &self.ws_hub.?,
                .ms = ms,
                .callback = callback,
                .io = undefined,
            }) catch {};
            return self;
        }

        pub fn sse(self: *Self, path: []const u8, comptime handler: fn (*Sse) anyerror!void) *Self {
            if (self.sse_hub == null) {
                self.sse_threaded = std.Io.Threaded.init_single_threaded;
                self.sse_hub = Hub.init(std.heap.smp_allocator, self.sse_threaded.?.io());
            }
            const H = buildSseWrapper(handler);
            self.router.add(.GET, path, H) catch unreachable;
            return self;
        }

        pub fn addRoute(
            self: *Self,
            method: std.http.Method,
            path: []const u8,
            middlewares: []const MiddlewareFn,
            handler: Handler,
        ) void {
            self.router.add(method, path, handler) catch {};
            if (middlewares.len > 0) {
                self.route_middlewares.append(std.heap.page_allocator, .{
                    .path = path,
                    .method = method,
                    .middlewares = middlewares,
                }) catch {};
            }
        }

        pub fn group(
            self: *Self,
            prefix: []const u8,
            middlewares: []const MiddlewareFn,
            register: *const fn (*Self, []const u8, []const MiddlewareFn) void,
        ) *Self {
            register(self, prefix, middlewares);
            return self;
        }

        pub fn listen(self: *Self, options: ListenOptions) !void {
            const port = options.port orelse self.config.port;
            const host = options.host orelse self.config.host;

            const gpa = std.heap.smp_allocator;

            var threaded: Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            const io = threaded.io();

            const address = try Io.net.IpAddress.parse(host, port);
            var listener = try address.listen(io, .{ .reuse_address = true });
            defer listener.deinit(io);

            std.log.info("Server listening on http://{s}:{d}", .{ host, port });

            for (self.interval_threads.items) |*entry| {
                entry.io = io;
                const t = std.Thread.spawn(.{}, intervalLoop, .{entry.*}) catch continue;
                t.detach();
            }

            const cpu_count = std.Thread.getCpuCount() catch 2;

            const threads = try gpa.alloc(std.Thread, cpu_count);
            defer gpa.free(threads);

            const views_idx_ptr: ?*const views_mod.ViewsIndex = if (self.views_index) |*idx| idx else null;

            const worker_ctx = WorkerCtx{
                .io = io,
                .gpa = gpa,
                .listener = &listener,
                .router = &self.router,
                .static_config = self.static_config,
                .views_index = views_idx_ptr,
                .config = self.config,
                .error_handler = self.error_handler,
                ._db = if (self._db) |*d| @as(*const Database, d) else null,
                ._driver_type = self._driver_type,
                .decorations = if (@sizeOf(T) == 0) null else @as(*const anyopaque, @ptrCast(&self.decorations)),
                .ws_hub = if (self.ws_hub) |*h| h else null,
                .sse_hub = if (self.sse_hub) |*h| h else null,
                .global_middlewares = self.global_middlewares[0..self.global_middleware_count],
                .path_middlewares = self.path_middlewares[0..self.path_middleware_count],
                .route_middlewares = self.route_middlewares.items,
            };

            for (threads) |*t| {
                t.* = std.Thread.spawn(.{}, workerLoop, .{worker_ctx}) catch |err| {
                    std.log.err("failed to spawn worker thread: {s}", .{@errorName(err)});
                    continue;
                };
            }

            for (threads) |t| t.join();
        }
    };
}

const EmptyDeco = struct {};

fn AppType(comptime T: type) type {
    return Server(T);
}

pub fn server() Server(EmptyDeco) {
    return Server(EmptyDeco).init();
}

pub fn app(decorations: anytype) AppType(@TypeOf(decorations)) {
    if (@hasDecl(@import("spider_config"), "is_default")) {
        std.log.warn(
            "No spider.config.zig found. Running with defaults: views_dir=\"./views\", port=3000, env=development. " ++
                "Runtime template loading may not work without it. " ++
                "Create spider.config.zig in your project root to customize.",
            .{},
        );
    }

    const cfg = @import("../internal/config.zig").fromRoot();
    var s = Server(@TypeOf(decorations)).init();
    s.decorations = decorations;
    s.config = cfg;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const views_dir = cfg.views_dir orelse "src";
    s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch null;

    if (cfg.env == .development) {
        _ = s.get("/_spider/reload", livereload.handler);
    }

    return s;
}

pub fn appWithConfig(config: Config) Server(EmptyDeco) {
    var s = Server(EmptyDeco).init();
    s.config = config;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const views_dir = config.views_dir orelse "src";
    s.views_index = views_mod.buildIndex(io, std.heap.smp_allocator, views_dir) catch null;

    if (config.env == .development) {
        _ = s.get("/_spider/reload", livereload.handler);
    }

    return s;
}
