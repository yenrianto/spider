// Test root for pg wrapper integration tests.
// This file exists at src/ level so that pg.zig's relative imports
// (../../internal/env.zig, ../../core/database.zig) resolve within the module scope.
const std = @import("std");
comptime {
    _ = @import("drivers/pg/pg.zig");
}
