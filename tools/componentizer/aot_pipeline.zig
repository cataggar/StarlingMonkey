const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const aot_cache = @import("aot_cache.zig");
const cli = @import("cli.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const File = Io.File;

const PipelineError = error{
    CommandFailed,
    CorruptAotCache,
    DebugOutputCollision,
    EmptyRuntimeArgument,
    IncompatibleEngineOptions,
    InvalidBuildRoot,
    InvalidAotCache,
    InvalidEngineProvenance,
    InvalidPath,
    MissingBuildArtifact,
    MissingAotCache,
    MissingWitFiles,
    UnrepresentableRuntimeArgument,
    UnsupportedWitEntry,
    StaleAotCache,
    TransactionChanged,
    UnsupportedRetainedExecution,
};

const EngineFeatures = struct {
    stdio: bool,
    random: bool,
    clocks: bool,
    http: bool,
    @"fetch-event": bool,
};

const EngineProvenance = struct {
    schema: u32,
    host_api: []const u8,
    features: EngineFeatures,
    component_world: []const u8,
    surface_world: []const u8,
};

const StagedWit = struct {
    absolute: []const u8,
    relative: []const u8,
    digest: []const u8,
};

const AotCache = struct {
    cache: []const u8,
    manifest: []const u8,
    expected_feature_abi: ?[]const u8,
};

const AotSnapshot = struct {
    engine: []const u8,
    weval: []const u8,
    weval_package_root: []const u8,
    validated: ?aot_cache.Validated = null,
    bundle: AotCache,
    engine_capture: CapturedFile,
    cache_capture: CapturedFile,
    manifest_capture: CapturedFile,
    weval_capture: CapturedWevalPackage,

    fn close(snapshot: AotSnapshot, io: Io) void {
        snapshot.engine_capture.close(io);
        snapshot.cache_capture.close(io);
        snapshot.manifest_capture.close(io);
        snapshot.weval_capture.close(io);
    }
};

const Runtime = struct {
    engine: []const u8,
    engine_capture: ?CapturedFile,
    external_capture: ?*CapturedExternalRuntime,
    adapter: []const u8,
    component_wit: ?[]const u8,
    component_world: ?[]const u8,
    surface_world: ?[]const u8,
    bindings: ?[]const u8,
    aot_cache: ?AotCache,
    cache_lock: ?File,
};

const WizerTool = struct {
    executable: []const u8,
    wasmtime_subcommand: bool,
};

const WevalTool = struct {
    selected: []const u8,
    package_root: []const u8,
    provenance: []const u8,
};

const CapturedAncestor = struct {
    name: []const u8,
    dir: Dir,
    identity: PackageIdentity,
};

const CapturedPath = struct {
    root: Dir,
    root_identity: PackageIdentity,
    ancestors: []CapturedAncestor,

    fn parent(captured: CapturedPath) Dir {
        if (captured.ancestors.len == 0) return captured.root;
        return captured.ancestors[captured.ancestors.len - 1].dir;
    }

    fn close(captured: CapturedPath, io: Io) void {
        var index = captured.ancestors.len;
        while (index != 0) {
            index -= 1;
            captured.ancestors[index].dir.close(io);
        }
        captured.root.close(io);
    }
};

const CapturedFile = struct {
    path: []const u8,
    basename: []const u8,
    parent_path: CapturedPath,
    file: File,
    name_identity: PackageIdentity,
    identity: PackageIdentity,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    fn close(captured: CapturedFile, io: Io) void {
        captured.file.close(io);
        captured.parent_path.close(io);
    }
};

const CapturedPackageEntry = struct {
    name: []const u8,
    value: union(enum) {
        file: CapturedPackageFile,
        directory: *CapturedPackageDirectory,
        sym_link: struct {
            file: File,
            identity: PackageIdentity,
            target: []const u8,
        },
    },
};

const CapturedPackageFile = struct {
    file: File,
    identity: PackageIdentity,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

const CapturedPackageDirectory = struct {
    dir: Dir,
    identity: PackageIdentity,
    entries: []CapturedPackageEntry,
};

const CapturedWevalPackage = struct {
    tree: CapturedDirectory,
    selected_relative: []const u8,

    fn close(captured: CapturedWevalPackage, io: Io) void {
        captured.tree.close(io);
    }
};

const CapturedDirectory = struct {
    path: []const u8,
    basename: []const u8,
    parent_path: CapturedPath,
    name_identity: PackageIdentity,
    root: *CapturedPackageDirectory,

    fn close(captured: CapturedDirectory, io: Io) void {
        closeCapturedPackageDirectory(io, captured.root);
        captured.parent_path.close(io);
    }
};

const CapturedExternalRuntime = struct {
    package: CapturedDirectory,
    runtime_root: *CapturedPackageDirectory,
    engine: CapturedPackageFile,
    adapter: CapturedPackageFile,
    features: CapturedPackageFile,
    component_wit: *CapturedPackageDirectory,
    surface_wit: *CapturedPackageDirectory,
    feature_wit: *CapturedPackageDirectory,
    aot_cache: ?CapturedPackageFile,
    aot_manifest: ?CapturedPackageFile,
    weval_package: ?*CapturedPackageDirectory,
    weval_selected_relative: ?[]const u8,
    weval: ?WevalTool,
    supplied_surface_wit: ?CapturedDirectory,
    supplied_component_wit: ?CapturedDirectory,

    fn close(captured: CapturedExternalRuntime, io: Io) void {
        captured.package.close(io);
        if (captured.supplied_surface_wit) |tree| tree.close(io);
        if (captured.supplied_component_wit) |tree| tree.close(io);
    }
};

const CapturedTool = struct {
    provenance: []const u8,
    executable: []const u8,
    package: CapturedWevalPackage,
    snapshot_package: ?CapturedWevalPackage = null,
    retained_plan: ?RetainedExecPlan = null,

    fn close(tool: CapturedTool, io: Io) void {
        if (tool.retained_plan) |plan| plan.close(io);
        if (tool.snapshot_package) |package| package.close(io);
        tool.package.close(io);
    }
};

const Tools = struct {
    wizer: ?WizerTool,
    weval: ?WevalTool,
    wabt: ?CapturedTool,
    wasm_tools: CapturedTool,

    fn close(tools: Tools, io: Io) void {
        tools.wasm_tools.close(io);
        if (tools.wabt) |tool| tool.close(io);
    }
};

pub fn main(init: std.process.Init) !void {
    try reserveStandardDescriptors();
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var action = cli.parse(allocator, args) catch |err| {
        std.process.fatal("{s}; run with --help for usage", .{parseErrorMessage(err)});
    };

    switch (action) {
        .help => try File.stdout().writeStreamingAll(init.io, cli.usage),
        .version => try File.stdout().writeStreamingAll(init.io, cli.version ++ "\n"),
        .run => |*config| {
            defer config.deinit(allocator);
            execute(
                allocator,
                init.io,
                init.environ_map,
                config,
            ) catch |err| std.process.fatal("componentization failed: {t}", .{err});
        },
    }
}

fn reserveStandardDescriptors() !void {
    if (builtin.os.tag != .linux)
        return;
    for (0..3) |index| {
        const handle: std.posix.fd_t = @intCast(index);
        switch (std.posix.errno(std.posix.system.fcntl(
            handle,
            std.posix.F.GETFD,
            @as(usize, 0),
        ))) {
            .SUCCESS => continue,
            .BADF => {},
            else => return error.UnsupportedRetainedExecution,
        }
        const replacement = try std.posix.openat(
            std.posix.AT.FDCWD,
            "/dev/null",
            .{ .ACCMODE = .RDWR, .CLOEXEC = false },
            0,
        );
        if (replacement != handle) {
            _ = std.os.linux.close(replacement);
            return error.UnsupportedRetainedExecution;
        }
    }
}

fn parseErrorMessage(err: cli.ParseError) []const u8 {
    return switch (err) {
        error.ConflictingFeatures => "the same feature cannot be both enabled and disabled",
        error.AotOptionRequiresAot => "AOT cache, tool, and stack controls require --aot",
        error.IncompatibleAotOptions => "--aot cannot be combined with --use-debug-build",
        error.InvalidAotMinStackSize => "--aot-min-stack-size must be a positive integer",
        error.InvalidDiagnosticFormat => "--diagnostic-format must be human or json",
        error.InvalidHeapLimit => "--js-heap-limit-mib must be an integer from 1 to 4095",
        error.MissingSource => "missing JavaScript source path",
        error.MissingValue => "an option is missing its value",
        error.MissingWitWorld => "--wit and --world-name must be provided together",
        error.MultipleSources => "multiple JavaScript source paths were provided",
        error.UnexpectedComponentWorld => "--component-wit requires --wit and its own world name",
        error.UnknownArgument => "unknown option",
        error.UnknownFeature => "unknown feature (expected stdio, random, clocks, http, or fetch-event)",
    };
}

fn retainedExecHelper(
    allocator: Allocator,
    io: Io,
    args: []const []const u8,
    child_env: ?[*:null]const ?[*:0]const u8,
    retained_inputs: []const std.posix.fd_t,
) !void {
    if (builtin.os.tag != .linux or args.len < 8)
        return error.UnsupportedRetainedExecution;
    const namespace_root_path = args[0];
    const host_component = args[1];
    const package_component = args[2];
    const selected_relative = args[3];
    const dynamic = if (std.mem.eql(u8, args[4], "dynamic"))
        true
    else if (std.mem.eql(u8, args[4], "static"))
        false
    else
        return error.UnsupportedRetainedExecution;
    const entry_args = try std.fmt.parseInt(usize, args[5], 10);
    if (args.len < 6 + entry_args + 2 or
        !std.mem.eql(u8, args[6 + entry_args], "--"))
        return error.UnsupportedRetainedExecution;
    const linux = std.os.linux;
    const original_cwd = try std.process.currentPathAlloc(io, allocator);
    try enterPrivateUserMountNamespace(io);
    const mount_path = try allocator.dupeSentinel(u8, namespace_root_path, 0);
    switch (linux.errno(linux.mount(
        "starling-retained-package",
        mount_path,
        "tmpfs",
        linux.MS.NOSUID | linux.MS.NODEV,
        0,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    var namespace_root = try Dir.openDirAbsolute(io, mount_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer namespace_root.close(io);
    try namespace_root.createDir(
        io,
        host_component,
        File.Permissions.fromMode(0o700),
    );
    try namespace_root.createDir(
        io,
        package_component,
        File.Permissions.fromMode(0o700),
    );
    const namespace_path = try std.fmt.allocPrint(
        allocator,
        "/proc/self/fd/{d}",
        .{namespace_root.handle},
    );
    const host_path = try std.fs.path.join(
        allocator,
        &.{ namespace_path, host_component },
    );
    const host_path_z = try allocator.dupeSentinel(u8, host_path, 0);
    switch (linux.errno(linux.mount(
        "/",
        host_path_z,
        null,
        linux.MS.BIND | linux.MS.REC,
        0,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    const MountAttr = extern struct {
        attr_set: u64,
        attr_clr: u64,
        propagation: u64,
        userns_fd: u64,
    };
    var mount_attr: MountAttr = .{
        .attr_set = 0x2 | 0x4 | 0x8,
        .attr_clr = 0,
        .propagation = 0,
        .userns_fd = 0,
    };
    switch (linux.errno(linux.syscall5(
        .mount_setattr,
        @as(u32, @bitCast(@as(i32, linux.AT.FDCWD))),
        @intFromPtr(host_path_z.ptr),
        linux.AT.RECURSIVE,
        @intFromPtr(&mount_attr),
        @sizeOf(MountAttr),
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    switch (linux.errno(linux.mount(
        null,
        host_path_z,
        null,
        linux.MS.BIND | linux.MS.REMOUNT | linux.MS.NOEXEC |
            linux.MS.NOSUID | linux.MS.NODEV,
        0,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    var host_root = try Dir.openDirAbsolute(io, "/", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer host_root.close(io);
    var root_entries = host_root.iterate();
    while (try root_entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, host_component) or
            std.mem.eql(u8, entry.name, package_component))
            return error.UnsupportedRetainedExecution;
        const target = try namespaceMirrorLinkTarget(
            allocator,
            host_component,
            entry.name,
        );
        try namespace_root.symLink(io, target, entry.name, .{});
    }
    var root = try namespace_root.openDir(io, package_component, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer root.close(io);
    switch (linux.errno(linux.fchdir(namespace_root.handle))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    var index: usize = 6;
    const entries_end = index + entry_args;
    while (index < entries_end) {
        const kind = args[index];
        if (std.mem.eql(u8, kind, "d")) {
            if (index + 3 > entries_end)
                return error.UnsupportedRetainedExecution;
            const relative = args[index + 1];
            const mode = try std.fmt.parseInt(std.posix.mode_t, args[index + 2], 10);
            try root.createDirPath(io, relative);
            var child = try root.openDir(io, relative, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer child.close(io);
            try child.setPermissions(io, File.Permissions.fromMode(mode));
            index += 3;
        } else if (std.mem.eql(u8, kind, "f")) {
            if (index + 4 > entries_end)
                return error.UnsupportedRetainedExecution;
            const relative = args[index + 1];
            const fd = try std.fmt.parseInt(std.posix.fd_t, args[index + 2], 10);
            const mode = try std.fmt.parseInt(std.posix.mode_t, args[index + 3], 10);
            const source: File = .{
                .handle = fd,
                .flags = .{ .nonblocking = false },
            };
            const stat = try source.stat(io);
            var output = try root.createFile(io, relative, .{
                .read = true,
                .truncate = true,
            });
            defer output.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < stat.size) {
                const count = try source.readPositional(
                    io,
                    &.{&buffer},
                    offset,
                );
                if (count == 0) return error.TransactionChanged;
                try output.writePositionalAll(io, buffer[0..count], offset);
                offset += count;
            }
            try output.setPermissions(io, File.Permissions.fromMode(mode));
            index += 4;
        } else if (std.mem.eql(u8, kind, "l")) {
            if (index + 3 > entries_end)
                return error.UnsupportedRetainedExecution;
            try root.symLink(io, args[index + 2], args[index + 1], .{});
            index += 3;
        } else {
            return error.UnsupportedRetainedExecution;
        }
    }
    try root.setPermissions(io, File.Permissions.fromMode(0o500));
    switch (linux.errno(linux.fchdir(namespace_root.handle))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    switch (linux.errno(linux.mount(
        null,
        ".",
        null,
        linux.MS.REMOUNT | linux.MS.RDONLY |
            linux.MS.NOSUID | linux.MS.NODEV,
        0,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    _ = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
    switch (linux.errno(linux.fchdir(namespace_root.handle))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    switch (linux.errno(linux.chroot("."))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    const cwd_z = try allocator.dupeSentinel(u8, original_cwd, 0);
    switch (linux.errno(linux.chdir(cwd_z))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    const selected_path = try std.fs.path.join(
        allocator,
        &.{ "/", package_component, selected_relative },
    );
    const child_args = args[7 + entry_args ..];
    if (child_args.len == 0)
        return error.UnsupportedRetainedExecution;
    var argv_z = try allocator.allocSentinel(
        ?[*:0]const u8,
        child_args.len,
        null,
    );
    argv_z[0] = (try allocator.dupeSentinel(u8, selected_path, 0)).ptr;
    for (child_args[1..], 1..) |arg, arg_index|
        argv_z[arg_index] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;
    const envp: [*:null]const ?[*:0]const u8 = child_env orelse
        @ptrCast(std.c.environ);
    const rc = if (dynamic) dynamic_exec: {
        const loader = try root.openFile(
            io,
            ".starling-runtime-v1/loader",
            .{ .follow_symlinks = false },
        );
        const library_path = try std.fs.path.join(
            allocator,
            &.{ "/", package_component, ".starling-runtime-v1/lib" },
        );
        var loader_argv = try allocator.allocSentinel(
            ?[*:0]const u8,
            child_args.len + 8,
            null,
        );
        const fixed = [_][]const u8{
            "starling-retained-loader",
            "--inhibit-cache",
            "--glibc-hwcaps-mask",
            "",
            "--library-path",
            library_path,
            "--argv0",
            selected_path,
            selected_path,
        };
        for (fixed, 0..) |arg, arg_index|
            loader_argv[arg_index] =
                (try allocator.dupeSentinel(u8, arg, 0)).ptr;
        for (child_args[1..], fixed.len..) |arg, arg_index|
            loader_argv[arg_index] =
                (try allocator.dupeSentinel(u8, arg, 0)).ptr;
        try closeUnallowlistedDescriptors(
            loader.handle,
            retained_inputs,
        );
        break :dynamic_exec linux.execveat(
            loader.handle,
            "",
            loader_argv.ptr,
            envp,
            .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = false },
        );
    } else static_exec: {
        const immutable_executable = try root.openFile(
            io,
            selected_relative,
            .{ .follow_symlinks = true },
        );
        try closeUnallowlistedDescriptors(
            immutable_executable.handle,
            retained_inputs,
        );
        break :static_exec linux.execveat(
            immutable_executable.handle,
            "",
            argv_z.ptr,
            envp,
            .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = false },
        );
    };
    std.debug.print(
        "error: retained executable could not start: {t}\n",
        .{linux.errno(rc)},
    );
    return error.UnsupportedRetainedExecution;
}

fn closeUnallowlistedDescriptors(
    executable: std.posix.fd_t,
    retained_inputs: []const std.posix.fd_t,
) !void {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    const linux = std.os.linux;
    // Linux UAPI CLOSE_RANGE_CLOEXEC is bit 2.
    const close_range_cloexec: linux.CLOSE_RANGE =
        @bitCast(@as(u32, 1) << 2);
    switch (linux.errno(linux.close_range(
        3,
        std.math.maxInt(std.posix.fd_t),
        close_range_cloexec,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    try allowDescriptorAcrossExec(executable);
    for (retained_inputs) |handle|
        try allowDescriptorAcrossExec(handle);
}

fn allowDescriptorAcrossExec(handle: std.posix.fd_t) !void {
    if (handle < 3) return error.UnsupportedRetainedExecution;
    switch (std.posix.errno(std.posix.system.fcntl(
        handle,
        std.posix.F.SETFD,
        @as(usize, 0),
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
}

fn namespaceMirrorLinkTarget(
    allocator: Allocator,
    host_component: []const u8,
    root_entry: []const u8,
) ![]const u8 {
    if (host_component.len == 0 or root_entry.len == 0 or
        std.mem.indexOfScalar(u8, host_component, '/') != null or
        std.mem.indexOfScalar(u8, root_entry, '/') != null)
        return error.UnsupportedRetainedExecution;
    return std.fmt.allocPrint(
        allocator,
        "/{s}/{s}",
        .{ host_component, root_entry },
    );
}

fn enterPrivateUserMountNamespace(io: Io) !void {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    const linux = std.os.linux;
    const uid = linux.getuid();
    const gid = linux.getgid();
    switch (linux.errno(linux.unshare(
        linux.CLONE.NEWUSER | linux.CLONE.NEWNS,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    Dir.cwd().writeFile(io, .{
        .sub_path = "/proc/self/setgroups",
        .data = "deny\n",
    }) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return error.UnsupportedRetainedExecution,
    };
    const uid_map = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "0 {d} 1\n",
        .{uid},
    );
    defer std.heap.page_allocator.free(uid_map);
    const gid_map = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "0 {d} 1\n",
        .{gid},
    );
    defer std.heap.page_allocator.free(gid_map);
    Dir.cwd().writeFile(io, .{
        .sub_path = "/proc/self/uid_map",
        .data = uid_map,
    }) catch return error.UnsupportedRetainedExecution;
    Dir.cwd().writeFile(io, .{
        .sub_path = "/proc/self/gid_map",
        .data = gid_map,
    }) catch return error.UnsupportedRetainedExecution;
    switch (linux.errno(linux.setresgid(0, 0, 0))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    switch (linux.errno(linux.setresuid(0, 0, 0))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    switch (linux.errno(linux.mount(
        null,
        "/",
        null,
        linux.MS.REC | linux.MS.PRIVATE,
        0,
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
}

fn execute(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    config: *const cli.Config,
) !void {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    const source_argument = if (config.source) |path|
        try absolutePath(allocator, cwd, path)
    else
        null;
    const source = if (config.source) |path| blk: {
        const resolved = try resolveExistingFile(allocator, io, cwd, path);
        try validateArgument(resolved);
        break :blk resolved;
    } else null;
    const needs_initialization = source != null or config.aot;
    const initializer = if (config.initializer_script_path) |path|
        try resolveExistingFile(allocator, io, cwd, path)
    else
        null;

    const output = if (config.output) |path|
        try absolutePath(allocator, cwd, path)
    else
        try defaultOutputPath(allocator, cwd, source_argument.?);
    try validateArgument(output);
    const output_parent = std.fs.path.dirname(output) orelse return error.InvalidPath;
    try Dir.cwd().createDirPath(io, output_parent);
    const resolved_output = try resolveDestination(allocator, io, output);
    if ((source != null and std.mem.eql(u8, source.?, resolved_output)) or
        (initializer != null and std.mem.eql(u8, initializer.?, resolved_output)))
    {
        return error.InputOutputCollision;
    }

    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    const build_root = if (config.engine == null)
        try discoverBuildRoot(allocator, io, environ, cwd, executable_dir, config.build_root)
    else if (config.build_root) |root|
        try resolveAndValidateRoot(allocator, io, cwd, root)
    else
        null;

    var runtime = if (config.engine) |engine_override|
        try externalRuntime(
            allocator,
            io,
            environ,
            cwd,
            config,
            engine_override,
            needs_initialization,
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
            needs_initialization,
        );
    defer if (runtime.engine_capture) |capture| capture.close(io);
    defer if (runtime.external_capture) |capture| capture.close(io);
    defer if (runtime.cache_lock) |lock| {
        lock.unlock(io);
        lock.close(io);
    };

    var tools = try resolveTools(
        allocator,
        io,
        environ,
        cwd,
        executable_dir,
        config,
        if (runtime.external_capture) |capture| capture.weval else null,
        runtime.component_wit != null,
        needs_initialization,
    );
    defer tools.close(io);

    var staging_exclusions: std.ArrayList([]const u8) = .empty;
    staging_exclusions.append(
        allocator,
        tools.wasm_tools.package.tree.path,
    ) catch @panic("out of memory");
    if (tools.wabt) |tool| {
        staging_exclusions.append(
            allocator,
            tool.package.tree.path,
        ) catch @panic("out of memory");
    }
    if (tools.weval) |tool| {
        staging_exclusions.append(
            allocator,
            tool.package_root,
        ) catch @panic("out of memory");
    }
    const tool_staging_dir = try createAotStagingDir(
        allocator,
        io,
        environ,
        cwd,
        executable_dir,
        staging_exclusions.items,
        std.fs.path.dirname(resolved_output) orelse return error.InvalidPath,
    );
    defer removeAotStagingDir(io, tool_staging_dir);

    const aot_staging_dir = if (config.aot)
        try createAotStagingDir(
            allocator,
            io,
            environ,
            cwd,
            executable_dir,
            staging_exclusions.items,
            std.fs.path.dirname(resolved_output) orelse return error.InvalidPath,
        )
    else
        null;
    defer if (aot_staging_dir) |path| removeAotStagingDir(io, path);

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
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    try Dir.createDirAbsolute(io, transaction_dir, private_permissions);
    defer removePrivateTree(io, transaction_dir);

    try runComponentizerTestHook(
        allocator,
        io,
        environ,
        "tools-resolved",
    );
    try snapshotTools(
        allocator,
        io,
        tool_staging_dir,
        &tools,
    );

    if (runtime.external_capture != null) {
        try snapshotExternalRuntime(
            allocator,
            io,
            environ,
            cwd,
            config,
            tools.wasm_tools,
            transaction_dir,
            &runtime,
        );
    }

    const aot_snapshot = if (config.aot) blk: {
        const bundle = runtime.aot_cache orelse return error.MissingAotCache;
        var snapshot = try snapshotAotInputs(
            allocator,
            io,
            environ,
            aot_staging_dir.?,
            runtime.engine,
            runtime.engine_capture,
            runtime.external_capture,
            tools.weval.?,
            bundle,
        );
        snapshot.validated = validateAotCache(
            allocator,
            io,
            snapshot.engine,
            snapshot.weval,
            snapshot.bundle,
        ) catch |err| {
            std.debug.print(
                "error: AOT cache validation failed for {s}: {t}\n",
                .{ bundle.cache, err },
            );
            return switch (err) {
                error.MissingCacheArtifact => error.MissingAotCache,
                error.CorruptCache, error.InvalidCacheFormat => error.CorruptAotCache,
                error.IncompleteCache,
                error.InvalidCacheSchema,
                error.InvalidManifest,
                error.SqliteUnavailable,
                => error.InvalidAotCache,
                error.StaleEngine, error.StaleFeatureAbi, error.StaleTool => error.StaleAotCache,
                else => err,
            };
        };
        break :blk snapshot;
    } else null;
    defer if (aot_snapshot) |snapshot| snapshot.close(io);
    const initialization_engine = if (aot_snapshot) |snapshot|
        snapshot.engine
    else
        runtime.engine;

    const runtime_args_path = if (source) |source_path| blk: {
        const path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "runtime-args.txt" },
        );
        const runtime_args = try renderRuntimeArgs(
            allocator,
            cwd,
            source_path,
            initializer,
            config,
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = runtime_args,
        });
        break :blk path;
    } else null;

    var command_log: std.ArrayList(u8) = .empty;
    const initialized = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "initialized.wasm" },
    );
    var initialization_args: std.ArrayList([]const u8) = .empty;
    if (config.aot) {
        initialization_args.appendSlice(allocator, &.{
            aot_snapshot.?.weval,
            "weval",
            "-w",
            "--init-func",
            if (source != null)
                "wizer-initialize"
            else
                "starling-aot-runtime-initialize",
            "--cache-ro",
            aot_snapshot.?.bundle.cache,
        }) catch @panic("out of memory");
        if (config.verbose) {
            initialization_args.appendSlice(
                allocator,
                &.{ "--verbose", "--show-stats" },
            ) catch @panic("out of memory");
        }
    } else if (needs_initialization) {
        const wizer = tools.wizer orelse return error.MissingWizer;
        initialization_args.append(allocator, wizer.executable) catch
            @panic("out of memory");
        if (wizer.wasmtime_subcommand) {
            initialization_args.append(allocator, "wizer") catch @panic("out of memory");
            initialization_args.appendSlice(allocator, &.{
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
            initialization_args.appendSlice(allocator, &.{
                "--allow-wasi",
                "--init-func",
                "wizer-initialize",
                "--inherit-env",
                "true",
                "--wasm-bulk-memory",
                "true",
            }) catch @panic("out of memory");
        }
    }

    if (needs_initialization) {
        if (source) |source_path| {
            const source_dir = std.fs.path.dirname(source_path) orelse return error.InvalidPath;
            if (!config.legacy_wrapper_preopen or config.preopen_dirs.len == 0) {
                try addPreopen(allocator, &initialization_args, source_dir);
            }
            if (!config.legacy_wrapper_preopen) {
                if (initializer) |initializer_path| {
                    const initializer_dir = std.fs.path.dirname(initializer_path) orelse return error.InvalidPath;
                    try addPreopen(allocator, &initialization_args, initializer_dir);
                }
            }
            for (config.preopen_dirs) |preopen| {
                const preopen_abs = try absolutePath(allocator, cwd, preopen);
                try addPreopen(allocator, &initialization_args, preopen_abs);
            }
        }
        initialization_args.appendSlice(
            allocator,
            if (config.aot)
                &.{ "-o", initialized, "-i", initialization_engine }
            else
                &.{ "-o", initialized, initialization_engine },
        ) catch @panic("out of memory");

        var pipeline_env = std.process.Environ.Map.init(allocator);
        try pipeline_env.putAll(environ);
        try pipeline_env.put("WASMTIME_BACKTRACE_DETAILS", "1");
        _ = pipeline_env.swapRemove("STARLINGMONKEY_CONFIG");
        _ = pipeline_env.swapRemove("RUST_MIN_STACK");
        if (config.aot) {
            try pipeline_env.put(
                "RUST_MIN_STACK",
                try std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{config.aot_min_stack_size orelse aot_cache.default_min_stack_size},
                ),
            );
            try verifyWevalPackageSnapshot(
                allocator,
                io,
                aot_snapshot.?,
            );
        }
        if (aot_snapshot) |snapshot| {
            const result = runRetainedPackageCommand(
                allocator,
                io,
                "weval AOT",
                snapshot.weval_capture,
                null,
                &.{
                    snapshot.engine_capture.file.handle,
                    snapshot.cache_capture.file.handle,
                },
                initialization_args.items,
                snapshot.weval,
                cwd,
                &pipeline_env,
                runtime_args_path,
                config.verbose,
                &command_log,
            );
            const verification = verifyWevalPackageSnapshot(
                allocator,
                io,
                snapshot,
            );
            try verification;
            try result;
        } else {
            try runCommand(
                allocator,
                io,
                "wizer",
                initialization_args.items,
                cwd,
                &pipeline_env,
                runtime_args_path,
                config.verbose,
                &command_log,
            );
        }
    } else {
        try Dir.copyFileAbsolute(runtime.engine, initialized, io, .{});
    }

    var stripped: ?[]const u8 = null;
    var embedded: ?[]const u8 = null;
    const candidate = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "candidate.wasm" },
    );
    if (runtime.component_wit) |component_wit| {
        const use_wabt = !config.aot or
            (runtime.external_capture != null and config.source != null);
        const component_tool = if (use_wabt) tools.wabt.? else tools.wasm_tools;
        const component_executable = component_tool.executable;
        stripped = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "stripped.wasm" },
        );
        embedded = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "embedded.wasm" },
        );
        try runCapturedToolCommand(
            allocator,
            io,
            if (use_wabt) "wabt module strip" else "wasm-tools strip",
            component_tool,
            if (use_wabt)
                &.{ component_executable, "module", "strip", "-o", stripped.?, initialized }
            else
                &.{ component_executable, "strip", "--all", "-o", stripped.?, initialized },
            cwd,
            null,
            null,
            config.verbose,
            &command_log,
        );
        try runCapturedToolCommand(
            allocator,
            io,
            if (use_wabt) "wabt component embed" else "wasm-tools component embed",
            component_tool,
            &.{
                component_executable,
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
        );
        const adapter_arg = try std.fmt.allocPrint(
            allocator,
            "wasi_snapshot_preview1={s}",
            .{runtime.adapter},
        );
        try runCapturedToolCommand(
            allocator,
            io,
            if (use_wabt) "wabt component new" else "wasm-tools component new",
            component_tool,
            &.{
                component_executable,
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
        );
    } else {
        const adapter_arg = try std.fmt.allocPrint(
            allocator,
            "wasi_snapshot_preview1={s}",
            .{runtime.adapter},
        );
        try runCapturedToolCommand(
            allocator,
            io,
            "wasm-tools component new",
            tools.wasm_tools,
            &.{
                tools.wasm_tools.executable,
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
        );
    }

    try runCapturedToolCommand(
        allocator,
        io,
        "wasm-tools validate",
        tools.wasm_tools,
        &.{
            tools.wasm_tools.executable,
            "validate",
            "--features",
            "all",
            candidate,
        },
        cwd,
        null,
        null,
        config.verbose,
        &command_log,
    );
    try requireFile(io, candidate);

    if (config.debug_bindings) {
        const command_log_path = try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "commands.txt" },
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = command_log_path,
            .data = command_log.items,
        });
        const debug_dir = if (config.debug_dir) |path|
            try absolutePath(allocator, cwd, path)
        else
            try std.fmt.allocPrint(allocator, "{s}.debug", .{output});
        if (pathContains(debug_dir, output)) return error.DebugOutputCollision;
        Dir.cwd().createDirPath(io, debug_dir) catch |err| switch (err) {
            error.NotDir => return error.DebugOutputCollision,
            else => return err,
        };
        var debug_dir_handle = Dir.openDirAbsolute(
            io,
            debug_dir,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.SymLinkLoop, error.NotDir => return error.DebugOutputCollision,
            else => return err,
        };
        defer debug_dir_handle.close(io);
        var debug_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const debug_path_len = try debug_dir_handle.realPath(io, &debug_path_buffer);
        const resolved_debug_dir = debug_path_buffer[0..debug_path_len];
        if (pathContains(resolved_debug_dir, resolved_output))
            return error.DebugOutputCollision;
        if (runtime_args_path) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "runtime-args.txt");
        }
        try copyDebugFile(io, initialized, debug_dir_handle, "initialized.wasm");
        if (stripped) |path| try copyDebugFile(io, path, debug_dir_handle, "stripped.wasm");
        if (embedded) |path| try copyDebugFile(io, path, debug_dir_handle, "embedded.wasm");
        try copyDebugFile(io, candidate, debug_dir_handle, "component.wasm");
        if (runtime.bindings) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "component-bindings.zig");
        }
        if (aot_snapshot) |snapshot| {
            const bundle = snapshot.bundle;
            try copyDebugFile(io, bundle.manifest, debug_dir_handle, "aot-cache.manifest");
        }
        try copyDebugFile(io, command_log_path, debug_dir_handle, "commands.txt");
    }

    if (runtime.external_capture) |capture| {
        verifyCapturedExternalRuntime(io, capture) catch
            {
                std.debug.print(
                    "error: external package changed before publication\n",
                    .{},
                );
                return error.TransactionChanged;
            };
    }
    verifyCapturedTools(io, tools) catch {
        std.debug.print(
            "error: WABT or wasm-tools package changed before publication\n",
            .{},
        );
        return error.TransactionChanged;
    };
    if (runtime.engine_capture) |capture| {
        try verifyCapturedFile(io, capture);
    }
    var candidate_file = try Dir.openFileAbsolute(io, candidate, .{});
    defer candidate_file.close(io);
    try candidate_file.sync(io);
    try Dir.renameAbsolute(candidate, output, io);
    if (source) |source_path| {
        std.debug.print("Componentized {s} into {s}\n", .{ source_path, output });
    } else {
        std.debug.print("Created runtime-eval component {s}\n", .{output});
    }
}

fn resolveWizerExecutable(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    path: []const u8,
) ![]const u8 {
    return resolveExecutable(
        allocator,
        io,
        environ,
        cwd,
        path,
    ) catch |err| {
        std.debug.print(
            "error: failed to resolve required Wizer executable '{s}': {t}\n",
            .{ path, err },
        );
        return err;
    };
}

fn externalRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    config: *const cli.Config,
    engine_override: []const u8,
    needs_initialization: bool,
) !Runtime {
    if (config.disable_features.len != 0 or
        config.enable_features.len != 0 or
        config.use_debug_build)
    {
        std.debug.print(
            "error: --engine cannot be combined with build-changing feature/debug options\n",
            .{},
        );
        return error.IncompatibleEngineOptions;
    }
    const requested_engine = try absolutePath(allocator, cwd, engine_override);
    const runtime_root_path = std.fs.path.dirname(requested_engine) orelse
        return error.InvalidPath;
    const bundle = if (config.aot and needs_initialization)
        try resolveAotBundle(
            allocator,
            io,
            cwd,
            config.aot_cache_dir,
            runtime_root_path,
            null,
        )
    else
        null;
    const requested_weval_name = config.weval_bin orelse
        environ.get("WEVAL_BIN");
    const resolved_weval = if (bundle != null)
        if (requested_weval_name) |path|
            try resolveWevalExecutable(
                allocator,
                io,
                environ,
                cwd,
                path,
            )
        else blk: {
            const flat = try std.fs.path.join(
                allocator,
                &.{ runtime_root_path, "weval-package", "weval" },
            );
            const parent = std.fs.path.dirname(runtime_root_path) orelse
                return error.InvalidPath;
            const managed = try std.fs.path.join(
                allocator,
                &.{ parent, "weval-package", "weval" },
            );
            const selected = if (pathExists(io, flat) or
                !std.mem.eql(u8, std.fs.path.basename(runtime_root_path), "bin"))
                flat
            else
                managed;
            break :blk WevalTool{
                .selected = selected,
                .package_root = std.fs.path.dirname(selected).?,
                .provenance = selected,
            };
        }
    else
        null;
    const requested_weval = if (resolved_weval) |tool| tool.selected else null;
    const parent_root = std.fs.path.dirname(runtime_root_path) orelse
        return error.InvalidPath;
    const managed_weval_root = try std.fs.path.join(
        allocator,
        &.{ parent_root, "weval-package" },
    );
    const managed_layout = if (bundle) |value|
        std.mem.eql(u8, std.fs.path.basename(runtime_root_path), "bin") and
            pathContains(runtime_root_path, value.cache) and
            pathContains(runtime_root_path, value.manifest) and
            pathContains(managed_weval_root, requested_weval.?)
    else
        false;
    const package_root = if (managed_layout) parent_root else runtime_root_path;
    const runtime_relative = try std.fs.path.relative(
        allocator,
        "/",
        null,
        package_root,
        runtime_root_path,
    );
    const engine_basename = std.fs.path.basename(requested_engine);
    const package_capture = captureDirectoryWithHook(
        allocator,
        io,
        package_root,
        config.aot,
        .{
            .environ = environ,
            .entry_name = if (runtime_relative.len == 0 or
                std.mem.eql(u8, runtime_relative, "."))
                engine_basename
            else
                std.fs.path.basename(runtime_root_path),
            .phase = "external-package-engine-captured",
        },
    ) catch |err| switch (err) {
        error.WevalPackageRace => return error.TransactionChanged,
        else => return error.InvalidEngineProvenance,
    };
    errdefer package_capture.close(io);
    const runtime_root = capturedPackageDirectoryPath(
        package_capture.root,
        runtime_relative,
    ) orelse return error.InvalidEngineProvenance;
    const engine_capture = capturedPackageFile(
        runtime_root,
        engine_basename,
    ) orelse return error.InvalidEngineProvenance;
    const engine = requested_engine;
    const provenance = try readEngineProvenance(
        allocator,
        io,
        engine_capture,
    );
    const adapter = try std.fs.path.join(
        allocator,
        &.{ runtime_root_path, "preview1-adapter.wasm" },
    );
    const adapter_capture = capturedPackageFile(
        runtime_root,
        "preview1-adapter.wasm",
    ) orelse return error.InvalidEngineProvenance;
    if (config.preview2_adapter) |path| {
        const supplied = try absolutePath(allocator, cwd, path);
        if (!std.mem.eql(u8, supplied, adapter))
            return error.InvalidEngineProvenance;
    }
    const features_capture = capturedPackageFile(
        runtime_root,
        "features.json",
    ) orelse return error.InvalidEngineProvenance;
    try validateExternalFeatures(
        allocator,
        io,
        features_capture,
        provenance.features,
    );
    const component_wit = try std.fs.path.join(
        allocator,
        &.{ runtime_root_path, "component-wit" },
    );
    const surface_wit = try std.fs.path.join(
        allocator,
        &.{ runtime_root_path, "surface-wit" },
    );
    const component_wit_capture = capturedPackageDirectory(
        runtime_root,
        "component-wit",
    ) orelse return error.InvalidEngineProvenance;
    const surface_wit_capture = capturedPackageDirectory(
        runtime_root,
        "surface-wit",
    ) orelse return error.InvalidEngineProvenance;
    const feature_wit_capture = capturedPackageDirectory(
        runtime_root,
        "feature-wit",
    ) orelse return error.InvalidEngineProvenance;
    const supplied_surface_wit = if (config.wit) |path| blk: {
        if (!std.mem.eql(u8, config.world_name.?, provenance.surface_world))
            return error.InvalidEngineProvenance;
        const supplied_path = try absolutePath(allocator, cwd, path);
        if (std.mem.eql(u8, supplied_path, surface_wit))
            break :blk null;
        const captured = captureDirectory(
            allocator,
            io,
            supplied_path,
            false,
        ) catch |err| switch (err) {
            error.TransactionChanged => return err,
            else => return error.InvalidEngineProvenance,
        };
        const supplied_digest = capturedDirectoryDigest(captured);
        const packaged_digest = capturedPackageDirectoryDigest(
            surface_wit_capture,
        );
        if (!std.mem.eql(
            u8,
            &supplied_digest,
            &packaged_digest,
        )) {
            captured.close(io);
            return error.InvalidEngineProvenance;
        }
        break :blk @as(?CapturedDirectory, captured);
    } else null;
    errdefer if (supplied_surface_wit) |tree| tree.close(io);
    const supplied_component_wit = if (config.component_wit) |path| blk: {
        const supplied_path = try absolutePath(allocator, cwd, path);
        if (std.mem.eql(u8, supplied_path, component_wit))
            break :blk null;
        const captured = captureDirectory(
            allocator,
            io,
            supplied_path,
            false,
        ) catch |err| switch (err) {
            error.TransactionChanged => return err,
            else => return error.InvalidEngineProvenance,
        };
        const supplied_digest = capturedDirectoryDigest(captured);
        const packaged_digest = capturedPackageDirectoryDigest(
            component_wit_capture,
        );
        if (!std.mem.eql(
            u8,
            &supplied_digest,
            &packaged_digest,
        )) {
            captured.close(io);
            return error.InvalidEngineProvenance;
        }
        break :blk @as(?CapturedDirectory, captured);
    } else null;
    errdefer if (supplied_component_wit) |tree| tree.close(io);
    if (config.component_world_name) |world| {
        if (!std.mem.eql(u8, world, provenance.component_world))
            return error.InvalidEngineProvenance;
    }
    try validateExternalEngineInventory(
        runtime_root,
        engine_basename,
    );
    const cache_relative = if (bundle) |value|
        try std.fs.path.relative(
            allocator,
            "/",
            null,
            package_root,
            value.cache,
        )
    else
        null;
    const manifest_relative = if (bundle) |value|
        try std.fs.path.relative(
            allocator,
            "/",
            null,
            package_root,
            value.manifest,
        )
    else
        null;
    const captured_cache = if (cache_relative) |relative|
        if (safePackageRelativePath(relative))
            capturedPackageFilePath(package_capture.root, relative)
        else
            null
    else
        null;
    const captured_manifest = if (manifest_relative) |relative|
        if (safePackageRelativePath(relative))
            capturedPackageFilePath(package_capture.root, relative)
        else
            null
    else
        null;
    if (bundle != null and (captured_cache == null or captured_manifest == null))
        return error.MissingAotCache;
    const weval_package_relative = "weval-package";
    const weval_package_capture = if (bundle != null)
        capturedPackageDirectoryPath(
            package_capture.root,
            weval_package_relative,
        ) orelse return error.MissingAotCache
    else
        null;
    const selected_weval_relative = if (requested_weval) |path|
        try std.fs.path.relative(
            allocator,
            "/",
            null,
            try std.fs.path.join(
                allocator,
                &.{ package_root, weval_package_relative },
            ),
            path,
        )
    else
        null;
    if (selected_weval_relative) |relative| {
        if (!safePackageRelativePath(relative))
            return error.MissingAotCache;
    }
    const external_capture = try allocator.create(CapturedExternalRuntime);
    external_capture.* = .{
        .package = package_capture,
        .runtime_root = runtime_root,
        .engine = engine_capture,
        .adapter = adapter_capture,
        .features = features_capture,
        .component_wit = component_wit_capture,
        .surface_wit = surface_wit_capture,
        .feature_wit = feature_wit_capture,
        .aot_cache = captured_cache,
        .aot_manifest = captured_manifest,
        .weval_package = weval_package_capture,
        .weval_selected_relative = selected_weval_relative,
        .weval = resolved_weval,
        .supplied_surface_wit = supplied_surface_wit,
        .supplied_component_wit = supplied_component_wit,
    };
    const expected_feature_abi = try aot_cache.featureAbi(
        allocator,
        provenance.features.stdio,
        provenance.features.random,
        provenance.features.clocks,
        provenance.features.http,
        provenance.features.@"fetch-event",
        "ReleaseSmall",
        provenance.host_api,
        true,
    );
    return .{
        .engine = engine,
        .engine_capture = null,
        .external_capture = external_capture,
        .adapter = adapter,
        .component_wit = component_wit,
        .component_world = provenance.component_world,
        .surface_world = provenance.surface_world,
        .bindings = null,
        .aot_cache = if (bundle) |value| .{
            .cache = value.cache,
            .manifest = value.manifest,
            .expected_feature_abi = expected_feature_abi,
        } else null,
        .cache_lock = null,
    };
}

fn snapshotExternalRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    config: *const cli.Config,
    wasm_tools: CapturedTool,
    transaction_dir: []const u8,
    runtime: *Runtime,
) !void {
    const captured = runtime.external_capture.?;
    const snapshot_engine = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "external-engine.wasm" },
    );
    const snapshot_adapter = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "external-adapter.wasm" },
    );
    const snapshot_component_wit = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "external-component-wit" },
    );
    const snapshot_surface_wit = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "external-surface-wit" },
    );
    const snapshot_feature_wit = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "external-feature-wit" },
    );
    try copyCapturedPackageFile(io, captured.engine, snapshot_engine);
    try copyCapturedPackageFile(io, captured.adapter, snapshot_adapter);
    try copyCapturedPackageDirectoryToPath(
        io,
        captured.component_wit,
        snapshot_component_wit,
    );
    try copyCapturedPackageDirectoryToPath(
        io,
        captured.surface_wit,
        snapshot_surface_wit,
    );
    try copyCapturedPackageDirectoryToPath(
        io,
        captured.feature_wit,
        snapshot_feature_wit,
    );
    const readonly_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o400)
    else
        .default_file;
    try setRegularFilePermissions(io, snapshot_engine, readonly_permissions);
    try setRegularFilePermissions(io, snapshot_adapter, readonly_permissions);
    try verifyCapturedExternalRuntime(io, captured);

    var command_log: std.ArrayList(u8) = .empty;
    try validateWitWorld(
        allocator,
        io,
        cwd,
        config.verbose,
        wasm_tools,
        snapshot_component_wit,
        runtime.component_world.?,
        transaction_dir,
        "component",
        &command_log,
    );
    try validateWitWorld(
        allocator,
        io,
        cwd,
        config.verbose,
        wasm_tools,
        snapshot_surface_wit,
        runtime.surface_world.?,
        transaction_dir,
        "surface",
        &command_log,
    );
    const feature_output = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "validated-feature-wit.wasm" },
    );
    runCapturedToolCommand(
        allocator,
        io,
        "validate external feature WIT",
        wasm_tools,
        &.{
            wasm_tools.executable,
            "component",
            "wit",
            "--wasm",
            "--output",
            feature_output,
            snapshot_feature_wit,
        },
        cwd,
        null,
        null,
        config.verbose,
        &command_log,
    ) catch |err| switch (err) {
        error.TransactionChanged => return err,
        else => return error.InvalidEngineProvenance,
    };
    try verifyCapturedExternalRuntime(io, captured);
    try runComponentizerTestHook(
        allocator,
        io,
        environ,
        "external-inputs-snapshotted",
    );
    verifyCapturedExternalRuntime(io, captured) catch
        {
            std.debug.print(
                "error: external package changed after snapshot validation\n",
                .{},
            );
            return error.TransactionChanged;
        };
    runtime.engine = snapshot_engine;
    runtime.engine_capture = null;
    runtime.adapter = snapshot_adapter;
    runtime.component_wit = snapshot_component_wit;
}

fn validateWitWorld(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    verbose: bool,
    wasm_tools: CapturedTool,
    wit: []const u8,
    world: []const u8,
    transaction_dir: []const u8,
    label: []const u8,
    command_log: *std.ArrayList(u8),
) !void {
    const output = try std.fs.path.join(
        allocator,
        &.{
            transaction_dir,
            try std.fmt.allocPrint(
                allocator,
                "validated-{s}-wit.wasm",
                .{label},
            ),
        },
    );
    runCapturedToolCommand(
        allocator,
        io,
        "validate external WIT world",
        wasm_tools,
        &.{
            wasm_tools.executable,
            "component",
            "embed",
            "--all-features",
            "--world",
            world,
            "--dummy",
            "--output",
            output,
            wit,
        },
        cwd,
        null,
        null,
        verbose,
        command_log,
    ) catch |err| switch (err) {
        error.TransactionChanged => return err,
        else => return error.InvalidEngineProvenance,
    };
}

fn verifyCapturedExternalRuntime(
    io: Io,
    captured: *CapturedExternalRuntime,
) !void {
    try verifyCapturedDirectory(io, captured.package);
    if (captured.supplied_surface_wit) |tree|
        try verifyCapturedDirectory(io, tree);
    if (captured.supplied_component_wit) |tree|
        try verifyCapturedDirectory(io, tree);
}

fn readEngineProvenance(
    allocator: Allocator,
    io: Io,
    engine: CapturedPackageFile,
) !EngineProvenance {
    var header: [8]u8 = undefined;
    try readCapturedExact(io, engine, &header, 0);
    if (!std.mem.eql(u8, &header, "\x00asm\x01\x00\x00\x00"))
        return error.InvalidEngineProvenance;
    var offset: u64 = header.len;
    var provenance_json: ?[]const u8 = null;
    while (offset < engine.identity.stat.size) {
        var section_id: [1]u8 = undefined;
        try readCapturedExact(io, engine, &section_id, offset);
        offset += 1;
        const section_length = try readWasmUleb(io, engine, &offset);
        const section_end = std.math.add(
            u64,
            offset,
            section_length,
        ) catch return error.InvalidEngineProvenance;
        if (section_end > engine.identity.stat.size)
            return error.InvalidEngineProvenance;
        if (section_id[0] == 0) {
            const name_length = try readWasmUleb(io, engine, &offset);
            if (name_length > 256 or name_length > section_end - offset)
                return error.InvalidEngineProvenance;
            const name = try allocator.alloc(u8, @intCast(name_length));
            try readCapturedExact(io, engine, name, offset);
            offset += name_length;
            if (std.mem.eql(u8, name, "starling:engine-provenance")) {
                if (provenance_json != null)
                    return error.InvalidEngineProvenance;
                const json_length = section_end - offset;
                if (json_length == 0 or json_length > 16 * 1024)
                    return error.InvalidEngineProvenance;
                const json = try allocator.alloc(
                    u8,
                    @intCast(json_length),
                );
                try readCapturedExact(io, engine, json, offset);
                provenance_json = json;
            }
        }
        offset = section_end;
    }
    const parsed = std.json.parseFromSliceLeaky(
        EngineProvenance,
        allocator,
        provenance_json orelse return error.InvalidEngineProvenance,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidEngineProvenance;
    if (parsed.schema != 1 or
        parsed.host_api.len == 0 or
        parsed.component_world.len == 0 or
        parsed.surface_world.len == 0)
        return error.InvalidEngineProvenance;
    try validateRuntimeText(parsed.host_api);
    try validateRuntimeText(parsed.component_world);
    try validateRuntimeText(parsed.surface_world);
    try verifyCapturedPackageFile(io, engine);
    return parsed;
}

fn readWasmUleb(
    io: Io,
    engine: CapturedPackageFile,
    offset: *u64,
) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    for (0..10) |_| {
        var byte: [1]u8 = undefined;
        try readCapturedExact(io, engine, &byte, offset.*);
        offset.* += 1;
        const value = @as(u64, byte[0] & 0x7f);
        if (shift == 63 and value > 1)
            return error.InvalidEngineProvenance;
        result |= value << shift;
        if (byte[0] & 0x80 == 0) return result;
        if (shift > 56) return error.InvalidEngineProvenance;
        shift += 7;
    }
    return error.InvalidEngineProvenance;
}

fn readCapturedExact(
    io: Io,
    captured: CapturedPackageFile,
    buffer: []u8,
    offset: u64,
) !void {
    if (offset > captured.identity.stat.size or
        buffer.len > captured.identity.stat.size - offset)
        return error.InvalidEngineProvenance;
    if (try captured.file.readPositionalAll(io, buffer, offset) != buffer.len)
        return error.InvalidEngineProvenance;
}

fn validateExternalFeatures(
    allocator: Allocator,
    io: Io,
    captured: CapturedPackageFile,
    expected: EngineFeatures,
) !void {
    if (captured.identity.stat.size == 0 or
        captured.identity.stat.size > 16 * 1024)
        return error.InvalidEngineProvenance;
    const data = try allocator.alloc(
        u8,
        @intCast(captured.identity.stat.size),
    );
    try readCapturedExact(io, captured, data, 0);
    const actual = std.json.parseFromSliceLeaky(
        EngineFeatures,
        allocator,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidEngineProvenance;
    if (!std.meta.eql(actual, expected))
        return error.InvalidEngineProvenance;
}

fn validateExternalEngineInventory(
    dir: *CapturedPackageDirectory,
    engine_basename: []const u8,
) !void {
    for (dir.entries) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".wasm") and
            !std.mem.eql(u8, entry.name, engine_basename) and
            !std.mem.eql(u8, entry.name, "preview1-adapter.wasm"))
            return error.InvalidEngineProvenance;
    }
}

fn buildRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    build_root: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    needs_initialization: bool,
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
        try resolveExecutable(allocator, io, environ, cwd, path)
    else if (environ.get("ZIG")) |path|
        try resolveExecutable(allocator, io, environ, cwd, path)
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
    if (config.aot) {
        argv.append(allocator, "-Daot-engine=true") catch @panic("out of memory");
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
    if (config.debug_bindings and dispatch_wit != null) {
        argv.append(allocator, "-Dcomponentizer-debug-bindings=true") catch
            @panic("out of memory");
    }

    const zig_global_cache = if (environ.get("ZIG_GLOBAL_CACHE_DIR")) |path|
        try absolutePath(allocator, cwd, path)
    else
        try std.fs.path.join(
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
    );

    const installed_bin = if (config.aot)
        try std.fs.path.join(
            allocator,
            &.{ prefix, ".starling-aot-engine", "current", "bin" },
        )
    else
        try std.fs.path.join(allocator, &.{ prefix, "bin" });
    const engine = try std.fs.path.join(
        allocator,
        &.{ installed_bin, "starling-raw.wasm" },
    );
    try requireFile(io, engine);
    const adapter = if (config.preview2_adapter) |path|
        try absolutePath(allocator, cwd, path)
    else blk: {
        const installed = try std.fs.path.join(
            allocator,
            &.{ installed_bin, "preview1-adapter.wasm" },
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
    const bindings = if (config.debug_bindings and dispatch_wit != null) blk: {
        const path = try std.fs.path.join(
            allocator,
            &.{ installed_bin, "component-bindings.zig" },
        );
        try requireFile(io, path);
        break :blk path;
    } else null;
    const expected_feature_abi = if (config.aot)
        try resolvedFeatureAbi(allocator, config)
    else
        null;
    const aot_bundle = if (config.aot and needs_initialization)
        try resolveAotBundle(
            allocator,
            io,
            cwd,
            config.aot_cache_dir,
            installed_bin,
            expected_feature_abi,
        )
    else
        null;

    return .{
        .engine = engine,
        .engine_capture = null,
        .external_capture = null,
        .adapter = adapter,
        .component_wit = if (component_wit) |wit| wit.absolute else null,
        .component_world = config.component_world_name orelse config.world_name,
        .surface_world = config.world_name,
        .bindings = bindings,
        .aot_cache = aot_bundle,
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
    retained_weval: ?WevalTool,
    needs_wabt: bool,
    needs_initialization: bool,
) !Tools {
    const wizer = if (config.aot or !needs_initialization)
        null
    else if (config.wizer_bin) |path|
        WizerTool{
            .executable = try resolveWizerExecutable(
                allocator,
                io,
                environ,
                cwd,
                path,
            ),
            .wasmtime_subcommand = false,
        }
    else if (config.wasmtime_bin) |path|
        WizerTool{
            .executable = try resolveWizerExecutable(
                allocator,
                io,
                environ,
                cwd,
                path,
            ),
            .wasmtime_subcommand = true,
        }
    else if (environ.get("WIZER_BIN")) |path|
        WizerTool{
            .executable = try resolveWizerExecutable(
                allocator,
                io,
                environ,
                cwd,
                path,
            ),
            .wasmtime_subcommand = false,
        }
    else if (environ.get("WASMTIME_BIN")) |path|
        WizerTool{
            .executable = try resolveWizerExecutable(
                allocator,
                io,
                environ,
                cwd,
                path,
            ),
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
    const wasm_tools_path = if (config.wasm_tools_bin) |path|
        try resolveExecutable(allocator, io, environ, cwd, path)
    else if (environ.get("WASM_TOOLS_BIN")) |path|
        try resolveExecutable(allocator, io, environ, cwd, path)
    else
        try resolveExecutable(
            allocator,
            io,
            environ,
            cwd,
            try siblingOrName(
                allocator,
                io,
                executable_dir,
                "wasm-tools",
                "wasm-tools",
            ),
        );
    const wasm_tools = try captureTool(
        allocator,
        io,
        wasm_tools_path,
    );
    errdefer wasm_tools.close(io);
    const wabt_path = if (!needs_wabt)
        null
    else if (config.wabt_bin) |path|
        try resolveExecutable(allocator, io, environ, cwd, path)
    else if (environ.get("WABT")) |path|
        try resolveExecutable(allocator, io, environ, cwd, path)
    else
        try resolveExecutable(
            allocator,
            io,
            environ,
            cwd,
            try siblingOrName(allocator, io, executable_dir, "wabt", "wabt"),
        );
    const wabt = if (wabt_path) |path|
        try captureTool(allocator, io, path)
    else
        null;
    errdefer if (wabt) |tool| tool.close(io);
    const weval = if (!config.aot or !needs_initialization)
        null
    else if (retained_weval) |tool|
        tool
    else if (config.weval_bin) |path|
        try resolveWevalExecutable(allocator, io, environ, cwd, path)
    else if (environ.get("WEVAL_BIN")) |path|
        try resolveWevalExecutable(allocator, io, environ, cwd, path)
    else blk: {
        const packaged = try std.fs.path.join(
            allocator,
            &.{ executable_dir, "..", "weval-package", "weval" },
        );
        if (pathExists(io, packaged)) {
            break :blk try resolveWevalExecutable(
                allocator,
                io,
                environ,
                cwd,
                packaged,
            );
        }
        const sibling = try std.fs.path.join(allocator, &.{ executable_dir, "weval" });
        if (pathExists(io, sibling)) {
            break :blk try resolveWevalExecutable(
                allocator,
                io,
                environ,
                cwd,
                sibling,
            );
        }
        break :blk try resolveWevalExecutable(
            allocator,
            io,
            environ,
            cwd,
            "weval",
        );
    };
    return .{
        .wizer = wizer,
        .weval = weval,
        .wabt = wabt,
        .wasm_tools = wasm_tools,
    };
}

fn resolveAotBundle(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    override: ?[]const u8,
    default_dir: []const u8,
    expected_feature_abi: ?[]const u8,
) !AotCache {
    const root = if (override) |path|
        try absolutePath(allocator, cwd, path)
    else
        default_dir;
    const stat = Dir.cwd().statFile(io, root, .{}) catch null;
    const cache = if (stat != null and stat.?.kind == .file)
        root
    else
        try std.fs.path.join(allocator, &.{ root, aot_cache.cache_basename });
    const manifest = if (stat != null and stat.?.kind == .file)
        try std.fmt.allocPrint(allocator, "{s}.manifest", .{root})
    else
        try std.fs.path.join(allocator, &.{ root, aot_cache.manifest_basename });
    return .{
        .cache = cache,
        .manifest = manifest,
        .expected_feature_abi = expected_feature_abi,
    };
}

fn validateAotCache(
    allocator: Allocator,
    io: Io,
    engine: []const u8,
    weval: []const u8,
    bundle: AotCache,
) !aot_cache.Validated {
    return aot_cache.validate(
        allocator,
        io,
        engine,
        weval,
        bundle.cache,
        bundle.manifest,
        bundle.expected_feature_abi,
    );
}

fn snapshotAotInputs(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    transaction_dir: []const u8,
    engine: []const u8,
    retained_engine: ?CapturedFile,
    external: ?*CapturedExternalRuntime,
    weval: WevalTool,
    bundle: AotCache,
) !AotSnapshot {
    const captured_engine = if (external == null)
        if (retained_engine) |capture|
            capture
        else
            try captureFile(allocator, io, engine)
    else
        null;
    defer if (external == null and retained_engine == null)
        captured_engine.?.close(io);
    const captured_cache = if (external == null)
        try captureFileWithHook(
            allocator,
            io,
            bundle.cache,
            .{
                .environ = environ,
                .parent_phase = "aot-cache-parent-captured",
                .captured_phase = "aot-cache-file-captured",
            },
        )
    else
        null;
    defer if (captured_cache) |capture| capture.close(io);
    const captured_manifest = if (external == null)
        try captureFile(allocator, io, bundle.manifest)
    else
        null;
    defer if (captured_manifest) |capture| capture.close(io);
    const captured_package = if (external == null)
        try captureWevalPackage(allocator, io, weval)
    else
        null;
    defer if (captured_package) |capture| capture.close(io);
    try runComponentizerTestHook(
        allocator,
        io,
        environ,
        "aot-inputs-captured",
    );

    const snapshot_engine = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "validated-engine.wasm" },
    );
    const snapshot_package_root = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "weval-package" },
    );
    const snapshot_cache = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, aot_cache.cache_basename },
    );
    const snapshot_manifest = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, aot_cache.manifest_basename },
    );
    const snapshot_weval = if (external) |captured| blk: {
        copyCapturedPackageFile(io, captured.engine, snapshot_engine) catch |err|
            return switch (err) {
                error.WevalPackageRace => error.TransactionChanged,
                else => err,
            };
        copyCapturedPackageFile(
            io,
            captured.aot_cache orelse return error.MissingAotCache,
            snapshot_cache,
        ) catch |err| return switch (err) {
            error.WevalPackageRace => error.TransactionChanged,
            else => err,
        };
        copyCapturedPackageFile(
            io,
            captured.aot_manifest orelse return error.MissingAotCache,
            snapshot_manifest,
        ) catch |err| return switch (err) {
            error.WevalPackageRace => error.TransactionChanged,
            else => err,
        };
        const copied = copyCapturedExecutablePackage(
            allocator,
            io,
            captured.weval_package orelse return error.MissingAotCache,
            captured.weval_selected_relative orelse return error.MissingAotCache,
            snapshot_package_root,
        ) catch |err| return switch (err) {
            error.WevalPackageRace => error.TransactionChanged,
            else => err,
        };
        verifyCapturedDirectory(io, captured.package) catch |err|
            return switch (err) {
                error.WevalPackageRace => error.TransactionChanged,
                else => err,
            };
        break :blk copied;
    } else blk: {
        try copyCapturedFile(io, captured_engine.?, snapshot_engine);
        try copyCapturedFile(io, captured_cache.?, snapshot_cache);
        try copyCapturedFile(io, captured_manifest.?, snapshot_manifest);
        const copied = try copyCapturedWevalPackage(
            allocator,
            io,
            captured_package.?,
            snapshot_package_root,
        );
        try verifyCapturedFile(io, captured_engine.?);
        try verifyCapturedFile(io, captured_cache.?);
        try verifyCapturedFile(io, captured_manifest.?);
        try verifyCapturedWevalPackage(io, captured_package.?);
        break :blk copied;
    };
    const readonly_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o400)
    else
        .default_file;
    const executable_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o500)
    else
        .executable_file;
    for ([_][]const u8{ snapshot_engine, snapshot_cache, snapshot_manifest }) |path| {
        try setRegularFilePermissions(io, path, readonly_permissions);
    }
    const snapshot_engine_capture = try captureFile(
        allocator,
        io,
        snapshot_engine,
    );
    errdefer snapshot_engine_capture.close(io);
    const snapshot_cache_capture = try captureFile(
        allocator,
        io,
        snapshot_cache,
    );
    errdefer snapshot_cache_capture.close(io);
    const snapshot_manifest_capture = try captureFile(
        allocator,
        io,
        snapshot_manifest,
    );
    errdefer snapshot_manifest_capture.close(io);
    const snapshot_weval_capture = try captureWevalPackage(
        allocator,
        io,
        .{
            .selected = snapshot_weval.selected,
            .package_root = snapshot_package_root,
            .provenance = snapshot_weval.provenance,
        },
    );
    errdefer snapshot_weval_capture.close(io);
    const handle_engine = try retainedFilePath(
        allocator,
        snapshot_engine_capture.file,
    );
    const handle_cache = try retainedFilePath(
        allocator,
        snapshot_cache_capture.file,
    );
    const handle_manifest = try retainedFilePath(
        allocator,
        snapshot_manifest_capture.file,
    );
    const handle_weval = try retainedPackageExecutablePath(
        allocator,
        snapshot_weval_capture,
    );
    var snapshot_dir = try Dir.openDirAbsolute(
        io,
        transaction_dir,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer snapshot_dir.close(io);
    if ((try snapshot_dir.stat(io)).kind != .directory)
        return error.InvalidPath;
    try snapshot_dir.setPermissions(io, executable_permissions);
    return .{
        .engine = handle_engine,
        .weval = handle_weval,
        .weval_package_root = snapshot_package_root,
        .bundle = .{
            .cache = handle_cache,
            .manifest = handle_manifest,
            .expected_feature_abi = bundle.expected_feature_abi,
        },
        .engine_capture = snapshot_engine_capture,
        .cache_capture = snapshot_cache_capture,
        .manifest_capture = snapshot_manifest_capture,
        .weval_capture = snapshot_weval_capture,
    };
}

