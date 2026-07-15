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
    InvalidUtf8Path,
    MetadataUnavailable,
    MissingBuildArtifact,
    MissingWitFiles,
    PublicationDirectoryChanged,
    RollbackIncomplete,
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

const InputSnapshot = struct {
    file: Snapshot,
    logical_path: []const u8,
    host_dir: []const u8,
    guest_dir: []const u8,
    tree_entry: []const u8,
    tree_digest: []const u8,
    shares_source_tree: bool,
};

const TreeSnapshot = struct {
    file: Snapshot,
    entry: []const u8,
    digest: []const u8,
};

const ZigSnapshot = struct {
    executable: Snapshot,
    lib_dir: []const u8,
    lib_digest: []const u8,
};

const EntryIdentity = struct {
    inode: File.INode,
    kind: File.Kind,

    fn fromStat(stat: File.Stat) EntryIdentity {
        return .{ .inode = stat.inode, .kind = stat.kind };
    }

    fn matches(self: EntryIdentity, stat: File.Stat) bool {
        return self.inode == stat.inode and self.kind == stat.kind;
    }
};

const OwnedEntry = struct {
    path: []const u8,
    identity: EntryIdentity,
};

const EffectiveCache = struct {
    path: []const u8,
    identity: EntryIdentity,
};

const InputExclusion = struct {
    path: []const u8,
    identity: ?EntryIdentity = null,

    fn matches(self: InputExclusion, path: []const u8, stat: File.Stat) bool {
        if (!std.mem.eql(u8, self.path, path)) return false;
        return if (self.identity) |identity| identity.matches(stat) else true;
    }
};

