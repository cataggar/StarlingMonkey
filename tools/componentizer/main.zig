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
    InvalidToolManifest,
    MetadataUnavailable,
    MissingBuildArtifact,
    MissingWitFiles,
    UnrepresentableRuntimeArgument,
    UnsupportedWitEntry,
};

const StagedWit = struct {
    absolute: []const u8,
    digest: []const u8,
};

const Snapshot = struct {
    path: []const u8,
    digest: []const u8,
};

const Runtime = struct {
    engine: Snapshot,
    adapter: Snapshot,
    component_wit: ?[]const u8,
    component_world: ?[]const u8,
    bindings: ?[]const u8,
    dispatch_wit_digest: ?[]const u8,
    component_wit_digest: ?[]const u8,
    features_known: bool,
    zig: ?Snapshot,
    build_tools: []const metadata.Tool,
    cache_lock: ?File,
};

const WizerTool = struct {
    executable: Snapshot,
    wasmtime_subcommand: bool,
};

const Tools = struct {
    wizer: WizerTool,
    wabt: ?Snapshot,
    wasm_tools: Snapshot,
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
        if (try pathKindNoFollow(io, destination)) |kind| {
            if (kind != .directory) return error.DebugOutputCollision;
        }
        const resolved_parent = try Dir.realPathFileAbsoluteAlloc(io, parent, allocator);
        const resolved = try resolveDestination(allocator, io, destination);
        if (pathContains(resolved, resolved_output) or
            pathContains(resolved, source) or
            (initializer != null and pathContains(resolved, initializer.?)) or
            (metadata_output != null and pathContains(resolved, metadata_output.?)) or
            !std.mem.eql(u8, resolved_parent, publication_parent))
        {
            return error.DebugOutputCollision;
        }
        break :blk destination;
    } else null;

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
    var transaction_safe_to_remove = true;
    defer if (transaction_safe_to_remove) {
        Dir.cwd().deleteTree(io, transaction_dir) catch {};
    };

    const source_snapshot = try snapshotAdjacent(
        allocator,
        io,
        source,
        "source",
        &random_hex,
    );
    defer Dir.deleteFileAbsolute(io, source_snapshot.path) catch {};
    const initializer_snapshot = if (initializer) |path|
        try snapshotAdjacent(allocator, io, path, "initializer", &random_hex)
    else
        null;
    defer if (initializer_snapshot) |snapshot| {
        Dir.deleteFileAbsolute(io, snapshot.path) catch {};
    };

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
            transaction_dir,
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
            transaction_dir,
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
        transaction_dir,
    );

    const runtime_args_path = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "runtime-args.txt" },
    );
    const provenance_runtime_args = try renderRuntimeArgs(
        allocator,
        cwd,
        source,
        initializer,
        config,
    );
    const runtime_args = try renderRuntimeArgs(
        allocator,
        cwd,
        source_snapshot.path,
        if (initializer_snapshot) |snapshot| snapshot.path else null,
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
    wizer_args.append(allocator, tools.wizer.executable.path) catch @panic("out of memory");
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

    const source_dir = std.fs.path.dirname(source_snapshot.path) orelse return error.InvalidPath;
    try addPreopen(allocator, &wizer_args, source_dir);
    if (initializer_snapshot) |snapshot| {
        const initializer_path = snapshot.path;
        const initializer_dir = std.fs.path.dirname(initializer_path) orelse return error.InvalidPath;
        try addPreopen(allocator, &wizer_args, initializer_dir);
    }
    for (config.preopen_dirs) |preopen| {
        const preopen_abs = try absolutePath(allocator, cwd, preopen);
        try addPreopen(allocator, &wizer_args, preopen_abs);
    }
    wizer_args.appendSlice(allocator, &.{ "-o", initialized, runtime.engine.path }) catch
        @panic("out of memory");

    var pipeline_env = std.process.Environ.Map.init(allocator);
    try copyEnvironment(&pipeline_env, environ);
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
        const wabt = tools.wabt.?.path;
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
            .{runtime.adapter.path},
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
            .{runtime.adapter.path},
        );
        diagnostic.begin(.adapt);
        try runCommand(
            allocator,
            io,
            "wasm-tools component new",
            &.{
                tools.wasm_tools.path,
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
            tools.wasm_tools.path,
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
        &.{ tools.wasm_tools.path, "validate", "--features", "all", processed },
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
            config,
            source_snapshot,
            initializer_snapshot,
            provenance_runtime_args,
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
        &transaction_safe_to_remove,
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
    transaction_dir: []const u8,
) !Runtime {
    if (config.disable_features.len != 0 or
        config.enable_features.len != 0 or
        config.use_debug_build)
    {
        return error.IncompatibleEngineOptions;
    }
    const engine_source = try absolutePath(allocator, cwd, engine_override);
    const engine = try snapshotFile(
        allocator,
        io,
        engine_source,
        try std.fs.path.join(allocator, &.{ transaction_dir, "engine.wasm" }),
    );
    const adapter_source = if (config.preview2_adapter) |path|
        try absolutePath(allocator, cwd, path)
    else
        try siblingOrName(allocator, io, executable_dir, "preview1-adapter.wasm", "preview1-adapter.wasm");
    const adapter = try snapshotFile(
        allocator,
        io,
        adapter_source,
        try std.fs.path.join(allocator, &.{ transaction_dir, "preview2-adapter.wasm" }),
    );
    const component_wit_source = if (config.component_wit orelse config.wit) |path|
        try absolutePath(allocator, cwd, path)
    else
        null;
    const dispatch_wit_source = if (config.wit) |path|
        try absolutePath(allocator, cwd, path)
    else
        null;
    const dispatch_wit = if (dispatch_wit_source) |path|
        try stageWit(
            allocator,
            io,
            path,
            try std.fs.path.join(allocator, &.{ transaction_dir, "dispatch-wit" }),
        )
    else
        null;
    const component_wit = if (component_wit_source) |path|
        if (dispatch_wit_source != null and std.mem.eql(u8, path, dispatch_wit_source.?))
            dispatch_wit
        else
            try stageWit(
                allocator,
                io,
                path,
                try std.fs.path.join(allocator, &.{ transaction_dir, "component-wit" }),
            )
    else
        null;
    return .{
        .engine = engine,
        .adapter = adapter,
        .component_wit = if (component_wit) |wit| wit.absolute else null,
        .component_world = config.component_world_name orelse config.world_name,
        .bindings = null,
        .dispatch_wit_digest = if (dispatch_wit) |wit| wit.digest else null,
        .component_wit_digest = if (component_wit) |wit| wit.digest else null,
        .features_known = false,
        .zig = null,
        .build_tools = &.{},
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
    transaction_dir: []const u8,
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
        const dispatch_source = try absolutePath(allocator, cwd, path);
        dispatch_wit = try stageWit(
            allocator,
            io,
            dispatch_source,
            try std.fs.path.join(allocator, &.{ transaction_dir, "dispatch-wit" }),
        );
        component_wit = if (config.component_wit) |component_path|
            if (std.mem.eql(
                u8,
                dispatch_source,
                try absolutePath(allocator, cwd, component_path),
            ))
                dispatch_wit
            else
                try stageWit(
                    allocator,
                    io,
                    try absolutePath(allocator, cwd, component_path),
                    try std.fs.path.join(allocator, &.{ transaction_dir, "component-wit" }),
                )
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

    const zig_source = if (config.zig_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("ZIG")) |path|
        try absolutePath(allocator, cwd, path)
    else
        build_options.zig_exe;
    const zig_resolved = try resolveExecutable(allocator, io, environ, zig_source);
    const zig = try snapshotFile(
        allocator,
        io,
        zig_resolved,
        try std.fs.path.join(allocator, &.{ transaction_dir, "zig" }),
    );

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(allocator, &.{
        zig.path,
        "build",
        "--prefix",
        prefix,
        if (config.use_debug_build) "-Doptimize=Debug" else "-Doptimize=ReleaseSmall",
    }) catch @panic("out of memory");
    if (dispatch_wit) |wit| {
        argv.appendSlice(allocator, &.{
            try std.fmt.allocPrint(allocator, "-Dcomponent-wit={s}", .{component_wit.?.absolute}),
            try std.fmt.allocPrint(allocator, "-Dcomponent-world={s}", .{
                config.component_world_name orelse config.world_name.?,
            }),
            try std.fmt.allocPrint(allocator, "-Ddispatch-wit={s}", .{wit.absolute}),
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
    try copyEnvironment(&build_env, environ);
    try build_env.put("ZIG_GLOBAL_CACHE_DIR", zig_global_cache);
    _ = build_env.swapRemove("ZIG_LOCAL_CACHE_DIR");
    if (environ.get("ZIG_LIB_DIR") == null) {
        const zig_parent = std.fs.path.dirname(zig_resolved) orelse
            return error.MissingBuildArtifact;
        const zig_lib_dir = try std.fs.path.join(
            allocator,
            &.{ zig_parent, "lib" },
        );
        if (try pathKindNoFollow(io, zig_lib_dir) == .directory) {
            try build_env.put("ZIG_LIB_DIR", zig_lib_dir);
        }
    }
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

    const engine_built = try std.fs.path.join(
        allocator,
        &.{ prefix, "bin", "starling-raw.wasm" },
    );
    const engine = try snapshotFile(
        allocator,
        io,
        engine_built,
        try std.fs.path.join(allocator, &.{ transaction_dir, "engine.wasm" }),
    );
    const adapter_built = if (config.preview2_adapter) |path|
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
    const adapter = try snapshotFile(
        allocator,
        io,
        adapter_built,
        try std.fs.path.join(allocator, &.{ transaction_dir, "preview2-adapter.wasm" }),
    );
    const bindings = if (needs_bindings) blk: {
        const path = try std.fs.path.join(
            allocator,
            &.{ prefix, "bin", "component-bindings.zig" },
        );
        break :blk (try snapshotFile(
            allocator,
            io,
            path,
            try std.fs.path.join(allocator, &.{ transaction_dir, "component-bindings.zig" }),
        )).path;
    } else null;
    const build_tools = try readBuildToolManifest(
        allocator,
        io,
        try std.fs.path.join(
            allocator,
            &.{ prefix, "bin", "runtime-build-tools.json" },
        ),
        transaction_dir,
    );

    return .{
        .engine = engine,
        .adapter = adapter,
        .component_wit = if (component_wit) |wit| wit.absolute else null,
        .component_world = config.component_world_name orelse config.world_name,
        .bindings = bindings,
        .dispatch_wit_digest = if (dispatch_wit) |wit| wit.digest else null,
        .component_wit_digest = if (component_wit) |wit| wit.digest else null,
        .features_known = true,
        .zig = zig,
        .build_tools = build_tools,
        .cache_lock = lock_file,
    };
}

fn copyEnvironment(
    destination: *std.process.Environ.Map,
    source: *const std.process.Environ.Map,
) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try destination.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn resolveTools(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    needs_wabt: bool,
    transaction_dir: []const u8,
) !Tools {
    const standalone_wizer = try std.fs.path.join(
        allocator,
        &.{ executable_dir, "wizer" },
    );
    const wizer_is_wasmtime = config.wizer_bin == null and
        (config.wasmtime_bin != null or
            (environ.get("WIZER_BIN") == null and
                (environ.get("WASMTIME_BIN") != null or
                    !pathExists(io, standalone_wizer))));
    const wizer_executable = if (config.wizer_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (config.wasmtime_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("WIZER_BIN")) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("WASMTIME_BIN")) |path|
        try absolutePath(allocator, cwd, path)
    else blk: {
        if (pathExists(io, standalone_wizer)) break :blk standalone_wizer;
        break :blk try siblingOrName(
            allocator,
            io,
            executable_dir,
            "wasmtime",
            "wasmtime",
        );
    };
    const wasm_tools_source = if (config.wasm_tools_bin) |path|
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
    const wabt_source = if (!needs_wabt)
        null
    else if (config.wabt_bin) |path|
        try absolutePath(allocator, cwd, path)
    else if (environ.get("WABT")) |path|
        try absolutePath(allocator, cwd, path)
    else
        try siblingOrName(allocator, io, executable_dir, "wabt", "wabt");
    const wizer = WizerTool{
        .executable = try snapshotFile(
            allocator,
            io,
            try resolveExecutable(allocator, io, environ, wizer_executable),
            try std.fs.path.join(allocator, &.{ transaction_dir, "wizer" }),
        ),
        .wasmtime_subcommand = wizer_is_wasmtime,
    };
    const wasm_tools = try snapshotFile(
        allocator,
        io,
        try resolveExecutable(allocator, io, environ, wasm_tools_source),
        try std.fs.path.join(allocator, &.{ transaction_dir, "wasm-tools" }),
    );
    const wabt = if (wabt_source) |path|
        try snapshotFile(
            allocator,
            io,
            try resolveExecutable(allocator, io, environ, path),
            try std.fs.path.join(allocator, &.{ transaction_dir, "wabt" }),
        )
    else
        null;
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
    source_path: []const u8,
    stage_path: []const u8,
) !StagedWit {
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
    return .{
        .absolute = stage_path,
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

fn buildMetadataDocument(
    allocator: Allocator,
    io: Io,
    config: *const cli.Config,
    source: Snapshot,
    initializer: ?Snapshot,
    runtime_args: []const u8,
    runtime: Runtime,
    tools: Tools,
    component: []const u8,
    imports: metadata.Imports,
) !metadata.Document {
    var features: std.ArrayList(metadata.Feature) = .empty;
    var feature_fields: std.ArrayList([2][]const u8) = .empty;
    if (runtime.features_known) {
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
    }
    const feature_values: ?[]const metadata.Feature = if (runtime.features_known)
        features.toOwnedSlice(allocator) catch @panic("out of memory")
    else
        null;
    const features_hash: ?[]const u8 = if (runtime.features_known)
        try metadata.hashFields(allocator, feature_fields.items)
    else
        null;

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
        try appendToolSnapshot(
            allocator,
            &tool_values,
            &tool_fields,
            "zig",
            zig,
        );
    }
    for (runtime.build_tools) |tool| {
        tool_values.append(allocator, tool) catch @panic("out of memory");
        tool_fields.append(allocator, .{ tool.name, tool.sha256 }) catch
            @panic("out of memory");
    }
    try appendToolSnapshot(
        allocator,
        &tool_values,
        &tool_fields,
        if (tools.wizer.wasmtime_subcommand) "wasmtime-wizer" else "wizer",
        tools.wizer.executable,
    );
    if (tools.wabt) |wabt| {
        try appendToolSnapshot(
            allocator,
            &tool_values,
            &tool_fields,
            "wabt",
            wabt,
        );
    }
    try appendToolSnapshot(
        allocator,
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
            .features = feature_values,
            .features_sha256 = features_hash,
            .tools = tool_values.toOwnedSlice(allocator) catch @panic("out of memory"),
            .tools_sha256 = try metadata.hashFields(allocator, tool_fields.items),
            .inputs = .{
                .source_sha256 = source.digest,
                .initializer_sha256 = if (initializer) |snapshot|
                    snapshot.digest
                else
                    null,
                .runtime_arguments_sha256 = try metadata.sha256Bytes(
                    allocator,
                    runtime_args,
                ),
                .engine_sha256 = runtime.engine.digest,
                .preview2_adapter_sha256 = runtime.adapter.digest,
            },
        },
    };
}

fn appendToolSnapshot(
    allocator: Allocator,
    tools: *std.ArrayList(metadata.Tool),
    fields: *std.ArrayList([2][]const u8),
    name: []const u8,
    executable: Snapshot,
) !void {
    tools.append(allocator, .{ .name = name, .sha256 = executable.digest }) catch
        @panic("out of memory");
    fields.append(allocator, .{ name, executable.digest }) catch @panic("out of memory");
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

const BuildToolManifest = struct {
    schema: []const u8,
    tools: []const Entry,

    const Entry = struct {
        name: []const u8,
        path: []const u8,
    };
};

fn readBuildToolManifest(
    allocator: Allocator,
    io: Io,
    manifest_path: []const u8,
    transaction_dir: []const u8,
) ![]const metadata.Tool {
    const manifest_snapshot = try snapshotFile(
        allocator,
        io,
        manifest_path,
        try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "runtime-build-tools.json" },
        ),
    );
    const source = try Dir.cwd().readFileAlloc(
        io,
        manifest_snapshot.path,
        allocator,
        .limited(1024 * 1024),
    );
    const manifest = std.json.parseFromSliceLeaky(
        BuildToolManifest,
        allocator,
        source,
        .{},
    ) catch return error.InvalidToolManifest;
    if (!std.mem.eql(
        u8,
        manifest.schema,
        "starling-componentize-build-tools/v1",
    )) return error.InvalidToolManifest;

    const manifest_dir = std.fs.path.dirname(manifest_path) orelse
        return error.InvalidToolManifest;
    var tools: std.ArrayList(metadata.Tool) = .empty;
    for (manifest.tools) |entry| {
        if (entry.name.len == 0 or
            std.mem.indexOfAny(u8, entry.name, "/\\\x00\r\n") != null or
            std.fs.path.isAbsolute(entry.path))
        {
            return error.InvalidToolManifest;
        }
        for (tools.items) |existing| {
            if (std.mem.eql(u8, existing.name, entry.name)) {
                return error.InvalidToolManifest;
            }
        }
        const source_path = try std.fs.path.resolve(
            allocator,
            &.{ manifest_dir, entry.path },
        );
        if (!pathContains(manifest_dir, source_path)) return error.InvalidToolManifest;
        const snapshot = try snapshotFile(
            allocator,
            io,
            source_path,
            try std.fs.path.join(
                allocator,
                &.{
                    transaction_dir,
                    try std.fmt.allocPrint(
                        allocator,
                        "runtime-build-tool-{s}",
                        .{entry.name},
                    ),
                },
            ),
        );
        tools.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .sha256 = snapshot.digest,
        }) catch @panic("out of memory");
    }
    return tools.toOwnedSlice(allocator) catch @panic("out of memory");
}

fn snapshotAdjacent(
    allocator: Allocator,
    io: Io,
    source: []const u8,
    label: []const u8,
    random_hex: []const u8,
) !Snapshot {
    const parent = std.fs.path.dirname(source) orelse return error.InvalidPath;
    const basename = std.fs.path.basename(source);
    const extension = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - extension.len];
    const snapshot_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.starling-componentize-{s}-{s}{s}",
        .{ stem, label, random_hex, extension },
    );
    return snapshotFile(
        allocator,
        io,
        source,
        try std.fs.path.join(allocator, &.{ parent, snapshot_name }),
    );
}