const weval_package_max_entries = 4096;
const weval_package_max_depth = 32;
const weval_package_max_bytes: u64 = 1024 * 1024 * 1024;

const SnapshotWeval = struct {
    selected: []const u8,
    provenance: []const u8,
};

const PackageCopyState = struct {
    allocator: Allocator,
    io: Io,
    entries: usize = 0,
    bytes: u64 = 0,
    symlinks: std.ArrayList([]const u8) = .empty,
};

const PackageIdentity = struct {
    stat: File.Stat,
    filesystem: u128,
};

const CapturePackageState = struct {
    allocator: Allocator,
    io: Io,
    allow_symlinks: bool,
    hook: ?CaptureDirectoryHook = null,
    entries: usize = 0,
    bytes: u64 = 0,
};

const CaptureDirectoryHook = struct {
    environ: *std.process.Environ.Map,
    entry_name: []const u8,
    phase: []const u8,
};

fn captureFile(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) !CapturedFile {
    return captureFileWithHook(allocator, io, path, null);
}

const CaptureFileHook = struct {
    environ: *std.process.Environ.Map,
    parent_phase: []const u8,
    captured_phase: []const u8,
};

fn captureFileWithHook(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    hook: ?CaptureFileHook,
) !CapturedFile {
    const parent_path = std.fs.path.dirname(path) orelse
        return error.InvalidPath;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or
        std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, ".."))
        return error.InvalidPath;
    const captured_parent = try captureAbsoluteDirectoryPath(
        allocator,
        io,
        parent_path,
    );
    errdefer captured_parent.close(io);
    if (hook) |test_hook| {
        try runComponentizerTestHook(
            allocator,
            io,
            test_hook.environ,
            test_hook.parent_phase,
        );
    }
    const parent = captured_parent.parent();
    const name_identity = try packagePathIdentity(io, parent, basename);
    var file = try parent.openFile(io, basename, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    errdefer file.close(io);
    const identity = try packageFileIdentity(io, file);
    if (identity.stat.kind != .file or
        !sameStablePackageIdentity(name_identity, identity))
        return error.InvalidPath;
    const digest = try hashPackageFile(io, file);
    if (hook) |test_hook| {
        try runComponentizerTestHook(
            allocator,
            io,
            test_hook.environ,
            test_hook.captured_phase,
        );
    }
    try verifyPackageNameIdentity(io, parent, basename, name_identity);
    try verifyCapturedPath(io, captured_parent);
    return .{
        .path = try allocator.dupe(u8, path),
        .basename = try allocator.dupe(u8, basename),
        .parent_path = captured_parent,
        .file = file,
        .name_identity = name_identity,
        .identity = identity,
        .digest = digest,
    };
}

