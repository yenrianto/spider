const std = @import("std");
const ast = @import("ast.zig");
const ctx_mod = @import("context.zig");
const parser_mod = @import("parser.zig");
const renderer_mod = @import("renderer.zig");

const Node = ast.Node;
const freeNode = ast.freeNode;
const Context = ctx_mod.Context;
const Value = ctx_mod.Value;
const structToContext = ctx_mod.structToContext;
const dupeValue = ctx_mod.dupeValue;
const Parser = parser_mod.Parser;
const renderNode = renderer_mod.renderNode;

fn isRootTemplate(template_str: []const u8) bool {
    return std.mem.indexOf(u8, template_str, "<html") != null;
}

pub const Template = struct {
    nodes: []Node,
    allocator: std.mem.Allocator,
    components: ?std.StringHashMapUnmanaged([]const u8) = null,
    layout: ?[]const u8 = null,
    is_root: bool = false,

    pub fn init(alc: std.mem.Allocator, template_str: []const u8) !Template {
        var parser = Parser.init(alc, template_str);
        const result = try parser.parse();

        const is_root = isRootTemplate(template_str);

        return Template{
            .nodes = result.nodes,
            .allocator = alc,
            .layout = result.layout,
            .is_root = is_root,
        };
    }

    pub fn deinit(self: *Template) void {
        for (self.nodes) |node| freeNode(node, self.allocator);
        self.allocator.free(self.nodes);
        if (self.layout) |l| self.allocator.free(l);
    }

    pub fn render(self: *Template, context: anytype, alc: std.mem.Allocator) ![]const u8 {
        var ctx = try structToContext(alc, context);
        defer ctx.deinit(alc);

        if (self.layout) |layout_name| {
            if (self.components) |comps| {
                if (comps.get(layout_name)) |layout_template| {
                    var slot_bufs = std.StringHashMapUnmanaged(std.ArrayList(u8)){};
                    defer {
                        var iter = slot_bufs.iterator();
                        while (iter.next()) |entry| {
                            entry.value_ptr.*.deinit(alc);
                            alc.free(entry.key_ptr.*);
                        }
                        slot_bufs.deinit(alc);
                    }

                    var cur_buf = std.ArrayList(u8).empty;
                    var cur_key: []const u8 = "slot";

                    for (self.nodes) |node| {
                        if (node == .interpolation) {
                            const expr = node.interpolation;
                            if (std.mem.startsWith(u8, expr, "slot_")) {
                                const key = try alc.dupe(u8, cur_key);
                                try slot_bufs.put(alc, key, cur_buf);
                                cur_key = expr;
                                cur_buf = std.ArrayList(u8).empty;
                                continue;
                            }
                        }
                        try renderNode(node, &ctx, alc, &cur_buf, self.components);
                    }
                    {
                        const key = try alc.dupe(u8, cur_key);
                        try slot_bufs.put(alc, key, cur_buf);
                    }

                    var layout_ctx = try ctx.clone(alc);
                    defer layout_ctx.deinit(alc);

                    var iter = slot_bufs.iterator();
                    while (iter.next()) |entry| {
                        try layout_ctx.set(alc, entry.key_ptr.*, Value{ .string = try alc.dupe(u8, entry.value_ptr.*.items) });
                    }

                    var layout_parser = Parser.init(alc, layout_template);
                    const layout_result = try layout_parser.parse();
                    defer {
                        for (layout_result.nodes) |n| freeNode(n, alc);
                        alc.free(layout_result.nodes);
                    }

                    var layout_result_bytes: std.ArrayList(u8) = .empty;
                    defer layout_result_bytes.deinit(alc);

                    for (layout_result.nodes) |n| {
                        try renderNode(n, &layout_ctx, alc, &layout_result_bytes, self.components);
                    }

                    return layout_result_bytes.toOwnedSlice(alc);
                }
            }
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(alc);

        for (self.nodes) |node| {
            try renderNode(node, &ctx, alc, &result, self.components);
        }

        return result.toOwnedSlice(alc);
    }
};

test {
    _ = @import("template_test.zig");
}
