const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const diagnostics = @import("diagnostics.zig");
const metadata = @import("metadata.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const File = Io.File;

const PipelineError = error{
    CommandFailed,
    DebugOutputCollision,
    EmptyRuntimeArgument,
    IncompatibleEngineOptions,
    InvalidBuildRoot,
    InvalidBindingsManifest,
    InvalidMetadataDestination,
    InvalidPath,
    MetadataUnavailable,
    MissingBuildArtifact,
    MissingWitFiles,
    UnrepresentableRuntimeArgument,
    UnsupportedWitEntry,
};

const StagedWit = struct {
    absolute: []const u8,
    relative: []const u8,
    digest: []const u8,
};

const Runtime = struct {
    engine: []const u8,
    adapter: []const u8,
    component_wit: ?[]const u8,
    component_world: ?[]const u8,
    bindings: ?[]const u8,
    dispatch_wit_digest: ?[]const u8,
    component_wit_digest: ?[]const u8,
    zig: ?[]const u8,
    cache_lock: ?File,
};

const WizerTool = struct {
    executable: []const u8,
    wasmtime_subcommand: bool,
};

const Tools = struct {
    wizer: WizerTool,
    wabt: ?[]const u8,
    wasm_tools: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var diagnostic = diagnostics.Context{
        .allocator = allocator,
        .io = init.io,
        .format = cli.detectDiagnosticFormat(args),
    };
    var action = cli.parse(allocator, args) catch |err| {
        diagnostic.reportParse(err, parseErrorMessage(err));
        std.process.exit(1);
    };

    switch (action) {
        .help => try File.stdout().writeStreamingAll(init.io, cli.usage),
        .version => try File.stdout().writeStreamingAll(init.io, cli.version ++ "\n"),
        .run => |*config| {
            defer config.deinit(allocator);
            diagnostic.format = config.diagnostic_format;
            execute(
                allocator,
                init.io,
                init.environ_map,
                config,
                &diagnostic,
            ) catch |err| {
                diagnostic.report(err);
                std.process.exit(1);
            };
        },
    }
}

fn parseErrorMessage(err: cli.ParseError) []const u8 {
    return switch (err) {
        error.ConflictingFeatures => "the same feature cannot be both enabled and disabled",
        error.InvalidDiagnosticFormat => "--diagnostic-format must be human or json",
        error.InvalidHeapLimit => "--js-heap-limit-mib must be an integer from 1 to 4095",
        error.MissingSource => "missing JavaScript source path",
        error.MissingValue => "an option is missing its value",
        error.MissingWitWorld => "--wit and --world-name must be provided together",
        error.MultipleSources => "multiple JavaScript source paths were provided",
        error.UnexpectedComponentWorld => "--component-wit requires --wit and its own world name",
        error.UnknownArgument => "unknown option",
        error.UnknownFeature => "unknown feature (expected stdio, random, clocks, http, or fetch-event)",
        error.UnsupportedAot => "AOT options are reserved for the dedicated AOT phase and are not implemented",
    };
}

fn execute(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    config: *const cli.Config,
    diagnostic: *diagnostics.Context,
) !void {
    diagnostic.begin(.inputs);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    const source_argument = try absolutePath(allocator, cwd, config.source);
    const source = try resolveExistingFile(allocator, io, cwd, config.source);
    try validateArgument(source);
    const initializer = if (config.initializer_script_path) |path|
        try resolveExistingFile(allocator, io, cwd, path)
    else
        null;

    const output = if (config.output) |path|
        try absolutePath(allocator, cwd, path)
    else
        try defaultOutputPath(allocator, cwd, source_argument);
    try validateArgument(output);
    const output_parent = std.fs.path.dirname(output) orelse return error.InvalidPath;
    try Dir.cwd().createDirPath(io, output_parent);
    const publication_parent = try Dir.realPathFileAbsoluteAlloc(
        io,
        output_parent,
        allocator,
    );
    try requireDestinationFileOrMissing(io, output, error.InvalidPath);
    const resolved_output = try resolveDestination(allocator, io, output);
    if (std.mem.eql(u8, source, resolved_output) or
        (initializer != null and std.mem.eql(u8, initializer.?, resolved_output)))
    {
        return error.InputOutputCollision;
    }

    if (config.metadata_out != null) diagnostic.begin(.metadata);
    const metadata_output = if (config.metadata_out) |path| blk: {
        const destination = try absolutePath(allocator, cwd, path);
        const parent = std.fs.path.dirname(destination) orelse
            return error.InvalidMetadataDestination;
        try Dir.cwd().createDirPath(io, parent);
        try requireDestinationFileOrMissing(
            io,
            destination,
            error.InvalidMetadataDestination,
        );
        const resolved_parent = try Dir.realPathFileAbsoluteAlloc(io, parent, allocator);
        const resolved = try resolveDestination(allocator, io, destination);
        if (std.mem.eql(u8, resolved, resolved_output) or
            std.mem.eql(u8, resolved, source) or
            (initializer != null and std.mem.eql(u8, resolved, initializer.?)))
        {
            return error.InvalidMetadataDestination;
        }
        if (!std.mem.eql(u8, resolved_parent, publication_parent)) {
            return error.InvalidMetadataDestination;
        }
        break :blk destination;
    } else null;

    if (config.debug_bindings) diagnostic.begin(.debug);
    const debug_dir = if (config.debug_bindings) blk: {
        const destination = if (config.debug_dir) |path|
            try absolutePath(allocator, cwd, path)
        else
            try std.fmt.allocPrint(allocator, "{s}.debug", .{output});
        const parent = std.fs.path.dirname(destination) orelse
            return error.DebugOutputCollision;
        try Dir.cwd().createDirPath(io, parent);
        const resolved_parent = try Dir.realPathFileAbsoluteAlloc(io, parent, allocator);
        const resolved = try resolveDestination(allocator, io, destination);
        if (pathExists(io, destination) or
            pathContains(resolved, resolved_output) or
            pathContains(resolved, source) or
            (initializer != null and pathContains(resolved, initializer.?)) or
            (metadata_output != null and pathContains(resolved, metadata_output.?)) or
            !std.mem.eql(u8, resolved_parent, publication_parent))
        {
            return error.DebugOutputCollision;
        }
        break :blk destination;
    } else null;

    diagnostic.begin(.inputs);
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    const build_root = if (config.engine == null)
        try discoverBuildRoot(allocator, io, environ, cwd, executable_dir, config.build_root)
    else if (config.build_root) |root|
        try resolveAndValidateRoot(allocator, io, cwd, root)
    else
        null;

    diagnostic.begin(.runtime_build);
    const runtime = if (config.engine) |engine_override|
        try externalRuntime(
            allocator,
            io,
            cwd,
            executable_dir,
            config,
            engine_override,
        )
    else
        try buildRuntime(
            allocator,
            io,
            environ,
            cwd,
            build_root.?,
            executable_dir,
            config,
            diagnostic,
        );
    defer if (runtime.cache_lock) |lock| {
        lock.unlock(io);
        lock.close(io);
    };

    diagnostic.begin(.inputs);
    const tools = try resolveTools(
        allocator,
        io,
        environ,
        cwd,
        executable_dir,
        config,
        runtime.component_wit != null,
    );

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const transaction_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.starling-componentize-{s}",
        .{ std.fs.path.basename(output), &random_hex },
    );
    const transaction_dir = try std.fs.path.join(
        allocator,
        &.{ output_parent, transaction_name },
    );
    try Dir.createDirAbsolute(io, transaction_dir, .default_dir);
    defer Dir.cwd().deleteTree(io, transaction_dir) catch {};

    const runtime_args_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "runtime-args.txt" },
    );
    const runtime_args = try renderRuntimeArgs(
        allocator,
        cwd,
        source,
        initializer,
        config,
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = runtime_args_path,
        .data = runtime_args,
    });

    var command_log: std.ArrayList(u8) = .empty;
    const initialized = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "initialized.wasm" },
    );
    var wizer_args: std.ArrayList([]const u8) = .empty;
    wizer_args.append(allocator, tools.wizer.executable) catch @panic("out of memory");
    if (tools.wizer.wasmtime_subcommand) {
        wizer_args.append(allocator, "wizer") catch @panic("out of memory");
        wizer_args.appendSlice(allocator, &.{
            "-S",
            "cli",
            "-S",
            "inherit-env",
            "-W",
            "bulk-memory",
            "-W",
            "unknown-imports-trap",
        }) catch @panic("out of memory");
    } else {
        wizer_args.appendSlice(allocator, &.{
            "--allow-wasi",
            "--init-func",
            "wizer-initialize",
            "--inherit-env",
            "true",
            "--wasm-bulk-memory",
            "true",
        }) catch @panic("out of memory");
    }

    const source_dir = std.fs.path.dirname(source) orelse return error.InvalidPath;
    try addPreopen(allocator, &wizer_args, source_dir);
    if (initializer) |initializer_path| {
        const initializer_dir = std.fs.path.dirname(initializer_path) orelse return error.InvalidPath;
        try addPreopen(allocator, &wizer_args, initializer_dir);
    }
    for (config.preopen_dirs) |preopen| {
        const preopen_abs = try absolutePath(allocator, cwd, preopen);
        try addPreopen(allocator, &wizer_args, preopen_abs);
    }
    wizer_args.appendSlice(allocator, &.{ "-o", initialized, runtime.engine }) catch
        @panic("out of memory");

    var pipeline_env = std.process.Environ.Map.init(allocator);
    try pipeline_env.putAll(environ);
    try pipeline_env.put("WASMTIME_BACKTRACE_DETAILS", "1");
    _ = pipeline_env.swapRemove("STARLINGMONKEY_CONFIG");
    diagnostic.begin(.initialize);
    try runCommand(
        allocator,
        io,
        "wizer",
        wizer_args.items,
        cwd,
        &pipeline_env,
        runtime_args_path,
        config.verbose,
        &command_log,
        diagnostic,
        transaction_dir,
    );

    var stripped: ?[]const u8 = null;
    var embedded: ?[]const u8 = null;
    const candidate = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "candidate.wasm" },
    );
    if (runtime.component_wit) |component_wit| {
        const wabt = tools.wabt.?;
        stripped = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "stripped.wasm" },
        );
        embedded = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "embedded.wasm" },
        );
        diagnostic.begin(.strip);
        try runCommand(
            allocator,
            io,
            "wabt module strip",
            &.{ wabt, "module", "strip", "-o", stripped.?, initialized },
            cwd,
            null,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_dir,
        );
        diagnostic.begin(.embed);
        try runCommand(
            allocator,
            io,
            "wabt component embed",
            &.{
                wabt,
                "component",
                "embed",
                "--world",
                runtime.component_world.?,
                "-o",
                embedded.?,
                component_wit,
                stripped.?,
            },
            cwd,
            null,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_dir,
        );
        const adapter_arg = try std.fmt.allocPrint(
            allocator,
            "wasi_snapshot_preview1={s}",
            .{runtime.adapter},
        );
        diagnostic.begin(.adapt);
        try runCommand(
            allocator,
            io,
            "wabt component new",
            &.{
                wabt,
                "component",
                "new",
                "--adapt",
                adapter_arg,
                "-o",
                candidate,
                embedded.?,
            },
            cwd,
            null,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_dir,
        );
    } else {
        const adapter_arg = try std.fmt.allocPrint(
            allocator,
            "wasi_snapshot_preview1={s}",
            .{runtime.adapter},
        );
        diagnostic.begin(.adapt);
        try runCommand(
            allocator,
            io,
            "wasm-tools component new",
            &.{
                tools.wasm_tools,
                "component",
                "new",
                "--adapt",
                adapter_arg,
                "--output",
                candidate,
                initialized,
            },
            cwd,
            null,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_dir,
        );
    }

    const processed = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "component.wasm" },
    );
    const processed_by = try std.fmt.allocPrint(
        allocator,
        "starling-componentize={s}",
        .{build_options.version},
    );
    diagnostic.begin(.metadata);
    try runCommand(
        allocator,
        io,
        "wasm-tools metadata add",
        &.{
            tools.wasm_tools,
            "metadata",
            "add",
            "--language",
            "JavaScript=",
            "--processed-by",
            processed_by,
            "--output",
            processed,
            candidate,
        },
        cwd,
        null,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        transaction_dir,
    );

    diagnostic.begin(.validate);
    try runCommand(
        allocator,
        io,
        "wasm-tools validate",
        &.{ tools.wasm_tools, "validate", "--features", "all", processed },
        cwd,
        null,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        transaction_dir,
    );
    try requireFile(io, processed);

    diagnostic.begin(.metadata);
    var imports = metadata.Imports{
        .complete = config.wit == null,
        .public = &.{},
        .bindings = &.{},
    };
    if (runtime.bindings) |bindings_path| {
        const bindings_source = try Dir.cwd().readFileAlloc(
            io,
            bindings_path,
            allocator,
            .unlimited,
        );
        imports = metadata.parseBindings(allocator, bindings_source) catch
            return error.InvalidBindingsManifest;
    } else if (config.metadata_out != null and config.wit != null) {
        return error.MetadataUnavailable;
    }

    var metadata_json: ?[]const u8 = null;
    if (metadata_output != null or debug_dir != null) {
        diagnostic.begin(.metadata);
        const document = try buildMetadataDocument(
            allocator,
            io,
            environ,
            config,
            source,
            initializer,
            runtime_args,
            runtime,
            tools,
            processed,
            imports,
        );
        metadata_json = try metadata.render(allocator, document);
    }

    const metadata_staged = if (metadata_output != null) blk: {
        const path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "metadata.json" },
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = metadata_json.?,
        });
        break :blk path;
    } else null;

    const debug_staged = if (debug_dir != null) blk: {
        diagnostic.begin(.debug);
        const directory = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "debug" },
        );
        try Dir.cwd().createDirPath(io, directory);
        var debug_dir_handle = try Dir.openDirAbsolute(
            io,
            directory,
            .{ .follow_symlinks = false },
        );
        defer debug_dir_handle.close(io);
        const command_log_path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "commands.txt" },
        );
        const stable_command_log = try std.mem.replaceOwned(
            u8,
            allocator,
            command_log.items,
            transaction_dir,
            "<transaction>",
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = command_log_path,
            .data = stable_command_log,
        });
        try copyDebugFile(io, runtime_args_path, debug_dir_handle, "runtime-args.txt");
        try copyDebugFile(io, initialized, debug_dir_handle, "initialized.wasm");
        if (stripped) |path| try copyDebugFile(io, path, debug_dir_handle, "stripped.wasm");
        if (embedded) |path| try copyDebugFile(io, path, debug_dir_handle, "embedded.wasm");
        try copyDebugFile(io, processed, debug_dir_handle, "component.wasm");
        if (runtime.bindings) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "component-bindings.zig");
        }
        try copyDebugFile(io, command_log_path, debug_dir_handle, "commands.txt");
        if (metadata_json) |json| {
            try debug_dir_handle.writeFile(io, .{
                .sub_path = "metadata.json",
                .data = json,
            });
            try debug_dir_handle.writeFile(io, .{
                .sub_path = "imports.json",
                .data = try metadata.renderImports(allocator, imports),
            });
        }
        break :blk directory;
    } else null;

    var candidate_file = try Dir.openFileAbsolute(io, processed, .{});
    defer candidate_file.close(io);
    try candidate_file.sync(io);
    if (metadata_staged) |path| {
        var metadata_file = try Dir.openFileAbsolute(io, path, .{});
        defer metadata_file.close(io);
        try metadata_file.sync(io);
    }

    diagnostic.begin(.publish);
    try publishArtifacts(
        allocator,
        io,
        transaction_dir,
        processed,
        output,
        metadata_staged,
        metadata_output,
        debug_staged,
        debug_dir,
    );
    diagnostic.reportSuccess(source, output);
}