const Transaction = struct {
    name: []const u8,
    cleanup_name: []const u8,
    storage_path: []const u8,
    publication_path: []const u8,
    publication: Dir,
    root: Dir,
    storage: Dir,
    publication_identity: EntryIdentity,
    root_identity: EntryIdentity,
    storage_identity: EntryIdentity,
    owner_identity: EntryIdentity,
    owned: std.ArrayList(OwnedEntry) = .empty,

    fn create(
        allocator: Allocator,
        io: Io,
        publication: Dir,
        publication_path: []const u8,
        name: []const u8,
        owner: []const u8,
    ) !Transaction {
        const publication_identity = EntryIdentity.fromStat(
            try publication.stat(io),
        );
        if (publication_identity.kind != .directory) {
            return error.PublicationDirectoryChanged;
        }
        try publication.createDir(io, name, .fromMode(0o700));
        var root = try publication.openDir(
            io,
            name,
            .{ .iterate = true, .follow_symlinks = false },
        );
        errdefer root.close(io);
        try root.setPermissions(io, .fromMode(0o700));
        const root_identity = EntryIdentity.fromStat(try root.stat(io));

        var owner_file = try root.createFile(io, ".owner", .{ .exclusive = true });
        defer owner_file.close(io);
        try owner_file.writeStreamingAll(io, owner);
        try owner_file.sync(io);
        const owner_identity = EntryIdentity.fromStat(try owner_file.stat(io));
        try root.createDir(io, "data", .fromMode(0o700));
        var storage = try root.openDir(
            io,
            "data",
            .{ .iterate = true, .follow_symlinks = false },
        );
        errdefer storage.close(io);
        const storage_identity = EntryIdentity.fromStat(try storage.stat(io));

        return .{
            .name = name,
            .cleanup_name = try std.fmt.allocPrint(
                allocator,
                "{s}.cleanup",
                .{name},
            ),
            .storage_path = try std.fs.path.join(
                allocator,
                &.{ publication_path, name, "data" },
            ),
            .publication_path = publication_path,
            .publication = publication,
            .root = root,
            .storage = storage,
            .publication_identity = publication_identity,
            .root_identity = root_identity,
            .storage_identity = storage_identity,
            .owner_identity = owner_identity,
        };
    }

    fn deinit(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        safe_to_remove: bool,
    ) void {
        if (safe_to_remove) self.cleanup(allocator, io) catch {};
        self.storage.close(io);
        self.root.close(io);
        self.publication.close(io);
        self.owned.deinit(allocator);
    }

    fn cleanup(self: *Transaction, allocator: Allocator, io: Io) !void {
        if (!try entryHasIdentity(
            self.publication,
            io,
            self.name,
            self.root_identity,
        )) return;
        if (!try self.rootEntryHasIdentity(io, ".owner", self.owner_identity)) return;
        if (!try self.rootEntryHasIdentity(io, "data", self.storage_identity)) return;

        var iterator = self.root.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.mem.eql(u8, entry.name, ".owner") and
                !std.mem.eql(u8, entry.name, "data"))
            {
                return;
            }
        }
        try self.verifyOwnedDirectory(allocator, io, self.storage, "");

        self.publication.renamePreserve(
            self.name,
            self.publication,
            self.cleanup_name,
            io,
        ) catch return;
        if (!try entryHasIdentity(
            self.publication,
            io,
            self.cleanup_name,
            self.root_identity,
        )) {
            self.publication.renamePreserve(
                self.cleanup_name,
                self.publication,
                self.name,
                io,
            ) catch {};
            return;
        }

        try self.removeOwnedDirectory(allocator, io, self.storage, "");
        if (!try self.rootEntryHasIdentity(io, "data", self.storage_identity)) return;
        try removeExactEntry(io, self.root, "data", self.storage_identity);
        if (!try self.rootEntryHasIdentity(io, ".owner", self.owner_identity)) return;
        try removeExactEntry(io, self.root, ".owner", self.owner_identity);
        var final_iterator = self.root.iterate();
        if (try final_iterator.next(io) != null) return error.TransactionChanged;
        if (!try entryHasIdentity(
            self.publication,
            io,
            self.cleanup_name,
            self.root_identity,
        )) return;
        try removeExactEntry(
            io,
            self.publication,
            self.cleanup_name,
            self.root_identity,
        );
    }

    fn recordStoragePath(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !void {
        const stat = try self.storage.statFile(
            io,
            path,
            .{ .follow_symlinks = false },
        );
        if (stat.kind != .file and
            stat.kind != .directory and
            stat.kind != .sym_link)
        {
            return error.TransactionChanged;
        }
        const identity = EntryIdentity.fromStat(stat);
        for (self.owned.items) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (!entry.identity.matches(stat)) return error.TransactionChanged;
            return;
        }
        self.owned.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .identity = identity,
        }) catch @panic("out of memory");
    }

    fn recordStorageAbsolute(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !void {
        if (!pathContains(self.storage_path, path) or
            path.len <= self.storage_path.len)
        {
            return error.InvalidPath;
        }
        const relative_start = self.storage_path.len +
            @intFromBool(!std.mem.endsWith(
                u8,
                self.storage_path,
                &.{std.fs.path.sep},
            ));
        try self.recordStoragePath(allocator, io, path[relative_start..]);
    }

    fn createStorageDir(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
        permissions: File.Permissions,
    ) !void {
        try self.storage.createDir(io, path, permissions);
        try self.recordStoragePath(allocator, io, path);
    }

    fn ensureStorageDirPath(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !void {
        var current: []const u8 = "";
        var components = std.mem.splitScalar(u8, path, std.fs.path.sep);
        while (components.next()) |component| {
            if (component.len == 0) continue;
            if (std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, ".."))
            {
                return error.InvalidPath;
            }
            current = if (current.len == 0)
                try allocator.dupe(u8, component)
            else
                try std.fs.path.join(allocator, &.{ current, component });
            const stat = self.storage.statFile(
                io,
                current,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    try self.storage.createDir(io, current, .fromMode(0o700));
                    try self.recordStoragePath(allocator, io, current);
                    continue;
                },
                else => return err,
            };
            if (stat.kind != .directory) return error.TransactionChanged;
            try self.recordStoragePath(allocator, io, current);
        }
    }

    fn verifyAttached(self: *const Transaction, io: Io) !void {
        if (!try entryHasIdentity(
            self.publication,
            io,
            self.name,
            self.root_identity,
        )) return error.TransactionChanged;
        if (!try self.rootEntryHasIdentity(io, "data", self.storage_identity)) {
            return error.TransactionChanged;
        }
    }

    fn verifyCanonicalPublication(self: *const Transaction, io: Io) !void {
        if (!self.publication_identity.matches(try self.publication.stat(io))) {
            return error.PublicationDirectoryChanged;
        }
        const canonical = Dir.cwd().statFile(
            io,
            self.publication_path,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.PublicationDirectoryChanged,
            else => return err,
        };
        if (!self.publication_identity.matches(canonical)) {
            return error.PublicationDirectoryChanged;
        }
    }

    fn ownedIdentity(
        self: *const Transaction,
        path: []const u8,
    ) ?EntryIdentity {
        for (self.owned.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.identity;
        }
        return null;
    }

    fn isRootEntry(
        self: *const Transaction,
        absolute_path: []const u8,
        stat: File.Stat,
    ) bool {
        const root_path = std.fs.path.dirname(self.storage_path) orelse
            return false;
        return std.mem.eql(u8, absolute_path, root_path) and
            self.root_identity.matches(stat);
    }

    fn verifyOwnedDirectory(
        self: *const Transaction,
        allocator: Allocator,
        io: Io,
        directory: Dir,
        relative: []const u8,
    ) !void {
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            const child_path = if (relative.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ relative, entry.name });
            const identity = self.ownedIdentity(child_path) orelse
                return error.TransactionChanged;
            const stat = try directory.statFile(
                io,
                entry.name,
                .{ .follow_symlinks = false },
            );
            if (!identity.matches(stat)) return error.TransactionChanged;
            if (identity.kind == .directory) {
                var child = try directory.openDir(
                    io,
                    entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                defer child.close(io);
                if (!identity.matches(try child.stat(io))) {
                    return error.TransactionChanged;
                }
                try self.verifyOwnedDirectory(
                    allocator,
                    io,
                    child,
                    child_path,
                );
            }
        }
    }

    fn removeOwnedDirectory(
        self: *const Transaction,
        allocator: Allocator,
        io: Io,
        directory: Dir,
        relative: []const u8,
    ) !void {
        const Child = struct {
            name: []const u8,
            path: []const u8,
            identity: EntryIdentity,
        };
        var children: std.ArrayList(Child) = .empty;
        defer children.deinit(allocator);
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            const child_path = if (relative.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ relative, entry.name });
            const identity = self.ownedIdentity(child_path) orelse
                return error.TransactionChanged;
            const stat = try directory.statFile(
                io,
                entry.name,
                .{ .follow_symlinks = false },
            );
            if (!identity.matches(stat)) return error.TransactionChanged;
            children.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .path = child_path,
                .identity = identity,
            }) catch @panic("out of memory");
        }

        for (children.items) |child_entry| {
            if (child_entry.identity.kind == .directory) {
                var child = try directory.openDir(
                    io,
                    child_entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                if (!child_entry.identity.matches(try child.stat(io))) {
                    child.close(io);
                    return error.TransactionChanged;
                }
                try child.setPermissions(io, .fromMode(0o700));
                try self.removeOwnedDirectory(
                    allocator,
                    io,
                    child,
                    child_entry.path,
                );
                child.close(io);
            }
            try removeExactEntry(
                io,
                directory,
                child_entry.name,
                child_entry.identity,
            );
        }

        var final_iterator = directory.iterate();
        if (try final_iterator.next(io) != null) return error.TransactionChanged;
    }

    fn rootEntryHasIdentity(
        self: *const Transaction,
        io: Io,
        name: []const u8,
        identity: EntryIdentity,
    ) !bool {
        const stat = self.root.statFile(
            io,
            name,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return identity.matches(stat);
    }
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
    zig: ?ZigSnapshot,
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
    try validateConfiguredPaths(config);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    const source_argument = try absolutePath(allocator, cwd, config.source);
    const source = try resolveExistingFile(allocator, io, cwd, config.source);
    const source_identity = try sourceFileIdentity(io, source);
    try validateArgument(source);
    const initializer = if (config.initializer_script_path) |path| blk: {
        const resolved = try resolveExistingFile(allocator, io, cwd, path);
        break :blk resolved;
    } else null;
    const initializer_identity = if (initializer) |path|
        try sourceFileIdentity(io, path)
    else
        null;

    const output = if (config.output) |path|
        try absolutePath(allocator, cwd, path)
    else
        try defaultOutputPath(allocator, cwd, source_argument);
    try validateArgument(output);
    const output_parent = std.fs.path.dirname(output) orelse return error.InvalidPath;
    const publication_parent = try resolveOrCreateDirectory(
        allocator,
        io,
        output_parent,
    );
    var publication_directory = try Dir.openDirAbsolute(
        io,
        publication_parent,
        .{ .iterate = true, .follow_symlinks = false },
    );
    var publication_transferred = false;
    defer if (!publication_transferred) publication_directory.close(io);
    const output_name = std.fs.path.basename(output);
    const resolved_output = try std.fs.path.join(
        allocator,
        &.{ publication_parent, output_name },
    );
    try requireDestinationFileOrMissingAt(
        publication_directory,
        io,
        output_name,
        error.InvalidPath,
    );
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
        const resolved_parent = try resolveOrCreateDirectory(allocator, io, parent);
        if (!std.mem.eql(u8, resolved_parent, publication_parent)) {
            return error.InvalidMetadataDestination;
        }
        const resolved = try std.fs.path.join(
            allocator,
            &.{ publication_parent, std.fs.path.basename(destination) },
        );
        try requireDestinationFileOrMissingAt(
            publication_directory,
            io,
            std.fs.path.basename(destination),
            error.InvalidMetadataDestination,
        );
        if (std.mem.eql(u8, resolved, resolved_output) or
            std.mem.eql(u8, resolved, source) or
            (initializer != null and std.mem.eql(u8, resolved, initializer.?)))
        {
            return error.InvalidMetadataDestination;
        }
        break :blk resolved;
    } else null;

    if (config.debug_bindings) diagnostic.begin(.debug);
    const debug_dir = if (config.debug_bindings) blk: {
        const destination = if (config.debug_dir) |path|
            try absolutePath(allocator, cwd, path)
        else
            try std.fmt.allocPrint(allocator, "{s}.debug", .{output});
        const parent = std.fs.path.dirname(destination) orelse
            return error.DebugOutputCollision;
        const resolved_parent = try resolveOrCreateDirectory(allocator, io, parent);
        if (!std.mem.eql(u8, resolved_parent, publication_parent)) {
            return error.DebugOutputCollision;
        }
        const resolved = try std.fs.path.join(
            allocator,
            &.{ publication_parent, std.fs.path.basename(destination) },
        );
        if (try pathKindNoFollowAt(
            publication_directory,
            io,
            std.fs.path.basename(destination),
        )) |kind| {
            if (kind != .directory) return error.DebugOutputCollision;
        }
        if (pathContains(resolved, resolved_output) or
            pathContains(resolved, source) or
            (initializer != null and pathContains(resolved, initializer.?)) or
            (metadata_output != null and pathContains(resolved, metadata_output.?)))
        {
            return error.DebugOutputCollision;
        }
        break :blk resolved;
    } else null;

    diagnostic.begin(.inputs);
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    const build_root = if (config.engine == null)
        try discoverBuildRoot(allocator, io, environ, cwd, executable_dir, config.build_root)
    else if (config.build_root) |root|
        try resolveAndValidateRoot(allocator, io, cwd, root)
    else
        null;
    const effective_cache: ?EffectiveCache =
        if (config.cache_dir != null or config.engine == null)
            try resolveEffectiveCache(
                allocator,
                io,
                cwd,
                build_root,
                config.cache_dir,
            )
        else
            null;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const transaction_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.starling-componentize-{s}",
        .{ std.fs.path.basename(output), &random_hex },
    );
    diagnostic.begin(.inputs);
    var transaction = try Transaction.create(
        allocator,
        io,
        publication_directory,
        publication_parent,
        transaction_name,
        &random_hex,
    );
    publication_transferred = true;
    const transaction_storage = transaction.storage_path;
    var transaction_safe_to_remove = true;
    defer transaction.deinit(
        allocator,
        io,
        transaction_safe_to_remove,
    );
    var input_exclusions: std.ArrayList(InputExclusion) = .empty;
    const source_parent = std.fs.path.dirname(source).?;
    const initializer_parent = if (initializer) |path|
        std.fs.path.dirname(path).?
    else
        null;
    if (effective_cache) |cache| {
        if (pathContains(source_parent, cache.path) or
            (initializer_parent != null and
                pathContains(initializer_parent.?, cache.path)))
        {
            input_exclusions.append(allocator, .{
                .path = cache.path,
                .identity = cache.identity,
            }) catch @panic("out of memory");
        }
    }
    input_exclusions.append(allocator, .{ .path = resolved_output }) catch
        @panic("out of memory");
    if (metadata_output) |path| {
        input_exclusions.append(allocator, .{ .path = path }) catch
            @panic("out of memory");
    }
    if (debug_dir) |path| {
        input_exclusions.append(allocator, .{ .path = path }) catch
            @panic("out of memory");
    }
    if (!std.mem.eql(u8, publication_parent, source_parent) and
        (initializer_parent == null or
            !std.mem.eql(u8, publication_parent, initializer_parent.?)))
    {
        input_exclusions.append(
            allocator,
            .{ .path = publication_parent },
        ) catch
            @panic("out of memory");
    }

    const input_snapshots = try snapshotInputs(
        allocator,
        io,
        source,
        source_identity,
        initializer,
        initializer_identity,
        input_exclusions.items,
        &transaction,
    );
    const source_snapshot = input_snapshots.source;
    const initializer_snapshot = input_snapshots.initializer;

    diagnostic.begin(.runtime_build);
    const runtime = if (config.engine) |engine_override|
        try externalRuntime(
            allocator,
            io,
            cwd,
            executable_dir,
            config,
            engine_override,
            &transaction,
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
            effective_cache.?.path,
            diagnostic,
            &transaction,
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
        &transaction,
    );

    const runtime_args_path = try std.fs.path.join(
        allocator,
        &.{ transaction_storage, "runtime-args.txt" },
    );
    const runtime_args = try renderRuntimeArgs(
        allocator,
        cwd,
        source_snapshot.logical_path,
        if (initializer_snapshot) |snapshot| snapshot.logical_path else null,
        config,
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = runtime_args_path,
        .data = runtime_args,
    });
    try transaction.recordStorageAbsolute(allocator, io, runtime_args_path);

    var command_log: std.ArrayList(u8) = .empty;
    const initialized = try std.fs.path.join(
        allocator,
        &.{ transaction_storage, "initialized.wasm" },
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

    try addMappedPreopen(
        allocator,
        &wizer_args,
        source_snapshot.host_dir,
        source_snapshot.guest_dir,
    );
    if (initializer_snapshot) |snapshot| {
        if (!std.mem.eql(u8, snapshot.host_dir, source_snapshot.host_dir)) {
            try addMappedPreopen(
                allocator,
                &wizer_args,
                snapshot.host_dir,
                snapshot.guest_dir,
            );
        }
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
        transaction_storage,
    );
    try transaction.recordStorageAbsolute(allocator, io, initialized);

    var stripped: ?[]const u8 = null;
    var embedded: ?[]const u8 = null;
    const candidate = try std.fs.path.join(
        allocator,
        &.{ transaction_storage, "candidate.wasm" },
    );
    if (runtime.component_wit) |component_wit| {
        const wabt = tools.wabt.?.path;
        stripped = try std.fs.path.join(
            allocator,
            &.{ transaction_storage, "stripped.wasm" },
        );
        embedded = try std.fs.path.join(
            allocator,
            &.{ transaction_storage, "embedded.wasm" },
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
            transaction_storage,
        );
        try transaction.recordStorageAbsolute(allocator, io, stripped.?);
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
            transaction_storage,
        );
        try transaction.recordStorageAbsolute(allocator, io, embedded.?);
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
            transaction_storage,
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
            transaction_storage,
        );
    }
    try transaction.recordStorageAbsolute(allocator, io, candidate);

    const processed = try std.fs.path.join(
        allocator,
        &.{ transaction_storage, "component.wasm" },
    );
    const processed_by = try std.fmt.allocPrint(
        allocator,
        "starling-componentize={s}",
        .{build_options.version},
    );
    var metadata_args: std.ArrayList([]const u8) = .empty;
    metadata_args.appendSlice(allocator, &.{
        tools.wasm_tools.path,
        "metadata",
        "add",
        "--language",
        "JavaScript=",
        "--processed-by",
        processed_by,
    }) catch @panic("out of memory");
    if (runtime.zig) |zig| {
        metadata_args.appendSlice(allocator, &.{
            "--processed-by",
            try std.fmt.allocPrint(
                allocator,
                "zig-sha256={s}",
                .{zig.executable.digest},
            ),
            "--processed-by",
            try std.fmt.allocPrint(
                allocator,
                "zig-lib-sha256={s}",
                .{zig.lib_digest},
            ),
        }) catch @panic("out of memory");
    }
    metadata_args.appendSlice(allocator, &.{
        "--output",
        processed,
        candidate,
    }) catch @panic("out of memory");
    diagnostic.begin(.metadata);
    try runCommand(
        allocator,
        io,
        "wasm-tools metadata add",
        metadata_args.items,
        cwd,
        null,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        transaction_storage,
    );
    try transaction.recordStorageAbsolute(allocator, io, processed);

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
        transaction_storage,
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
            &.{ transaction_storage, "metadata.json" },
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = metadata_json.?,
        });
        try transaction.recordStorageAbsolute(allocator, io, path);
        break :blk path;
    } else null;

    const debug_staged = if (debug_dir != null) blk: {
        diagnostic.begin(.debug);
        const directory = try std.fs.path.join(
            allocator,
            &.{ transaction_storage, "debug" },
        );
        try transaction.createStorageDir(
            allocator,
            io,
            "debug",
            .fromMode(0o700),
        );
        var debug_dir_handle = try Dir.openDirAbsolute(
            io,
            directory,
            .{ .follow_symlinks = false },
        );
        defer debug_dir_handle.close(io);
        const command_log_path = try std.fs.path.join(
            allocator,
            &.{ transaction_storage, "commands.txt" },
        );
        const stable_command_log = try std.mem.replaceOwned(
            u8,
            allocator,
            command_log.items,
            transaction_storage,
            "<transaction>",
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = command_log_path,
            .data = stable_command_log,
        });
        try transaction.recordStorageAbsolute(allocator, io, command_log_path);
        try copyDebugFile(io, runtime_args_path, debug_dir_handle, "runtime-args.txt");
        try transaction.recordStoragePath(allocator, io, "debug/runtime-args.txt");
        try copyDebugFile(io, initialized, debug_dir_handle, "initialized.wasm");
        try transaction.recordStoragePath(allocator, io, "debug/initialized.wasm");
        if (stripped) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "stripped.wasm");
            try transaction.recordStoragePath(allocator, io, "debug/stripped.wasm");
        }
        if (embedded) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "embedded.wasm");
            try transaction.recordStoragePath(allocator, io, "debug/embedded.wasm");
        }
        try copyDebugFile(io, processed, debug_dir_handle, "component.wasm");
        try transaction.recordStoragePath(allocator, io, "debug/component.wasm");
        if (runtime.bindings) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "component-bindings.zig");
            try transaction.recordStoragePath(
                allocator,
                io,
                "debug/component-bindings.zig",
            );
        }
        try copyDebugFile(io, command_log_path, debug_dir_handle, "commands.txt");
        try transaction.recordStoragePath(allocator, io, "debug/commands.txt");
        if (metadata_json) |json| {
            try debug_dir_handle.writeFile(io, .{
                .sub_path = "metadata.json",
                .data = json,
            });
            try transaction.recordStoragePath(allocator, io, "debug/metadata.json");
            try debug_dir_handle.writeFile(io, .{
                .sub_path = "imports.json",
                .data = try metadata.renderImports(allocator, imports),
            });
            try transaction.recordStoragePath(allocator, io, "debug/imports.json");
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
        &transaction,
        processed,
        output_name,
        metadata_staged,
        if (metadata_output) |path| std.fs.path.basename(path) else null,
        debug_staged,
        if (debug_dir) |path| std.fs.path.basename(path) else null,
        &transaction_safe_to_remove,
        source,
        resolved_output,
        diagnostic,
    );
}