fn captureAbsoluteDirectoryPath(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) !CapturedPath {
    if (!std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, '\\') != null)
        return error.InvalidPath;
    var root = try Dir.openDirAbsolute(io, "/", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer root.close(io);
    const root_identity = try packageDirectoryIdentity(io, root);
    var ancestors: std.ArrayList(CapturedAncestor) = .empty;
    errdefer {
        var index = ancestors.items.len;
        while (index != 0) {
            index -= 1;
            ancestors.items[index].dir.close(io);
        }
    }
    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |name| {
        if (std.mem.eql(u8, name, ".") or
            std.mem.eql(u8, name, ".."))
            return error.InvalidPath;
        const parent = if (ancestors.items.len == 0)
            root
        else
            ancestors.items[ancestors.items.len - 1].dir;
        const name_identity = try packagePathIdentity(io, parent, name);
        var child = try parent.openDir(io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer child.close(io);
        const identity = try packageDirectoryIdentity(io, child);
        if (identity.stat.kind != .directory or
            !sameStablePackageIdentity(name_identity, identity))
            return error.WevalPackageRace;
        try ancestors.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .dir = child,
            .identity = identity,
        });
    }
    const owned = try ancestors.toOwnedSlice(allocator);
    return .{
        .root = root,
        .root_identity = root_identity,
        .ancestors = owned,
    };
}