fn externalRuntime(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    engine_override: []const u8,
) !Runtime {
    if (config.disable_features.len != 0 or
        config.enable_features.len != 0 or
        config.use_debug_build)
    {
        return error.IncompatibleEngineOptions;
    }
    const engine = try absolutePath(allocator, cwd, engine_override);
    try requireFile(io, engine);
    const adapter = if (config.preview2_adapter) |path|
        try absolutePath(allocator, cwd, path)
    else
        try siblingOrName(allocator, io, executable_dir, "preview1-adapter.wasm", "preview1-adapter.wasm");
    try requireFile(io, adapter);
    const component_wit = if (config.component_wit orelse config.wit) |path|
        try absolutePath(allocator, cwd, path)
    else
        null;
    const dispatch_wit_path = if (config.wit) |path|
        try absolutePath(allocator, cwd, path)
    else
        null;
    const dispatch_wit_digest = if (dispatch_wit_path) |path|
        try digestWitDirectory(allocator, io, path)
    else
        null;
    const component_wit_digest = if (component_wit) |path|
        if (dispatch_wit_path != null and std.mem.eql(u8, path, dispatch_wit_path.?))
            dispatch_wit_digest
        else
            try digestWitDirectory(allocator, io, path)
    else
        null;
    return .{
        .engine = engine,
        .adapter = adapter,
        .component_wit = component_wit,
        .component_world = config.component_world_name orelse config.world_name,
        .bindings = null,
        .dispatch_wit_digest = dispatch_wit_digest,
        .component_wit_digest = component_wit_digest,
        .zig = null,
        .cache_lock = null,
    };
}

