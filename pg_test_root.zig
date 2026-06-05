// Test root for pg wrapper integration tests.
const std = @import("std");
comptime {
    _ = @import("modules/pg/src/pg.zig");
}