fn externalRuntime(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    engine_override: []const u8,
    transaction: *Transaction,
) !Runtime {
    const transaction_dir = transaction.storage_path;
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
        transaction,
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
        transaction,
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
            transaction,
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
                transaction,
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
    cache_dir: []const u8,
    diagnostic: *diagnostics.Context,
    transaction: *Transaction,
) !Runtime {
    const transaction_dir = transaction.storage_path;

    var dispatch_wit: ?StagedWit = null;
    var component_wit: ?StagedWit = null;
    if (config.wit) |path| {
        const dispatch_source = try absolutePath(allocator, cwd, path);
        dispatch_wit = try stageWit(
            allocator,
            io,
            dispatch_source,
            try std.fs.path.join(allocator, &.{ transaction_dir, "dispatch-wit" }),
            transaction,
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
                    transaction,
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
    const zig_install = try snapshotZigInstallation(
        allocator,
        io,
        zig_resolved,
        environ,
        build_root,
        transaction,
    );
    const zig = zig_install.executable;

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
    const zig_local_cache = try std.fs.path.join(
        allocator,
        &.{ cache_dir, "zig-local-cache" },
    );
    try Dir.cwd().createDirPath(io, zig_global_cache);
    try Dir.cwd().createDirPath(io, zig_local_cache);
    var build_env = std.process.Environ.Map.init(allocator);
    try copyEnvironment(&build_env, environ);
    try build_env.put("ZIG_GLOBAL_CACHE_DIR", zig_global_cache);
    try build_env.put("ZIG_LOCAL_CACHE_DIR", zig_local_cache);
    try build_env.put("ZIG_LIB_DIR", zig_install.lib_dir);
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
        transaction_dir,
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
        transaction,
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
        transaction,
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
            transaction,
        )).path;
    } else null;
    const build_tools = try readBuildToolManifest(
        allocator,
        io,
        try std.fs.path.join(
            allocator,
            &.{ prefix, "bin", "runtime-build-tools.json" },
        ),
        transaction,
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
        .zig = zig_install,
        .build_tools = build_tools,
        .cache_lock = lock_file,
    };
}

fn snapshotZigInstallation(
    allocator: Allocator,
    io: Io,
    zig_path: []const u8,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    transaction: *Transaction,
) !ZigSnapshot {
    const zig_absolute = try absolutePath(allocator, cwd, zig_path);
    const zig_source = try Dir.realPathFileAbsoluteAlloc(
        io,
        zig_absolute,
        allocator,
    );
    const zig_identity = try sourceFileIdentity(io, zig_source);
    const lib_source = try discoverZigLibDir(
        allocator,
        io,
        zig_source,
        environ,
        cwd,
    );
    if (!zig_identity.matches(try Dir.cwd().statFile(
        io,
        zig_source,
        .{ .follow_symlinks = false },
    ))) return error.InputChanged;

    try transaction.ensureStorageDirPath(allocator, io, "zig-install/bin");
    try transaction.ensureStorageDirPath(allocator, io, "zig-install/lib");
    const executable_path = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, "zig-install", "bin", "zig" },
    );
    const executable = try snapshotFileExpected(
        allocator,
        io,
        zig_source,
        executable_path,
        transaction,
        zig_identity,
    );
    const lib_destination = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, "zig-install", "lib" },
    );
    const lib_digest = try snapshotDirectoryTree(
        allocator,
        io,
        lib_source,
        lib_destination,
        transaction,
    );
    return .{
        .executable = executable,
        .lib_dir = lib_destination,
        .lib_digest = lib_digest,
    };
}

