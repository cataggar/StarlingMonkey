const std = @import("std");

const section_name = "starling:engine-provenance";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 11) {
        std.process.fatal(
            "usage: {s} <input> <output> <host-api> <component-world> <surface-world> <stdio> <random> <clocks> <http> <fetch-event>",
            .{args[0]},
        );
    }
    const json = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"host_api\":\"{s}\",\"features\":{{\"stdio\":{s},\"random\":{s},\"clocks\":{s},\"http\":{s},\"fetch-event\":{s}}},\"component_world\":\"{s}\",\"surface_world\":\"{s}\"}}",
        .{
            args[3],
            args[6],
            args[7],
            args[8],
            args[9],
            args[10],
            args[4],
            args[5],
        },
    );
    const Dir = std.Io.Dir;
    var input = try Dir.cwd().openFile(init.io, args[1], .{});
    defer input.close(init.io);
    var output = try Dir.cwd().createFile(init.io, args[2], .{
        .read = true,
        .truncate = true,
    });
    defer output.close(init.io);

    const stat = try input.stat(init.io);
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (offset < stat.size) {
        const count = try input.readPositional(
            init.io,
            &.{&buffer},
            offset,
        );
        if (count == 0) return error.UnexpectedEndOfFile;
        try output.writePositionalAll(init.io, buffer[0..count], offset);
        offset += count;
    }

    const name_length = encodeUleb(section_name.len);
    const payload_length = name_length.len + section_name.len + json.len;
    const section_length = encodeUleb(payload_length);
    try output.writePositionalAll(init.io, &.{0}, offset);
    offset += 1;
    try output.writePositionalAll(init.io, section_length.bytes[0..section_length.len], offset);
    offset += section_length.len;
    try output.writePositionalAll(init.io, name_length.bytes[0..name_length.len], offset);
    offset += name_length.len;
    try output.writePositionalAll(init.io, section_name, offset);
    offset += section_name.len;
    try output.writePositionalAll(init.io, json, offset);
    try output.sync(init.io);
}

const EncodedUleb = struct {
    bytes: [10]u8,
    len: u8,
};

fn encodeUleb(input: usize) EncodedUleb {
    var value = input;
    var result: EncodedUleb = .{ .bytes = undefined, .len = 0 };
    while (true) {
        var byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        result.bytes[result.len] = byte;
        result.len += 1;
        if (value == 0) return result;
    }
}