fn buildRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    build_root: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    diagnostic: *diagnostics.Context,
) !Runtime {
    const cache_dir = if (config.cache_dir) |path|
        try absolutePath(allocator, cwd, path)
    else
        try std.fs.path.join(
            allocator,
            &.{ build_root, ".zig-cache", "starling-componentizer" },
        );
    try Dir.cwd().createDirPath(io, cache_dir);

    var dispatch_wit: ?StagedWit = null;
    var component_wit: ?StagedWit = null;
    if (config.wit) |path| {
        dispatch_wit = try stageWit(allocator, io, cwd, build_root, path);
        component_wit = if (config.component_wit) |component_path|
            try stageWit(allocator, io, cwd, build_root, component_path)
        else
            dispatch_wit;
    }

    const key = try runtimeKey(
        allocator,
        config,
        if (dispatch_wit) |wit| wit.digest else null,
        if (component_wit) |wit| wit.digest else null,
    );
    const prefix = try std.fs.path.join(
        allocator,
        &.{ cache_dir, "runtimes", key },
    );
    const lock_dir = try std.fs.path.join(allocator, &.{ cache_dir, "locks" });
    try Dir.cwd().createDirPath(io, lock_dir);
    const lock_path = try std.fs.path.join(
        allocator,
        &.{ lock_dir, try std.fmt.allocPrint(allocator, "{s}.lock", .{key}) },
    );
    const lock_file = try Dir.createFileAbsolute(io, lock_path, .{ .truncate = false });
    errdefer lock_file.close(io);
    try lock_file.lock(io, .exclusive);
    errdefer lock_file.unlock(io);

    const zig = if (config.zig_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("ZIG")) |path|
        try absolutePath(allocator, cwd, path)
    else
        build_options.zig_exe;

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(allocator, &.{
        zig,
        "build",
        "--prefix",
        prefix,
        if (config.use_debug_build) "-Doptimize=Debug" else "-Doptimize=ReleaseSmall",
    }) catch @panic("out of memory");
    if (dispatch_wit) |wit| {
        argv.appendSlice(allocator, &.{
            try std.fmt.allocPrint(allocator, "-Dcomponent-wit={s}", .{component_wit.?.relative}),
            try std.fmt.allocPrint(allocator, "-Dcomponent-world={s}", .{
                config.component_world_name orelse config.world_name.?,
            }),
            try std.fmt.allocPrint(allocator, "-Ddispatch-wit={s}", .{wit.relative}),
            try std.fmt.allocPrint(allocator, "-Ddispatch-world={s}", .{config.world_name.?}),
        }) catch @panic("out of memory");
    }
    if (config.disable_features.len != 0) {
        argv.append(
            allocator,
            try std.fmt.allocPrint(
                allocator,
                "-Ddisable-features={s}",
                .{try joinComma(allocator, config.disable_features)},
            ),
        ) catch @panic("out of memory");
    }
    if (config.enable_features.len != 0) {
        argv.append(
            allocator,
            try std.fmt.allocPrint(
                allocator,
                "-Denable-features={s}",
                .{try joinComma(allocator, config.enable_features)},
            ),
        ) catch @panic("out of memory");
    }
    const needs_bindings = (config.debug_bindings or config.metadata_out != null) and
        dispatch_wit != null;
    if (needs_bindings) {
        argv.append(allocator, "-Dcomponentizer-debug-bindings=true") catch
            @panic("out of memory");
    }

    const zig_global_cache = try std.fs.path.join(
        allocator,
        &.{ cache_dir, "zig-global-cache" },
    );
    try Dir.cwd().createDirPath(io, zig_global_cache);
    var build_env = std.process.Environ.Map.init(allocator);
    try build_env.putAll(environ);
    try build_env.put("ZIG_GLOBAL_CACHE_DIR", zig_global_cache);
    _ = build_env.swapRemove("ZIG_LOCAL_CACHE_DIR");
    var command_log: std.ArrayList(u8) = .empty;
    try runCommand(
        allocator,
        io,
        "zig build runtime",
        argv.items,
        build_root,
        &build_env,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        null,
    );

    const engine = try std.fs.path.join(
        allocator,
        &.{ prefix, "bin", "starling-raw.wasm" },
    );
    try requireFile(io, engine);
    const adapter = if (config.preview2_adapter) |path|
        try absolutePath(allocator, cwd, path)
    else blk: {
        const installed = try std.fs.path.join(
            allocator,
            &.{ prefix, "bin", "preview1-adapter.wasm" },
        );
        if (pathExists(io, installed)) break :blk installed;
        break :blk try siblingOrName(
            allocator,
            io,
            executable_dir,
            "preview1-adapter.wasm",
            "preview1-adapter.wasm",
        );
    };
    try requireFile(io, adapter);
    const bindings = if (needs_bindings) blk: {
        const path = try std.fs.path.join(
            allocator,
            &.{ prefix, "bin", "component-bindings.zig" },
        );
        try requireFile(io, path);
        break :blk path;
    } else null;

    return .{
        .engine = engine,
        .adapter = adapter,
        .component_wit = if (component_wit) |wit| wit.absolute else null,
        .component_world = config.component_world_name orelse config.world_name,
        .bindings = bindings,
        .dispatch_wit_digest = if (dispatch_wit) |wit| wit.digest else null,
        .component_wit_digest = if (component_wit) |wit| wit.digest else null,
        .zig = zig,
        .cache_lock = lock_file,
    };
}