fn snapshotFile(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
) !Snapshot {
    var source = try Dir.openFileAbsolute(
        io,
        source_path,
        .{ .follow_symlinks = false },
    );
    defer source.close(io);
    const source_stat = try source.stat(io);
    if (source_stat.kind != .file) return error.MissingBuildArtifact;

    var destination = try Dir.createFileAbsolute(
        io,
        destination_path,
        .{ .exclusive = true },
    );
    errdefer Dir.deleteFileAbsolute(io, destination_path) catch {};
    defer destination.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = source.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) continue;
        hasher.update(buffer[0..count]);
        try destination.writeStreamingAll(io, buffer[0..count]);
    }
    try destination.setPermissions(io, source_stat.permissions);
    try destination.sync(io);
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest_bytes);
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    return .{
        .path = destination_path,
        .digest = try allocator.dupe(u8, &digest_hex),
    };
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
    transaction_safe_to_remove: *bool,
) !void {
    const component_backup = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "previous-component" },
    );
    const metadata_backup = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "previous-metadata" },
    );
    const debug_backup = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "previous-debug" },
    );
    const old_debug_generated = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "previous-debug-generated" },
    );
    var component_backed_up = false;
    var metadata_backed_up = false;
    var debug_backed_up = false;
    var component_published = false;
    var metadata_published = false;
    var debug_published = false;

    errdefer {
        if (debug_published) {
            Dir.renameAbsolute(debug_output.?, debug_staged.?, io) catch {
                transaction_safe_to_remove.* = false;
            };
        }
        if (debug_backed_up) {
            restoreDebugDestination(
                allocator,
                io,
                debug_staged.?,
                debug_backup,
                old_debug_generated,
                debug_output.?,
            ) catch {
                transaction_safe_to_remove.* = false;
            };
        }
        if (metadata_published) {
            Dir.cwd().deleteFile(io, metadata_output.?) catch {};
        }
        if (component_published) {
            Dir.cwd().deleteFile(io, component_output) catch {};
        }
        if (metadata_backed_up) {
            Dir.renameAbsolute(metadata_backup, metadata_output.?, io) catch {
                transaction_safe_to_remove.* = false;
            };
        }
        if (component_backed_up) {
            Dir.renameAbsolute(component_backup, component_output, io) catch {
                transaction_safe_to_remove.* = false;
            };
        }
    }

    component_backed_up = try backupRegularDestination(
        io,
        component_output,
        component_backup,
        error.InvalidPath,
        transaction_safe_to_remove,
    );
    if (metadata_output) |path| {
        metadata_backed_up = try backupRegularDestination(
            io,
            path,
            metadata_backup,
            error.InvalidMetadataDestination,
            transaction_safe_to_remove,
        );
    }
    if (debug_staged) |staged| {
        debug_backed_up = try prepareDebugDestination(
            allocator,
            io,
            staged,
            debug_output.?,
            debug_backup,
            old_debug_generated,
            transaction_safe_to_remove,
        );
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

    if (component_backed_up) Dir.deleteFileAbsolute(io, component_backup) catch {};
    if (metadata_backed_up) Dir.deleteFileAbsolute(io, metadata_backup) catch {};
    if (debug_backed_up) {
        removeOldGeneratedFiles(allocator, io, old_debug_generated) catch {};
        Dir.deleteDirAbsolute(io, old_debug_generated) catch {};
        Dir.deleteDirAbsolute(io, debug_backup) catch {};
    }
}

