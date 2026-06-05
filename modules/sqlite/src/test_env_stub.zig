// Minimal env stub that allows sqlite.zig tests to compile standalone
// without the full spider framework. Returns defaults for all keys.
pub const env = struct {
    pub fn getOr(_: []const u8, default_val: []const u8) []const u8 {
        return default_val;
    }
};