fn resolveTools(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    needs_wabt: bool,
) !Tools {
    const wizer = if (config.wizer_bin) |path|
        WizerTool{
            .executable = try absolutePath(allocator, cwd, path),
            .wasmtime_subcommand = false,
        }
    else if (config.wasmtime_bin) |path|
        WizerTool{
            .executable = try absolutePath(allocator, cwd, path),
            .wasmtime_subcommand = true,
        }
    else if (environ.get("WIZER_BIN")) |path|
        WizerTool{
            .executable = try absolutePath(allocator, cwd, path),
            .wasmtime_subcommand = false,
        }
    else if (environ.get("WASMTIME_BIN")) |path|
        WizerTool{
            .executable = try absolutePath(allocator, cwd, path),
            .wasmtime_subcommand = true,
        }
    else blk: {
        const standalone = try std.fs.path.join(
            allocator,
            &.{ executable_dir, "wizer" },
        );
        if (pathExists(io, standalone)) {
            break :blk WizerTool{
                .executable = standalone,
                .wasmtime_subcommand = false,
            };
        }
        break :blk WizerTool{
            .executable = try siblingOrName(
                allocator,
                io,
                executable_dir,
                "wasmtime",
                "wasmtime",
            ),
            .wasmtime_subcommand = true,
        };
    };
    const wasm_tools = if (config.wasm_tools_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("WASM_TOOLS_BIN")) |path|
        try absolutePath(allocator, cwd, path)
    else
        try siblingOrName(
            allocator,
            io,
            executable_dir,
            "wasm-tools",
            "wasm-tools",
        );
    const wabt = if (!needs_wabt)
        null
    else if (config.wabt_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("WABT")) |path|
        try absolutePath(allocator, cwd, path)
    else
        try siblingOrName(allocator, io, executable_dir, "wabt", "wabt");
    return .{ .wizer = wizer, .wabt = wabt, .wasm_tools = wasm_tools };
}