fn verifyCapturedPath(io: Io, captured: CapturedPath) !void {
    if (!samePathIdentity(
        captured.root_identity,
        try packageDirectoryIdentity(io, captured.root),
    )) return error.WevalPackageRace;
    for (captured.ancestors, 0..) |ancestor, index| {
        const parent = if (index == 0)
            captured.root
        else
            captured.ancestors[index - 1].dir;
        if (!samePathIdentity(
            ancestor.identity,
            try packageDirectoryIdentity(io, ancestor.dir),
        )) return error.WevalPackageRace;
        try verifyRetainedPathNameIdentity(
            io,
            parent,
            ancestor.name,
            ancestor.identity,
        );
    }
}

fn verifyRetainedPathNameIdentity(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected: PackageIdentity,
) !void {
    var current = parent.openFile(io, name, .{
        .path_only = true,
        .allow_directory = true,
        .follow_symlinks = false,
    }) catch return error.WevalPackageRace;
    defer current.close(io);
    const identity = PackageIdentity{
        .stat = try current.stat(io),
        .filesystem = try packageFilesystemId(current),
    };
    if (!samePathIdentity(expected, identity))
        return error.WevalPackageRace;
}

fn samePathIdentity(left: PackageIdentity, right: PackageIdentity) bool {
    return left.filesystem == right.filesystem and
        left.stat.kind == right.stat.kind and
        left.stat.inode == right.stat.inode;
}

fn copyCapturedFile(
    io: Io,
    captured: CapturedFile,
    destination: []const u8,
) !void {
    return copyCapturedFileContents(
        io,
        captured.file,
        captured.identity,
        captured.digest,
        destination,
    );
}

fn copyCapturedPackageFile(
    io: Io,
    captured: CapturedPackageFile,
    destination: []const u8,
) !void {
    return copyCapturedFileContents(
        io,
        captured.file,
        captured.identity,
        captured.digest,
        destination,
    );
}

fn copyCapturedFileContents(
    io: Io,
    source_file: File,
    source_identity: PackageIdentity,
    source_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    destination: []const u8,
) !void {
    var output = try Dir.createFileAbsolute(io, destination, .{
        .read = true,
        .truncate = true,
    });
    defer output.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < source_identity.stat.size) {
        const count = try source_file.readPositional(
            io,
            &.{&buffer},
            offset,
        );
        if (count == 0) return error.WevalPackageRace;
        hasher.update(buffer[0..count]);
        try output.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &digest, &source_digest))
        return error.WevalPackageRace;
    try output.sync(io);
}

fn verifyCapturedFile(io: Io, captured: CapturedFile) !void {
    const identity = try packageFileIdentity(io, captured.file);
    if (!sameRetainedPackageIdentity(captured.identity, identity))
        return error.WevalPackageRace;
    const digest = try hashPackageFile(io, captured.file);
    if (!std.mem.eql(u8, &digest, &captured.digest))
        return error.WevalPackageRace;
    try verifyRetainedNameIdentity(
        io,
        captured.parent_path.parent(),
        captured.basename,
        captured.name_identity,
    );
    try verifyCapturedPath(io, captured.parent_path);
}

fn verifyCapturedPackageFile(
    io: Io,
    captured: CapturedPackageFile,
) !void {
    const identity = try packageFileIdentity(io, captured.file);
    if (!sameRetainedPackageIdentity(captured.identity, identity))
        return error.WevalPackageRace;
    const digest = try hashPackageFile(io, captured.file);
    if (!std.mem.eql(u8, &digest, &captured.digest))
        return error.WevalPackageRace;
}

fn captureWevalPackage(
    allocator: Allocator,
    io: Io,
    weval: WevalTool,
) !CapturedWevalPackage {
    const tree = try captureDirectory(
        allocator,
        io,
        weval.package_root,
        true,
    );
    const selected_relative = try std.fs.path.relative(
        allocator,
        "/",
        null,
        weval.package_root,
        weval.selected,
    );
    if (std.mem.eql(u8, selected_relative, ".") or
        !safePackageRelativePath(selected_relative))
        return error.UnsafeWevalPackage;
    return .{
        .tree = tree,
        .selected_relative = selected_relative,
    };
}

fn captureDirectory(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    allow_symlinks: bool,
) !CapturedDirectory {
    return captureDirectoryWithHook(
        allocator,
        io,
        path,
        allow_symlinks,
        null,
    );
}

fn captureDirectoryWithHook(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    allow_symlinks: bool,
    hook: ?CaptureDirectoryHook,
) !CapturedDirectory {
    const parent_path = std.fs.path.dirname(path) orelse
        return error.InvalidPath;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or
        std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, ".."))
        return error.InvalidPath;
    const captured_parent = try captureAbsoluteDirectoryPath(
        allocator,
        io,
        parent_path,
    );
    errdefer captured_parent.close(io);
    const parent = captured_parent.parent();
    const name_identity = try packagePathIdentity(io, parent, basename);
    var root_dir = try parent.openDir(io, basename, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer root_dir.close(io);
    const root_identity = try packageDirectoryIdentity(io, root_dir);
    if (root_identity.stat.kind != .directory or
        !sameStablePackageIdentity(name_identity, root_identity))
        return error.WevalPackageRace;
    var state: CapturePackageState = .{
        .allocator = allocator,
        .io = io,
        .allow_symlinks = allow_symlinks,
        .hook = hook,
    };
    const root = try capturePackageDirectory(
        &state,
        root_dir,
        root_identity,
        0,
    );
    if (allow_symlinks)
        try validateCapturedPackageSymlinks(allocator, root);
    try verifyPackageNameIdentity(io, parent, basename, name_identity);
    try verifyCapturedPath(io, captured_parent);
    return .{
        .path = try allocator.dupe(u8, path),
        .basename = try allocator.dupe(u8, basename),
        .parent_path = captured_parent,
        .name_identity = name_identity,
        .root = root,
    };
}

