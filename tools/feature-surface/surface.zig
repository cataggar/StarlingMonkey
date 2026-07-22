const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

pub const Features = struct {
    stdio: bool = true,
    random: bool = true,
    clocks: bool = true,
    http: bool = true,
    fetch_event: bool = true,

    pub fn allEnabled(self: Features) bool {
        return self.stdio and self.random and self.clocks and self.http and self.fetch_event;
    }

    pub fn pure(self: Features) bool {
        return !self.stdio and !self.random and !self.clocks and !self.http and !self.fetch_event;
    }
};

pub const RuntimeConfig = enum {
    external,
    snapshotted,
};

pub const Options = struct {
    wabt: []const u8,
    wasm_tools: []const u8,
    platform_wit: []const u8,
    component: []const u8,
    output: []const u8,
    work_dir: []const u8,
    target_wit: ?[]const u8,
    target_world: ?[]const u8,
    features: Features,
    runtime_config: RuntimeConfig = .snapshotted,
    inspect_candidate: bool = true,
    cwd: []const u8,
    verbose: bool = false,
    command_log: ?*std.ArrayList(u8) = null,
    command_runner: ?CommandRunner = null,
    generated_inputs: ?GeneratedInputs = null,
};

pub const CommandRunner = struct {
    context: *anyopaque,
    run: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        io: Io,
        stage: []const u8,
        argv: []const []const u8,
        cwd: []const u8,
        verbose: bool,
        command_log: ?*std.ArrayList(u8),
    ) anyerror!void,
};

pub const GeneratedInputs = struct {
    context: *anyopaque,
    retain_file: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        io: Io,
        stage: []const u8,
        path: []const u8,
    ) anyerror![]const u8,
    snapshot_tree: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        io: Io,
        stage: []const u8,
        path: []const u8,
    ) anyerror![]const u8,
    verify: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        io: Io,
    ) anyerror!void,
    set_diagnostic_detail: *const fn (
        context: *anyopaque,
        detail: []const u8,
    ) void,
};

