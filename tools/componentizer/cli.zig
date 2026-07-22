const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const version = "0.4.1";

pub const usage =
    \\Usage: starling-componentize [options] [source.js] [output.wasm]
    \\
    \\Options:
    \\  -w, --wit <dir>                    WIT directory used to generate dispatch bindings
    \\  -n, --world-name <name>            Dispatch world selected from --wit
    \\      --component-wit <dir>          Complete component WIT closure (defaults to --wit)
    \\      --component-world-name <name>  Component world (defaults to --world-name)
    \\  -o, --out, --output <file>         Output component (defaults to <source>.wasm)
    \\  -d, --disable <feature[,feature]>  Disable platform features; repeatable
    \\      --enable <feature[,feature]>   Re-enable platform features; repeatable
    \\      --runtime-args <args>          Raw StarlingMonkey runtime argument string
    \\      --runtime-arg <arg>            One safely quoted runtime argument; repeatable
    \\  -i, --initializer-script-path <p>  Run an initializer script before the source module
    \\      --strip-path-prefix <prefix>   Strip a path prefix from diagnostics
    \\      --legacy-script                Evaluate the source as a legacy script
    \\      --wpt-mode                     Enable WPT compatibility mode
    \\      --init-location <url>          Set globalThis.location during initialization
    \\      --js-heap-limit-mib <MiB>      Set the SpiderMonkey heap ceiling (1-4095)
    \\      --preopen-dir <dir>            Add a Wizer preopened directory; repeatable
    \\      --engine <file>                Use an already WIT-matched starling-raw.wasm
    \\      --preview2-adapter <file>      Override the preview1-to-preview2 adapter
    \\      --zig-bin <file>               Override the Zig executable
    \\      --wizer-bin <file>             Override the Wizer executable
    \\      --wasmtime-bin <file>           Override Wasmtime's wizer subcommand
    \\      --wabt-bin <file>              Override the WABT executable
    \\      --wasm-tools-bin <file>        Override the wasm-tools executable
    \\      --weval-bin <file>             Override the Weval executable
    \\      --build-root <dir>             Override StarlingMonkey source-root discovery
    \\      --cache-dir <dir>              Override the monolithic runtime cache
    \\      --metadata-out <file>          Write deterministic imports/provenance JSON
    \\      --diagnostic-format <format>   Diagnostic stream: human (default) or json
    \\      --json-diagnostics             Alias for --diagnostic-format json
    \\      --use-debug-build              Build a Debug runtime instead of ReleaseSmall
    \\      --debug-bindings               Preserve generated bindings and intermediates
    \\      --debug-dir <dir>              Directory for debug intermediates
    \\      --enable-wizer-logging         Print successful Wizer output
    \\      --aot                          Use the Weval AOT engine and cache
    \\      --aot-cache-dir <dir>          Override the validated AOT cache bundle
    \\      --aot-min-stack-size <bytes>   Set Weval's RUST_MIN_STACK (default: 8 MiB)
    \\  -v, --verbose                      Print structured pipeline commands
    \\  -V, --version                      Print the componentizer version
    \\  -h, --help                         Print this help
    \\
    \\The monolithic pipeline requires --wit/--world-name to describe dispatch
    \\bindings and --component-wit/--component-world-name to describe the full
    \\component embedding world. They may be the same only when that world also
    \\contains StarlingMonkey's complete WASI import/export closure.
    \\
;

pub const Action = union(enum) {
    run: Config,
    help,
    version,
};

pub const Config = struct {
    source: ?[]const u8 = null,
    output: ?[]const u8 = null,
    wit: ?[]const u8 = null,
    world_name: ?[]const u8 = null,
    component_wit: ?[]const u8 = null,
    component_world_name: ?[]const u8 = null,
    disable_features: []const []const u8 = &.{},
    enable_features: []const []const u8 = &.{},
    runtime_args: ?[]const u8 = null,
    runtime_argv: []const []const u8 = &.{},
    initializer_script_path: ?[]const u8 = null,
    strip_path_prefix: ?[]const u8 = null,
    init_location: ?[]const u8 = null,
    js_heap_limit_mib: ?u32 = null,
    preopen_dirs: []const []const u8 = &.{},
    legacy_wrapper_preopen: bool = false,
    legacy_script: bool = false,
    wpt_mode: bool = false,
    engine: ?[]const u8 = null,
    preview2_adapter: ?[]const u8 = null,
    zig_bin: ?[]const u8 = null,
    wizer_bin: ?[]const u8 = null,
    wasmtime_bin: ?[]const u8 = null,
    wabt_bin: ?[]const u8 = null,
    wasm_tools_bin: ?[]const u8 = null,
    weval_bin: ?[]const u8 = null,
    build_root: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    metadata_out: ?[]const u8 = null,
    debug_dir: ?[]const u8 = null,
    diagnostic_format: diagnostics.Format = .human,
    use_debug_build: bool = false,
    debug_bindings: bool = false,
    enable_wizer_logging: bool = false,
    aot: bool = false,
    aot_cache_dir: ?[]const u8 = null,
    aot_min_stack_size: ?u64 = null,
    verbose: bool = false,

    pub fn deinit(config: *Config, allocator: std.mem.Allocator) void {
        allocator.free(config.disable_features);
        allocator.free(config.enable_features);
        allocator.free(config.runtime_argv);
        allocator.free(config.preopen_dirs);
        config.* = undefined;
    }
};

