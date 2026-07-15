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

pub const Options = struct {
    wac: []const u8,
    wasm_tools: []const u8,
    platform_wit: []const u8,
    component: []const u8,
    output: []const u8,
    work_dir: []const u8,
    target_wit: ?[]const u8,
    target_world: ?[]const u8,
    features: Features,
    inspect_candidate: bool = true,
    cwd: []const u8,
    verbose: bool = false,
    command_log: ?*std.ArrayList(u8) = null,
};

pub fn apply(
    allocator: Allocator,
    io: Io,
    options: Options,
) !void {
    if (options.target_wit == null and options.features.allEnabled()) {
        return copyFile(io, options.component, options.output);
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
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: generate target component",
            &.{
                options.wasm_tools,
                "component",
                "new",
                target_core,
                "-o",
                target_component,
            },
        );
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: inspect target",
            &.{
                options.wasm_tools,
                "component",
                "wit",
                target_component,
                "-o",
                target_surface,
            },
        );
        const target_text = try readFile(allocator, io, target_surface);
        target_imports = try collectWasiImports(allocator, target_text);
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
    const platform_root = try path(allocator, platform_dir, "bindings.wit");
    const platform_text = try readFile(allocator, io, platform_root);
    const platform_imports = try collectWasiImports(allocator, platform_text);
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
        const candidate_text = try readFile(allocator, io, candidate_surface);
        actual_imports = try collectComponentImports(allocator, candidate_text);
    } else {
        var assumed: std.ArrayList([]const u8) = .empty;
        assumed.appendSlice(allocator, platform_imports) catch @panic("out of memory");
        actual_imports = try assumed.toOwnedSlice(allocator);
    }

    var provided: std.ArrayList([]const u8) = .empty;
    const demand_driven = options.target_wit != null;
    var preserved: std.ArrayList([]const u8) = .empty;
    for (platform_imports) |name| {
        if (!shouldProvide(name, target_imports, options.features, demand_driven)) {
            preserved.append(allocator, name) catch @panic("out of memory");
        }
        if ((options.features.pure() or contains(actual_imports, name)) and
            shouldProvide(name, target_imports, options.features, demand_driven) and
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
    if (providers.items.len == 0) return copyFile(io, options.component, options.output);
    var consumer = options.component;
    for (providers.items, 0..) |provider, index| {
        const output = if (index + 1 == providers.items.len)
            options.output
        else
            try passPath(allocator, options.work_dir, index, "partial.wasm");
        try runCommand(
            allocator,
            io,
            options,
            "feature surface: compose provider",
            &.{
                options.wac,
                "plug",
                "--plug",
                provider,
                consumer,
                "-o",
                output,
            },
        );
        consumer = output;
    }
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
    const provider_wit = try path(allocator, provider_dir, "component.wit");
    const provider_base_text = try readFile(allocator, io, provider_wit);
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
            const dependency = try path(allocator, provider_dir, "deps");
            const wit = try path(allocator, dependency, basename);
            const text = try readFile(allocator, io, wit);
            const inlined = try inlineMonotonicDuration(allocator, text);
            try Dir.cwd().writeFile(io, .{ .sub_path = wit, .data = inlined });
        }
    }

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
            provider_dir,
            "--world",
            "feature-provider",
            "--dummy",
            "-o",
            provider_core,
        },
    );
    try runCommand(
        allocator,
        io,
        options,
        "feature surface: generate provider component",
        &.{
            options.wasm_tools,
            "component",
            "new",
            provider_core,
            "-o",
            provider_component,
        },
    );

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
            provider_component,
            "-o",
            provider_surface,
        },
    );
    const provider_surface_text = try readFile(allocator, io, provider_surface);
    const provider_imports = try collectWasiImports(allocator, provider_surface_text);
    var residuals: std.ArrayList([]const u8) = .empty;
    for (provider_imports) |name| {
        if (shouldProvide(
            name,
            target_imports,
            options.features,
            demand_driven,
        ) and
            !contains(residuals.items, name))
        {
            residuals.append(allocator, name) catch @panic("out of memory");
        }
    }
    definitions.append(allocator, provider_component) catch @panic("out of memory");
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
) bool {
    const target_requires = contains(target_imports, name);

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
    if (interface(name, "wasi:http/types")) {
        return !features.http and !features.fetch_event;
    }
    if (std.mem.startsWith(u8, name, "wasi:io/")) {
        if (target_requires) return false;
        return !features.stdio and !features.clocks and !features.http;
    }
    if (std.mem.startsWith(u8, name, "wasi:filesystem/")) {
        if (target_requires) return false;
        return (demand_driven and !features.stdio) or features.pure();
    }
    if (std.mem.startsWith(u8, name, "wasi:sockets/") or
        interface(name, "wasi:cli/environment") or
        interface(name, "wasi:cli/exit"))
    {
        if (target_requires) return false;
        return demand_driven or features.pure();
    }

    if (target_requires) return false;
    return demand_driven or features.pure();
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

fn copyFile(io: Io, source: []const u8, destination: []const u8) !void {
    const parent = std.fs.path.dirname(destination) orelse ".";
    var dir = if (std.fs.path.isAbsolute(parent))
        try Dir.openDirAbsolute(io, parent, .{})
    else
        try Dir.cwd().openDir(io, parent, .{});
    defer dir.close(io);
    try Dir.cwd().copyFile(source, dir, std.fs.path.basename(destination), io, .{});
}

fn runCommand(
    allocator: Allocator,
    io: Io,
    options: Options,
    stage: []const u8,
    argv: []const []const u8,
) !void {
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
    ));
    try std.testing.expect(shouldProvide(
        "wasi:clocks/monotonic-clock@0.2.10",
        no_target,
        .{ .clocks = false },
        minimal,
    ));
    try std.testing.expect(!shouldProvide(
        "wasi:clocks/wall-clock@0.2.10",
        no_target,
        .{ .clocks = false },
        minimal,
    ));
    try std.testing.expect(shouldProvide(
        "wasi:cli/stdin@0.2.10",
        no_target,
        .{ .stdio = false },
        minimal,
    ));
    try std.testing.expect(!shouldProvide(
        "wasi:cli/stderr@0.2.10",
        no_target,
        .{ .stdio = false },
        minimal,
    ));
    try std.testing.expect(shouldProvide(
        "wasi:http/outgoing-handler@0.2.10",
        no_target,
        .{ .http = false },
        minimal,
    ));
    try std.testing.expect(!shouldProvide(
        "wasi:http/types@0.2.10",
        no_target,
        .{ .http = false },
        minimal,
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
        try std.testing.expect(shouldProvide(name, &.{}, features, true));
    }
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