pub fn apply(
    allocator: Allocator,
    io: Io,
    options: Options,
) !bool {
    if (options.target_wit == null and options.features.allEnabled()) {
        try copyFile(io, options.component, options.output);
        return false;
    }

    var target_imports: []const []const u8 = &.{};
    if (options.target_wit) |target_wit| {
        const target_core = try passPath(allocator, options.work_dir, 0, "target-core.wasm");
        const target_component = try passPath(allocator, options.work_dir, 0, "target.wasm");
        const target_surface = try passPath(allocator, options.work_dir, 0, "target.wit");
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: generate target core",
            &.{
                options.wasm_tools,
                "component",
                "embed",
                target_wit,
                "--world",
                options.target_world.?,
                "--dummy",
                "-o",
                target_core,
            },
        );
        const retained_target_core = try retainGeneratedFile(
            allocator,
            io,
            options,
            "feature-target-core",
            target_core,
        );
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: generate target component",
            &.{
                options.wasm_tools,
                "component",
                "new",
                retained_target_core,
                "-o",
                target_component,
            },
        );
        const retained_target_component = try retainGeneratedFile(
            allocator,
            io,
            options,
            "feature-target-component",
            target_component,
        );
        try verifyGeneratedInputs(allocator, io, options);
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: inspect target",
            &.{
                options.wasm_tools,
                "component",
                "wit",
                retained_target_component,
                "-o",
                target_surface,
            },
        );
        const retained_target_surface = try retainGeneratedFile(
            allocator,
            io,
            options,
            "feature-target-surface",
            target_surface,
        );
        try verifyGeneratedInputs(allocator, io, options);
        const target_text = try readFile(allocator, io, retained_target_surface);
        target_imports = try collectWasiImports(allocator, target_text);
        try verifyGeneratedInputs(allocator, io, options);
    }

    const platform_dir = try passPath(allocator, options.work_dir, 0, "platform-wit");
    try Dir.cwd().createDirPath(io, platform_dir);
    try runCommand(
        allocator,
        io,
        options,
        "feature surface: resolve platform WIT",
        &.{
            options.wasm_tools,
            "component",
            "wit",
            options.platform_wit,
            "--out-dir",
            platform_dir,
        },
    );
    const retained_platform_dir = try snapshotGeneratedTree(
        allocator,
        io,
        options,
        "feature-platform-wit",
        platform_dir,
    );
    const platform_root = try generatedRootWit(
        allocator,
        io,
        options,
        retained_platform_dir,
    );
    const platform_text = try readFile(allocator, io, platform_root);
    try validateGeneratedRootWit(platform_text);
    const platform_imports = try collectWasiImports(allocator, platform_text);
    try verifyGeneratedInputs(allocator, io, options);
    var actual_imports: []const []const u8 = &.{};
    if (options.inspect_candidate) {
        const candidate_surface = try passPath(
            allocator,
            options.work_dir,
            0,
            "candidate.wat",
        );
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: inspect candidate",
            &.{
                options.wasm_tools,
                "print",
                options.component,
                "-o",
                candidate_surface,
            },
        );
        const retained_candidate_surface = try retainGeneratedFile(
            allocator,
            io,
            options,
            "feature-candidate-surface",
            candidate_surface,
        );
        const candidate_text = try readFile(
            allocator,
            io,
            retained_candidate_surface,
        );
        actual_imports = try collectComponentImports(allocator, candidate_text);
        try verifyGeneratedInputs(allocator, io, options);
    } else {
        var assumed: std.ArrayList([]const u8) = .empty;
        assumed.appendSlice(allocator, platform_imports) catch @panic("out of memory");
        actual_imports = try assumed.toOwnedSlice(allocator);
    }

    var provided: std.ArrayList([]const u8) = .empty;
    const demand_driven = options.target_wit != null;
    var preserved: std.ArrayList([]const u8) = .empty;
    for (platform_imports) |name| {
        if (!shouldProvide(
            name,
            target_imports,
            options.features,
            demand_driven,
            options.runtime_config,
        )) {
            preserved.append(allocator, name) catch @panic("out of memory");
        }
        if ((options.features.pure() or contains(actual_imports, name)) and
            shouldProvide(
                name,
                target_imports,
                options.features,
                demand_driven,
                options.runtime_config,
            ) and
            !contains(provided.items, name))
        {
            provided.append(allocator, name) catch @panic("out of memory");
        }
    }
    var primary: std.ArrayList([]const u8) = .empty;
    for (provided.items) |name| {
        primary.append(allocator, name) catch @panic("out of memory");
    }
    var providers: std.ArrayList([]const u8) = .empty;
    if (primary.items.len != 0) {
        try buildProvider(
            allocator,
            io,
            options,
            primary.items,
            preserved.items,
            target_imports,
            demand_driven,
            providers.items.len,
            &providers,
        );
    }
    if (providers.items.len == 0) {
        try copyFile(io, options.component, options.output);
        return false;
    }
    var consumer = options.component;
    for (providers.items, 0..) |provider, index| {
        const final = index + 1 == providers.items.len;
        const output = if (final)
            options.output
        else
            try passPath(allocator, options.work_dir, index, "partial.wasm");
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: compose provider",
            &.{
                options.wabt,
                "component",
                "compose",
                "-d",
                provider,
                "-o",
                output,
                consumer,
            },
        );
        if (final) {
            try verifyGeneratedInputs(allocator, io, options);
        } else {
            const stage = try std.fmt.allocPrint(
                allocator,
                "feature-provider-partial-{d}",
                .{index},
            );
            consumer = try retainGeneratedFile(
                allocator,
                io,
                options,
                stage,
                output,
            );
            try verifyGeneratedInputs(allocator, io, options);
        }
    }
    return true;
}

