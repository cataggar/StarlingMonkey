const std = @import("std");
const aot_cache = @import("aot_cache.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) usage();
    const sealing = std.mem.eql(u8, args[1], "seal");
    const validating = std.mem.eql(u8, args[1], "validate");
    const recovering = std.mem.eql(u8, args[1], "recover");
    const publishing = std.mem.eql(u8, args[1], "publish-bundle");
    const publishing_prefix = std.mem.eql(u8, args[1], "publish-prefix");
    const recovering_bundle = std.mem.eql(u8, args[1], "recover-bundle");
    if (!sealing and !validating and !recovering and !publishing and
        !publishing_prefix and !recovering_bundle) usage();

    var engine: ?[]const u8 = null;
    var weval: ?[]const u8 = null;
    var cache: ?[]const u8 = null;
    var canonical_cache: ?[]const u8 = null;
    var primer: ?[]const u8 = null;
    var feature_abi: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var manifest: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var engine_name: ?[]const u8 = null;
    var generation: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) usage();
        if (std.mem.eql(u8, args[i], "--engine")) {
            engine = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--weval")) {
            weval = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--cache")) {
            cache = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--cache-out")) {
            canonical_cache = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--primer")) {
            primer = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--feature-abi")) {
            feature_abi = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--out")) {
            output = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--manifest")) {
            manifest = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--target")) {
            target = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--engine-name")) {
            engine_name = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--generation")) {
            generation = args[i + 1];
        } else {
            usage();
        }
    }
    if (sealing) {
        if (manifest != null or target != null or engine_name != null or
            generation != null) usage();
        aot_cache.sealWithHooks(
            allocator,
            init.io,
            engine orelse usage(),
            weval orelse usage(),
            cache orelse usage(),
            canonical_cache,
            primer orelse usage(),
            feature_abi orelse usage(),
            output orelse usage(),
            .{
                .directory = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_HOOK_DIR",
                ),
                .wait_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_WAIT_AT",
                ),
                .notify_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_NOTIFY_AT",
                ),
                .fail_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_FAIL",
                ),
            },
        ) catch |err| std.process.fatal("failed to seal AOT cache: {t}", .{err});
    } else if (validating) {
        if (primer != null or canonical_cache != null or output != null or
            target != null or engine_name != null or generation != null)
            usage();
        const validated = aot_cache.validateWithHooks(
            allocator,
            init.io,
            engine orelse usage(),
            weval orelse usage(),
            cache orelse usage(),
            manifest orelse usage(),
            feature_abi,
            .{
                .directory = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_HOOK_DIR",
                ),
                .wait_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_WAIT_AT",
                ),
                .notify_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_NOTIFY_AT",
                ),
                .fail_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_FAIL",
                ),
            },
        ) catch |err| std.process.fatal("failed to validate AOT cache: {t}", .{err});
        std.debug.print("Validated AOT cache {s}\n", .{validated.key});
    } else if (recovering) {
        if (engine != null or weval != null or primer != null or
            canonical_cache != null or output != null or feature_abi != null or
            target != null or engine_name != null or generation != null)
            usage();
        aot_cache.recoverWithHooks(
            allocator,
            init.io,
            cache orelse usage(),
            manifest orelse usage(),
            .{
                .directory = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_HOOK_DIR",
                ),
                .wait_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_WAIT_AT",
                ),
                .notify_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_NOTIFY_AT",
                ),
                .fail_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_FAIL",
                ),
            },
        ) catch |err| std.process.fatal(
            "failed to recover AOT cache transaction: {t}",
            .{err},
        );
        std.debug.print("Recovered AOT cache transaction\n", .{});
    } else if (publishing) {
        if (primer != null or canonical_cache != null or output != null or
            target == null or generation != null)
            usage();
        aot_cache.publishBundleDirectory(
            allocator,
            init.io,
            target.?,
            engine orelse usage(),
            engine_name orelse "starling-raw.wasm",
            weval orelse usage(),
            cache orelse usage(),
            manifest orelse usage(),
            feature_abi,
            .{
                .directory = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_HOOK_DIR",
                ),
                .wait_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_WAIT_AT",
                ),
                .notify_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_NOTIFY_AT",
                ),
                .fail_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_FAIL",
                ),
            },
        ) catch |err| std.process.fatal(
            "failed to publish AOT bundle: {t}",
            .{err},
        );
        std.debug.print("Published AOT bundle to {s}\n", .{target.?});
    } else if (publishing_prefix) {
        if (engine != null or weval != null or cache != null or
            canonical_cache != null or primer != null or output != null or
            manifest != null or engine_name != null or target == null or
            generation == null or feature_abi == null)
            usage();
        aot_cache.publishPrefixDirectory(
            allocator,
            init.io,
            target.?,
            generation.?,
            feature_abi.?,
            .{
                .directory = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_HOOK_DIR",
                ),
                .wait_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_WAIT_AT",
                ),
                .notify_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_NOTIFY_AT",
                ),
                .fail_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_FAIL",
                ),
            },
        ) catch |err| std.process.fatal(
            "failed to publish AOT prefix: {t}",
            .{err},
        );
        std.debug.print(
            "Published AOT prefix generation to {s}\n",
            .{target.?},
        );
    } else {
        if (engine != null or weval != null or cache != null or
            canonical_cache != null or primer != null or feature_abi != null or
            output != null or manifest != null or engine_name != null or
            generation != null or target == null)
            usage();
        aot_cache.recoverBundleDirectory(
            allocator,
            init.io,
            target.?,
            .{
                .directory = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_HOOK_DIR",
                ),
                .wait_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_WAIT_AT",
                ),
                .notify_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_NOTIFY_AT",
                ),
                .fail_at = init.environ_map.get(
                    "STARLING_AOT_CACHE_TEST_FAIL",
                ),
            },
        ) catch |err| std.process.fatal(
            "failed to recover AOT bundle publication: {t}",
            .{err},
        );
        std.debug.print("Recovered AOT bundle publication\n", .{});
    }
}

fn usage() noreturn {
    std.process.fatal(
        "usage: starling-aot-cache seal --engine <wasm> --weval <bin> " ++
            "--cache <sqlite> [--cache-out <canonical-sqlite>] --primer <js> " ++
            "--feature-abi <abi> --out <manifest>\n" ++
            "       starling-aot-cache validate --engine <wasm> --weval <bin> " ++
            "--cache <sqlite> --manifest <manifest> [--feature-abi <abi>]\n" ++
            "       starling-aot-cache recover --cache <sqlite> " ++
            "--manifest <manifest>\n" ++
            "       starling-aot-cache publish-bundle --target <directory> " ++
            "--engine <wasm> [--engine-name <name>] --weval <bin> " ++
            "--cache <sqlite> --manifest <manifest> [--feature-abi <abi>]\n" ++
            "       starling-aot-cache publish-prefix --target <directory> " ++
            "--generation <private-directory> --feature-abi <abi>\n" ++
            "       starling-aot-cache recover-bundle --target <directory>",
        .{},
    );
}
