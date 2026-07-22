const std = @import("std");
const surface = @import("surface.zig");

const Args = struct {
    wabt: []const u8 = "",
    wasm_tools: []const u8 = "",
    platform_wit: []const u8 = "",
    component: []const u8 = "",
    output: []const u8 = "",
    work_dir: []const u8 = "",
    target_wit: ?[]const u8 = null,
    target_world: ?[]const u8 = null,
    features: surface.Features = .{},
    runtime_config: surface.RuntimeConfig = .snapshotted,
    inspect_candidate: bool = true,
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(allocator);
    const args = parse(argv) catch |err| {
        std.process.fatal("invalid feature-surface arguments: {t}", .{err});
    };
    const cwd = try std.process.currentPathAlloc(init.io, allocator);
    _ = try surface.apply(allocator, init.io, .{
        .wabt = args.wabt,
        .wasm_tools = args.wasm_tools,
        .platform_wit = args.platform_wit,
        .component = args.component,
        .output = args.output,
        .work_dir = args.work_dir,
        .target_wit = args.target_wit,
        .target_world = args.target_world,
        .features = args.features,
        .runtime_config = args.runtime_config,
        .inspect_candidate = args.inspect_candidate,
        .cwd = cwd,
        .verbose = args.verbose,
    });
}

fn parse(argv: []const []const u8) !Args {
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--wabt")) {
            args.wabt = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--wasm-tools")) {
            args.wasm_tools = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--platform-wit")) {
            args.platform_wit = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--component")) {
            args.component = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--output")) {
            args.output = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            args.work_dir = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--target-wit")) {
            args.target_wit = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--target-world")) {
            args.target_world = try value(argv, &i);
        } else if (std.mem.eql(u8, arg, "--features")) {
            args.features = try parseFeatures(try value(argv, &i));
        } else if (std.mem.eql(u8, arg, "--runtime-config")) {
            const mode = try value(argv, &i);
            args.runtime_config = if (std.mem.eql(u8, mode, "external"))
                .external
            else if (std.mem.eql(u8, mode, "snapshotted"))
                .snapshotted
            else
                return error.InvalidRuntimeConfig;
        } else if (std.mem.eql(u8, arg, "--no-inspect-candidate")) {
            args.inspect_candidate = false;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if (args.wabt.len == 0 or
        args.wasm_tools.len == 0 or
        args.platform_wit.len == 0 or
        args.component.len == 0 or
        args.output.len == 0 or
        args.work_dir.len == 0)
    {
        return error.MissingArgument;
    }
    if ((args.target_wit == null) != (args.target_world == null)) {
        return error.IncompleteTarget;
    }
    return args;
}

fn value(argv: []const []const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return error.MissingValue;
    return argv[i.*];
}

fn parseFeatures(text: []const u8) !surface.Features {
    var values: [5]bool = undefined;
    var parts = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == values.len) return error.InvalidFeatures;
        values[count] = if (std.mem.eql(u8, part, "1"))
            true
        else if (std.mem.eql(u8, part, "0"))
            false
        else
            return error.InvalidFeatures;
        count += 1;
    }
    if (count != values.len) return error.InvalidFeatures;
    return .{
        .stdio = values[0],
        .random = values[1],
        .clocks = values[2],
        .http = values[3],
        .fetch_event = values[4],
    };
}

test "parses feature tuple and target" {
    const argv = [_][]const u8{
        "starling-feature-surface",
        "--wabt",
        "wabt",
        "--wasm-tools",
        "wasm-tools",
        "--platform-wit",
        "platform-wit",
        "--component",
        "input.wasm",
        "--output",
        "output.wasm",
        "--work-dir",
        "work",
        "--target-wit",
        "wit",
        "--target-world",
        "probe",
        "--features",
        "0,1,0,1,0",
        "--runtime-config",
        "external",
    };
    const args = try parse(&argv);
    try std.testing.expect(!args.features.stdio);
    try std.testing.expect(args.features.random);
    try std.testing.expectEqualStrings("probe", args.target_world.?);
    try std.testing.expectEqual(surface.RuntimeConfig.external, args.runtime_config);
}