fn buildProvider(
    allocator: Allocator,
    io: Io,
    options: Options,
    provided: []const []const u8,
    preserved: []const []const u8,
    target_imports: []const []const u8,
    demand_driven: bool,
    depth: usize,
    definitions: *std.ArrayList([]const u8),
) !void {
    if (depth == 8) return error.FeatureProviderCycle;
    const provider_dir = try passPath(allocator, options.work_dir, depth, "provider-wit");
    try Dir.cwd().createDirPath(io, provider_dir);
    try runCommand(
        allocator,
        io,
        options,
        "feature surface: resolve exact candidate WIT",
        &.{
            options.wasm_tools,
            "component",
            "wit",
            options.component,
            "--out-dir",
            provider_dir,
        },
    );
    const retained_provider_dir = try snapshotGeneratedTree(
        allocator,
        io,
        options,
        "feature-provider-wit",
        provider_dir,
    );
    const retained_provider_wit = try generatedRootWit(
        allocator,
        io,
        options,
        retained_provider_dir,
    );
    const provider_wit = try path(
        allocator,
        provider_dir,
        std.fs.path.basename(retained_provider_wit),
    );
    const provider_base_text = try readFile(
        allocator,
        io,
        retained_provider_wit,
    );
    try validateGeneratedRootWit(provider_base_text);
    const provider_text = try renderProviderWit(
        allocator,
        provider_base_text,
        provided,
        preserved,
    );
    try Dir.cwd().writeFile(io, .{ .sub_path = provider_wit, .data = provider_text });
    if (!options.features.clocks) {
        // Duration is a u64 alias. Inlining it prevents preserved HTTP and
        // internalized socket interfaces from reintroducing monotonic-clock.
        for ([_][]const u8{ "http.wit", "sockets.wit" }) |basename| {
            const retained_dependency = try path(
                allocator,
                retained_provider_dir,
                "deps",
            );
            const dependency = try path(allocator, provider_dir, "deps");
            const wit = try path(allocator, dependency, basename);
            const retained_wit = try path(
                allocator,
                retained_dependency,
                basename,
            );
            const text = try readFile(allocator, io, retained_wit);
            const inlined = try inlineMonotonicDuration(allocator, text);
            try Dir.cwd().writeFile(io, .{ .sub_path = wit, .data = inlined });
        }
    }
    try verifyGeneratedInputs(allocator, io, options);
    const retained_rendered_provider_dir = try snapshotGeneratedTree(
        allocator,
        io,
        options,
        "feature-provider-wit-rendered",
        provider_dir,
    );

    const provider_core = try passPath(allocator, options.work_dir, depth, "provider-core.wasm");
    const provider_component = try providerComponentPath(allocator, options.work_dir, depth);
    try runCommand(
        allocator,
        io,
        options,
        "feature surface: generate provider core",
        &.{
            options.wasm_tools,
            "component",
            "embed",
            retained_rendered_provider_dir,
            "--world",
            "feature-provider",
            "--dummy",
            "-o",
            provider_core,
        },
    );
    const retained_provider_core = try retainGeneratedFile(
        allocator,
        io,
        options,
        "feature-provider-core",
        provider_core,
    );
    try verifyGeneratedInputs(allocator, io, options);
    try runCommand(
        allocator,
        io,
        options,
        "feature surface: generate provider component",
        &.{
            options.wasm_tools,
            "component",
            "new",
            retained_provider_core,
            "-o",
            provider_component,
        },
    );
    const retained_provider_component = try retainGeneratedFile(
        allocator,
        io,
        options,
        "feature-provider-component",
        provider_component,
    );
    try verifyGeneratedInputs(allocator, io, options);

    const provider_surface = try passPath(allocator, options.work_dir, depth, "provider-surface.wit");
    try runCommand(
        allocator,
        io,
        options,
        "feature surface: inspect provider",
        &.{
            options.wasm_tools,
            "component",
            "wit",
            retained_provider_component,
            "-o",
            provider_surface,
        },
    );
    const retained_provider_surface = try retainGeneratedFile(
        allocator,
        io,
        options,
        "feature-provider-surface",
        provider_surface,
    );
    try verifyGeneratedInputs(allocator, io, options);
    const provider_surface_text = try readFile(
        allocator,
        io,
        retained_provider_surface,
    );
    const provider_imports = try collectWasiImports(allocator, provider_surface_text);
    try verifyGeneratedInputs(allocator, io, options);
    var residuals: std.ArrayList([]const u8) = .empty;
    for (provider_imports) |name| {
        if (shouldProvide(
            name,
            target_imports,
            options.features,
            demand_driven,
            options.runtime_config,
        ) and
            !contains(residuals.items, name))
        {
            residuals.append(allocator, name) catch @panic("out of memory");
        }
    }
    definitions.append(allocator, retained_provider_component) catch @panic("out of memory");
    if (residuals.items.len == 0) return;
    try buildProvider(
        allocator,
        io,
        options,
        residuals.items,
        preserved,
        target_imports,
        demand_driven,
        depth + 1,
        definitions,
    );
}