fn discoverBuildRoot(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    executable_dir: []const u8,
    override: ?[]const u8,
) ![]const u8 {
    if (override) |path| return resolveAndValidateRoot(allocator, io, cwd, path);
    if (environ.get("STARLINGMONKEY_BUILD_ROOT")) |path| {
        return resolveAndValidateRoot(allocator, io, cwd, path);
    }
    if (try findBuildRoot(allocator, io, cwd)) |root| return root;
    if (try findBuildRoot(allocator, io, executable_dir)) |root| return root;
    return error.InvalidBuildRoot;
}

fn resolveAndValidateRoot(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    path: []const u8,
) ![]const u8 {
    const root = try absolutePath(allocator, cwd, path);
    if (!isBuildRoot(allocator, io, root)) return error.InvalidBuildRoot;
    return root;
}

fn findBuildRoot(
    allocator: Allocator,
    io: Io,
    start: []const u8,
) !?[]const u8 {
    var candidate = try allocator.dupe(u8, start);
    while (true) {
        if (isBuildRoot(allocator, io, candidate)) return candidate;
        const parent = std.fs.path.dirname(candidate) orelse return null;
        if (std.mem.eql(u8, parent, candidate)) return null;
        candidate = try allocator.dupe(u8, parent);
    }
}

fn isBuildRoot(allocator: Allocator, io: Io, candidate: []const u8) bool {
    const build_zig = std.fs.path.join(allocator, &.{ candidate, "build.zig" }) catch
        return false;
    const build_zon = std.fs.path.join(allocator, &.{ candidate, "build.zig.zon" }) catch
        return false;
    const runtime = std.fs.path.join(allocator, &.{ candidate, "runtime", "js.cpp" }) catch
        return false;
    const componentizer = std.fs.path.join(
        allocator,
        &.{ candidate, "tools", "componentizer", "main.zig" },
    ) catch return false;
    return pathExists(io, build_zig) and
        pathExists(io, build_zon) and
        pathExists(io, runtime) and
        pathExists(io, componentizer);
}

fn stageWit(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    build_root: []const u8,
    input_path: []const u8,
) !StagedWit {
    const source_path = try absolutePath(allocator, cwd, input_path);
    var source_dir = try Dir.openDirAbsolute(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                if (!std.mem.endsWith(u8, entry.path, ".wit")) continue;
                files.append(allocator, try allocator.dupe(u8, entry.path)) catch
                    @panic("out of memory");
            },
            else => return error.UnsupportedWitEntry,
        }
    }
    if (files.items.len == 0) return error.MissingWitFiles;
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var contents: std.ArrayList([]const u8) = .empty;
    for (files.items) |relative| {
        hasher.update(relative);
        hasher.update(&.{0});
        const data = try source_dir.readFileAlloc(
            io,
            relative,
            allocator,
            .unlimited,
        );
        contents.append(allocator, data) catch @panic("out of memory");
        hasher.update(data);
        hasher.update(&.{0xff});
    }
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest_bytes);
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    const digest = try allocator.dupe(u8, &digest_hex);
    const stage_path = try std.fs.path.join(
        allocator,
        &.{
            build_root,
            ".zig-cache",
            "starling-componentizer",
            "inputs",
            digest,
        },
    );
    const marker = try std.fs.path.join(allocator, &.{ stage_path, ".complete" });
    const input_lock_dir = try std.fs.path.join(
        allocator,
        &.{
            build_root,
            ".zig-cache",
            "starling-componentizer",
            "input-locks",
        },
    );
    try Dir.cwd().createDirPath(io, input_lock_dir);
    const input_lock_path = try std.fs.path.join(
        allocator,
        &.{ input_lock_dir, try std.fmt.allocPrint(allocator, "{s}.lock", .{digest}) },
    );
    const input_lock = try Dir.createFileAbsolute(io, input_lock_path, .{ .truncate = false });
    defer input_lock.close(io);
    try input_lock.lock(io, .exclusive);
    defer input_lock.unlock(io);
    if (!pathExists(io, marker)) {
        try Dir.cwd().deleteTree(io, stage_path);
        try Dir.cwd().createDirPath(io, stage_path);
        for (files.items, contents.items) |relative, data| {
            const destination = try std.fs.path.join(allocator, &.{ stage_path, relative });
            const destination_parent = std.fs.path.dirname(destination) orelse
                return error.InvalidPath;
            try Dir.cwd().createDirPath(io, destination_parent);
            try Dir.cwd().writeFile(io, .{
                .sub_path = destination,
                .data = data,
            });
        }
        try Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = digest });
    }
    const relative_stage = try std.fs.path.relative(
        allocator,
        build_root,
        null,
        build_root,
        stage_path,
    );
    return .{
        .absolute = stage_path,
        .relative = relative_stage,
        .digest = digest,
    };
}

