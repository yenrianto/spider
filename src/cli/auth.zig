const std = @import("std");
const template_engine = @import("template_engine.zig");
const fs_utils = @import("fs_utils.zig");
const mod_updater = @import("mod_updater.zig");
const auth_updater = @import("auth_updater.zig");

const mod_tmpl = @embedFile("templates/auth/mod.zig.template");
const controller_tmpl = @embedFile("templates/auth/controller.zig.template");
const login_html_tmpl = @embedFile("templates/auth/login.html.template");

const keycloak_config =
    \\        .base_url      = spider.env.getOr("KEYCLOAK_BASE_URL", ""),
    \\        .realm         = spider.env.getOr("KEYCLOAK_REALM", ""),
    \\        .client_id     = spider.env.getOr("KEYCLOAK_CLIENT_ID", ""),
    \\        .client_secret = spider.env.getOr("KEYCLOAK_CLIENT_SECRET", ""),
    \\        .redirect_uri  = spider.env.getOr("KEYCLOAK_REDIRECT_URI", "http://localhost:3000/auth/callback"),
    \\        .login_path    = "/auth/login",
    \\        .after_callback_path = "/auth/session",
    \\        .auth_skip_paths = &.{ "/auth/login", "/auth/callback", "/auth/logout", "/up", "/invite", "/auth/session" },
;

const google_config =
    \\        .client_id     = spider.env.getOr("GOOGLE_CLIENT_ID", ""),
    \\        .client_secret = spider.env.getOr("GOOGLE_CLIENT_SECRET", ""),
    \\        .redirect_uri  = spider.env.getOr("GOOGLE_REDIRECT_URI", "http://localhost:3000/auth/callback"),
;

pub fn run(io: std.Io, allocator: std.mem.Allocator, provider: []const u8) !void {
    if (!std.mem.eql(u8, provider, "keycloak") and !std.mem.eql(u8, provider, "google")) {
        std.debug.print("error: unsupported provider '{s}'. Use --provider=keycloak or --provider=google\n", .{provider});
        return error.UnsupportedProvider;
    }

    const root_dir = try fs_utils.findProjectRoot(io);

    const Provider = try std.fmt.allocPrint(allocator, "{c}{s}", .{ std.ascii.toUpper(provider[0]), provider[1..] });
    defer allocator.free(Provider);

    const vars = [_][2][]const u8{
        .{ "{{provider}}", provider },
        .{ "{{Provider}}", Provider },
    };

    std.debug.print("Generating auth feature with provider '{s}'...\n", .{provider});

    // Create features/auth/ directory
    var features_dir = root_dir.openDir(io, "src/features", .{}) catch |err| {
        std.debug.print("error: 'src/features' directory not found. Are you in a Spider project?\n", .{});
        return err;
    };
    defer features_dir.close(io);

    features_dir.createDir(io, "auth", .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("error: auth feature already exists\n", .{});
            return error.FeatureExists;
        }
        return err;
    };

    var auth_dir = try features_dir.openDir(io, "auth", .{});
    defer auth_dir.close(io);

    try auth_dir.createDir(io, "views", .default_dir);

    // Write mod.zig
    const mod_content = try template_engine.renderTemplateWithVars(allocator, mod_tmpl, &vars);
    defer allocator.free(mod_content);
    try fs_utils.writeFile(io, auth_dir, "mod.zig", mod_content);
    std.debug.print("  create  src/features/auth/mod.zig\n", .{});

    // Write controller.zig
    const controller_content = try template_engine.renderTemplateWithVars(allocator, controller_tmpl, &vars);
    defer allocator.free(controller_content);
    try fs_utils.writeFile(io, auth_dir, "controller.zig", controller_content);
    std.debug.print("  create  src/features/auth/controller.zig\n", .{});

    // Write views/login.html
    const login_html_content = try template_engine.renderTemplateWithVars(allocator, login_html_tmpl, &vars);
    defer allocator.free(login_html_content);
    try fs_utils.writeFile(io, auth_dir, "views/login.html", login_html_content);
    std.debug.print("  create  src/features/auth/views/login.html\n", .{});

    // Update features/mod.zig
    try mod_updater.updateFeaturesMod(io, allocator, features_dir, "auth");
    std.debug.print("  update  src/features/mod.zig\n", .{});

    // Select provider config
    const provider_config = if (std.mem.eql(u8, provider, "keycloak")) keycloak_config else google_config;

    // Update main.zig
    try auth_updater.updateMainZig(io, allocator, root_dir, provider, provider_config);
    std.debug.print("  update  src/main.zig\n", .{});

    std.debug.print("\nDone! Auth feature with {s} provider generated.\n", .{provider});
    std.debug.print("\nAdd these environment variables to your .env file:\n", .{});
    if (std.mem.eql(u8, provider, "keycloak")) {
        std.debug.print("  KEYCLOAK_BASE_URL=http://localhost:8080\n", .{});
        std.debug.print("  KEYCLOAK_REALM=myrealm\n", .{});
        std.debug.print("  KEYCLOAK_CLIENT_ID=spider-app\n", .{});
        std.debug.print("  KEYCLOAK_CLIENT_SECRET=your-client-secret\n", .{});
        std.debug.print("  KEYCLOAK_REDIRECT_URI=http://localhost:3000/auth/callback\n", .{});
        std.debug.print("  KEYCLOAK_REDIRECT_URI_LOGOUT=http://localhost:3000\n", .{});
    } else {
        std.debug.print("  GOOGLE_CLIENT_ID=your-client-id\n", .{});
        std.debug.print("  GOOGLE_CLIENT_SECRET=your-client-secret\n", .{});
        std.debug.print("  GOOGLE_REDIRECT_URI=http://localhost:3000/auth/callback\n", .{});
    }
    std.debug.print("  JWT_SECRET=change-me-in-production\n", .{});
}
