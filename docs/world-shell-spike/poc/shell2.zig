extern fn engine_echo_upper(ptr: [*]const u8, len: usize, out_len: *usize) [*]const u8;
var msg = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
export fn @"shell-echo"() u32 {
    var out_len: usize = 0;
    const result = engine_echo_upper(&msg, msg.len, &out_len);
    // Return first byte of the uppercased result as proof it round-tripped through engine's memory.
    if (out_len != msg.len) return 0xFFFFFFFF;
    return result[0];
}