fn safePackageRelativePath(relative: []const u8) bool {
    if (relative.len == 0 or
        std.fs.path.isAbsolute(relative) or
        std.mem.indexOfScalar(u8, relative, '\\') != null)
        return false;
    var components = std.mem.splitScalar(u8, relative, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return false;
    }
    return true;
}

fn capturedPackageEntry(
    captured: *CapturedPackageDirectory,
    name: []const u8,
) ?*const CapturedPackageEntry {
    for (captured.entries) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn normalizeCapturedSymlinkPath(
    allocator: Allocator,
    link_relative: []const u8,
    target: []const u8,
    remaining: []const []const u8,
) ![]const u8 {
    if (target.len == 0 or std.fs.path.isAbsolute(target) or
        std.mem.indexOfScalar(u8, target, '\\') != null)
        return error.UnsafeWevalPackage;
    var components: std.ArrayList([]const u8) = .empty;
    const parent = std.fs.path.dirname(link_relative) orelse "";
    var parent_parts = std.mem.splitScalar(u8, parent, '/');
    while (parent_parts.next()) |component| {
        if (component.len != 0 and !std.mem.eql(u8, component, "."))
            components.append(allocator, component) catch @panic("out of memory");
    }
    var target_parts = std.mem.splitScalar(u8, target, '/');
    while (target_parts.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len == 0)
                return error.UnsafeWevalPackage;
            _ = components.pop();
        } else {
            components.append(allocator, component) catch @panic("out of memory");
        }
    }
    for (remaining) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, "."))
            return error.UnsafeWevalPackage;
        if (std.mem.eql(u8, component, ".."))
            return error.UnsafeWevalPackage;
        components.append(allocator, component) catch @panic("out of memory");
    }
    if (components.items.len == 0)
        return error.UnsafeWevalPackage;
    return std.mem.join(allocator, "/", components.items);
}

fn resolveCapturedPackageEntry(
    allocator: Allocator,
    root: *CapturedPackageDirectory,
    initial_relative: []const u8,
) !struct {
    relative: []const u8,
    entry: *const CapturedPackageEntry,
} {
    var relative = initial_relative;
    var link_count: usize = 0;
    restart: while (true) {
        if (!safePackageRelativePath(relative))
            return error.UnsafeWevalPackage;
        var parts: std.ArrayList([]const u8) = .empty;
        var iterator = std.mem.splitScalar(u8, relative, '/');
        while (iterator.next()) |component|
            parts.append(allocator, component) catch @panic("out of memory");
        var directory = root;
        var prefix: std.ArrayList(u8) = .empty;
        for (parts.items, 0..) |component, index| {
            const entry = capturedPackageEntry(directory, component) orelse
                return error.UnsafeWevalPackage;
            if (entry.value == .sym_link) {
                link_count += 1;
                if (link_count > weval_package_max_depth)
                    return error.UnsafeWevalPackage;
                if (prefix.items.len != 0)
                    prefix.append(allocator, '/') catch @panic("out of memory");
                prefix.appendSlice(allocator, component) catch @panic("out of memory");
                relative = try normalizeCapturedSymlinkPath(
                    allocator,
                    prefix.items,
                    entry.value.sym_link.target,
                    parts.items[index + 1 ..],
                );
                continue :restart;
            }
            if (index + 1 == parts.items.len)
                return .{ .relative = relative, .entry = entry };
            directory = switch (entry.value) {
                .directory => |child| child,
                else => return error.UnsafeWevalPackage,
            };
            if (prefix.items.len != 0)
                prefix.append(allocator, '/') catch @panic("out of memory");
            prefix.appendSlice(allocator, component) catch @panic("out of memory");
        }
        return error.UnsafeWevalPackage;
    }
}

fn validateCapturedPackageSymlinks(
    allocator: Allocator,
    root: *CapturedPackageDirectory,
) !void {
    try validateCapturedPackageDirectorySymlinks(allocator, root, root, "");
}

fn validateCapturedPackageDirectorySymlinks(
    allocator: Allocator,
    root: *CapturedPackageDirectory,
    directory: *CapturedPackageDirectory,
    prefix: []const u8,
) !void {
    for (directory.entries) |entry| {
        const relative = if (prefix.len == 0)
            entry.name
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.value) {
            .directory => |child| try validateCapturedPackageDirectorySymlinks(
                allocator,
                root,
                child,
                relative,
            ),
            .sym_link => {
                _ = try resolveCapturedPackageEntry(allocator, root, relative);
            },
            .file => {},
        }
    }
}

fn capturedDirectoryDigest(
    captured: CapturedDirectory,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    return capturedPackageDirectoryDigest(captured.root);
}

fn capturedPackageDirectoryDigest(
    captured: *CapturedPackageDirectory,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashCapturedPackageDirectory(&hasher, captured);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn capturedPackageFile(
    captured: *CapturedPackageDirectory,
    name: []const u8,
) ?CapturedPackageFile {
    for (captured.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        return switch (entry.value) {
            .file => |file| file,
            else => null,
        };
    }
    return null;
}

fn capturedPackageDirectory(
    captured: *CapturedPackageDirectory,
    name: []const u8,
) ?*CapturedPackageDirectory {
    for (captured.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        return switch (entry.value) {
            .directory => |directory| directory,
            else => null,
        };
    }
    return null;
}

fn capturedPackageDirectoryPath(
    root: *CapturedPackageDirectory,
    relative: []const u8,
) ?*CapturedPackageDirectory {
    if (relative.len == 0 or std.mem.eql(u8, relative, ".")) return root;
    var current = root;
    var components = std.mem.tokenizeScalar(u8, relative, std.fs.path.sep);
    while (components.next()) |component| {
        if (!safePackageRelativePath(component)) return null;
        current = capturedPackageDirectory(current, component) orelse return null;
    }
    return current;
}

fn capturedPackageFilePath(
    root: *CapturedPackageDirectory,
    relative: []const u8,
) ?CapturedPackageFile {
    const dirname = std.fs.path.dirname(relative) orelse ".";
    const parent = capturedPackageDirectoryPath(root, dirname) orelse return null;
    return capturedPackageFile(parent, std.fs.path.basename(relative));
}

fn hashCapturedPackageDirectory(
    hasher: *std.crypto.hash.sha2.Sha256,
    captured: *CapturedPackageDirectory,
) void {
    for (captured.entries) |entry| {
        hasher.update(entry.name);
        hasher.update(&.{0});
        switch (entry.value) {
            .file => |file| {
                hasher.update("file\x00");
                hasher.update(&file.digest);
            },
            .directory => |directory| {
                hasher.update("directory\x00");
                hashCapturedPackageDirectory(hasher, directory);
            },
            .sym_link => |link| {
                hasher.update("symlink\x00");
                hasher.update(link.target);
            },
        }
        hasher.update(&.{0xff});
    }
}

fn capturePackageDirectory(
    state: *CapturePackageState,
    dir: Dir,
    identity: PackageIdentity,
    depth: usize,
) anyerror!*CapturedPackageDirectory {
    if (depth > weval_package_max_depth)
        return error.WevalPackageTooDeep;
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(state.io)) |entry| {
        if (state.entries >= weval_package_max_entries)
            return error.WevalPackageTooLarge;
        state.entries += 1;
        names.append(
            state.allocator,
            try state.allocator.dupe(u8, entry.name),
        ) catch @panic("out of memory");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    const entries = try state.allocator.alloc(
        CapturedPackageEntry,
        names.items.len,
    );
    for (names.items, 0..) |name, index| {
        const entry_identity = try packagePathIdentity(
            state.io,
            dir,
            name,
        );
        entries[index] = .{
            .name = name,
            .value = switch (entry_identity.stat.kind) {
                .file => blk: {
                    if (entry_identity.stat.size >
                        weval_package_max_bytes - state.bytes)
                        return error.WevalPackageTooLarge;
                    state.bytes += entry_identity.stat.size;
                    const file = try dir.openFile(state.io, name, .{
                        .allow_directory = false,
                        .follow_symlinks = false,
                    });
                    const opened = try packageFileIdentity(state.io, file);
                    if (!sameStablePackageIdentity(
                        entry_identity,
                        opened,
                    )) return error.WevalPackageRace;
                    break :blk .{ .file = .{
                        .file = file,
                        .identity = opened,
                        .digest = try hashPackageFile(state.io, file),
                    } };
                },
                .directory => blk: {
                    const child = try dir.openDir(state.io, name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    });
                    const opened = try packageDirectoryIdentity(
                        state.io,
                        child,
                    );
                    if (!sameStablePackageIdentity(
                        entry_identity,
                        opened,
                    )) return error.WevalPackageRace;
                    break :blk .{ .directory = try capturePackageDirectory(
                        state,
                        child,
                        opened,
                        depth + 1,
                    ) };
                },
                .sym_link => blk: {
                    if (!state.allow_symlinks)
                        return error.UnsafeWevalPackage;
                    const file = try dir.openFile(state.io, name, .{
                        .path_only = true,
                        .allow_directory = true,
                        .follow_symlinks = false,
                    });
                    const opened = try packageFileIdentity(state.io, file);
                    if (!sameStablePackageIdentity(
                        entry_identity,
                        opened,
                    )) return error.WevalPackageRace;
                    var target_buffer: [Dir.max_path_bytes]u8 = undefined;
                    const target_len = try dir.readLink(
                        state.io,
                        name,
                        &target_buffer,
                    );
                    const target = target_buffer[0..target_len];
                    if (target.len == 0 or std.fs.path.isAbsolute(target))
                        return error.UnsafeWevalPackage;
                    break :blk .{ .sym_link = .{
                        .file = file,
                        .identity = opened,
                        .target = try state.allocator.dupe(u8, target),
                    } };
                },
                else => return error.UnsafeWevalPackage,
            },
        };
        try verifyPackageNameIdentity(
            state.io,
            dir,
            name,
            entry_identity,
        );
        if (depth == 0) {
            if (state.hook) |hook| {
                if (std.mem.eql(u8, name, hook.entry_name)) {
                    try runComponentizerTestHook(
                        state.allocator,
                        state.io,
                        hook.environ,
                        hook.phase,
                    );
                    state.hook = null;
                }
            }
        }
    }
    if (!sameStablePackageIdentity(
        identity,
        try packageDirectoryIdentity(state.io, dir),
    )) return error.WevalPackageRace;
    const captured = try state.allocator.create(CapturedPackageDirectory);
    captured.* = .{
        .dir = dir,
        .identity = identity,
        .entries = entries,
    };
    return captured;
}

fn closeCapturedPackageDirectory(
    io: Io,
    captured: *CapturedPackageDirectory,
) void {
    for (captured.entries) |entry| switch (entry.value) {
        .file => |file| file.file.close(io),
        .directory => |directory| closeCapturedPackageDirectory(
            io,
            directory,
        ),
        .sym_link => |link| link.file.close(io),
    };
    captured.dir.close(io);
}

fn copyCapturedWevalPackage(
    allocator: Allocator,
    io: Io,
    captured: CapturedWevalPackage,
    destination_path: []const u8,
) !SnapshotWeval {
    return copyCapturedExecutablePackage(
        allocator,
        io,
        captured.tree.root,
        captured.selected_relative,
        destination_path,
    );
}

fn copyCapturedExecutablePackage(
    allocator: Allocator,
    io: Io,
    root: *CapturedPackageDirectory,
    selected_relative: []const u8,
    destination_path: []const u8,
) !SnapshotWeval {
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    try Dir.createDirAbsolute(io, destination_path, private_permissions);
    var destination = try Dir.openDirAbsolute(io, destination_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer destination.close(io);
    try copyCapturedPackageDirectory(io, root, destination);
    const selected = try std.fs.path.join(
        allocator,
        &.{ destination_path, selected_relative },
    );
    const provenance = Dir.realPathFileAbsoluteAlloc(
        io,
        selected,
        allocator,
    ) catch return error.UnsafeWevalPackage;
    if (!pathContains(destination_path, provenance))
        return error.UnsafeWevalPackage;
    try requireExecutableFile(allocator, io, selected);
    return .{ .selected = selected, .provenance = provenance };
}

fn captureTool(
    allocator: Allocator,
    io: Io,
    executable: []const u8,
) !CapturedTool {
    const package_root = std.fs.path.dirname(executable) orelse
        return error.InvalidPath;
    const package = try captureWevalPackage(
        allocator,
        io,
        .{
            .selected = executable,
            .package_root = package_root,
            .provenance = executable,
        },
    );
    return .{
        .provenance = try allocator.dupe(u8, executable),
        .executable = try allocator.dupe(u8, executable),
        .package = package,
    };
}

fn snapshotTools(
    allocator: Allocator,
    io: Io,
    transaction_dir: []const u8,
    tools: *Tools,
) !void {
    try snapshotTool(
        allocator,
        io,
        transaction_dir,
        "wasm-tools",
        &tools.wasm_tools,
    );
    if (tools.wabt) |*tool| {
        try snapshotTool(
            allocator,
            io,
            transaction_dir,
            "wabt",
            tool,
        );
    }
}

fn snapshotTool(
    allocator: Allocator,
    io: Io,
    transaction_dir: []const u8,
    label: []const u8,
    tool: *CapturedTool,
) !void {
    const destination = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, try std.fmt.allocPrint(
            allocator,
            "tool-{s}",
            .{label},
        ) },
    );
    const snapshot = copyCapturedWevalPackage(
        allocator,
        io,
        tool.package,
        destination,
    ) catch |err| switch (err) {
        error.WevalPackageRace => {
            std.debug.print(
                "error: resolved {s} package changed before snapshot\n",
                .{tool.provenance},
            );
            return error.TransactionChanged;
        },
        else => return err,
    };
    verifyCapturedWevalPackage(io, tool.package) catch {
        std.debug.print(
            "error: resolved {s} package changed during snapshot\n",
            .{tool.provenance},
        );
        return error.TransactionChanged;
    };
    const snapshot_package = try captureWevalPackage(
        allocator,
        io,
        .{
            .selected = snapshot.selected,
            .package_root = destination,
            .provenance = snapshot.provenance,
        },
    );
    errdefer snapshot_package.close(io);
    const retained_plan = try createRetainedExecPlan(
        allocator,
        io,
        snapshot_package,
    );
    errdefer retained_plan.close(io);
    tool.executable = try retainedPackageExecutablePath(
        allocator,
        snapshot_package,
    );
    tool.snapshot_package = snapshot_package;
    tool.retained_plan = retained_plan;
}

fn verifyCapturedTools(io: Io, tools: Tools) !void {
    try verifyCapturedWevalPackage(io, tools.wasm_tools.package);
    try verifySnapshotTool(io, tools.wasm_tools);
    if (tools.wabt) |tool| {
        try verifyCapturedWevalPackage(io, tool.package);
        try verifySnapshotTool(io, tool);
    }
}

fn verifySnapshotTool(io: Io, tool: CapturedTool) !void {
    try verifyCapturedWevalPackage(
        io,
        tool.snapshot_package orelse return error.TransactionChanged,
    );
    try (tool.retained_plan orelse return error.TransactionChanged).verify(io);
}

fn verifyToolTransaction(io: Io, tool: CapturedTool) !void {
    try verifyCapturedWevalPackage(io, tool.package);
    try verifySnapshotTool(io, tool);
}

fn retainedFilePath(allocator: Allocator, file: File) ![]const u8 {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    switch (std.posix.errno(std.posix.system.fcntl(
        file.handle,
        std.posix.F.SETFD,
        @as(usize, 0),
    ))) {
        .SUCCESS => {},
        else => return error.MissingBuildArtifact,
    }
    return std.fmt.allocPrint(
        allocator,
        "/proc/self/fd/{d}",
        .{file.handle},
    );
}

fn retainedPackageExecutablePath(
    allocator: Allocator,
    package: CapturedWevalPackage,
) ![]const u8 {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    return std.fs.path.join(
        allocator,
        &.{ package.tree.path, package.selected_relative },
    );
}

const RetainedExecPlan = struct {
    helper_argv: []const []const u8,
    files: []const File,
    captures: []const CapturedFile,

    fn close(plan: RetainedExecPlan, io: Io) void {
        for (plan.files) |file| file.close(io);
        for (plan.captures) |capture| capture.close(io);
    }

    fn verify(plan: RetainedExecPlan, io: Io) !void {
        for (plan.captures) |capture| try verifyCapturedFile(io, capture);
    }
};

const ElfClosureInfo = struct {
    interpreter: ?[]const u8,
    needed: []const []const u8,
    runpath: ?[]const u8,
};

const RuntimeLibrary = struct {
    name: []const u8,
    source: CapturedPackageFile,
};

const RuntimeObject = struct {
    source: CapturedPackageFile,
    package_relative: ?[]const u8,
};

fn readPositionalExact(
    io: Io,
    file: File,
    buffer: []u8,
    offset: u64,
) !void {
    var completed: usize = 0;
    while (completed < buffer.len) {
        const count = try file.readPositional(
            io,
            &.{buffer[completed..]},
            offset + completed,
        );
        if (count == 0) return error.UnsupportedRetainedExecution;
        completed += count;
    }
}