fn discoverZigLibDir(
    allocator: Allocator,
    io: Io,
    zig: []const u8,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
) ![]const u8 {
    const discovered = if (environ.get("ZIG_LIB_DIR")) |configured|
        try absolutePath(allocator, cwd, configured)
    else blk: {
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ zig, "env" },
            .cwd = .{ .path = cwd },
            .environ_map = environ,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (!termSucceeded(result.term)) return error.MissingBuildArtifact;

        const marker = ".lib_dir = ";
        const marker_start = std.mem.indexOf(u8, result.stdout, marker) orelse
            return error.MissingBuildArtifact;
        const value_start = marker_start + marker.len;
        const value_end = if (std.mem.indexOfScalar(
            u8,
            result.stdout[value_start..],
            '\n',
        )) |offset|
            value_start + offset
        else
            result.stdout.len;
        var literal = std.mem.trim(u8, result.stdout[value_start..value_end], " \t\r");
        if (std.mem.endsWith(u8, literal, ",")) {
            literal = std.mem.trimEnd(u8, literal[0 .. literal.len - 1], " \t\r");
        }
        const parsed = std.zig.string_literal.parseAlloc(
            allocator,
            literal,
        ) catch return error.MissingBuildArtifact;
        break :blk try absolutePath(allocator, cwd, parsed);
    };
    const canonical = try Dir.realPathFileAbsoluteAlloc(io, discovered, allocator);
    const stat = try Dir.cwd().statFile(
        io,
        canonical,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .directory) return error.MissingBuildArtifact;
    return canonical;
}

fn snapshotDirectoryTree(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
    transaction: *Transaction,
) ![]const u8 {
    var source = try Dir.openDirAbsolute(
        io,
        source_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source.close(io);
    const source_identity = SourceIdentity.fromStat(try source.stat(io));
    var destination = try Dir.openDirAbsolute(
        io,
        destination_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer destination.close(io);
    const destination_relative = try std.fs.path.relative(
        allocator,
        transaction.storage_path,
        null,
        transaction.storage_path,
        destination_path,
    );
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("starling-componentizer-zig-lib-tree-v1\x00");
    _ = try copyInputDirectory(
        allocator,
        io,
        source,
        destination,
        source_path,
        "",
        destination_relative,
        "",
        &.{},
        transaction,
        &hasher,
    );
    if (!source_identity.matches(try source.stat(io)) or
        !source_identity.matches(try Dir.cwd().statFile(
            io,
            source_path,
            .{ .follow_symlinks = false },
        )))
    {
        return error.InputChanged;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
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
    transaction: *Transaction,
) !Tools {
    const transaction_dir = transaction.storage_path;
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
            transaction,
        ),
        .wasmtime_subcommand = wizer_is_wasmtime,
    };
    const wasm_tools = try snapshotFile(
        allocator,
        io,
        try resolveExecutable(allocator, io, environ, wasm_tools_source),
        try std.fs.path.join(allocator, &.{ transaction_dir, "wasm-tools" }),
        transaction,
    );
    const wabt = if (wabt_source) |path|
        try snapshotFile(
            allocator,
            io,
            try resolveExecutable(allocator, io, environ, path),
            try std.fs.path.join(allocator, &.{ transaction_dir, "wabt" }),
            transaction,
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
    transaction: *Transaction,
) !StagedWit {
    var source_dir = try Dir.openDirAbsolute(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        try validatePathUtf8(entry.path);
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
    const stage_relative = std.fs.path.basename(stage_path);
    try transaction.ensureStorageDirPath(allocator, io, stage_relative);
    for (files.items, contents.items) |relative, data| {
        const destination = try std.fs.path.join(allocator, &.{ stage_path, relative });
        if (std.fs.path.dirname(destination) == null) return error.InvalidPath;
        const relative_parent = std.fs.path.dirname(relative);
        if (relative_parent) |parent| {
            try transaction.ensureStorageDirPath(
                allocator,
                io,
                try std.fs.path.join(allocator, &.{ stage_relative, parent }),
            );
        }
        try Dir.cwd().writeFile(io, .{
            .sub_path = destination,
            .data = data,
        });
        try transaction.recordStorageAbsolute(allocator, io, destination);
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
    source: InputSnapshot,
    initializer: ?InputSnapshot,
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
        tool_values.append(allocator, .{
            .name = "zig",
            .sha256 = zig.executable.digest,
            .lib_tree_sha256 = zig.lib_digest,
        }) catch @panic("out of memory");
        tool_fields.append(
            allocator,
            .{ "zig", zig.executable.digest },
        ) catch @panic("out of memory");
        tool_fields.append(
            allocator,
            .{ "zig-lib", zig.lib_digest },
        ) catch @panic("out of memory");
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
                .source_sha256 = source.file.digest,
                .initializer_sha256 = if (initializer) |snapshot|
                    snapshot.file.digest
                else
                    null,
                .source_tree = .{
                    .entry = source.tree_entry,
                    .sha256 = source.tree_digest,
                },
                .initializer_tree = if (initializer) |snapshot|
                    .{
                        .entry = snapshot.tree_entry,
                        .sha256 = snapshot.tree_digest,
                        .shares_source_tree = snapshot.shares_source_tree,
                    }
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
    transaction: *Transaction,
) ![]const metadata.Tool {
    const transaction_dir = transaction.storage_path;
    const manifest_snapshot = try snapshotFile(
        allocator,
        io,
        manifest_path,
        try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "runtime-build-tools.json" },
        ),
        transaction,
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
        try validatePathUtf8(entry.name);
        try validatePathUtf8(entry.path);
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
            transaction,
        );
        tools.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .sha256 = snapshot.digest,
        }) catch @panic("out of memory");
    }
    return tools.toOwnedSlice(allocator) catch @panic("out of memory");
}

fn snapshotInputs(
    allocator: Allocator,
    io: Io,
    source: []const u8,
    source_identity: SourceIdentity,
    initializer: ?[]const u8,
    initializer_identity: ?SourceIdentity,
    excluded_paths: []const InputExclusion,
    transaction: *Transaction,
) !struct { source: InputSnapshot, initializer: ?InputSnapshot } {
    if (!source_identity.matches(try Dir.cwd().statFile(
        io,
        source,
        .{ .follow_symlinks = false },
    ))) return error.InputChanged;
    if (initializer) |path| {
        if (!initializer_identity.?.matches(try Dir.cwd().statFile(
            io,
            path,
            .{ .follow_symlinks = false },
        ))) return error.InputChanged;
    }
    const source_parent = std.fs.path.dirname(source) orelse return error.InvalidPath;
    const initializer_parent = if (initializer) |path|
        std.fs.path.dirname(path) orelse return error.InvalidPath
    else
        null;
    const shared_root = if (initializer_parent) |parent|
        if (pathContains(source_parent, parent))
            source_parent
        else if (pathContains(parent, source_parent))
            parent
        else
            null
    else
        null;
    try transaction.createStorageDir(
        allocator,
        io,
        "inputs",
        .fromMode(0o700),
    );
    const source_tree_name = if (shared_root != null)
        "inputs/shared"
    else
        "inputs/source";
    try transaction.createStorageDir(
        allocator,
        io,
        source_tree_name,
        .fromMode(0o700),
    );
    const source_host = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, source_tree_name },
    );
    const source_file = try snapshotInputTree(
        allocator,
        io,
        shared_root orelse source_parent,
        source_host,
        try std.fs.path.relative(
            allocator,
            shared_root orelse source_parent,
            null,
            shared_root orelse source_parent,
            source,
        ),
        excluded_paths,
        transaction,
    );
    const source_snapshot = InputSnapshot{
        .file = source_file.file,
        .logical_path = source,
        .host_dir = source_host,
        .guest_dir = shared_root orelse source_parent,
        .tree_entry = source_file.entry,
        .tree_digest = source_file.digest,
        .shares_source_tree = false,
    };

    const initializer_snapshot: ?InputSnapshot = if (initializer) |path| blk: {
        if (std.mem.eql(u8, path, source)) {
            var shared_snapshot = source_snapshot;
            shared_snapshot.shares_source_tree = true;
            break :blk shared_snapshot;
        }
        const host = if (shared_root != null)
            source_host
        else
            try std.fs.path.join(
                allocator,
                &.{ transaction.storage_path, "inputs", "initializer" },
            );
        if (shared_root == null) {
            try transaction.createStorageDir(
                allocator,
                io,
                "inputs/initializer",
                .fromMode(0o700),
            );
        }
        const tree_root = shared_root orelse initializer_parent.?;
        const entry = try std.fs.path.relative(
            allocator,
            tree_root,
            null,
            tree_root,
            path,
        );
        const distinct_tree = if (shared_root == null)
            try snapshotInputTree(
                allocator,
                io,
                initializer_parent.?,
                host,
                entry,
                excluded_paths,
                transaction,
            )
        else
            null;
        break :blk .{
            .file = if (shared_root != null)
                Snapshot{
                    .path = try std.fs.path.join(
                        allocator,
                        &.{ host, entry },
                    ),
                    .digest = try metadata.sha256File(
                        allocator,
                        io,
                        try std.fs.path.join(
                            allocator,
                            &.{ host, entry },
                        ),
                    ),
                }
            else
                distinct_tree.?.file,
            .logical_path = path,
            .host_dir = host,
            .guest_dir = tree_root,
            .tree_entry = if (shared_root != null)
                try normalizeTreePath(allocator, entry)
            else
                distinct_tree.?.entry,
            .tree_digest = if (shared_root != null)
                source_snapshot.tree_digest
            else
                distinct_tree.?.digest,
            .shares_source_tree = shared_root != null,
        };
    } else null;

    if (!source_identity.matches(try Dir.cwd().statFile(
        io,
        source,
        .{ .follow_symlinks = false },
    ))) return error.InputChanged;
    if (initializer) |path| {
        if (!initializer_identity.?.matches(try Dir.cwd().statFile(
            io,
            path,
            .{ .follow_symlinks = false },
        ))) return error.InputChanged;
    }
    return .{
        .source = source_snapshot,
        .initializer = initializer_snapshot,
    };
}

