const std = @import("std");
const new = @import("new.zig");
const generate = @import("generate.zig");
const migrate = @import("migrate.zig");

const usage =
    \\Spider CLI — spiderme.org
    \\
    \\Usage:
    \\  spider new <app_name>          Create a new Spider project
    \\  spider generate <subcommand>   Generate code (aliases: g)
    \\  spider g <subcommand>          Alias for generate
    \\    feature <name>                Generate a new feature
    \\  spider migrate                 Run pending database migrations
    \\  spider help                    Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name

    const command = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return;
    };

    if (std.mem.eql(u8, command, "new")) {
        var use_daisyui = false;
        var arg = args.next();

        if (arg != null and std.mem.eql(u8, arg.?, "--daisyui")) {
            use_daisyui = true;
            arg = args.next();
        }

        const app_name = arg orelse {
            std.debug.print("error: missing app name\nUsage: spider new <app_name>\n", .{});
            return error.MissingAppName;
        };
        try new.run(io, allocator, app_name, use_daisyui);
    } else if (std.mem.eql(u8, command, "generate")) {
        const subcommand = args.next() orelse {
            std.debug.print("Usage: spider generate <subcommand>\n", .{});
            return;
        };
        try generate.run(io, allocator, subcommand, &args);
    } else if (std.mem.eql(u8, command, "g")) {
        const subcommand = args.next() orelse {
            std.debug.print("Usage: spider g <subcommand>\n", .{});
            std.debug.print("Available subcommands:\n", .{});
            std.debug.print("  feature <name>    Generate a new feature\n", .{});
            return;
        };
        try generate.run(io, allocator, subcommand, &args);
    } else if (std.mem.eql(u8, command, "migrate")) {
        try migrate.run(io, allocator);
    } else if (std.mem.eql(u8, command, "help")) {
        std.debug.print("{s}", .{usage});
    } else {
        std.debug.print("error: unknown command '{s}'\n{s}", .{ command, usage });
    }
}