pub const ParseError = error{
    ConflictingFeatures,
    InvalidHeapLimit,
    InvalidAotMinStackSize,
    IncompatibleAotOptions,
    InvalidDiagnosticFormat,
    MissingSource,
    MissingValue,
    MissingWitWorld,
    MultipleSources,
    UnexpectedComponentWorld,
    UnknownArgument,
    UnknownFeature,
    AotOptionRequiresAot,
};

pub const feature_names = [_][]const u8{
    "stdio",
    "random",
    "clocks",
    "http",
    "fetch-event",
};

fn isFeature(name: []const u8) bool {
    for (feature_names) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

fn appendFeatureList(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) ParseError!void {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0 or !isFeature(name)) return error.UnknownFeature;
        for (list.items) |existing| {
            if (std.mem.eql(u8, name, existing)) break;
        } else {
            list.append(allocator, name) catch @panic("out of memory");
        }
    }
}

fn isFeatureList(value: []const u8) bool {
    var saw_feature = false;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0 or !isFeature(name)) return false;
        saw_feature = true;
    }
    return saw_feature;
}

fn appendVariadicFeatures(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    args: []const []const u8,
    index: *usize,
) ParseError!void {
    const first = try nextValue(args, index);
    try appendFeatureList(allocator, list, first);
    while (index.* + 1 < args.len and isFeatureList(args[index.* + 1])) {
        index.* += 1;
        try appendFeatureList(allocator, list, args[index.*]);
    }
}

fn nextValue(args: []const []const u8, index: *usize) ParseError![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingValue;
    return args[index.*];
}

fn parseDiagnosticFormat(value: []const u8) ParseError!diagnostics.Format {
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "json")) return .json;
    return error.InvalidDiagnosticFormat;
}