fn runtimeKey(
    allocator: Allocator,
    config: *const cli.Config,
    dispatch_digest: ?[]const u8,
    component_digest: ?[]const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "schema", "1");
    hashField(&hasher, "version", build_options.version);
    hashField(&hasher, "optimize", if (config.use_debug_build) "Debug" else "ReleaseSmall");
    hashField(&hasher, "dispatch-wit", dispatch_digest orelse "");
    hashField(&hasher, "component-wit", component_digest orelse "");
    hashField(&hasher, "dispatch-world", config.world_name orelse "");
    hashField(&hasher, "component-world", config.component_world_name orelse config.world_name orelse "");
    for (config.disable_features) |feature| hashField(&hasher, "disable", feature);
    for (config.enable_features) |feature| hashField(&hasher, "enable", feature);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn hashField(
    hasher: *std.crypto.hash.sha2.Sha256,
    name: []const u8,
    value: []const u8,
) void {
    hasher.update(name);
    hasher.update(&.{0});
    hasher.update(value);
    hasher.update(&.{0xff});
}

fn digestWitDirectory(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) ![]const u8 {
    var source_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                if (!std.mem.endsWith(u8, entry.path, ".wit")) continue;
                files.append(allocator, try allocator.dupe(u8, entry.path)) catch
                    @panic("out of memory");
            },
            else => return error.UnsupportedWitEntry,
        }
    }
    if (files.items.len == 0) return error.MissingWitFiles;
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |relative| {
        hasher.update(relative);
        hasher.update(&.{0});
        const data = try source_dir.readFileAlloc(
            io,
            relative,
            allocator,
            .unlimited,
        );
        hasher.update(data);
        hasher.update(&.{0xff});
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn buildMetadataDocument(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    config: *const cli.Config,
    source: []const u8,
    initializer: ?[]const u8,
    runtime_args: []const u8,
    runtime: Runtime,
    tools: Tools,
    component: []const u8,
    imports: metadata.Imports,
) !metadata.Document {
    var features: std.ArrayList(metadata.Feature) = .empty;
    var feature_fields: std.ArrayList([2][]const u8) = .empty;
    for (cli.feature_names) |name| {
        var enabled = true;
        for (config.disable_features) |disabled| {
            if (std.mem.eql(u8, name, disabled)) enabled = false;
        }
        for (config.enable_features) |explicitly_enabled| {
            if (std.mem.eql(u8, name, explicitly_enabled)) enabled = true;
        }
        features.append(allocator, .{ .name = name, .enabled = enabled }) catch
            @panic("out of memory");
        feature_fields.append(
            allocator,
            .{ name, if (enabled) "1" else "0" },
        ) catch @panic("out of memory");
    }
    const features_hash = try metadata.hashFields(allocator, feature_fields.items);

    const dispatch_world = metadata.World{
        .name = config.world_name,
        .wit_sha256 = runtime.dispatch_wit_digest,
    };
    const component_world = metadata.World{
        .name = config.component_world_name orelse config.world_name,
        .wit_sha256 = runtime.component_wit_digest,
    };
    const world_fields = [_][2][]const u8{
        .{ "dispatch-name", dispatch_world.name orelse "" },
        .{ "dispatch-wit", dispatch_world.wit_sha256 orelse "" },
        .{ "component-name", component_world.name orelse "" },
        .{ "component-wit", component_world.wit_sha256 orelse "" },
    };

    var tool_values: std.ArrayList(metadata.Tool) = .empty;
    var tool_fields: std.ArrayList([2][]const u8) = .empty;
    if (runtime.zig) |zig| {
        try appendToolHash(
            allocator,
            io,
            environ,
            &tool_values,
            &tool_fields,
            "zig",
            zig,
        );
    }
    try appendToolHash(
        allocator,
        io,
        environ,
        &tool_values,
        &tool_fields,
        if (tools.wizer.wasmtime_subcommand) "wasmtime-wizer" else "wizer",
        tools.wizer.executable,
    );
    if (tools.wabt) |wabt| {
        try appendToolHash(
            allocator,
            io,
            environ,
            &tool_values,
            &tool_fields,
            "wabt",
            wabt,
        );
    }
    try appendToolHash(
        allocator,
        io,
        environ,
        &tool_values,
        &tool_fields,
        "wasm-tools",
        tools.wasm_tools,
    );

    return .{
        .processed_by = .{ .version = build_options.version },
        .component_sha256 = try metadata.sha256File(allocator, io, component),
        .imports_complete = imports.complete,
        .imports = imports.public,
        .bindings = imports.bindings,
        .provenance = .{
            .dispatch_world = dispatch_world,
            .component_world = component_world,
            .worlds_sha256 = try metadata.hashFields(allocator, &world_fields),
            .features = features.toOwnedSlice(allocator) catch @panic("out of memory"),
            .features_sha256 = features_hash,
            .tools = tool_values.toOwnedSlice(allocator) catch @panic("out of memory"),
            .tools_sha256 = try metadata.hashFields(allocator, tool_fields.items),
            .inputs = .{
                .source_sha256 = try metadata.sha256File(allocator, io, source),
                .initializer_sha256 = if (initializer) |path|
                    try metadata.sha256File(allocator, io, path)
                else
                    null,
                .runtime_arguments_sha256 = try metadata.sha256Bytes(
                    allocator,
                    runtime_args,
                ),
                .engine_sha256 = try metadata.sha256File(
                    allocator,
                    io,
                    runtime.engine,
                ),
                .preview2_adapter_sha256 = try metadata.sha256File(
                    allocator,
                    io,
                    runtime.adapter,
                ),
            },
        },
    };
}

fn appendToolHash(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    tools: *std.ArrayList(metadata.Tool),
    fields: *std.ArrayList([2][]const u8),
    name: []const u8,
    executable: []const u8,
) !void {
    const path = try resolveExecutable(allocator, io, environ, executable);
    const digest = try metadata.sha256File(allocator, io, path);
    tools.append(allocator, .{ .name = name, .sha256 = digest }) catch
        @panic("out of memory");
    fields.append(allocator, .{ name, digest }) catch @panic("out of memory");
}

fn resolveExecutable(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    executable: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(executable)) {
        try requireFile(io, executable);
        return allocator.dupe(u8, executable);
    }
    if (std.mem.indexOfScalar(u8, executable, std.fs.path.sep) != null) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        const path = try absolutePath(allocator, cwd, executable);
        try requireFile(io, path);
        return path;
    }
    const path_value = environ.get("PATH") orelse return error.MissingBuildArtifact;
    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, executable });
        if (pathExists(io, candidate)) return candidate;
    }
    return error.MissingBuildArtifact;
}