const debug_generated_names = [_][]const u8{
    "runtime-args.txt",
    "initialized.wasm",
    "stripped.wasm",
    "embedded.wasm",
    "component.wasm",
    "component-bindings.zig",
    "commands.txt",
    "metadata.json",
    "imports.json",
};

fn isGeneratedDebugName(name: []const u8) bool {
    for (debug_generated_names) |generated| {
        if (std.mem.eql(u8, name, generated)) return true;
    }
    return false;
}

fn backupRegularDestination(
    io: Io,
    destination: []const u8,
    backup: []const u8,
    invalid_error: anyerror,
    transaction_safe_to_remove: *bool,
) !bool {
    if (try pathKindNoFollow(io, destination) == null) return false;
    try Dir.renameAbsolute(destination, backup, io);
    var valid_backup = false;
    errdefer if (!valid_backup) {
        Dir.renameAbsolute(backup, destination, io) catch {
            transaction_safe_to_remove.* = false;
        };
    };
    const kind = try pathKindNoFollow(io, backup);
    if (kind == .file) {
        valid_backup = true;
        return true;
    }
    return invalid_error;
}

fn prepareDebugDestination(
    allocator: Allocator,
    io: Io,
    staged: []const u8,
    destination: []const u8,
    backup: []const u8,
    old_generated: []const u8,
    transaction_safe_to_remove: *bool,
) !bool {
    if (try pathKindNoFollow(io, destination) == null) return false;
    try Dir.renameAbsolute(destination, backup, io);
    var prepared = false;
    errdefer if (!prepared) {
        restoreDebugDestination(
            allocator,
            io,
            staged,
            backup,
            old_generated,
            destination,
        ) catch {
            transaction_safe_to_remove.* = false;
        };
    };
    if (try pathKindNoFollow(io, backup) != .directory) {
        return error.DebugOutputCollision;
    }
    try Dir.createDirAbsolute(io, old_generated, .default_dir);

    var backup_dir = try Dir.openDirAbsolute(
        io,
        backup,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer backup_dir.close(io);
    var iterator = backup_dir.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try iterator.next(io)) |entry| {
        names.append(allocator, try allocator.dupe(u8, entry.name)) catch
            @panic("out of memory");
        if (isGeneratedDebugName(entry.name) and
            entry.kind != .file and entry.kind != .sym_link)
        {
            return error.DebugOutputCollision;
        }
    }

    for (names.items) |name| {
        const source = try std.fs.path.join(allocator, &.{ backup, name });
        const target_parent = if (isGeneratedDebugName(name)) old_generated else staged;
        const target = try std.fs.path.join(allocator, &.{ target_parent, name });
        try Dir.renameAbsolute(source, target, io);
    }
    prepared = true;
    return true;
}