fn readLeInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn readElfClosureInfo(
    allocator: Allocator,
    io: Io,
    source: CapturedPackageFile,
) !ElfClosureInfo {
    var header: [64]u8 = undefined;
    if (source.identity.stat.size < header.len)
        return error.UnsupportedRetainedExecution;
    try readPositionalExact(io, source.file, &header, 0);
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or
        header[4] != std.elf.ELFCLASS64 or
        header[5] != std.elf.ELFDATA2LSB)
        return error.UnsupportedRetainedExecution;
    const phoff = readLeInt(u64, header[32..40]);
    const phentsize = readLeInt(u16, header[54..56]);
    const phnum = readLeInt(u16, header[56..58]);
    if (phentsize < 56 or phnum > 256)
        return error.UnsupportedRetainedExecution;
    const Load = struct { offset: u64, vaddr: u64, filesz: u64 };
    var loads: std.ArrayList(Load) = .empty;
    var interpreter_offset: ?u64 = null;
    var interpreter_size: u64 = 0;
    var dynamic_offset: ?u64 = null;
    var dynamic_size: u64 = 0;
    var ph: [56]u8 = undefined;
    for (0..phnum) |index| {
        const delta = std.math.mul(
            u64,
            @intCast(index),
            phentsize,
        ) catch return error.UnsupportedRetainedExecution;
        const offset = std.math.add(
            u64,
            phoff,
            delta,
        ) catch return error.UnsupportedRetainedExecution;
        if (offset > source.identity.stat.size or
            source.identity.stat.size - offset < ph.len)
            return error.UnsupportedRetainedExecution;
        try readPositionalExact(io, source.file, &ph, offset);
        const kind = readLeInt(u32, ph[0..4]);
        const file_offset = readLeInt(u64, ph[8..16]);
        const vaddr = readLeInt(u64, ph[16..24]);
        const filesz = readLeInt(u64, ph[32..40]);
        switch (kind) {
            std.elf.PT_LOAD => loads.append(
                allocator,
                .{ .offset = file_offset, .vaddr = vaddr, .filesz = filesz },
            ) catch @panic("out of memory"),
            std.elf.PT_INTERP => {
                interpreter_offset = file_offset;
                interpreter_size = filesz;
            },
            std.elf.PT_DYNAMIC => {
                dynamic_offset = file_offset;
                dynamic_size = filesz;
            },
            else => {},
        }
    }
    const interpreter = if (interpreter_offset) |offset| blk: {
        if (interpreter_size < 2 or interpreter_size > 4096 or
            offset > source.identity.stat.size or
            source.identity.stat.size - offset < interpreter_size)
            return error.UnsupportedRetainedExecution;
        const bytes = try allocator.alloc(u8, @intCast(interpreter_size));
        try readPositionalExact(io, source.file, bytes, offset);
        if (bytes[bytes.len - 1] != 0)
            return error.UnsupportedRetainedExecution;
        break :blk bytes[0 .. bytes.len - 1];
    } else null;
    const dyn_offset = dynamic_offset orelse return .{
        .interpreter = interpreter,
        .needed = &.{},
        .runpath = null,
    };
    if (dynamic_size > 1024 * 1024 or
        dyn_offset > source.identity.stat.size or
        source.identity.stat.size - dyn_offset < dynamic_size)
        return error.UnsupportedRetainedExecution;
    var needed_offsets: std.ArrayList(u64) = .empty;
    var string_vaddr: ?u64 = null;
    var string_size: ?u64 = null;
    var runpath_offset: ?u64 = null;
    var dynamic_entry: [16]u8 = undefined;
    var cursor: u64 = 0;
    while (cursor + dynamic_entry.len <= dynamic_size) : (cursor += dynamic_entry.len) {
        try readPositionalExact(
            io,
            source.file,
            &dynamic_entry,
            dyn_offset + cursor,
        );
        const tag = readLeInt(i64, dynamic_entry[0..8]);
        const value = readLeInt(u64, dynamic_entry[8..16]);
        switch (tag) {
            std.elf.DT_NULL => break,
            std.elf.DT_NEEDED => needed_offsets.append(
                allocator,
                value,
            ) catch @panic("out of memory"),
            std.elf.DT_STRTAB => string_vaddr = value,
            std.elf.DT_STRSZ => string_size = value,
            std.elf.DT_RUNPATH => {
                if (runpath_offset != null)
                    return error.UnsupportedRetainedExecution;
                runpath_offset = value;
            },
            std.elf.DT_RPATH => return error.UnsupportedRetainedExecution,
            else => {},
        }
    }
    if (needed_offsets.items.len == 0 and runpath_offset == null)
        return .{ .interpreter = interpreter, .needed = &.{}, .runpath = null };
    const str_vaddr = string_vaddr orelse
        return error.UnsupportedRetainedExecution;
    const str_size = string_size orelse return error.UnsupportedRetainedExecution;
    if (str_size == 0 or str_size > 4 * 1024 * 1024)
        return error.UnsupportedRetainedExecution;
    var str_file_offset: ?u64 = null;
    for (loads.items) |load| {
        if (str_vaddr >= load.vaddr and
            str_vaddr - load.vaddr < load.filesz)
        {
            str_file_offset = std.math.add(
                u64,
                load.offset,
                str_vaddr - load.vaddr,
            ) catch return error.UnsupportedRetainedExecution;
            break;
        }
    }
    const strings_offset = str_file_offset orelse
        return error.UnsupportedRetainedExecution;
    if (strings_offset > source.identity.stat.size or
        source.identity.stat.size - strings_offset < str_size)
        return error.UnsupportedRetainedExecution;
    const strings = try allocator.alloc(u8, @intCast(str_size));
    try readPositionalExact(io, source.file, strings, strings_offset);
    var needed: std.ArrayList([]const u8) = .empty;
    for (needed_offsets.items) |offset| {
        needed.append(
            allocator,
            try elfStringAt(strings, offset),
        ) catch @panic("out of memory");
    }
    return .{
        .interpreter = interpreter,
        .needed = try needed.toOwnedSlice(allocator),
        .runpath = if (runpath_offset) |offset|
            try elfStringAt(strings, offset)
        else
            null,
    };
}

fn elfStringAt(strings: []const u8, offset: u64) ![]const u8 {
    if (offset >= strings.len) return error.UnsupportedRetainedExecution;
    const start: usize = @intCast(offset);
    const end = std.mem.indexOfScalarPos(
        u8,
        strings,
        start,
        0,
    ) orelse return error.UnsupportedRetainedExecution;
    if (end == start) return error.UnsupportedRetainedExecution;
    return strings[start..end];
}

fn capturedPackageSource(captured: CapturedFile) CapturedPackageFile {
    return .{
        .file = captured.file,
        .identity = captured.identity,
        .digest = captured.digest,
    };
}

fn normalizePackageLibraryPath(
    allocator: Allocator,
    origin_relative: []const u8,
    runpath: []const u8,
    library: []const u8,
) ![]const u8 {
    const origin = std.fs.path.dirname(origin_relative) orelse "";
    const suffix = if (std.mem.startsWith(u8, runpath, "$ORIGIN"))
        runpath["$ORIGIN".len..]
    else if (std.mem.startsWith(u8, runpath, "${ORIGIN}"))
        runpath["${ORIGIN}".len..]
    else
        return error.UnsupportedRetainedExecution;
    if (suffix.len != 0 and suffix[0] != '/')
        return error.UnsupportedRetainedExecution;
    const candidate = try std.mem.join(
        allocator,
        "/",
        &.{ origin, std.mem.trimStart(u8, suffix, "/"), library },
    );
    var normalized: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, candidate, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (normalized.items.len == 0)
                return error.UnsupportedRetainedExecution;
            _ = normalized.pop();
        } else {
            normalized.append(allocator, part) catch @panic("out of memory");
        }
    }
    if (normalized.items.len == 0)
        return error.UnsupportedRetainedExecution;
    return std.mem.join(allocator, "/", normalized.items);
}

fn validatePackageRunpath(runpath: []const u8) !void {
    if (runpath.len == 0)
        return error.UnsupportedRetainedExecution;
    var paths = std.mem.splitScalar(u8, runpath, ':');
    while (paths.next()) |path| {
        if (path.len == 0 or std.fs.path.isAbsolute(path))
            return error.UnsupportedRetainedExecution;
        const suffix = if (std.mem.startsWith(u8, path, "$ORIGIN"))
            path["$ORIGIN".len..]
        else if (std.mem.startsWith(u8, path, "${ORIGIN}"))
            path["${ORIGIN}".len..]
        else
            return error.UnsupportedRetainedExecution;
        if (suffix.len != 0 and suffix[0] != '/')
            return error.UnsupportedRetainedExecution;
        if (std.mem.indexOfScalar(u8, suffix, '$') != null)
            return error.UnsupportedRetainedExecution;
    }
}

fn resolvePackageRuntimeLibrary(
    allocator: Allocator,
    root: *CapturedPackageDirectory,
    object_relative: []const u8,
    runpath: ?[]const u8,
    library: []const u8,
) !?struct { relative: []const u8, source: CapturedPackageFile } {
    const value = runpath orelse return null;
    try validatePackageRunpath(value);
    var paths = std.mem.splitScalar(u8, value, ':');
    while (paths.next()) |path| {
        const relative = normalizePackageLibraryPath(
            allocator,
            object_relative,
            path,
            library,
        ) catch return error.UnsupportedRetainedExecution;
        const resolved = resolveCapturedPackageEntry(
            allocator,
            root,
            relative,
        ) catch continue;
        const source = switch (resolved.entry.value) {
            .file => |file| file,
            else => continue,
        };
        return .{ .relative = resolved.relative, .source = source };
    }
    return null;
}

const system_library_directories = [_][]const u8{
    "/usr/lib",
    "/lib",
    "/lib64",
    "/usr/lib64",
    "/usr/lib/x86_64-linux-gnu",
    "/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/lib/aarch64-linux-gnu",
};

fn captureSystemRuntimeFile(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) !CapturedFile {
    const resolved = try resolveExistingFile(allocator, io, "/", path);
    return captureFile(allocator, io, resolved) catch
        return error.UnsupportedRetainedExecution;
}

fn captureSystemRuntimeLibrary(
    allocator: Allocator,
    io: Io,
    name: []const u8,
) !CapturedFile {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null)
        return error.UnsupportedRetainedExecution;
    for (system_library_directories) |directory| {
        const candidate = try std.fs.path.join(
            allocator,
            &.{ directory, name },
        );
        if (!pathExists(io, candidate)) continue;
        return captureSystemRuntimeFile(allocator, io, candidate);
    }
    return error.UnsupportedRetainedExecution;
}

fn captureExecutableRuntimeClosure(
    allocator: Allocator,
    io: Io,
    package: CapturedWevalPackage,
    selected_relative: []const u8,
    selected_entry: *const CapturedPackageEntry,
    libraries: *std.ArrayList(RuntimeLibrary),
    captures: *std.ArrayList(CapturedFile),
) !?CapturedFile {
    const selected_source = switch (selected_entry.value) {
        .file => |file| file,
        else => return error.UnsupportedRetainedExecution,
    };
    const selected_info = try readElfClosureInfo(
        allocator,
        io,
        selected_source,
    );
    if (selected_info.interpreter == null and selected_info.needed.len == 0)
        return null;
    const interpreter = selected_info.interpreter orelse
        return error.UnsupportedRetainedExecution;
    if (!std.fs.path.isAbsolute(interpreter))
        return error.UnsupportedRetainedExecution;
    const loader = try captureSystemRuntimeFile(
        allocator,
        io,
        interpreter,
    );
    captures.append(allocator, loader) catch @panic("out of memory");
    const loader_info = try readElfClosureInfo(
        allocator,
        io,
        capturedPackageSource(loader),
    );
    if (loader_info.interpreter != null or loader_info.needed.len != 0)
        return error.UnsupportedRetainedExecution;
    var objects: std.ArrayList(struct {
        object: RuntimeObject,
        info: ElfClosureInfo,
    }) = .empty;
    objects.append(allocator, .{
        .object = .{
            .source = selected_source,
            .package_relative = selected_relative,
        },
        .info = selected_info,
    }) catch @panic("out of memory");
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    seen.put(
        allocator,
        std.fs.path.basename(loader.path),
        {},
    ) catch @panic("out of memory");
    var object_index: usize = 0;
    while (object_index < objects.items.len) : (object_index += 1) {
        if (objects.items.len > 128)
            return error.UnsupportedRetainedExecution;
        const current = objects.items[object_index];
        if (current.object.package_relative != null) {
            if (current.info.runpath) |runpath|
                try validatePackageRunpath(runpath);
        }
        for (current.info.needed) |name| {
            if (seen.contains(name)) continue;
            seen.put(allocator, name, {}) catch @panic("out of memory");
            if (current.object.package_relative) |relative| {
                if (try resolvePackageRuntimeLibrary(
                    allocator,
                    package.tree.root,
                    relative,
                    current.info.runpath,
                    name,
                )) |package_library| {
                    libraries.append(allocator, .{
                        .name = try allocator.dupe(u8, name),
                        .source = package_library.source,
                    }) catch @panic("out of memory");
                    const info = try readElfClosureInfo(
                        allocator,
                        io,
                        package_library.source,
                    );
                    objects.append(allocator, .{
                        .object = .{
                            .source = package_library.source,
                            .package_relative = package_library.relative,
                        },
                        .info = info,
                    }) catch @panic("out of memory");
                    continue;
                }
            }
            const system = try captureSystemRuntimeLibrary(
                allocator,
                io,
                name,
            );
            captures.append(allocator, system) catch @panic("out of memory");
            libraries.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .source = capturedPackageSource(system),
            }) catch @panic("out of memory");
            const info = try readElfClosureInfo(
                allocator,
                io,
                capturedPackageSource(system),
            );
            objects.append(allocator, .{
                .object = .{
                    .source = capturedPackageSource(system),
                    .package_relative = null,
                },
                .info = info,
            }) catch @panic("out of memory");
        }
    }
    return loader;
}

fn createSealedPackageFile(
    io: Io,
    source: CapturedPackageFile,
) !File {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    const linux = std.os.linux;
    const fd = try std.posix.memfd_create(
        "starling-retained-package",
        linux.MFD.ALLOW_SEALING,
    );
    const sealed: File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    errdefer sealed.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < source.identity.stat.size) {
        const count = try source.file.readPositional(
            io,
            &.{&buffer},
            offset,
        );
        if (count == 0) return error.TransactionChanged;
        hasher.update(buffer[0..count]);
        try sealed.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &digest, &source.digest))
        return error.TransactionChanged;
    try sealed.setPermissions(
        io,
        File.Permissions.fromMode(
            source.identity.stat.permissions.toMode() & 0o777,
        ),
    );
    switch (std.posix.errno(std.posix.system.fcntl(
        sealed.handle,
        linux.F.ADD_SEALS,
        @as(usize, linux.F.SEAL_SEAL | linux.F.SEAL_SHRINK |
            linux.F.SEAL_GROW | linux.F.SEAL_WRITE),
    ))) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    return sealed;
}

fn appendRetainedPackageEntries(
    allocator: Allocator,
    io: Io,
    directory: *CapturedPackageDirectory,
    prefix: []const u8,
    args: *std.ArrayList([]const u8),
    files: *std.ArrayList(File),
) !void {
    if (prefix.len != 0) {
        args.appendSlice(allocator, &.{
            "d",
            prefix,
            try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{directory.identity.stat.permissions.toMode() & 0o777},
            ),
        }) catch @panic("out of memory");
    }
    for (directory.entries) |*entry| {
        const relative = if (prefix.len == 0)
            entry.name
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.value) {
            .file => |source| {
                const sealed = try createSealedPackageFile(io, source);
                files.append(allocator, sealed) catch @panic("out of memory");
                args.appendSlice(allocator, &.{
                    "f",
                    relative,
                    try std.fmt.allocPrint(allocator, "{d}", .{sealed.handle}),
                    try std.fmt.allocPrint(
                        allocator,
                        "{d}",
                        .{source.identity.stat.permissions.toMode() & 0o777},
                    ),
                }) catch @panic("out of memory");
            },
            .directory => |child| try appendRetainedPackageEntries(
                allocator,
                io,
                child,
                relative,
                args,
                files,
            ),
            .sym_link => |link| {
                args.appendSlice(
                    allocator,
                    &.{ "l", relative, link.target },
                ) catch @panic("out of memory");
            },
        }
    }
}

fn createRetainedExecPlan(
    allocator: Allocator,
    io: Io,
    package: CapturedWevalPackage,
) !RetainedExecPlan {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    const selected = try resolveCapturedPackageEntry(
        allocator,
        package.tree.root,
        package.selected_relative,
    );
    if (selected.entry.value != .file)
        return error.UnsafeWevalPackage;
    var entries: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(File) = .empty;
    errdefer for (files.items) |file| file.close(io);
    var captures: std.ArrayList(CapturedFile) = .empty;
    errdefer for (captures.items) |capture| capture.close(io);
    var libraries: std.ArrayList(RuntimeLibrary) = .empty;
    if (capturedPackageEntry(
        package.tree.root,
        ".starling-runtime-v1",
    ) != null) return error.UnsupportedRetainedExecution;
    const loader = try captureExecutableRuntimeClosure(
        allocator,
        io,
        package,
        selected.relative,
        selected.entry,
        &libraries,
        &captures,
    );
    try appendRetainedPackageEntries(
        allocator,
        io,
        package.tree.root,
        "",
        &entries,
        &files,
    );
    if (loader) |captured_loader| {
        entries.appendSlice(allocator, &.{
            "d",
            ".starling-runtime-v1",
            "500",
            "d",
            ".starling-runtime-v1/lib",
            "500",
        }) catch @panic("out of memory");
        const sealed_loader = try createSealedPackageFile(
            io,
            capturedPackageSource(captured_loader),
        );
        files.append(allocator, sealed_loader) catch @panic("out of memory");
        entries.appendSlice(allocator, &.{
            "f",
            ".starling-runtime-v1/loader",
            try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{sealed_loader.handle},
            ),
            "500",
        }) catch @panic("out of memory");
        for (libraries.items) |library| {
            const sealed_library = try createSealedPackageFile(
                io,
                library.source,
            );
            files.append(
                allocator,
                sealed_library,
            ) catch @panic("out of memory");
            entries.appendSlice(allocator, &.{
                "f",
                try std.fmt.allocPrint(
                    allocator,
                    ".starling-runtime-v1/lib/{s}",
                    .{library.name},
                ),
                try std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{sealed_library.handle},
                ),
                "400",
            }) catch @panic("out of memory");
        }
    }
    var namespace_random: [16]u8 = undefined;
    io.random(&namespace_random);
    const namespace_hex = std.fmt.bytesToHex(namespace_random, .lower);
    const host_component = try std.fmt.allocPrint(
        allocator,
        ".__starling-host-{s}",
        .{&namespace_hex},
    );
    const package_component = try std.fmt.allocPrint(
        allocator,
        ".__starling-package-{s}",
        .{&namespace_hex},
    );
    var helper: std.ArrayList([]const u8) = .empty;
    helper.appendSlice(allocator, &.{
        package.tree.path,
        host_component,
        package_component,
        package.selected_relative,
        if (loader != null) "dynamic" else "static",
        try std.fmt.allocPrint(allocator, "{d}", .{entries.items.len}),
    }) catch @panic("out of memory");
    helper.appendSlice(allocator, entries.items) catch @panic("out of memory");
    helper.append(allocator, "--") catch @panic("out of memory");
    return .{
        .helper_argv = try helper.toOwnedSlice(allocator),
        .files = try files.toOwnedSlice(allocator),
        .captures = try captures.toOwnedSlice(allocator),
    };
}

fn copyCapturedDirectory(
    io: Io,
    captured: CapturedDirectory,
    destination_path: []const u8,
) !void {
    return copyCapturedPackageDirectoryToPath(
        io,
        captured.root,
        destination_path,
    );
}