fn publishArtifacts(
    allocator: Allocator,
    io: Io,
    transaction_dir: []const u8,
    component_staged: []const u8,
    component_output: []const u8,
    metadata_staged: ?[]const u8,
    metadata_output: ?[]const u8,
    debug_staged: ?[]const u8,
    debug_output: ?[]const u8,
) !void {
    const component_backup = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "previous-component" },
    );
    const metadata_backup = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "previous-metadata" },
    );
    var component_backed_up = false;
    var metadata_backed_up = false;
    var component_published = false;
    var metadata_published = false;
    var debug_published = false;

    errdefer {
        if (debug_published) {
            Dir.cwd().deleteTree(io, debug_output.?) catch {};
        }
        if (metadata_published) {
            Dir.cwd().deleteFile(io, metadata_output.?) catch {};
        }
        if (component_published) {
            Dir.cwd().deleteFile(io, component_output) catch {};
        }
        if (metadata_backed_up) {
            Dir.renameAbsolute(metadata_backup, metadata_output.?, io) catch {};
        }
        if (component_backed_up) {
            Dir.renameAbsolute(component_backup, component_output, io) catch {};
        }
    }

    if (pathExists(io, component_output)) {
        try Dir.renameAbsolute(component_output, component_backup, io);
        component_backed_up = true;
    }
    if (metadata_output) |path| {
        if (pathExists(io, path)) {
            try Dir.renameAbsolute(path, metadata_backup, io);
            metadata_backed_up = true;
        }
    }

    try Dir.renameAbsolute(component_staged, component_output, io);
    component_published = true;
    if (metadata_staged) |path| {
        try Dir.renameAbsolute(path, metadata_output.?, io);
        metadata_published = true;
    }
    if (debug_staged) |path| {
        try Dir.renameAbsolute(path, debug_output.?, io);
        debug_published = true;
    }
}

fn renderRuntimeArgs(
    allocator: Allocator,
    cwd: []const u8,
    source: []const u8,
    initializer: ?[]const u8,
    config: *const cli.Config,
) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    if (config.runtime_args) |raw| {
        try validateRuntimeText(raw);
        output.appendSlice(allocator, raw) catch @panic("out of memory");
    }
    for (config.runtime_argv) |arg| try appendRuntimeArg(allocator, &output, arg);
    if (config.initializer_script_path) |path| {
        try appendRuntimeArg(allocator, &output, "--initializer-script-path");
        try appendRuntimeArg(
            allocator,
            &output,
            initializer orelse try absolutePath(allocator, cwd, path),
        );
    }
    if (config.strip_path_prefix) |prefix| {
        try appendRuntimeArg(allocator, &output, "--strip-path-prefix");
        try appendRuntimeArg(allocator, &output, prefix);
    }
    if (config.wpt_mode) try appendRuntimeArg(allocator, &output, "--wpt-mode");
    if (config.init_location) |location| {
        try appendRuntimeArg(allocator, &output, "--init-location");
        try appendRuntimeArg(allocator, &output, location);
    }
    if (config.js_heap_limit_mib) |limit| {
        try appendRuntimeArg(allocator, &output, "--js-heap-limit-mib");
        try appendRuntimeArg(
            allocator,
            &output,
            try std.fmt.allocPrint(allocator, "{d}", .{limit}),
        );
    }
    if (config.verbose or config.enable_wizer_logging) {
        try appendRuntimeArg(allocator, &output, "--verbose");
    }
    if (config.legacy_script) try appendRuntimeArg(allocator, &output, "--legacy-script");
    try appendRuntimeArg(allocator, &output, source);
    output.append(allocator, '\n') catch @panic("out of memory");
    return output.toOwnedSlice(allocator);
}

fn appendRuntimeArg(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    arg: []const u8,
) !void {
    if (arg.len == 0) return error.EmptyRuntimeArgument;
    try validateRuntimeText(arg);
    if (std.mem.indexOfScalar(u8, arg, '"') != null) {
        return error.UnrepresentableRuntimeArgument;
    }
    if (output.items.len != 0 and output.items[output.items.len - 1] != ' ') {
        output.append(allocator, ' ') catch @panic("out of memory");
    }
    const needs_quotes = std.mem.indexOfAny(u8, arg, " \t") != null;
    if (needs_quotes and std.mem.endsWith(u8, arg, "\\")) {
        return error.UnrepresentableRuntimeArgument;
    }
    if (needs_quotes) output.append(allocator, '"') catch @panic("out of memory");
    output.appendSlice(allocator, arg) catch @panic("out of memory");
    if (needs_quotes) output.append(allocator, '"') catch @panic("out of memory");
}

fn validateRuntimeText(text: []const u8) !void {
    if (std.mem.indexOfAny(u8, text, "\x00\x0b\x0c\r\n") != null) {
        return error.UnrepresentableRuntimeArgument;
    }
}