fn shouldProvide(
    name: []const u8,
    target_imports: []const []const u8,
    features: Features,
    demand_driven: bool,
    runtime_config: RuntimeConfig,
) bool {
    const target_requires = contains(target_imports, name);
    const dependencies = featureDependencies(features);

    if (interface(name, "wasi:random/random")) return !features.random;
    if (interface(name, "wasi:random/insecure") or
        interface(name, "wasi:random/insecure-seed"))
    {
        if (!features.random) return true;
        if (target_requires) return false;
        return demand_driven or features.pure();
    }
    if (interface(name, "wasi:clocks/monotonic-clock")) return !features.clocks;
    if (interface(name, "wasi:clocks/wall-clock")) {
        return !features.clocks and !features.stdio;
    }
    if (interface(name, "wasi:clocks/timezone")) {
        return !features.clocks and !target_requires;
    }
    if (interface(name, "wasi:cli/stdin") or interface(name, "wasi:cli/stdout")) {
        return !features.stdio;
    }
    if (interface(name, "wasi:cli/stderr")) {
        return !features.stdio and features.pure();
    }
    if (std.mem.startsWith(u8, name, "wasi:cli/terminal-")) {
        return !features.stdio;
    }
    if (interface(name, "wasi:http/outgoing-handler")) return !features.http;
    if (interface(name, "wasi:http/types")) return !dependencies.http_types;
    if (std.mem.startsWith(u8, name, "wasi:io/")) {
        if (target_requires) return false;
        return !dependencies.io_resource_identities;
    }
    if (std.mem.startsWith(u8, name, "wasi:filesystem/")) {
        if (target_requires) return false;
        return (demand_driven and !features.stdio) or features.pure();
    }
    if (std.mem.startsWith(u8, name, "wasi:sockets/") or
        interface(name, "wasi:cli/exit"))
    {
        if (target_requires) return false;
        return demand_driven or features.pure();
    }

    if (interface(name, "wasi:cli/environment")) {
        if (runtime_config == .external or target_requires) return false;
        return demand_driven or features.pure();
    }

    if (target_requires) return false;
    return demand_driven or features.pure();
}

const FeatureDependencies = struct {
    http_types: bool,
    io_resource_identities: bool,
};

fn featureDependencies(features: Features) FeatureDependencies {
    const http_types = features.http or features.fetch_event;
    return .{
        .http_types = http_types,
        .io_resource_identities = features.stdio or
            features.clocks or
            http_types,
    };
}

fn interface(name: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, name, prefix) or
        (std.mem.startsWith(u8, name, prefix) and
            name.len > prefix.len and
            name[prefix.len] == '@');
}

fn collectWasiImports(
    allocator: Allocator,
    text: []const u8,
) ![]const []const u8 {
    var imports: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const prefix = "import ";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const end = std.mem.indexOfScalarPos(u8, trimmed, prefix.len, ';') orelse continue;
        const item = trimmed[prefix.len..end];
        if (!std.mem.startsWith(u8, item, "wasi:")) continue;
        imports.append(allocator, item) catch @panic("out of memory");
    }

    return imports.toOwnedSlice(allocator);
}