pub fn detectDiagnosticFormat(args: []const []const u8) diagnostics.Format {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json-diagnostics")) return .json;
        if (std.mem.eql(u8, args[i], "--diagnostic-format") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "json")) return .json;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--diagnostic-format=json")) {
            return .json;
        }
    }
    return .human;
}

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Action {
    var disabled: std.ArrayList([]const u8) = .empty;
    errdefer disabled.deinit(allocator);
    var enabled: std.ArrayList([]const u8) = .empty;
    errdefer enabled.deinit(allocator);
    var runtime_argv: std.ArrayList([]const u8) = .empty;
    errdefer runtime_argv.deinit(allocator);
    var preopen_dirs: std.ArrayList([]const u8) = .empty;
    errdefer preopen_dirs.deinit(allocator);

    var config = Config{};
    var aot_option_seen = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wit")) {
            config.wit = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--world-name")) {
            config.world_name = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--component-wit")) {
            config.component_wit = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--component-world-name")) {
            config.component_world_name = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "-o") or
            std.mem.eql(u8, arg, "--out") or
            std.mem.eql(u8, arg, "--output"))
        {
            config.output = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--disable")) {
            try appendVariadicFeatures(allocator, &disabled, args, &i);
        } else if (std.mem.eql(u8, arg, "--enable")) {
            try appendVariadicFeatures(allocator, &enabled, args, &i);
        } else if (std.mem.eql(u8, arg, "--runtime-args")) {
            config.runtime_args = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--runtime-arg")) {
            runtime_argv.append(allocator, try nextValue(args, &i)) catch @panic("out of memory");
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--initializer-script-path")) {
            config.initializer_script_path = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--strip-path-prefix")) {
            config.strip_path_prefix = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--legacy-script")) {
            config.legacy_script = true;
        } else if (std.mem.eql(u8, arg, "--wpt-mode")) {
            config.wpt_mode = true;
        } else if (std.mem.eql(u8, arg, "--init-location")) {
            config.init_location = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--js-heap-limit-mib")) {
            const raw = try nextValue(args, &i);
            const value = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidHeapLimit;
            if (value < 1 or value > 4095) return error.InvalidHeapLimit;
            config.js_heap_limit_mib = value;
        } else if (std.mem.eql(u8, arg, "--preopen-dir")) {
            preopen_dirs.append(allocator, try nextValue(args, &i)) catch @panic("out of memory");
        } else if (std.mem.eql(u8, arg, "--legacy-wrapper-preopen")) {
            config.legacy_wrapper_preopen = true;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            config.engine = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--preview2-adapter")) {
            config.preview2_adapter = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--zig-bin")) {
            config.zig_bin = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--wizer-bin")) {
            config.wizer_bin = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--wasmtime-bin")) {
            config.wasmtime_bin = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--wabt-bin")) {
            config.wabt_bin = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--wasm-tools-bin")) {
            config.wasm_tools_bin = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--weval-bin")) {
            config.weval_bin = try nextValue(args, &i);
            aot_option_seen = true;
        } else if (std.mem.eql(u8, arg, "--build-root")) {
            config.build_root = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            config.cache_dir = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--metadata-out")) {
            config.metadata_out = try nextValue(args, &i);
        } else if (std.mem.eql(u8, arg, "--diagnostic-format")) {
            config.diagnostic_format = try parseDiagnosticFormat(try nextValue(args, &i));
        } else if (std.mem.startsWith(u8, arg, "--diagnostic-format=")) {
            config.diagnostic_format = try parseDiagnosticFormat(
                arg["--diagnostic-format=".len..],
            );
        } else if (std.mem.eql(u8, arg, "--json-diagnostics")) {
            config.diagnostic_format = .json;
        } else if (std.mem.eql(u8, arg, "--use-debug-build")) {
            config.use_debug_build = true;
        } else if (std.mem.eql(u8, arg, "--debug-bindings")) {
            config.debug_bindings = true;
        } else if (std.mem.eql(u8, arg, "--debug-dir")) {
            config.debug_dir = try nextValue(args, &i);
            config.debug_bindings = true;
        } else if (std.mem.eql(u8, arg, "--enable-wizer-logging")) {
            config.enable_wizer_logging = true;
        } else if (std.mem.eql(u8, arg, "--aot")) {
            config.aot = true;
        } else if (std.mem.eql(u8, arg, "--aot-cache-dir")) {
            config.aot_cache_dir = try nextValue(args, &i);
            aot_option_seen = true;
        } else if (std.mem.eql(u8, arg, "--aot-min-stack-size")) {
            const raw = try nextValue(args, &i);
            const value = std.fmt.parseInt(u64, raw, 10) catch
                return error.InvalidAotMinStackSize;
            if (value == 0) return error.InvalidAotMinStackSize;
            config.aot_min_stack_size = value;
            aot_option_seen = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else if (config.source == null) {
            config.source = arg;
        } else if (config.output == null) {
            config.output = arg;
        } else {
            return error.MultipleSources;
        }
    }

    if (aot_option_seen and !config.aot) return error.AotOptionRequiresAot;
    if (config.aot and config.use_debug_build) return error.IncompatibleAotOptions;
    if (config.source == null and config.output == null) return error.MissingSource;
    if ((config.wit == null) != (config.world_name == null)) return error.MissingWitWorld;
    if (config.component_wit != null and config.wit == null) return error.UnexpectedComponentWorld;
    if (config.component_world_name != null and config.wit == null) {
        return error.UnexpectedComponentWorld;
    }

    for (disabled.items) |disabled_name| {
        for (enabled.items) |enabled_name| {
            if (std.mem.eql(u8, disabled_name, enabled_name)) return error.ConflictingFeatures;
        }
    }

    config.disable_features = disabled.toOwnedSlice(allocator) catch @panic("out of memory");
    config.enable_features = enabled.toOwnedSlice(allocator) catch @panic("out of memory");
    config.runtime_argv = runtime_argv.toOwnedSlice(allocator) catch @panic("out of memory");
    config.preopen_dirs = preopen_dirs.toOwnedSlice(allocator) catch @panic("out of memory");
    return .{ .run = config };
}

test "parses the native componentizer surface" {
    const args = [_][]const u8{
        "starling-componentize",
        "--wit",
        "wit dir",
        "--world-name",
        "js-exports",
        "--component-wit",
        "component wit",
        "--component-world-name",
        "js-dispatch",
        "--disable",
        "stdio,random",
        "--enable",
        "http",
        "--runtime-arg",
        "--enable-script-debugging",
        "--preopen-dir",
        "extra dir",
        "--legacy-wrapper-preopen",
        "--wabt-bin",
        "tools/wabt",
        "--js-heap-limit-mib",
        "256",
        "--debug-bindings",
        "--metadata-out",
        "metadata.json",
        "--diagnostic-format",
        "json",
        "--out",
        "out file.wasm",
        "source file.js",
    };
    var action = try parse(std.testing.allocator, &args);
    defer switch (action) {
        .run => |*config| config.deinit(std.testing.allocator),
        else => {},
    };
    const config = action.run;
    try std.testing.expectEqualStrings("source file.js", config.source.?);
    try std.testing.expectEqualStrings("out file.wasm", config.output.?);
    try std.testing.expectEqual(@as(usize, 2), config.disable_features.len);
    try std.testing.expectEqualStrings("random", config.disable_features[1]);
    try std.testing.expectEqual(@as(u32, 256), config.js_heap_limit_mib.?);
    try std.testing.expectEqualStrings("tools/wabt", config.wabt_bin.?);
    try std.testing.expect(config.debug_bindings);
    try std.testing.expect(config.legacy_wrapper_preopen);
    try std.testing.expectEqual(diagnostics.Format.json, config.diagnostic_format);
    try std.testing.expectEqualStrings("metadata.json", config.metadata_out.?);
}