fn runCommand(
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    stdin_path: ?[]const u8,
    verbose: bool,
    command_log: *std.ArrayList(u8),
    diagnostic: *diagnostics.Context,
    redact_path: ?[]const u8,
) !void {
    command_log.appendSlice(allocator, stage) catch @panic("out of memory");
    command_log.append(allocator, '\n') catch @panic("out of memory");
    for (argv) |arg| {
        command_log.appendSlice(allocator, "  ") catch @panic("out of memory");
        command_log.appendSlice(allocator, arg) catch @panic("out of memory");
        command_log.append(allocator, '\n') catch @panic("out of memory");
    }
    if (verbose and diagnostic.format == .human) {
        const header = try std.fmt.allocPrint(allocator, "[{s}]\n", .{stage});
        try File.stderr().writeStreamingAll(io, header);
        for (argv) |arg| {
            const line = try std.fmt.allocPrint(allocator, "  {s}\n", .{arg});
            try File.stderr().writeStreamingAll(io, line);
        }
    }

    const stdin_file: ?File = if (stdin_path) |path|
        try Dir.openFileAbsolute(io, path, .{})
    else
        null;
    defer if (stdin_file) |file| file.close(io);
    const stdin_behavior: std.process.SpawnOptions.StdIo = if (stdin_file) |file|
        .{ .file = file }
    else
        .ignore;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environ,
        .stdin = stdin_behavior,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: File.MultiReader.Buffer(2) = undefined;
    var multi_reader: File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();
    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |read_err| return read_err,
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);
    if (!term.success()) {
        diagnostic.commandFailed(stage, term, stderr, redact_path);
        return error.CommandFailed;
    }
    if (diagnostic.format == .human) {
        try File.stdout().writeStreamingAll(io, stdout);
        try File.stderr().writeStreamingAll(io, stderr);
    }
}

fn addPreopen(
    allocator: Allocator,
    args: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    try validateArgument(path);
    args.appendSlice(allocator, &.{ "--dir", path }) catch @panic("out of memory");
}

fn joinComma(allocator: Allocator, values: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, ",", values);
}

fn siblingOrName(
    allocator: Allocator,
    io: Io,
    executable_dir: []const u8,
    sibling: []const u8,
    fallback: []const u8,
) ![]const u8 {
    const candidate = try std.fs.path.join(allocator, &.{ executable_dir, sibling });
    if (pathExists(io, candidate)) return candidate;
    return allocator.dupe(u8, fallback);
}

fn defaultOutputPath(
    allocator: Allocator,
    cwd: []const u8,
    source: []const u8,
) ![]const u8 {
    const basename = std.fs.path.basename(source);
    const stem = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot|
        basename[0..dot]
    else
        basename;
    return std.fs.path.join(
        allocator,
        &.{ cwd, try std.fmt.allocPrint(allocator, "{s}.wasm", .{stem}) },
    );
}

fn absolutePath(
    allocator: Allocator,
    cwd: []const u8,
    path: []const u8,
) ![]const u8 {
    try validateArgument(path);
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn validateArgument(value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\x00\r\n") != null) {
        return error.InvalidPath;
    }
}

fn pathExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn requireFile(io: Io, path: []const u8) !void {
    const stat = Dir.cwd().statFile(io, path, .{}) catch return error.MissingBuildArtifact;
    if (stat.kind != .file) return error.MissingBuildArtifact;
}

fn requireDestinationFileOrMissing(
    io: Io,
    path: []const u8,
    invalid_error: anyerror,
) !void {
    const stat = Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return invalid_error;
}

fn resolveExistingFile(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    path: []const u8,
) ![]const u8 {
    const absolute = try absolutePath(allocator, cwd, path);
    try requireFile(io, absolute);
    return Dir.realPathFileAbsoluteAlloc(io, absolute, allocator);
}

fn copyDebugFile(
    io: Io,
    source: []const u8,
    debug_dir: Dir,
    basename: []const u8,
) !void {
    try Dir.cwd().copyFile(source, debug_dir, basename, io, .{});
}

fn resolveDestination(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) ![]const u8 {
    return Dir.realPathFileAbsoluteAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            const basename = std.fs.path.basename(path);
            const resolved_parent = try Dir.realPathFileAbsoluteAlloc(io, parent, allocator);
            return std.fs.path.join(allocator, &.{ resolved_parent, basename });
        },
        else => return err,
    };
}

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, child)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (std.mem.endsWith(u8, parent, &.{std.fs.path.sep})) return true;
    return child.len > parent.len and child[parent.len] == std.fs.path.sep;
}

test "runtime arguments preserve paths with spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var config = cli.Config{
        .source = "source.js",
        .runtime_argv = &.{"--enable-script-debugging"},
        .initializer_script_path = "init script.js",
        .js_heap_limit_mib = 256,
    };
    const rendered = try renderRuntimeArgs(
        allocator,
        "/work/path with spaces",
        "/work/path with spaces/source.js",
        null,
        &config,
    );
    try std.testing.expectEqualStrings(
        "--enable-script-debugging --initializer-script-path " ++
            "\"/work/path with spaces/init script.js\" --js-heap-limit-mib 256 " ++
            "\"/work/path with spaces/source.js\"\n",
        rendered,
    );
}

test "runtime arguments reject line injection" {
    var config = cli.Config{
        .source = "source.js",
        .runtime_args = "--verbose\nother",
    };
    try std.testing.expectError(
        error.UnrepresentableRuntimeArgument,
        renderRuntimeArgs(
            std.testing.allocator,
            "/work",
            "/work/source.js",
            null,
            &config,
        ),
    );
}

test "runtime arguments reject parser-ambiguous whitespace and quoting" {
    var control_whitespace = cli.Config{
        .source = "source.js",
        .runtime_argv = &.{"two\x0bvalues"},
    };
    try std.testing.expectError(
        error.UnrepresentableRuntimeArgument,
        renderRuntimeArgs(
            std.testing.allocator,
            "/work",
            "/work/source.js",
            null,
            &control_whitespace,
        ),
    );

    var trailing_backslash = cli.Config{
        .source = "source.js",
        .runtime_argv = &.{"two values\\"},
    };
    try std.testing.expectError(
        error.UnrepresentableRuntimeArgument,
        renderRuntimeArgs(
            std.testing.allocator,
            "/work",
            "/work/source.js",
            null,
            &trailing_backslash,
        ),
    );
}

test "runtime cache key excludes JavaScript source" {
    var config = cli.Config{
        .source = "first.js",
        .world_name = "world",
        .component_world_name = "component-world",
        .disable_features = &.{"http"},
    };
    const first = try runtimeKey(std.testing.allocator, &config, "a", "b");
    defer std.testing.allocator.free(first);
    config.source = "second.js";
    const second = try runtimeKey(std.testing.allocator, &config, "a", "b");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}