fn copyCapturedPackageDirectoryToPath(
    io: Io,
    captured: *CapturedPackageDirectory,
    destination_path: []const u8,
) !void {
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    try Dir.createDirAbsolute(io, destination_path, private_permissions);
    var destination = try Dir.openDirAbsolute(io, destination_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer destination.close(io);
    try copyCapturedPackageDirectory(io, captured, destination);
}

fn copyCapturedPackageDirectory(
    io: Io,
    captured: *CapturedPackageDirectory,
    destination: Dir,
) anyerror!void {
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    for (captured.entries) |entry| switch (entry.value) {
        .file => |source| {
            var output = try destination.createFile(io, entry.name, .{
                .read = true,
                .exclusive = true,
            });
            defer output.close(io);
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (offset < source.identity.stat.size) {
                const count = try source.file.readPositional(
                    io,
                    &.{&buffer},
                    offset,
                );
                if (count == 0) return error.WevalPackageRace;
                hasher.update(buffer[0..count]);
                try output.writePositionalAll(
                    io,
                    buffer[0..count],
                    offset,
                );
                offset += count;
            }
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
                undefined;
            hasher.final(&digest);
            if (!std.mem.eql(u8, &digest, &source.digest))
                return error.WevalPackageRace;
            try output.setPermissions(
                io,
                immutablePackagePermissions(source.identity.stat.permissions),
            );
            try output.sync(io);
        },
        .directory => |source| {
            try destination.createDir(
                io,
                entry.name,
                private_permissions,
            );
            var child = try destination.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer child.close(io);
            try copyCapturedPackageDirectory(io, source, child);
        },
        .sym_link => |source| {
            try destination.symLink(io, source.target, entry.name, .{});
        },
    };
    try destination.setPermissions(
        io,
        immutablePackagePermissions(captured.identity.stat.permissions),
    );
    try syncPackageDirectory(io, destination);
}

fn verifyCapturedWevalPackage(
    io: Io,
    captured: CapturedWevalPackage,
) !void {
    try verifyCapturedDirectory(io, captured.tree);
}

fn verifyCapturedDirectory(
    io: Io,
    captured: CapturedDirectory,
) !void {
    try verifyCapturedPackageDirectory(io, captured.root);
    try verifyRetainedNameIdentity(
        io,
        captured.parent_path.parent(),
        captured.basename,
        captured.name_identity,
    );
    try verifyCapturedPath(io, captured.parent_path);
}

fn verifyCapturedPackageDirectory(
    io: Io,
    captured: *CapturedPackageDirectory,
) anyerror!void {
    if (!sameRetainedPackageIdentity(
        captured.identity,
        try packageDirectoryIdentity(io, captured.dir),
    )) {
        std.debug.print("error: retained package directory metadata changed\n", .{});
        return error.WevalPackageRace;
    }
    for (captured.entries) |entry| {
        switch (entry.value) {
            .file => |source| {
                if (!sameRetainedPackageIdentity(
                    source.identity,
                    try packageFileIdentity(io, source.file),
                )) {
                    std.debug.print(
                        "error: retained package file changed: {s}\n",
                        .{entry.name},
                    );
                    return error.WevalPackageRace;
                }
                const digest = try hashPackageFile(io, source.file);
                if (!std.mem.eql(u8, &digest, &source.digest)) {
                    std.debug.print(
                        "error: retained package file digest changed: {s}\n",
                        .{entry.name},
                    );
                    return error.WevalPackageRace;
                }
            },
            .directory => |source| try verifyCapturedPackageDirectory(
                io,
                source,
            ),
            .sym_link => |source| {
                if (!sameRetainedPackageIdentity(
                    source.identity,
                    try packageFileIdentity(io, source.file),
                )) {
                    std.debug.print(
                        "error: retained package symlink changed: {s}\n",
                        .{entry.name},
                    );
                    return error.WevalPackageRace;
                }
            },
        }
        try verifyRetainedNameIdentity(
            io,
            captured.dir,
            entry.name,
            switch (entry.value) {
                .file => |source| source.identity,
                .directory => |source| source.identity,
                .sym_link => |source| source.identity,
            },
        );
    }
}

fn snapshotWevalPackage(
    allocator: Allocator,
    io: Io,
    weval: WevalTool,
    destination_path: []const u8,
) !SnapshotWeval {
    var source = try Dir.openDirAbsolute(
        io,
        weval.package_root,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source.close(io);
    const source_identity = try packageDirectoryIdentity(io, source);
    if (source_identity.stat.kind != .directory)
        return error.UnsafeWevalPackage;

    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    try Dir.createDirAbsolute(io, destination_path, private_permissions);
    var destination = try Dir.openDirAbsolute(
        io,
        destination_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer destination.close(io);

    var state: PackageCopyState = .{
        .allocator = allocator,
        .io = io,
    };
    defer state.symlinks.deinit(allocator);
    try copyWevalPackageDirectory(
        &state,
        source,
        destination,
        "",
        0,
        source_identity,
    );

    for (state.symlinks.items) |relative| {
        const snapshot_link = try std.fs.path.join(
            allocator,
            &.{ destination_path, relative },
        );
        const resolved = Dir.realPathFileAbsoluteAlloc(
            io,
            snapshot_link,
            allocator,
        ) catch return error.UnsafeWevalPackage;
        if (!pathContains(destination_path, resolved))
            return error.UnsafeWevalPackage;
    }

    const selected = try std.fs.path.join(
        allocator,
        &.{ destination_path, std.fs.path.basename(weval.selected) },
    );
    const provenance = Dir.realPathFileAbsoluteAlloc(
        io,
        selected,
        allocator,
    ) catch return error.UnsafeWevalPackage;
    if (!pathContains(destination_path, provenance))
        return error.UnsafeWevalPackage;
    const source_relative = try std.fs.path.relative(
        allocator,
        weval.package_root,
        null,
        weval.package_root,
        weval.provenance,
    );
    const snapshot_relative = try std.fs.path.relative(
        allocator,
        destination_path,
        null,
        destination_path,
        provenance,
    );
    if (!std.mem.eql(u8, source_relative, snapshot_relative))
        return error.WevalPackageRace;
    try requireExecutableFile(allocator, io, selected);
    return .{ .selected = selected, .provenance = provenance };
}

fn copyWevalPackageDirectory(
    state: *PackageCopyState,
    source: Dir,
    destination: Dir,
    relative_dir: []const u8,
    depth: usize,
    initial_identity: PackageIdentity,
) anyerror!void {
    if (depth > weval_package_max_depth)
        return error.WevalPackageTooDeep;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(state.allocator);
    var iterator = source.iterate();
    while (try iterator.next(state.io)) |entry| {
        if (state.entries >= weval_package_max_entries)
            return error.WevalPackageTooLarge;
        state.entries += 1;
        names.append(
            state.allocator,
            try state.allocator.dupe(u8, entry.name),
        ) catch @panic("out of memory");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        const relative = if (relative_dir.len == 0)
            try state.allocator.dupe(u8, name)
        else
            try std.fs.path.join(state.allocator, &.{ relative_dir, name });
        const identity = try packagePathIdentity(state.io, source, name);
        switch (identity.stat.kind) {
            .file => try copyWevalPackageFile(
                state,
                source,
                destination,
                name,
                identity,
            ),
            .directory => try copyWevalPackageSubdirectory(
                state,
                source,
                destination,
                name,
                relative,
                depth,
                identity,
            ),
            .sym_link => try copyWevalPackageSymlink(
                state,
                source,
                destination,
                name,
                relative,
                identity,
            ),
            else => return error.UnsafeWevalPackage,
        }
        try verifyPackageNameIdentity(
            state.io,
            source,
            name,
            identity,
        );
    }
    const final_identity = try packageDirectoryIdentity(state.io, source);
    if (!sameStablePackageIdentity(initial_identity, final_identity))
        return error.WevalPackageRace;
    try destination.setPermissions(
        state.io,
        immutablePackagePermissions(initial_identity.stat.permissions),
    );
    try syncPackageDirectory(state.io, destination);
}

fn copyWevalPackageFile(
    state: *PackageCopyState,
    source: Dir,
    destination: Dir,
    name: []const u8,
    identity: PackageIdentity,
) !void {
    if (identity.stat.size > weval_package_max_bytes - state.bytes)
        return error.WevalPackageTooLarge;
    state.bytes += identity.stat.size;
    var input = try source.openFile(state.io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer input.close(state.io);
    const opened_identity = try packageFileIdentity(state.io, input);
    if (!sameStablePackageIdentity(identity, opened_identity))
        return error.WevalPackageRace;
    var output = try destination.createFile(state.io, name, .{
        .read = true,
        .exclusive = true,
    });
    defer output.close(state.io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try input.readPositional(
            state.io,
            &.{&buffer},
            offset,
        );
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        try output.writePositionalAll(state.io, buffer[0..count], offset);
        offset += count;
    }
    if (offset != identity.stat.size)
        return error.WevalPackageRace;
    const final_input = try packageFileIdentity(state.io, input);
    if (!sameStablePackageIdentity(identity, final_input))
        return error.WevalPackageRace;
    try output.setPermissions(
        state.io,
        immutablePackagePermissions(identity.stat.permissions),
    );
    try output.sync(state.io);
    var source_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&source_digest);
    const destination_digest = try hashPackageFile(state.io, output);
    if (!std.mem.eql(u8, &source_digest, &destination_digest))
        return error.WevalPackageRace;
}

fn copyWevalPackageSubdirectory(
    state: *PackageCopyState,
    source: Dir,
    destination: Dir,
    name: []const u8,
    relative: []const u8,
    depth: usize,
    identity: PackageIdentity,
) anyerror!void {
    var input = try source.openDir(state.io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer input.close(state.io);
    const opened_identity = try packageDirectoryIdentity(state.io, input);
    if (!sameStablePackageIdentity(identity, opened_identity))
        return error.WevalPackageRace;
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    try destination.createDir(state.io, name, private_permissions);
    var output = try destination.openDir(state.io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer output.close(state.io);
    try copyWevalPackageDirectory(
        state,
        input,
        output,
        relative,
        depth + 1,
        opened_identity,
    );
}

fn copyWevalPackageSymlink(
    state: *PackageCopyState,
    source: Dir,
    destination: Dir,
    name: []const u8,
    relative: []const u8,
    identity: PackageIdentity,
) !void {
    var target_buffer: [Dir.max_path_bytes]u8 = undefined;
    const target_len = try source.readLink(
        state.io,
        name,
        &target_buffer,
    );
    const target = target_buffer[0..target_len];
    if (target.len == 0 or std.fs.path.isAbsolute(target))
        return error.UnsafeWevalPackage;
    var verify_buffer: [Dir.max_path_bytes]u8 = undefined;
    const verify_len = try source.readLink(
        state.io,
        name,
        &verify_buffer,
    );
    if (!std.mem.eql(u8, target, verify_buffer[0..verify_len]))
        return error.WevalPackageRace;
    try verifyPackageNameIdentity(state.io, source, name, identity);
    try destination.symLink(state.io, target, name, .{});
    state.symlinks.append(
        state.allocator,
        try state.allocator.dupe(u8, relative),
    ) catch @panic("out of memory");
}

fn verifyPackageNameIdentity(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected: PackageIdentity,
) !void {
    var current = parent.openFile(io, name, .{
        .path_only = true,
        .allow_directory = true,
        .follow_symlinks = false,
    }) catch return error.WevalPackageRace;
    defer current.close(io);
    const identity = PackageIdentity{
        .stat = try current.stat(io),
        .filesystem = try packageFilesystemId(current),
    };
    if (!sameStablePackageIdentity(expected, identity))
        return error.WevalPackageRace;
}

fn verifyRetainedNameIdentity(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected: PackageIdentity,
) !void {
    var current = parent.openFile(io, name, .{
        .path_only = true,
        .allow_directory = true,
        .follow_symlinks = false,
    }) catch return error.WevalPackageRace;
    defer current.close(io);
    const identity = PackageIdentity{
        .stat = try current.stat(io),
        .filesystem = try packageFilesystemId(current),
    };
    if (!sameRetainedPackageIdentity(expected, identity))
        return error.WevalPackageRace;
}

fn packagePathIdentity(
    io: Io,
    parent: Dir,
    name: []const u8,
) !PackageIdentity {
    var file = try parent.openFile(io, name, .{
        .path_only = true,
        .allow_directory = true,
        .follow_symlinks = false,
    });
    defer file.close(io);
    return packageFileIdentity(io, file);
}

fn packageFileIdentity(io: Io, file: File) !PackageIdentity {
    return .{
        .stat = try file.stat(io),
        .filesystem = try packageFilesystemId(file),
    };
}

fn packageDirectoryIdentity(io: Io, dir: Dir) !PackageIdentity {
    const file: File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    return packageFileIdentity(io, file);
}

fn sameStablePackageIdentity(
    left: PackageIdentity,
    right: PackageIdentity,
) bool {
    return left.filesystem == right.filesystem and
        left.stat.kind == right.stat.kind and
        left.stat.inode == right.stat.inode and
        left.stat.nlink == right.stat.nlink and
        left.stat.size == right.stat.size and
        left.stat.permissions == right.stat.permissions and
        left.stat.mtime.nanoseconds == right.stat.mtime.nanoseconds and
        left.stat.ctime.nanoseconds == right.stat.ctime.nanoseconds;
}

fn sameRetainedPackageIdentity(
    left: PackageIdentity,
    right: PackageIdentity,
) bool {
    return left.filesystem == right.filesystem and
        left.stat.kind == right.stat.kind and
        left.stat.inode == right.stat.inode and
        left.stat.nlink == right.stat.nlink and
        left.stat.size == right.stat.size and
        left.stat.permissions == right.stat.permissions and
        left.stat.mtime.nanoseconds == right.stat.mtime.nanoseconds;
}

fn immutablePackagePermissions(
    permissions: File.Permissions,
) File.Permissions {
    if (!File.Permissions.has_executable_bit) return permissions;
    return File.Permissions.fromMode(
        permissions.toMode() & ~@as(std.posix.mode_t, 0o222),
    );
}

fn hashPackageFile(io: Io, file: File) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    const before = try file.stat(io);
    if (before.kind != .file) return error.UnsafeWevalPackage;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (offset != before.size)
        return error.WevalPackageRace;
    const after = try file.stat(io);
    if (before.inode != after.inode or before.size != after.size or
        before.mtime.nanoseconds != after.mtime.nanoseconds or
        before.ctime.nanoseconds != after.ctime.nanoseconds)
        return error.WevalPackageRace;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn syncPackageDirectory(io: Io, dir: Dir) !void {
    const file: File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try file.sync(io);
}

fn verifyWevalPackageSnapshot(
    allocator: Allocator,
    io: Io,
    snapshot: AotSnapshot,
) !void {
    verifyCapturedFile(io, snapshot.engine_capture) catch
        return error.TransactionChanged;
    verifyCapturedFile(io, snapshot.cache_capture) catch
        return error.TransactionChanged;
    verifyCapturedFile(io, snapshot.manifest_capture) catch
        return error.TransactionChanged;
    verifyCapturedWevalPackage(io, snapshot.weval_capture) catch
        return error.TransactionChanged;
    try aot_cache.validateWevalPackage(
        allocator,
        io,
        snapshot.weval,
        snapshot.validated orelse return error.InvalidAotCache,
    );
}

const package_c_fstat = struct {
    extern "c" fn fstat(fd: std.c.fd_t, stat: *std.c.Stat) c_int;
}.fstat;

fn packageFilesystemId(file: File) !u128 {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx = std.mem.zeroes(linux.Statx);
        var request = linux.STATX.BASIC_STATS;
        request.MNT_ID = true;
        while (true) switch (linux.errno(linux.statx(
            file.handle,
            "",
            linux.AT.EMPTY_PATH,
            request,
            &statx,
        ))) {
            .SUCCESS => return (@as(u128, statx.dev_major) << 64) |
                @as(u128, statx.dev_minor),
            .INTR => continue,
            else => return error.Unexpected,
        };
    }
    if (comptime builtin.os.tag == .windows) return 0;
    var native: std.c.Stat = undefined;
    while (true) switch (std.c.errno(package_c_fstat(file.handle, &native))) {
        .SUCCESS => return @intCast(native.dev),
        .INTR => continue,
        else => return error.Unexpected,
    };
}

fn setRegularFilePermissions(
    io: Io,
    path: []const u8,
    permissions: File.Permissions,
) !void {
    var file = try Dir.openFileAbsolute(io, path, .{ .allow_directory = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidPath;
    try file.setPermissions(io, permissions);
    try file.sync(io);
}

fn createAotStagingDir(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    executable_dir: []const u8,
    excluded_roots: []const []const u8,
    output_parent: []const u8,
) ![]const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    candidates.append(allocator, executable_dir) catch @panic("out of memory");
    for ([_][]const u8{
        "ZIG_GLOBAL_CACHE_DIR",
        "XDG_RUNTIME_DIR",
        "TMPDIR",
        "TMP",
        "TEMP",
    }) |name| {
        if (environ.get(name)) |path| {
            candidates.append(
                allocator,
                try absolutePath(allocator, cwd, path),
            ) catch @panic("out of memory");
        }
    }
    if (environ.get("STARLING_AOT_CACHE_TEST_DEFAULT_TMPDIR")) |path| {
        candidates.append(
            allocator,
            try absolutePath(allocator, cwd, path),
        ) catch @panic("out of memory");
    } else {
        if (platformDefaultTempRoot()) |root|
            candidates.append(allocator, root) catch @panic("out of memory");
    }
    candidates.append(allocator, cwd) catch @panic("out of memory");

    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    for (candidates.items) |candidate_root| {
        const root = Dir.realPathFileAbsoluteAlloc(
            io,
            candidate_root,
            allocator,
        ) catch continue;
        if (pathContains(output_parent, root)) continue;
        var excluded = false;
        for (excluded_roots) |excluded_root| {
            if (pathContains(excluded_root, root)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fs.path.join(
            allocator,
            &.{ root, try std.fmt.allocPrint(
                allocator,
                ".starling-aot-exec-{s}",
                .{&random_hex},
            ) },
        );
        Dir.createDirAbsolute(io, path, private_permissions) catch continue;
        probeExecutableStagingDir(allocator, io, path) catch {
            Dir.cwd().deleteTree(io, path) catch {};
            continue;
        };
        return path;
    }
    return error.InvalidPath;
}

fn platformDefaultTempRoot() ?[]const u8 {
    return switch (builtin.os.tag) {
        .dragonfly,
        .driverkit,
        .freebsd,
        .haiku,
        .hurd,
        .illumos,
        .ios,
        .linux,
        .macos,
        .maccatalyst,
        .netbsd,
        .openbsd,
        .tvos,
        .visionos,
        .watchos,
        => "/tmp",
        else => null,
    };
}

fn probeExecutableStagingDir(
    allocator: Allocator,
    io: Io,
    staging_dir: []const u8,
) !void {
    if (!File.Permissions.has_executable_bit) return;
    const probe = try std.fs.path.join(
        allocator,
        &.{ staging_dir, ".execution-probe" },
    );
    defer Dir.deleteFileAbsolute(io, probe) catch {};
    try Dir.cwd().writeFile(io, .{
        .sub_path = probe,
        .data = "#!/bin/sh\nexit 0\n",
        .flags = .{ .permissions = File.Permissions.fromMode(0o500) },
    });
    var child = try std.process.spawn(io, .{
        .argv = &.{probe},
        .cwd = .{ .path = staging_dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    if (!(try child.wait(io)).success()) return error.InvalidPath;
}

fn removeAotStagingDir(io: Io, path: []const u8) void {
    removePrivateTree(io, path);
}

fn runComponentizerTestHook(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    phase: []const u8,
) !void {
    const directory = environ.get(
        "STARLING_COMPONENTIZER_TEST_HOOK_DIR",
    ) orelse return;
    const wait_at = environ.get("STARLING_COMPONENTIZER_TEST_WAIT_AT");
    const notify_at = environ.get("STARLING_COMPONENTIZER_TEST_NOTIFY_AT");
    const should_wait = wait_at != null and
        hookPhaseEnabled(wait_at.?, phase);
    const should_notify = notify_at != null and
        hookPhaseEnabled(notify_at.?, phase);
    if (!should_wait and !should_notify) return;
    const ready = try std.fs.path.join(
        allocator,
        &.{
            directory,
            try std.fmt.allocPrint(allocator, "{s}.ready", .{phase}),
        },
    );
    try Dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "ready\n" });
    if (!should_wait) return;
    const proceed = try std.fs.path.join(
        allocator,
        &.{
            directory,
            try std.fmt.allocPrint(allocator, "{s}.continue", .{phase}),
        },
    );
    while (true) {
        _ = Dir.cwd().statFile(io, proceed, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try io.sleep(.fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        break;
    }
}

fn hookPhaseEnabled(value: []const u8, phase: []const u8) bool {
    var phases = std.mem.splitScalar(u8, value, ',');
    while (phases.next()) |candidate| {
        if (std.mem.eql(u8, candidate, phase)) return true;
    }
    return false;
}

fn removePrivateTree(io: Io, path: []const u8) void {
    if (File.Permissions.has_executable_bit) {
        var dir = Dir.openDirAbsolute(
            io,
            path,
            .{ .iterate = true, .follow_symlinks = false },
        ) catch {
            Dir.cwd().deleteTree(io, path) catch {};
            Dir.deleteDirAbsolute(io, path) catch {};
            return;
        };
        makeAotStagingTreeRemovable(io, dir);
        dir.close(io);
    }
    Dir.cwd().deleteTree(io, path) catch |err| {
        std.debug.print("error: private tree cleanup failed for {s}: {t}\n", .{
            path,
            err,
        });
    };
    Dir.deleteDirAbsolute(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print(
            "error: private directory cleanup failed for {s}: {t}\n",
            .{ path, err },
        ),
    };
}

fn makeAotStagingTreeRemovable(io: Io, dir: Dir) void {
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var child = dir.openDir(io, entry.name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch continue;
        makeAotStagingTreeRemovable(io, child);
        child.close(io);
    }
    dir.setPermissions(io, File.Permissions.fromMode(0o700)) catch {};
}

fn resolvedFeatureAbi(
    allocator: Allocator,
    config: *const cli.Config,
) ![]const u8 {
    var stdio = true;
    var random = true;
    var clocks = true;
    var http = true;
    var fetch_event = true;
    for (config.disable_features) |feature| {
        if (std.mem.eql(u8, feature, "stdio")) stdio = false;
        if (std.mem.eql(u8, feature, "random")) random = false;
        if (std.mem.eql(u8, feature, "clocks")) clocks = false;
        if (std.mem.eql(u8, feature, "http")) http = false;
        if (std.mem.eql(u8, feature, "fetch-event")) fetch_event = false;
    }
    for (config.enable_features) |feature| {
        if (std.mem.eql(u8, feature, "stdio")) stdio = true;
        if (std.mem.eql(u8, feature, "random")) random = true;
        if (std.mem.eql(u8, feature, "clocks")) clocks = true;
        if (std.mem.eql(u8, feature, "http")) http = true;
        if (std.mem.eql(u8, feature, "fetch-event")) fetch_event = true;
    }
    return aot_cache.featureAbi(
        allocator,
        stdio,
        random,
        clocks,
        http,
        fetch_event,
        if (config.use_debug_build) "Debug" else "ReleaseSmall",
        "wasi-0.2.10",
        true,
    );
}

fn resolveExecutable(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    name: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(name) or
        std.mem.indexOfScalar(u8, name, std.fs.path.sep) != null)
    {
        const path = try absolutePath(allocator, cwd, name);
        try requireExecutableFile(allocator, io, path);
        return Dir.realPathFileAbsoluteAlloc(io, path, allocator);
    }
    const path_value = environ.get("PATH") orelse return error.MissingBuildArtifact;
    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        const directory = if (entry.len == 0) cwd else entry;
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        const absolute = if (std.fs.path.isAbsolute(candidate))
            candidate
        else
            try absolutePath(allocator, cwd, candidate);
        const stat = Dir.cwd().statFile(io, absolute, .{}) catch continue;
        if (stat.kind != .file) continue;
        if (!hasEffectiveExecuteAccess(allocator, io, absolute)) continue;
        return Dir.realPathFileAbsoluteAlloc(io, absolute, allocator);
    }
    return error.MissingBuildArtifact;
}

fn resolveWevalExecutable(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    name: []const u8,
) !WevalTool {
    if (std.fs.path.isAbsolute(name) or
        std.mem.indexOfScalar(u8, name, std.fs.path.sep) != null)
    {
        return describeWevalExecutable(
            allocator,
            io,
            try absolutePath(allocator, cwd, name),
        );
    }
    const path_value = environ.get("PATH") orelse
        return error.MissingBuildArtifact;
    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        const directory = if (entry.len == 0) cwd else entry;
        const candidate = try std.fs.path.join(
            allocator,
            &.{ directory, name },
        );
        const absolute = if (std.fs.path.isAbsolute(candidate))
            candidate
        else
            try absolutePath(allocator, cwd, candidate);
        const stat = Dir.cwd().statFile(io, absolute, .{}) catch continue;
        if (stat.kind != .file) continue;
        if (!hasEffectiveExecuteAccess(allocator, io, absolute)) continue;
        return describeWevalExecutable(allocator, io, absolute);
    }
    return error.MissingBuildArtifact;
}

fn describeWevalExecutable(
    allocator: Allocator,
    io: Io,
    absolute: []const u8,
) !WevalTool {
    if (std.mem.eql(u8, std.fs.path.basename(absolute), "weval")) {
        if (std.fs.path.dirname(absolute)) |parent| {
            if (std.mem.eql(u8, std.fs.path.basename(parent), "bin")) {
                if (std.fs.path.dirname(parent)) |prefix| {
                    const managed = try std.fs.path.join(
                        allocator,
                        &.{ prefix, "weval-package", "weval" },
                    );
                    if (pathExists(io, managed))
                        return describeWevalExecutable(
                            allocator,
                            io,
                            managed,
                        );
                }
            }
        }
    }
    const resolved = try Dir.realPathFileAbsoluteAlloc(
        io,
        absolute,
        allocator,
    );
    if (!std.mem.eql(u8, resolved, absolute) and
        std.mem.eql(u8, std.fs.path.basename(resolved), "weval"))
    {
        if (std.fs.path.dirname(resolved)) |parent| {
            if (std.mem.eql(u8, std.fs.path.basename(parent), "bin")) {
                if (std.fs.path.dirname(parent)) |prefix| {
                    const managed = try std.fs.path.join(
                        allocator,
                        &.{ prefix, "weval-package", "weval" },
                    );
                    if (pathExists(io, managed))
                        return describeWevalExecutable(
                            allocator,
                            io,
                            managed,
                        );
                }
            }
        }
    }
    const parent_path = std.fs.path.dirname(absolute) orelse
        return error.UnsafeWevalPackage;
    const basename = std.fs.path.basename(absolute);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, ".."))
        return error.UnsafeWevalPackage;
    const package_root = try Dir.realPathFileAbsoluteAlloc(
        io,
        parent_path,
        allocator,
    );
    const selected = try std.fs.path.join(
        allocator,
        &.{ package_root, basename },
    );
    try requireExecutableFile(allocator, io, selected);
    const provenance = try Dir.realPathFileAbsoluteAlloc(
        io,
        selected,
        allocator,
    );
    if (!pathContains(package_root, provenance))
        return error.UnsafeWevalPackage;
    return .{
        .selected = selected,
        .package_root = package_root,
        .provenance = provenance,
    };
}

fn requireExecutableFile(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) !void {
    try requireFile(io, path);
    if (!hasEffectiveExecuteAccess(allocator, io, path))
        return error.MissingBuildArtifact;
}

fn hasEffectiveExecuteAccess(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) bool {
    if (!File.Permissions.has_executable_bit) return true;
    switch (builtin.os.tag) {
        .linux,
        .macos,
        .freebsd,
        .netbsd,
        .dragonfly,
        .openbsd,
        .haiku,
        .illumos,
        .serenity,
        => {
            const path_z = allocator.dupeSentinel(u8, path, 0) catch return false;
            return std.c.faccessat(
                std.c.AT.FDCWD,
                path_z,
                std.c.X_OK,
                if (builtin.os.tag == .linux) 0x200 else std.c.AT.EACCESS,
            ) == 0;
        },
        else => {
            Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
            return true;
        },
    }
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
    hashField(&hasher, "schema", "2");
    hashField(&hasher, "version", cli.version);
    hashField(&hasher, "optimize", if (config.use_debug_build) "Debug" else "ReleaseSmall");
    hashField(&hasher, "pipeline", if (config.aot) "weval-aot" else "wizer");
    if (config.aot) hashField(&hasher, "aot-engine-abi", aot_cache.engine_abi);
    hashField(&hasher, "dispatch-wit", dispatch_digest orelse "");
    hashField(&hasher, "component-wit", component_digest orelse "");
    hashField(&hasher, "dispatch-world", config.world_name orelse "");
    hashField(&hasher, "component-world", config.component_world_name orelse config.world_name orelse "");
    const feature_abi = try resolvedFeatureAbi(allocator, config);
    defer allocator.free(feature_abi);
    hashField(&hasher, "feature-abi", feature_abi);
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
) !void {
    return runCommandWithDisplay(
        allocator,
        io,
        stage,
        argv,
        null,
        cwd,
        environ,
        stdin_path,
        verbose,
        command_log,
    );
}

fn runCapturedToolCommand(
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    tool: CapturedTool,
    argv: []const []const u8,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    stdin_path: ?[]const u8,
    verbose: bool,
    command_log: *std.ArrayList(u8),
) !void {
    verifyToolTransaction(io, tool) catch
        return error.TransactionChanged;
    const result = runRetainedPackageCommand(
        allocator,
        io,
        stage,
        tool.snapshot_package orelse return error.TransactionChanged,
        tool.retained_plan,
        &.{},
        argv,
        tool.provenance,
        cwd,
        environ,
        stdin_path,
        verbose,
        command_log,
    );
    verifyToolTransaction(io, tool) catch
        return error.TransactionChanged;
    return result;
}

fn runCommandWithDisplay(
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    argv: []const []const u8,
    display_argv0: ?[]const u8,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    stdin_path: ?[]const u8,
    verbose: bool,
    command_log: *std.ArrayList(u8),
) !void {
    recordCommand(
        allocator,
        stage,
        argv,
        display_argv0,
        verbose,
        command_log,
    );
    try spawnCommand(io, stage, argv, cwd, environ, stdin_path);
}

fn recordCommand(
    allocator: Allocator,
    stage: []const u8,
    argv: []const []const u8,
    display_argv0: ?[]const u8,
    verbose: bool,
    command_log: *std.ArrayList(u8),
) void {
    command_log.appendSlice(allocator, stage) catch @panic("out of memory");
    command_log.append(allocator, '\n') catch @panic("out of memory");
    for (argv, 0..) |arg, index| {
        command_log.appendSlice(allocator, "  ") catch @panic("out of memory");
        command_log.appendSlice(
            allocator,
            if (index == 0) display_argv0 orelse arg else arg,
        ) catch @panic("out of memory");
        command_log.append(allocator, '\n') catch @panic("out of memory");
    }
    if (verbose) {
        std.debug.print("[{s}]\n", .{stage});
        for (argv, 0..) |arg, index| {
            std.debug.print(
                "  {s}\n",
                .{if (index == 0) display_argv0 orelse arg else arg},
            );
        }
    }
}

fn spawnCommand(
    io: Io,
    stage: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    stdin_path: ?[]const u8,
) !void {
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
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("error: {s} failed ({t})\n", .{ stage, term });
        return error.CommandFailed;
    }
}

fn runRetainedPackageCommand(
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    package: CapturedWevalPackage,
    prepared_plan: ?RetainedExecPlan,
    retained_inputs: []const std.posix.fd_t,
    argv: []const []const u8,
    display_argv0: ?[]const u8,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    stdin_path: ?[]const u8,
    verbose: bool,
    command_log: *std.ArrayList(u8),
) !void {
    recordCommand(
        allocator,
        stage,
        argv,
        display_argv0,
        verbose,
        command_log,
    );
    const owned_plan = if (prepared_plan == null)
        try createRetainedExecPlan(allocator, io, package)
    else
        null;
    defer if (owned_plan) |plan| plan.close(io);
    const plan = prepared_plan orelse owned_plan.?;
    plan.verify(io) catch return error.TransactionChanged;
    var helper_args: std.ArrayList([]const u8) = .empty;
    helper_args.appendSlice(
        allocator,
        plan.helper_argv,
    ) catch @panic("out of memory");
    helper_args.appendSlice(allocator, argv) catch @panic("out of memory");
    if (environ) |map| {
        const phase = if (std.mem.eql(u8, stage, "weval AOT"))
            "retained-environment-captured-weval"
        else
            "retained-environment-captured-tool";
        try runComponentizerTestHook(
            allocator,
            io,
            @constCast(map),
            phase,
        );
    }
    const result = runRetainedHelperProcess(
        allocator,
        io,
        stage,
        helper_args.items,
        retained_inputs,
        cwd,
        environ,
        stdin_path,
    );
    plan.verify(io) catch return error.TransactionChanged;
    try result;
}

fn runRetainedHelperProcess(
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    helper_args: []const []const u8,
    retained_inputs: []const std.posix.fd_t,
    cwd: []const u8,
    environ: ?*const std.process.Environ.Map,
    stdin_path: ?[]const u8,
) !void {
    if (builtin.os.tag != .linux)
        return error.UnsupportedRetainedExecution;
    const linux = std.os.linux;
    const stdin_file = try Dir.openFileAbsolute(
        io,
        stdin_path orelse "/dev/null",
        .{},
    );
    defer stdin_file.close(io);
    var sanitized_environment = if (environ) |map|
        try map.clone(allocator)
    else
        try currentEnvironmentMap(allocator);
    defer sanitized_environment.deinit();
    const loader_environment = [_][]const u8{
        "LD_AUDIT",
        "LD_DEBUG",
        "LD_DEBUG_OUTPUT",
        "LD_LIBRARY_PATH",
        "LD_PRELOAD",
        "GLIBC_TUNABLES",
    };
    for (loader_environment) |name|
        _ = sanitized_environment.swapRemove(name);
    const env_block = try sanitized_environment.createPosixBlock(
        allocator,
        .{},
    );
    defer env_block.deinit(allocator);
    const fork_result = linux.fork();
    switch (linux.errno(fork_result)) {
        .SUCCESS => {},
        else => return error.UnsupportedRetainedExecution,
    }
    if (fork_result == 0) {
        const cwd_z = allocator.dupeSentinel(u8, cwd, 0) catch
            linux.exit_group(126);
        if (linux.errno(linux.chdir(cwd_z)) != .SUCCESS)
            linux.exit_group(126);
        if (linux.errno(linux.dup2(stdin_file.handle, 0)) != .SUCCESS)
            linux.exit_group(126);
        retainedExecHelper(
            allocator,
            io,
            helper_args,
            @ptrCast(env_block.view().slice.ptr),
            retained_inputs,
        ) catch |err| {
            std.debug.print(
                "error: retained execution helper failed: {t}\n",
                .{err},
            );
            linux.exit_group(127);
        };
        unreachable;
    }
    var status: i32 = 0;
    const wait_result = linux.waitpid(
        @intCast(fork_result),
        &status,
        0,
    );
    switch (linux.errno(wait_result)) {
        .SUCCESS => {},
        else => return error.CommandFailed,
    }
    const wait_status: u32 = @bitCast(status);
    if (!linux.W.IFEXITED(wait_status) or
        linux.W.EXITSTATUS(wait_status) != 0)
    {
        std.debug.print("error: {s} failed\n", .{stage});
        return error.CommandFailed;
    }
}

fn currentEnvironmentMap(
    allocator: Allocator,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const value = std.mem.span(entry);
        const separator = std.mem.indexOfScalar(u8, value, '=') orelse
            continue;
        if (separator == 0) continue;
        try map.put(value[0..separator], value[separator + 1 ..]);
    }
    return map;
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

test "Unix AOT staging has a platform default temp root" {
    switch (builtin.os.tag) {
        .dragonfly,
        .driverkit,
        .freebsd,
        .haiku,
        .hurd,
        .illumos,
        .ios,
        .linux,
        .macos,
        .maccatalyst,
        .netbsd,
        .openbsd,
        .tvos,
        .visionos,
        .watchos,
        => try std.testing.expectEqualStrings(
            "/tmp",
            platformDefaultTempRoot().?,
        ),
        else => try std.testing.expect(platformDefaultTempRoot() == null),
    }
}

test "private namespace mirrors caller-visible mnt paths" {
    const target = try namespaceMirrorLinkTarget(
        std.testing.allocator,
        ".__starling-host-test",
        "mnt",
    );
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(
        "/.__starling-host-test/mnt",
        target,
    );
    try std.testing.expect(!std.mem.startsWith(
        u8,
        "/mnt/caller/source.js",
        "/.__starling-package-test",
    ));
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

test "runtime cache key separates AOT and canonicalizes feature order" {
    var config = cli.Config{
        .source = "source.js",
        .world_name = "world",
        .disable_features = &.{ "http", "random" },
    };
    const wizer = try runtimeKey(std.testing.allocator, &config, "a", "b");
    defer std.testing.allocator.free(wizer);
    config.aot = true;
    const aot = try runtimeKey(std.testing.allocator, &config, "a", "b");
    defer std.testing.allocator.free(aot);
    try std.testing.expect(!std.mem.eql(u8, wizer, aot));

    config.disable_features = &.{ "random", "http" };
    const reordered = try runtimeKey(std.testing.allocator, &config, "a", "b");
    defer std.testing.allocator.free(reordered);
    try std.testing.expectEqualStrings(aot, reordered);
}