fn restoreDebugDestination(
    allocator: Allocator,
    io: Io,
    staged: []const u8,
    backup: []const u8,
    old_generated: []const u8,
    destination: []const u8,
) !void {
    try moveDebugEntries(allocator, io, staged, backup, false);
    try moveDebugEntries(allocator, io, old_generated, backup, true);
    Dir.deleteDirAbsolute(io, old_generated) catch {};
    try Dir.renameAbsolute(backup, destination, io);
}

fn moveDebugEntries(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
    generated_only: bool,
) !void {
    var source = Dir.openDirAbsolute(
        io,
        source_path,
        .{ .iterate = true, .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer source.close(io);
    var iterator = source.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try iterator.next(io)) |entry| {
        if (generated_only != isGeneratedDebugName(entry.name)) continue;
        names.append(allocator, try allocator.dupe(u8, entry.name)) catch
            @panic("out of memory");
    }
    for (names.items) |name| {
        try Dir.renameAbsolute(
            try std.fs.path.join(allocator, &.{ source_path, name }),
            try std.fs.path.join(allocator, &.{ destination_path, name }),
            io,
        );
    }
}

fn removeOldGeneratedFiles(
    allocator: Allocator,
    io: Io,
    directory: []const u8,
) !void {
    for (debug_generated_names) |name| {
        const path = try std.fs.path.join(allocator, &.{ directory, name });
        if (try pathKindNoFollow(io, path) != null) {
            try Dir.deleteFileAbsolute(io, path);
        }
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
    if (!termSucceeded(term)) {
        diagnostic.commandFailed(stage, term, stderr, redact_path);
        return error.CommandFailed;
    }
    if (diagnostic.format == .human) {
        try File.stdout().writeStreamingAll(io, stdout);
        try File.stderr().writeStreamingAll(io, stderr);
    }
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
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

fn pathKindNoFollow(io: Io, path: []const u8) !?File.Kind {
    const stat = Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return stat.kind;
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
    const stat = Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
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