fn collectComponentImports(
    allocator: Allocator,
    text: []const u8,
) ![]const []const u8 {
    var imports: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const prefix = "(import \"";
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const end = std.mem.indexOfScalarPos(u8, trimmed, prefix.len, '"') orelse continue;
        const item = trimmed[prefix.len..end];
        if (!std.mem.startsWith(u8, item, "wasi:")) continue;
        if (!contains(imports.items, item)) {
            imports.append(allocator, item) catch @panic("out of memory");
        }
    }
    return imports.toOwnedSlice(allocator);
}

fn renderProviderWit(
    allocator: Allocator,
    text: []const u8,
    provided: []const []const u8,
    preserved: []const []const u8,
) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const prefix = "  import ";
        if (std.mem.startsWith(u8, line, "world ")) {
            output.appendSlice(allocator, "world feature-provider {") catch
                @panic("out of memory");
        } else if (std.mem.startsWith(u8, line, prefix)) {
            const end = std.mem.indexOfScalarPos(u8, line, prefix.len, ';');
            const item = if (end) |index| line[prefix.len..index] else "";
            if (contains(provided, item)) {
                output.appendSlice(allocator, "  export ") catch @panic("out of memory");
                output.appendSlice(allocator, line[prefix.len..]) catch @panic("out of memory");
            } else if (contains(preserved, item)) {
                output.appendSlice(allocator, line) catch @panic("out of memory");
            } else {
                continue;
            }
        } else if (std.mem.startsWith(u8, line, "  export ")) {
            continue;
        } else {
            output.appendSlice(allocator, line) catch @panic("out of memory");
        }
        output.append(allocator, '\n') catch @panic("out of memory");
    }
    return output.toOwnedSlice(allocator);
}

fn inlineMonotonicDuration(allocator: Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(
            u8,
            line,
            "  use wasi:clocks/monotonic-clock",
        ) and std.mem.endsWith(u8, line, ".{duration};")) {
            output.appendSlice(allocator, "  type duration = u64;") catch
                @panic("out of memory");
        } else {
            output.appendSlice(allocator, line) catch @panic("out of memory");
        }

        output.append(allocator, '\n') catch @panic("out of memory");
    }
    return output.toOwnedSlice(allocator);
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }

    return false;
}

fn path(allocator: Allocator, directory: []const u8, basename: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ directory, basename });
}

fn generatedRootWit(
    allocator: Allocator,
    io: Io,
    options: Options,
    directory: []const u8,
) ![]const u8 {
    var dir = try Dir.openDirAbsolute(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var root: ?[]const u8 = null;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.path, ".wit") or
            std.fs.path.dirname(entry.path) != null)
        {
            continue;
        }
        if (root != null) {
            setGeneratedInputDiagnosticDetail(
                allocator,
                options,
                "generated WIT has multiple root packages ('{s}' and '{s}')",
                .{ root.?, entry.path },
            );
            return error.AmbiguousGeneratedWitRoot;
        }
        root = try allocator.dupe(u8, entry.path);
    }
    const relative = root orelse {
        setGeneratedInputDiagnosticDetail(
            allocator,
            options,
            "generated WIT has no root package",
            .{},
        );
        return error.MissingGeneratedWitRoot;
    };
    return path(allocator, directory, relative);
}

fn setGeneratedInputDiagnosticDetail(
    allocator: Allocator,
    options: Options,
    comptime format: []const u8,
    args: anytype,
) void {
    const generated = options.generated_inputs orelse return;
    const detail = std.fmt.allocPrint(allocator, format, args) catch
        "generated WIT root validation failed";
    generated.set_diagnostic_detail(generated.context, detail);
}

