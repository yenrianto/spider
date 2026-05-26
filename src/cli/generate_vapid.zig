const std = @import("std");

const P256 = std.crypto.ecc.P256;

pub fn run(io: std.Io, allocator: std.mem.Allocator, subject: ?[]const u8) !void {
    _ = allocator;
    const private_key = P256.scalar.random(io, .big);
    const public_key = try P256.basePoint.mul(private_key, .big);

    var priv_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&priv_buf, &private_key);

    const pub_sec1 = public_key.toUncompressedSec1();
    var pub_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(65)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&pub_buf, &pub_sec1);

    const sub = subject orelse "mailto:admin@example.com";

    std.debug.print(
        \\VAPID keys generated successfully!
        \\
        \\Add these to your .env file:
        \\
        \\VAPID_SUBJECT={s}
        \\VAPID_PUBLIC_KEY={s}
        \\VAPID_PRIVATE_KEY={s}
        \\
    , .{ sub, &pub_buf, &priv_buf });
}