test "rejects conflicting feature selections" {
    const args = [_][]const u8{
        "starling-componentize",
        "--disable",
        "http",
        "--enable",
        "http",
        "source.js",
    };
    try std.testing.expectError(error.ConflictingFeatures, parse(std.testing.allocator, &args));
}

test "parses ComponentizeJS-compatible variadic feature values" {
    const args = [_][]const u8{
        "starling-componentize",
        "source.js",
        "--disable",
        "http",
        "random",
        "--out",
        "out.wasm",
    };
    var action = try parse(std.testing.allocator, &args);
    defer switch (action) {
        .run => |*config| config.deinit(std.testing.allocator),
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), action.run.disable_features.len);
    try std.testing.expectEqualStrings("random", action.run.disable_features[1]);
}

test "requires WIT and world together" {
    const args = [_][]const u8{
        "starling-componentize",
        "--wit",
        "wit",
        "source.js",
    };
    try std.testing.expectError(error.MissingWitWorld, parse(std.testing.allocator, &args));
}

test "parses AOT controls" {
    const args = [_][]const u8{
        "starling-componentize",
        "--aot",
        "--weval-bin",
        "tools/weval",
        "--aot-cache-dir",
        "cache bundle",
        "--aot-min-stack-size",
        "16777216",
        "source.js",
    };
    var action = try parse(std.testing.allocator, &args);
    defer switch (action) {
        .run => |*config| config.deinit(std.testing.allocator),
        else => {},
    };
    try std.testing.expect(action.run.aot);
    try std.testing.expectEqualStrings("cache bundle", action.run.aot_cache_dir.?);
    try std.testing.expectEqual(@as(u64, 16777216), action.run.aot_min_stack_size.?);
}

test "preserves legacy output forms" {
    const positional_args = [_][]const u8{
        "starling-componentize",
        "source.js",
        "positional output.wasm",
    };
    var positional = try parse(std.testing.allocator, &positional_args);
    defer positional.run.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("source.js", positional.run.source.?);
    try std.testing.expectEqualStrings("positional output.wasm", positional.run.output.?);

    const output_only_args = [_][]const u8{
        "starling-componentize",
        "--output",
        "runtime component.wasm",
    };
    var output_only = try parse(std.testing.allocator, &output_only_args);
    defer output_only.run.deinit(std.testing.allocator);
    try std.testing.expect(output_only.run.source == null);
    try std.testing.expectEqualStrings("runtime component.wasm", output_only.run.output.?);
}

test "rejects AOT-only controls without AOT" {
    const args = [_][]const u8{
        "starling-componentize",
        "--aot-cache-dir",
        "cache",
        "source.js",
    };
    try std.testing.expectError(error.AotOptionRequiresAot, parse(std.testing.allocator, &args));
}

test "rejects debug AOT and invalid stack sizes" {
    const debug_args = [_][]const u8{
        "starling-componentize",
        "--aot",
        "--use-debug-build",
        "source.js",
    };
    try std.testing.expectError(error.IncompatibleAotOptions, parse(std.testing.allocator, &debug_args));

    const stack_args = [_][]const u8{
        "starling-componentize",
        "--aot",
        "--aot-min-stack-size",
        "0",
        "source.js",
    };
    try std.testing.expectError(error.InvalidAotMinStackSize, parse(std.testing.allocator, &stack_args));
}

test "detects JSON diagnostics before full argument parsing" {
    const args = [_][]const u8{
        "starling-componentize",
        "--not-a-real-option",
        "--diagnostic-format=json",
    };
    try std.testing.expectEqual(
        diagnostics.Format.json,
        detectDiagnosticFormat(&args),
    );
}

test "rejects unknown diagnostic formats" {
    const args = [_][]const u8{
        "starling-componentize",
        "--diagnostic-format",
        "xml",
        "source.js",
    };
    try std.testing.expectError(
        error.InvalidDiagnosticFormat,
        parse(std.testing.allocator, &args),
    );
}