fn validateGeneratedRootWit(text: []const u8) !void {
    var packages: usize = 0;
    var worlds: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "package ") and
            std.mem.endsWith(u8, trimmed, ";"))
        {
            packages += 1;
        }
        if (std.mem.startsWith(u8, trimmed, "world ")) worlds += 1;
    }
    if (packages != 1 or worlds == 0) {
        return error.InvalidGeneratedWitRoot;
    }
}

fn passPath(
    allocator: Allocator,
    directory: []const u8,
    depth: usize,
    basename: []const u8,
) ![]const u8 {
    const name = try std.fmt.allocPrint(allocator, "feature-{d}-{s}", .{ depth, basename });
    return path(allocator, directory, name);
}

fn providerComponentPath(
    allocator: Allocator,
    directory: []const u8,
    depth: usize,
) ![]const u8 {
    const suffix = "abcdefgh"[depth .. depth + 1];
    const name = try std.fmt.allocPrint(allocator, "feature-provider-{s}.wasm", .{suffix});
    return path(allocator, directory, name);
}

fn readFile(allocator: Allocator, io: Io, absolute: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(absolute) orelse return error.InvalidPath;
    var dir = try Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(absolute), allocator, .unlimited);
}

fn retainGeneratedFile(
    allocator: Allocator,
    io: Io,
    options: Options,
    stage: []const u8,
    absolute: []const u8,
) ![]const u8 {
    const generated_inputs = options.generated_inputs orelse return absolute;
    return generated_inputs.retain_file(
        generated_inputs.context,
        allocator,
        io,
        stage,
        absolute,
    );
}

fn snapshotGeneratedTree(
    allocator: Allocator,
    io: Io,
    options: Options,
    stage: []const u8,
    absolute: []const u8,
) ![]const u8 {
    const generated_inputs = options.generated_inputs orelse return absolute;
    return generated_inputs.snapshot_tree(
        generated_inputs.context,
        allocator,
        io,
        stage,
        absolute,
    );
}

fn verifyGeneratedInputs(
    allocator: Allocator,
    io: Io,
    options: Options,
) !void {
    const generated_inputs = options.generated_inputs orelse return;
    try generated_inputs.verify(
        generated_inputs.context,
        allocator,
        io,
    );
}

fn copyFile(io: Io, source: []const u8, destination: []const u8) !void {
    var source_file = try Dir.openFileAbsolute(io, source, .{});
    defer source_file.close(io);
    var destination_file = try Dir.createFileAbsolute(io, destination, .{
        .read = true,
        .truncate = true,
    });
    defer destination_file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = source_file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count != 0) {
            try destination_file.writeStreamingAll(io, buffer[0..count]);
        }
    }
}

fn runCommand(
    allocator: Allocator,
    io: Io,
    options: Options,
    stage: []const u8,
    argv: []const []const u8,
) !void {
    if (options.command_runner) |runner| {
        return runner.run(
            runner.context,
            allocator,
            io,
            stage,
            argv,
            options.cwd,
            options.verbose,
            options.command_log,
        );
    }
    if (options.command_log) |log| {
        log.appendSlice(allocator, stage) catch @panic("out of memory");
        log.append(allocator, '\n') catch @panic("out of memory");
        for (argv) |arg| {
            log.appendSlice(allocator, "  ") catch @panic("out of memory");
            log.appendSlice(allocator, arg) catch @panic("out of memory");
            log.append(allocator, '\n') catch @panic("out of memory");
        }
    }
    if (options.verbose) {
        std.debug.print("[{s}]\n", .{stage});
        for (argv) |arg| std.debug.print("  {s}\n", .{arg});
    }
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = options.cwd },
        .stdin = .ignore,
        .stdout = if (options.verbose) .inherit else .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("error: {s} failed ({t})\n", .{ stage, term });
        return error.CommandFailed;
    }
}