const SourceIdentity = struct {
    entry: EntryIdentity,
    size: u64,
    mtime: Io.Timestamp,
    ctime: Io.Timestamp,

    fn fromStat(stat: File.Stat) SourceIdentity {
        return .{
            .entry = EntryIdentity.fromStat(stat),
            .size = stat.size,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
        };
    }

    fn matches(self: SourceIdentity, stat: File.Stat) bool {
        return self.entry.matches(stat) and
            self.size == stat.size and
            self.mtime.nanoseconds == stat.mtime.nanoseconds and
            self.ctime.nanoseconds == stat.ctime.nanoseconds;
    }
};

fn sourceFileIdentity(io: Io, path: []const u8) !SourceIdentity {
    const stat = try Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .file) return error.MissingBuildArtifact;
    return SourceIdentity.fromStat(stat);
}

fn snapshotInputTree(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
    entry_name: []const u8,
    excluded_paths: []const InputExclusion,
    transaction: *Transaction,
) !TreeSnapshot {
    var source_dir = try Dir.openDirAbsolute(
        io,
        source_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source_dir.close(io);
    const source_identity = SourceIdentity.fromStat(try source_dir.stat(io));
    var destination_dir = try Dir.openDirAbsolute(
        io,
        destination_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer destination_dir.close(io);
    const destination_relative = try std.fs.path.relative(
        allocator,
        transaction.storage_path,
        null,
        transaction.storage_path,
        destination_path,
    );
    const normalized_entry = try normalizeTreePath(allocator, entry_name);
    var tree_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    tree_hasher.update("starling-componentizer-source-tree-v1\x00");
    const file_digest = try copyInputDirectory(
        allocator,
        io,
        source_dir,
        destination_dir,
        source_path,
        "",
        destination_relative,
        normalized_entry,
        excluded_paths,
        transaction,
        &tree_hasher,
    );
    if (!source_identity.matches(try source_dir.stat(io))) {
        return error.InputChanged;
    }
    var tree_digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
        undefined;
    tree_hasher.final(&tree_digest_bytes);
    const tree_digest_hex = std.fmt.bytesToHex(tree_digest_bytes, .lower);
    return .{
        .file = .{
            .path = try std.fs.path.join(
                allocator,
                &.{ destination_path, entry_name },
            ),
            .digest = file_digest orelse return error.MissingBuildArtifact,
        },
        .entry = normalized_entry,
        .digest = try allocator.dupe(u8, &tree_digest_hex),
    };
}

fn normalizeTreePath(allocator: Allocator, path: []const u8) ![]const u8 {
    try validatePathUtf8(path);
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') {
        for (normalized) |*byte| {
            if (byte.* == std.fs.path.sep) byte.* = '/';
        }
    }
    return normalized;
}

fn hashTreeEntryHeader(
    hasher: *std.crypto.hash.sha2.Sha256,
    kind: u8,
    relative: []const u8,
    payload_len: u64,
) void {
    var length_buffer: [32]u8 = undefined;
    const encoded_length = std.fmt.bufPrint(
        &length_buffer,
        "{d}",
        .{payload_len},
    ) catch unreachable;
    hasher.update(&.{kind});
    hasher.update(relative);
    hasher.update(&.{0});
    hasher.update(encoded_length);
    hasher.update(&.{0});
}

fn validateTreeSymlink(relative: []const u8, target: []const u8) !void {
    if (std.fs.path.isAbsolute(target)) return error.UnsupportedInputEntry;
    var depth: usize = 0;
    if (std.fs.path.dirname(relative)) |parent| {
        var parent_components = std.mem.splitScalar(u8, parent, '/');
        while (parent_components.next()) |component| {
            if (component.len != 0) depth += 1;
        }
    }
    var target_components = std.mem.splitScalar(u8, target, std.fs.path.sep);
    while (target_components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.UnsupportedInputEntry;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
}

fn copyInputDirectory(
    allocator: Allocator,
    io: Io,
    source: Dir,
    destination: Dir,
    source_path: []const u8,
    relative: []const u8,
    destination_relative: []const u8,
    digest_entry: []const u8,
    excluded_paths: []const InputExclusion,
    transaction: *Transaction,
    tree_hasher: *std.crypto.hash.sha2.Sha256,
) !?[]const u8 {
    const SourceEntry = struct {
        name: []const u8,
        identity: SourceIdentity,
    };
    var entries: std.ArrayList(SourceEntry) = .empty;
    defer entries.deinit(allocator);
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        try validatePathUtf8(entry.name);
        const child_source_path = try std.fs.path.join(
            allocator,
            &.{ source_path, entry.name },
        );
        const stat = try source.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        if (transaction.isRootEntry(child_source_path, stat)) {
            continue;
        }
        for (excluded_paths) |excluded| {
            if (excluded.matches(child_source_path, stat)) break;
        } else {
            entries.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .identity = SourceIdentity.fromStat(stat),
            }) catch @panic("out of memory");
        }
    }
    std.mem.sort(SourceEntry, entries.items, {}, struct {
        fn lessThan(_: void, left: SourceEntry, right: SourceEntry) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);

    var selected_digest: ?[]const u8 = null;
    for (entries.items) |entry| {
        const child_relative = if (relative.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ relative, entry.name },
            );
        const child_source_path = try std.fs.path.join(
            allocator,
            &.{ source_path, entry.name },
        );
        const owned_path = try std.fs.path.join(
            allocator,
            &.{ destination_relative, entry.name },
        );
        switch (entry.identity.entry.kind) {
            .file => {
                hashTreeEntryHeader(
                    tree_hasher,
                    'f',
                    child_relative,
                    entry.identity.size,
                );
                var source_file = try source.openFile(io, entry.name, .{});
                defer source_file.close(io);
                if (!entry.identity.matches(try source_file.stat(io))) {
                    return error.InputChanged;
                }
                var destination_file = try destination.createFile(
                    io,
                    entry.name,
                    .{ .exclusive = true },
                );
                defer destination_file.close(io);
                try transaction.recordStoragePath(
                    allocator,
                    io,
                    owned_path,
                );
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                var buffer: [64 * 1024]u8 = undefined;
                while (true) {
                    const count = source_file.readStreaming(
                        io,
                        &.{&buffer},
                    ) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (count == 0) continue;
                    if (std.mem.eql(u8, child_relative, digest_entry)) {
                        hasher.update(buffer[0..count]);
                    }
                    tree_hasher.update(buffer[0..count]);
                    try destination_file.writeStreamingAll(io, buffer[0..count]);
                }
                tree_hasher.update(&.{0xff});
                if (!entry.identity.matches(try source_file.stat(io))) {
                    return error.InputChanged;
                }
                try destination_file.setPermissions(
                    io,
                    (try source_file.stat(io)).permissions,
                );
                try destination_file.sync(io);
                if (std.mem.eql(u8, child_relative, digest_entry)) {
                    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
                        undefined;
                    hasher.final(&digest_bytes);
                    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
                    selected_digest = try allocator.dupe(u8, &digest_hex);
                }
            },
            .directory => {
                hashTreeEntryHeader(tree_hasher, 'd', child_relative, 0);
                tree_hasher.update(&.{0xff});
                try destination.createDir(io, entry.name, .fromMode(0o700));
                const destination_absolute = try destination.realPathFileAlloc(
                    io,
                    entry.name,
                    allocator,
                );
                try transaction.recordStorageAbsolute(
                    allocator,
                    io,
                    destination_absolute,
                );
                var source_child = try source.openDir(
                    io,
                    entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                defer source_child.close(io);
                if (!entry.identity.entry.matches(try source_child.stat(io))) {
                    return error.InputChanged;
                }
                var destination_child = try destination.openDir(
                    io,
                    entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                defer destination_child.close(io);
                _ = try copyInputDirectory(
                    allocator,
                    io,
                    source_child,
                    destination_child,
                    child_source_path,
                    child_relative,
                    owned_path,
                    digest_entry,
                    excluded_paths,
                    transaction,
                    tree_hasher,
                );
                if (!entry.identity.entry.matches(try source_child.stat(io))) {
                    return error.InputChanged;
                }
                try destination_child.setPermissions(
                    io,
                    (try source_child.stat(io)).permissions,
                );
            },
            .sym_link => {
                var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_len = try source.readLink(io, entry.name, &link_buffer);
                if (!entry.identity.matches(try source.statFile(
                    io,
                    entry.name,
                    .{ .follow_symlinks = false },
                ))) return error.InputChanged;
                try validateTreeSymlink(child_relative, link_buffer[0..link_len]);
                hashTreeEntryHeader(
                    tree_hasher,
                    'l',
                    child_relative,
                    link_len,
                );
                tree_hasher.update(link_buffer[0..link_len]);
                tree_hasher.update(&.{0xff});
                try destination.symLink(
                    io,
                    link_buffer[0..link_len],
                    entry.name,
                    .{},
                );
                try transaction.recordStorageAbsolute(
                    allocator,
                    io,
                    try std.fs.path.join(
                        allocator,
                        &.{ transaction.storage_path, owned_path },
                    ),
                );
            },
            else => return error.UnsupportedInputEntry,
        }
    }

    var seen: usize = 0;
    var final_iterator = source.iterate();
    while (try final_iterator.next(io)) |entry| {
        try validatePathUtf8(entry.name);
        const child_source_path = try std.fs.path.join(
            allocator,
            &.{ source_path, entry.name },
        );
        const stat = try source.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        if (transaction.isRootEntry(child_source_path, stat)) {
            continue;
        }
        for (excluded_paths) |excluded| {
            if (excluded.matches(child_source_path, stat)) break;
        } else {
            var matched = false;
            for (entries.items) |initial| {
                if (!std.mem.eql(u8, initial.name, entry.name)) continue;
                if (!initial.identity.matches(stat)) return error.InputChanged;
                matched = true;
                break;
            }
            if (!matched) return error.InputChanged;
            seen += 1;
        }
    }
    if (seen != entries.items.len) return error.InputChanged;
    return selected_digest;
}

fn snapshotFile(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
    transaction: *Transaction,
) !Snapshot {
    const source_stat = try Dir.cwd().statFile(
        io,
        source_path,
        .{ .follow_symlinks = true },
    );
    return snapshotFileExpected(
        allocator,
        io,
        source_path,
        destination_path,
        transaction,
        SourceIdentity.fromStat(source_stat),
    );
}

fn snapshotFileExpected(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
    transaction: *Transaction,
    expected_identity: SourceIdentity,
) !Snapshot {
    var source = try Dir.openFileAbsolute(
        io,
        source_path,
        .{},
    );
    defer source.close(io);
    const source_stat = try source.stat(io);
    if (source_stat.kind != .file) return error.MissingBuildArtifact;
    const source_identity = SourceIdentity.fromStat(source_stat);
    if (!expected_identity.matches(source_stat)) return error.InputChanged;

    var destination = try Dir.createFileAbsolute(
        io,
        destination_path,
        .{ .exclusive = true },
    );
    const destination_identity = EntryIdentity.fromStat(try destination.stat(io));
    try transaction.recordStorageAbsolute(allocator, io, destination_path);
    errdefer removeExactEntry(
        io,
        transaction.storage,
        std.fs.path.basename(destination_path),
        destination_identity,
    ) catch {};
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
    if (!source_identity.matches(try source.stat(io)) or
        !source_identity.matches(try Dir.cwd().statFile(
            io,
            source_path,
            .{ .follow_symlinks = true },
        )))
    {
        return error.InputChanged;
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

fn statEntry(directory: Dir, io: Io, name: []const u8) !?File.Stat {
    return directory.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn entryHasIdentity(
    directory: Dir,
    io: Io,
    name: []const u8,
    identity: EntryIdentity,
) !bool {
    const stat = try statEntry(directory, io, name) orelse return false;
    return identity.matches(stat);
}

fn removeExactEntry(
    io: Io,
    directory: Dir,
    name: []const u8,
    identity: EntryIdentity,
) !void {
    if (!try entryHasIdentity(directory, io, name, identity)) {
        return error.TransactionChanged;
    }
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    var cleanup_name_buffer: [".cleanup-".len + random_hex.len]u8 = undefined;
    const cleanup_name = try std.fmt.bufPrint(
        &cleanup_name_buffer,
        ".cleanup-{s}",
        .{&random_hex},
    );
    try directory.renamePreserve(name, directory, cleanup_name, io);
    if (!try entryHasIdentity(directory, io, cleanup_name, identity)) {
        directory.renamePreserve(
            cleanup_name,
            directory,
            name,
            io,
        ) catch {};
        return error.TransactionChanged;
    }
    if (identity.kind == .directory) {
        try directory.deleteDir(io, cleanup_name);
    } else {
        try directory.deleteFile(io, cleanup_name);
    }
}

fn verifyDirectoryEntries(
    io: Io,
    directory: Dir,
    expected: anytype,
) !void {
    var seen: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        var matched = false;
        for (expected) |candidate| {
            if (!std.mem.eql(u8, candidate.name, entry.name)) continue;
            if (!try entryHasIdentity(
                directory,
                io,
                entry.name,
                candidate.identity,
            )) return error.TransactionChanged;
            matched = true;
            break;
        }
        if (!matched) return error.TransactionChanged;
        seen += 1;
    }
    if (seen != expected.len) return error.TransactionChanged;
}

fn publishArtifacts(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component_staged: []const u8,
    component_output: []const u8,
    metadata_staged: ?[]const u8,
    metadata_output: ?[]const u8,
    debug_staged: ?[]const u8,
    debug_output: ?[]const u8,
    transaction_safe_to_remove: *bool,
    source: []const u8,
    resolved_output: []const u8,
    diagnostic: *diagnostics.Context,
) !void {
    _ = component_staged;
    var component = ArtifactState{
        .destination = component_output,
        .staged = "component.wasm",
        .backup_name = "previous-component",
    };
    var metadata_state: ?ArtifactState = if (metadata_staged != null) .{
        .destination = metadata_output.?,
        .staged = "metadata.json",
        .backup_name = "previous-metadata",
    } else null;
    var debug_state = DebugPublication{
        .destination = debug_output,
        .staged = if (debug_staged != null) "debug" else null,
    };

    publishArtifactsAttempt(
        allocator,
        io,
        transaction,
        &component,
        &metadata_state,
        &debug_state,
        transaction_safe_to_remove,
    ) catch |publish_error| {
        rollbackPublication(
            allocator,
            io,
            transaction,
            component,
            metadata_state,
            debug_state,
        ) catch {
            transaction_safe_to_remove.* = false;
            return error.RollbackIncomplete;
        };
        return publish_error;
    };

    transaction.verifyCanonicalPublication(io) catch |path_error| {
        rollbackPublication(
            allocator,
            io,
            transaction,
            component,
            metadata_state,
            debug_state,
        ) catch {
            transaction_safe_to_remove.* = false;
            return error.RollbackIncomplete;
        };
        return path_error;
    };
    diagnostic.reportSuccess(source, resolved_output);

    if (component.backup) |identity| {
        removeExactEntry(
            io,
            transaction.storage,
            component.backup_name,
            identity,
        ) catch {
            transaction_safe_to_remove.* = false;
        };
    }
    if (metadata_state) |state| {
        if (state.backup) |identity| {
            removeExactEntry(
                io,
                transaction.storage,
                state.backup_name,
                identity,
            ) catch {
                transaction_safe_to_remove.* = false;
            };
        }
    }
    if (debug_state.backup) |backup| {
        finalizeDebugBackup(
            io,
            transaction,
            backup,
        ) catch {
            transaction_safe_to_remove.* = false;
        };
    }
}

fn publishArtifactsAttempt(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component: *ArtifactState,
    metadata_state: *?ArtifactState,
    debug_state: *DebugPublication,
    transaction_safe_to_remove: *bool,
) !void {
    try transaction.verifyAttached(io);
    component.backup = try backupRegularDestination(
        allocator,
        io,
        transaction,
        component.destination,
        component.backup_name,
        error.InvalidPath,
    );
    if (metadata_state.*) |*state| {
        state.backup = try backupRegularDestination(
            allocator,
            io,
            transaction,
            state.destination,
            state.backup_name,
            error.InvalidMetadataDestination,
        );
    }
    if (debug_state.staged != null) {
        debug_state.backup = try prepareDebugDestination(
            allocator,
            io,
            transaction,
            debug_state.destination.?,
            transaction_safe_to_remove,
        );
    }

    component.published = try publishEntry(
        io,
        transaction,
        component.staged,
        component.destination,
    );
    try transaction.verifyAttached(io);
    if (!try entryHasIdentity(
        transaction.publication,
        io,
        component.destination,
        component.published.?,
    )) return error.TransactionChanged;
    if (metadata_state.*) |*state| {
        state.published = try publishEntry(
            io,
            transaction,
            state.staged,
            state.destination,
        );
    }
    if (debug_state.staged) |staged| {
        debug_state.published = try publishEntry(
            io,
            transaction,
            staged,
            debug_state.destination.?,
        );
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

const DebugMovedEntry = struct {
    name: []const u8,
    identity: EntryIdentity,
    generated: bool,
};

const DebugBackup = struct {
    identity: EntryIdentity,
    old_generated_identity: EntryIdentity,
    moved: []const DebugMovedEntry,
};

const DebugPublication = struct {
    destination: ?[]const u8,
    staged: ?[]const u8,
    backup: ?DebugBackup = null,
    published: ?EntryIdentity = null,
};

const ArtifactState = struct {
    destination: []const u8,
    staged: []const u8,
    backup_name: []const u8,
    backup: ?EntryIdentity = null,
    published: ?EntryIdentity = null,
};

fn backupRegularDestination(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    backup: []const u8,
    invalid_error: anyerror,
) !?EntryIdentity {
    const stat = try statEntry(transaction.publication, io, destination) orelse
        return null;
    if (stat.kind != .file) return invalid_error;
    const identity = EntryIdentity.fromStat(stat);
    try transaction.publication.renamePreserve(
        destination,
        transaction.storage,
        backup,
        io,
    );
    const moved = try transaction.storage.statFile(
        io,
        backup,
        .{ .follow_symlinks = false },
    );
    if (!identity.matches(moved)) {
        transaction.storage.renamePreserve(
            backup,
            transaction.publication,
            destination,
            io,
        ) catch {};
        return error.TransactionChanged;
    }
    try transaction.recordStoragePath(allocator, io, backup);
    return identity;
}

fn prepareDebugDestination(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    transaction_safe_to_remove: *bool,
) !?DebugBackup {
    const initial = try statEntry(
        transaction.publication,
        io,
        destination,
    ) orelse return null;
    if (initial.kind != .directory) return error.DebugOutputCollision;
    const backup_identity = EntryIdentity.fromStat(initial);
    try transaction.publication.renamePreserve(
        destination,
        transaction.storage,
        "previous-debug",
        io,
    );
    const moved_backup = try transaction.storage.statFile(
        io,
        "previous-debug",
        .{ .follow_symlinks = false },
    );
    if (!backup_identity.matches(moved_backup)) {
        transaction.storage.renamePreserve(
            "previous-debug",
            transaction.publication,
            destination,
            io,
        ) catch {};
        return error.TransactionChanged;
    }
    try transaction.recordStoragePath(allocator, io, "previous-debug");
    try transaction.createStorageDir(
        allocator,
        io,
        "previous-debug-generated",
        .fromMode(0o700),
    );
    const old_generated_identity = transaction.ownedIdentity(
        "previous-debug-generated",
    ).?;

    var backup_dir = try transaction.storage.openDir(
        io,
        "previous-debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer backup_dir.close(io);
    var staged_dir = try transaction.storage.openDir(
        io,
        "debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer staged_dir.close(io);
    var old_generated_dir = try transaction.storage.openDir(
        io,
        "previous-debug-generated",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer old_generated_dir.close(io);

    var iterator = backup_dir.iterate();
    var moved: std.ArrayList(DebugMovedEntry) = .empty;
    var moved_count: usize = 0;
    var prepared = false;
    errdefer if (!prepared) {
        undoDebugPreparation(
            io,
            transaction,
            destination,
            backup_identity,
            old_generated_identity,
            moved.items[0..moved_count],
        ) catch {
            transaction_safe_to_remove.* = false;
        };
    };
    while (try iterator.next(io)) |entry| {
        const stat = try backup_dir.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        const generated = isGeneratedDebugName(entry.name);
        if (generated and stat.kind != .file and stat.kind != .sym_link) {
            return error.DebugOutputCollision;
        }
        moved.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .identity = EntryIdentity.fromStat(stat),
            .generated = generated,
        }) catch @panic("out of memory");
    }

    try verifyDirectoryEntries(io, backup_dir, moved.items);
    for (moved.items) |entry| {
        const target = if (entry.generated)
            old_generated_dir
        else
            staged_dir;
        try backup_dir.renamePreserve(entry.name, target, entry.name, io);
        const moved_stat = try target.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        if (!entry.identity.matches(moved_stat)) {
            target.renamePreserve(
                entry.name,
                backup_dir,
                entry.name,
                io,
            ) catch {};
            return error.TransactionChanged;
        }
        moved_count += 1;
        try transaction.recordStoragePath(
            allocator,
            io,
            try std.fs.path.join(
                allocator,
                &.{
                    if (entry.generated)
                        "previous-debug-generated"
                    else
                        "debug",
                    entry.name,
                },
            ),
        );
    }
    var final_iterator = backup_dir.iterate();
    if (try final_iterator.next(io) != null) return error.TransactionChanged;
    prepared = true;
    return .{
        .identity = backup_identity,
        .old_generated_identity = old_generated_identity,
        .moved = moved.toOwnedSlice(allocator) catch @panic("out of memory"),
    };
}

fn undoDebugPreparation(
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    backup_identity: EntryIdentity,
    old_generated_identity: EntryIdentity,
    moved: []const DebugMovedEntry,
) !void {
    var backup_dir = try transaction.storage.openDir(
        io,
        "previous-debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer backup_dir.close(io);
    var staged_dir = try transaction.storage.openDir(
        io,
        "debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer staged_dir.close(io);
    var old_generated_dir = try transaction.storage.openDir(
        io,
        "previous-debug-generated",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer old_generated_dir.close(io);
    var index = moved.len;
    while (index > 0) {
        index -= 1;
        const entry = moved[index];
        const source = if (entry.generated) old_generated_dir else staged_dir;
        if (!try entryHasIdentity(source, io, entry.name, entry.identity)) {
            return error.TransactionChanged;
        }
        try source.renamePreserve(entry.name, backup_dir, entry.name, io);
        if (!try entryHasIdentity(
            backup_dir,
            io,
            entry.name,
            entry.identity,
        )) return error.TransactionChanged;
    }
    var old_generated_iterator = old_generated_dir.iterate();
    if (try old_generated_iterator.next(io) != null) {
        return error.TransactionChanged;
    }
    try removeExactEntry(
        io,
        transaction.storage,
        "previous-debug-generated",
        old_generated_identity,
    );
    try restoreBackup(
        io,
        transaction,
        destination,
        "previous-debug",
        backup_identity,
    );
}

fn publishEntry(
    io: Io,
    transaction: *Transaction,
    staged: []const u8,
    destination: []const u8,
) !EntryIdentity {
    const stat = try transaction.storage.statFile(
        io,
        staged,
        .{ .follow_symlinks = false },
    );
    const identity = transaction.ownedIdentity(staged) orelse
        return error.TransactionChanged;
    if (!identity.matches(stat)) return error.TransactionChanged;
    try transaction.storage.renamePreserve(
        staged,
        transaction.publication,
        destination,
        io,
    );
    const published = try transaction.publication.statFile(
        io,
        destination,
        .{ .follow_symlinks = false },
    );
    if (!identity.matches(published)) {
        transaction.publication.renamePreserve(
            destination,
            transaction.storage,
            staged,
            io,
        ) catch {};
        return error.TransactionChanged;
    }
    return identity;
}

fn rollbackPublication(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component: ArtifactState,
    metadata_state: ?ArtifactState,
    debug_state: DebugPublication,
) !void {
    var first_error: ?anyerror = null;
    if (debug_state.published) |identity| {
        returnPublishedEntry(
            io,
            transaction,
            debug_state.destination.?,
            debug_state.staged.?,
            identity,
        ) catch |err| if (first_error == null) {
            first_error = err;
        };
    }
    if (metadata_state) |state| {
        if (state.published) |identity| {
            returnPublishedEntry(
                io,
                transaction,
                state.destination,
                state.staged,
                identity,
            ) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
    }
    if (component.published) |identity| {
        returnPublishedEntry(
            io,
            transaction,
            component.destination,
            component.staged,
            identity,
        ) catch |err| if (first_error == null) {
            first_error = err;
        };
    }

    if (debug_state.backup) |backup| {
        restoreDebugBackup(
            allocator,
            io,
            transaction,
            debug_state.destination.?,
            backup,
        ) catch |err| if (first_error == null) {
            first_error = err;
        };
    }
    if (metadata_state) |state| {
        if (state.backup) |identity| {
            restoreBackup(
                io,
                transaction,
                state.destination,
                state.backup_name,
                identity,
            ) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
    }
    if (component.backup) |identity| {
        restoreBackup(
            io,
            transaction,
            component.destination,
            component.backup_name,
            identity,
        ) catch |err| if (first_error == null) {
            first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn returnPublishedEntry(
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    staged: []const u8,
    identity: EntryIdentity,
) !void {
    if (!try entryHasIdentity(
        transaction.publication,
        io,
        destination,
        identity,
    )) return error.TransactionChanged;
    try transaction.publication.renamePreserve(
        destination,
        transaction.storage,
        staged,
        io,
    );
    if (!try entryHasIdentity(
        transaction.storage,
        io,
        staged,
        identity,
    )) {
        transaction.storage.renamePreserve(
            staged,
            transaction.publication,
            destination,
            io,
        ) catch {};
        return error.TransactionChanged;
    }
}

fn restoreBackup(
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    backup: []const u8,
    identity: EntryIdentity,
) !void {
    if (try statEntry(transaction.publication, io, destination) != null) {
        return error.TransactionChanged;
    }
    if (!try entryHasIdentity(
        transaction.storage,
        io,
        backup,
        identity,
    )) return error.TransactionChanged;
    try transaction.storage.renamePreserve(
        backup,
        transaction.publication,
        destination,
        io,
    );
    if (!try entryHasIdentity(
        transaction.publication,
        io,
        destination,
        identity,
    )) return error.TransactionChanged;
}

fn restoreDebugBackup(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    backup: DebugBackup,
) !void {
    var backup_dir = try transaction.storage.openDir(
        io,
        "previous-debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer backup_dir.close(io);
    if (!backup.identity.matches(try backup_dir.stat(io))) {
        return error.TransactionChanged;
    }
    var staged_dir = try transaction.storage.openDir(
        io,
        "debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer staged_dir.close(io);
    var old_generated_dir = try transaction.storage.openDir(
        io,
        "previous-debug-generated",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer old_generated_dir.close(io);
    for (backup.moved) |entry| {
        const source = if (entry.generated) old_generated_dir else staged_dir;
        if (!try entryHasIdentity(source, io, entry.name, entry.identity)) {
            return error.TransactionChanged;
        }
        try source.renamePreserve(entry.name, backup_dir, entry.name, io);
        if (!try entryHasIdentity(
            backup_dir,
            io,
            entry.name,
            entry.identity,
        )) return error.TransactionChanged;
    }
    _ = allocator;
    try restoreBackup(
        io,
        transaction,
        destination,
        "previous-debug",
        backup.identity,
    );
}

fn finalizeDebugBackup(
    io: Io,
    transaction: *Transaction,
    backup: DebugBackup,
) !void {
    var backup_dir = try transaction.storage.openDir(
        io,
        "previous-debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer backup_dir.close(io);
    if (!backup.identity.matches(try backup_dir.stat(io))) {
        return error.TransactionChanged;
    }
    var backup_iterator = backup_dir.iterate();
    if (try backup_iterator.next(io) != null) return error.TransactionChanged;

    var old_generated = try transaction.storage.openDir(
        io,
        "previous-debug-generated",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer old_generated.close(io);
    if (!backup.old_generated_identity.matches(try old_generated.stat(io))) {
        return error.TransactionChanged;
    }
    for (backup.moved) |entry| {
        if (!entry.generated) continue;
        try removeExactEntry(io, old_generated, entry.name, entry.identity);
    }
    var final_iterator = old_generated.iterate();
    if (try final_iterator.next(io) != null) return error.TransactionChanged;
    if (!try entryHasIdentity(
        transaction.storage,
        io,
        "previous-debug-generated",
        backup.old_generated_identity,
    )) return error.TransactionChanged;
    try removeExactEntry(
        io,
        transaction.storage,
        "previous-debug-generated",
        backup.old_generated_identity,
    );
    if (!try entryHasIdentity(
        transaction.storage,
        io,
        "previous-debug",
        backup.identity,
    )) return error.TransactionChanged;
    try removeExactEntry(
        io,
        transaction.storage,
        "previous-debug",
        backup.identity,
    );
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

const child_output_limit = 16 * 1024;
const child_capture_limit = child_output_limit + std.fs.max_path_bytes;

const BoundedChildOutput = struct {
    bytes: std.ArrayList(u8) = .empty,
    truncated: bool = false,

    fn deinit(self: *BoundedChildOutput, allocator: Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn append(
        self: *BoundedChildOutput,
        allocator: Allocator,
        chunk: []const u8,
    ) !void {
        if (chunk.len >= child_capture_limit) {
            self.bytes.clearRetainingCapacity();
            try self.bytes.appendSlice(
                allocator,
                chunk[chunk.len - child_capture_limit ..],
            );
            self.truncated = true;
            return;
        }
        const overflow = self.bytes.items.len + chunk.len;
        if (overflow > child_capture_limit) {
            const remove = overflow - child_capture_limit;
            @memmove(
                self.bytes.items[0 .. self.bytes.items.len - remove],
                self.bytes.items[remove..],
            );
            self.bytes.items.len -= remove;
            self.truncated = true;
        }
        try self.bytes.appendSlice(allocator, chunk);
    }

    fn render(
        self: *const BoundedChildOutput,
        allocator: Allocator,
        stream_name: []const u8,
        redact_path: ?[]const u8,
    ) ![]const u8 {
        const stable = if (redact_path) |path|
            try std.mem.replaceOwned(
                u8,
                allocator,
                self.bytes.items,
                path,
                "<transaction>",
            )
        else
            try allocator.dupe(u8, self.bytes.items);
        if (!self.truncated and stable.len <= child_output_limit) return stable;
        defer allocator.free(stable);
        const marker = try std.fmt.allocPrint(
            allocator,
            "[child {s} truncated; showing final output]\n",
            .{stream_name},
        );
        defer allocator.free(marker);
        const tail_len = @min(
            stable.len,
            child_output_limit - marker.len,
        );
        return std.mem.concat(
            allocator,
            u8,
            &.{
                marker,
                stable[stable.len - tail_len ..],
            },
        );
    }
};

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
            const stable_arg = if (redact_path) |path|
                try std.mem.replaceOwned(
                    u8,
                    allocator,
                    arg,
                    path,
                    "<transaction>",
                )
            else
                arg;
            const line = try std.fmt.allocPrint(
                allocator,
                "  {s}\n",
                .{stable_arg},
            );
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
    var stdout_capture: BoundedChildOutput = .{};
    defer stdout_capture.deinit(allocator);
    var stderr_capture: BoundedChildOutput = .{};
    defer stderr_capture.deinit(allocator);
    while (true) {
        multi_reader.fill(4096, .none) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |read_err| return read_err,
        };
        const stdout = multi_reader.reader(0);
        const stderr = multi_reader.reader(1);
        const stdout_chunk = stdout.buffered();
        const stderr_chunk = stderr.buffered();
        if (diagnostic.format == .human and redact_path == null) {
            if (stdout_chunk.len != 0) {
                try File.stdout().writeStreamingAll(io, stdout_chunk);
            }
            if (stderr_chunk.len != 0) {
                try File.stderr().writeStreamingAll(io, stderr_chunk);
            }
        }
        try stdout_capture.append(allocator, stdout_chunk);
        try stderr_capture.append(allocator, stderr_chunk);
        stdout.tossBuffered();
        stderr.tossBuffered();
    }
    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    if (diagnostic.format == .human and redact_path != null) {
        const stdout = try stdout_capture.render(
            allocator,
            "stdout",
            redact_path,
        );
        if (stdout.len != 0) {
            try File.stdout().writeStreamingAll(io, stdout);
        }
        if (termSucceeded(term)) {
            const stderr = try stderr_capture.render(
                allocator,
                "stderr",
                redact_path,
            );
            if (stderr.len != 0) {
                try File.stderr().writeStreamingAll(io, stderr);
            }
        }
    }
    if (!termSucceeded(term)) {
        const stderr = try stderr_capture.render(
            allocator,
            "stderr",
            redact_path,
        );
        diagnostic.commandFailed(stage, term, stderr, null);
        return error.CommandFailed;
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

fn addMappedPreopen(
    allocator: Allocator,
    args: *std.ArrayList([]const u8),
    host: []const u8,
    guest: []const u8,
) !void {
    try validateArgument(host);
    try validateArgument(guest);
    const mapping = try std.fmt.allocPrint(
        allocator,
        "{s}::{s}",
        .{ host, guest },
    );
    args.appendSlice(allocator, &.{ "--dir", mapping }) catch @panic("out of memory");
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
    try validatePathUtf8(value);
}

fn validatePathUtf8(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8Path;
}

fn validateConfiguredPaths(config: *const cli.Config) !void {
    try validateArgument(config.source);
    const optional_paths = [_]?[]const u8{
        config.output,
        config.wit,
        config.component_wit,
        config.initializer_script_path,
        config.strip_path_prefix,
        config.engine,
        config.preview2_adapter,
        config.zig_bin,
        config.wizer_bin,
        config.wasmtime_bin,
        config.wabt_bin,
        config.wasm_tools_bin,
        config.weval_bin,
        config.build_root,
        config.cache_dir,
        config.metadata_out,
        config.debug_dir,
    };
    for (optional_paths) |path| {
        if (path) |value| try validateArgument(value);
    }
    for (config.preopen_dirs) |path| try validateArgument(path);
}

fn pathExists(io: Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pathKindNoFollow(io: Io, path: []const u8) !?File.Kind {
    return pathKindNoFollowAt(.cwd(), io, path);
}

fn pathKindNoFollowAt(directory: Dir, io: Io, path: []const u8) !?File.Kind {
    const stat = directory.statFile(
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
    return requireDestinationFileOrMissingAt(
        .cwd(),
        io,
        path,
        invalid_error,
    );
}

fn requireDestinationFileOrMissingAt(
    directory: Dir,
    io: Io,
    path: []const u8,
    invalid_error: anyerror,
) !void {
    const stat = directory.statFile(
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

fn resolveOrCreateDirectory(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) ![]const u8 {
    return Dir.realPathFileAbsoluteAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            try Dir.cwd().createDirPath(io, path);
            return Dir.realPathFileAbsoluteAlloc(io, path, allocator);
        },
        else => return err,
    };
}

fn resolveEffectiveCache(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    build_root: ?[]const u8,
    configured: ?[]const u8,
) !EffectiveCache {
    const requested = if (configured) |path|
        try absolutePath(allocator, cwd, path)
    else
        try std.fs.path.join(
            allocator,
            &.{ build_root.?, ".zig-cache", "starling-componentizer" },
        );
    try Dir.cwd().createDirPath(io, requested);
    const resolved = try Dir.realPathFileAbsoluteAlloc(io, requested, allocator);
    const stat = try Dir.cwd().statFile(
        io,
        resolved,
        .{ .follow_symlinks = false },
    );
    if (stat.kind != .directory) return error.InvalidPath;
    return .{
        .path = resolved,
        .identity = EntryIdentity.fromStat(stat),
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

test "child output capture retains a bounded marked tail" {
    var capture: BoundedChildOutput = .{};
    defer capture.deinit(std.testing.allocator);
    const chunk = "0123456789abcdef";
    var index: usize = 0;
    while (index < child_capture_limit / chunk.len + 2) : (index += 1) {
        try capture.append(std.testing.allocator, chunk);
    }
    try std.testing.expectEqual(child_capture_limit, capture.bytes.items.len);
    try std.testing.expect(capture.truncated);

    const rendered = try capture.render(
        std.testing.allocator,
        "stderr",
        null,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(rendered.len <= child_output_limit);
    try std.testing.expect(std.mem.startsWith(
        u8,
        rendered,
        "[child stderr truncated; showing final output]\n",
    ));
    try std.testing.expect(std.mem.endsWith(u8, rendered, chunk));
}
