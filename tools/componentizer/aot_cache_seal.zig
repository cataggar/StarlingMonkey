const std = @import("std");
const aot_cache = @import("aot_cache.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) usage();
    const sealing = std.mem.eql(u8, args[1], "seal");
    const validating = std.mem.eql(u8, args[1], "validate");
    if (!sealing and !validating) usage();

    var engine: ?[]const u8 = null;
    var weval: ?[]const u8 = null;
    var cache: ?[]const u8 = null;
    var primer: ?[]const u8 = null;
    var feature_abi: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var manifest: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) usage();
        if (std.mem.eql(u8, args[i], "--engine")) {
            engine = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--weval")) {
            weval = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--cache")) {
            cache = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--primer")) {
            primer = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--feature-abi")) {
            feature_abi = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--out")) {
            output = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--manifest")) {
            manifest = args[i + 1];
        } else {
            usage();
        }
    }
    if (sealing) {
        if (manifest != null) usage();
        aot_cache.seal(
            allocator,
            init.io,
            engine orelse usage(),
            weval orelse usage(),
            cache orelse usage(),
            primer orelse usage(),
            feature_abi orelse usage(),
            output orelse usage(),
        ) catch |err| std.process.fatal("failed to seal AOT cache: {t}", .{err});
    } else {
        if (primer != null or output != null) usage();
        const validated = aot_cache.validate(
            allocator,
            init.io,
            engine orelse usage(),
            weval orelse usage(),
            cache orelse usage(),
            manifest orelse usage(),
            feature_abi,
        ) catch |err| std.process.fatal("failed to validate AOT cache: {t}", .{err});
        std.debug.print("Validated AOT cache {s}\n", .{validated.key});
    }
}

fn usage() noreturn {
    std.process.fatal(
        "usage: starling-aot-cache seal --engine <wasm> --weval <bin> " ++
            "--cache <sqlite> --primer <js> --feature-abi <abi> --out <manifest>\n" ++
            "       starling-aot-cache validate --engine <wasm> --weval <bin> " ++
            "--cache <sqlite> --manifest <manifest> [--feature-abi <abi>]",
        .{},
    );
}