test "disabled feature policy matches the frozen minimal-world surfaces" {
    const no_target: []const []const u8 = &.{};
    const minimal = true;

    try std.testing.expect(shouldProvide(
        "wasi:random/random@0.2.10",
        no_target,
        .{ .random = false },
        minimal,
        .snapshotted,
    ));
    try std.testing.expect(shouldProvide(
        "wasi:clocks/monotonic-clock@0.2.10",
        no_target,
        .{ .clocks = false },
        minimal,
        .snapshotted,
    ));
    try std.testing.expect(!shouldProvide(
        "wasi:clocks/wall-clock@0.2.10",
        no_target,
        .{ .clocks = false },
        minimal,
        .snapshotted,
    ));
    try std.testing.expect(shouldProvide(
        "wasi:cli/stdin@0.2.10",
        no_target,
        .{ .stdio = false },
        minimal,
        .snapshotted,
    ));
    try std.testing.expect(!shouldProvide(
        "wasi:cli/stderr@0.2.10",
        no_target,
        .{ .stdio = false },
        minimal,
        .snapshotted,
    ));
    try std.testing.expect(shouldProvide(
        "wasi:http/outgoing-handler@0.2.10",
        no_target,
        .{ .http = false },
        minimal,
        .snapshotted,
    ));
    try std.testing.expect(!shouldProvide(
        "wasi:http/types@0.2.10",
        no_target,
        .{ .http = false },
        minimal,
        .snapshotted,
    ));
}

test "pure mode provides every residual for a world without WASI imports" {
    const features = Features{
        .stdio = false,
        .random = false,
        .clocks = false,
        .http = false,
        .fetch_event = false,
    };
    const imports = [_][]const u8{
        "wasi:io/poll@0.2.10",
        "wasi:filesystem/types@0.2.10",
        "wasi:sockets/network@0.2.10",
        "wasi:cli/environment@0.2.10",
    };
    for (imports) |name| {
        try std.testing.expect(shouldProvide(
            name,
            &.{},
            features,
            true,
            .snapshotted,
        ));
    }
    try std.testing.expect(!shouldProvide(
        "wasi:cli/environment@0.2.10",
        &.{},
        features,
        true,
        .external,
    ));
}

test "fetch-event preserves HTTP resource dependency identities" {
    const fetch_only = Features{
        .stdio = false,
        .random = false,
        .clocks = false,
        .http = false,
        .fetch_event = true,
    };
    for ([_][]const u8{
        "wasi:http/types@0.2.10",
        "wasi:io/error@0.2.10",
        "wasi:io/poll@0.2.10",
        "wasi:io/streams@0.2.10",
    }) |name| {
        try std.testing.expect(!shouldProvide(
            name,
            &.{},
            fetch_only,
            true,
            .snapshotted,
        ));
    }
    try std.testing.expect(shouldProvide(
        "wasi:http/outgoing-handler@0.2.10",
        &.{},
        fetch_only,
        true,
        .snapshotted,
    ));
    try std.testing.expect(shouldProvide(
        "wasi:random/random@0.2.10",
        &.{},
        fetch_only,
        true,
        .snapshotted,
    ));
}

test "generated root WIT metadata is validated independently of its filename" {
    try validateGeneratedRootWit(
        \\package custom:runtime-package;
        \\
        \\world non-bindings {}
        \\
    );
    try std.testing.expectError(
        error.InvalidGeneratedWitRoot,
        validateGeneratedRootWit("world missing-package {}\n"),
    );
}

test "provider WIT exports only selected interfaces" {
    const input =
        \\package root:component;
        \\
        \\world root {
        \\  import wasi:filesystem/types@0.2.10;
        \\  import wasi:cli/environment@0.2.10;
        \\  import wasi:http/types@0.2.10;
        \\}
        \\
    ;
    const output = try renderProviderWit(
        std.testing.allocator,
        input,
        &.{
            "wasi:filesystem/types@0.2.10",
            "wasi:cli/environment@0.2.10",
        },
        &.{},
    );
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "export wasi:filesystem/types@0.2.10",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "export wasi:cli/environment@0.2.10",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "wasi:http/types@0.2.10",
    ) == null);
}
