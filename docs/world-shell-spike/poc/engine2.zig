const std = @import("std");
var buf: [64]u8 = undefined;
export fn engine_echo_upper(ptr: [*]const u8, len: usize, out_len: *usize) [*]const u8 {
    for (0..len) |i| {
        buf[i] = std.ascii.toUpper(ptr[i]);
    }
    out_len.* = len;
    return &buf;
}
