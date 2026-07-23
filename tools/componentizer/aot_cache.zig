const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema = "starling-weval-cache-v2";
pub const engine_abi = "spidermonkey-pbl-weval-aot-ics-v1";
pub const cache_abi = "weval-sqlite-v1";
pub const primer_abi = "starling-aot-cache-initialize-v1";
pub const cache_basename = "starling-ics.wevalcache";
pub const manifest_basename = "starling-ics.wevalcache.manifest";
pub const default_min_stack_size: u64 = 8 * 1024 * 1024;

pub const Error = error{
    AotCacheTestFailure,
    CorruptCache,
    IncompleteCache,
    InstallOwnershipConflict,
    InvalidCacheFormat,
    InvalidCacheSchema,
    InvalidDestinationKind,
    InvalidManifest,
    InvalidRecoveryJournal,
    MissingCacheArtifact,
    SealPathAlias,
    SealPathRace,
    SqliteUnavailable,
    StaleEngine,
    StaleFeatureAbi,
    StaleTool,
    TransactionRecoveryRequired,
    UnsafeWevalPackage,
    WevalPackageRace,
    WevalPackageTooDeep,
    WevalPackageTooLarge,
};

pub const Validated = struct {
    key: []const u8,
    feature_abi: []const u8,
    weval_package_sha256: []const u8,
    weval_selected_relative: []const u8,
    weval_selected_basename: []const u8,
};

const Manifest = struct {
    key: []const u8 = "",
    engine_sha256: []const u8 = "",
    weval_sha256: []const u8 = "",
    cache_sha256: []const u8 = "",
    feature_abi: []const u8 = "",
    primer_sha256: []const u8 = "",
    weval_package_sha256: []const u8 = "",
    weval_selected_relative: []const u8 = "",
    weval_selected_basename: []const u8 = "",
};

const WevalPackageSeal = struct {
    root: []const u8,
    selected: []const u8,
    provenance: []const u8,
    digest: []const u8,
    selected_relative: []const u8,
    selected_basename: []const u8,
};

pub fn featureAbi(
    allocator: Allocator,
    stdio: bool,
    random: bool,
    clocks: bool,
    http: bool,
    fetch_event: bool,
    optimize: []const u8,
    host_api: []const u8,
    debugger: bool,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "starling-features-v1;stdio={d};random={d};clocks={d};http={d};" ++
            "fetch-event={d};optimize={s};host-api={s};debugger={d}",
        .{
            @intFromBool(stdio),
            @intFromBool(random),
            @intFromBool(clocks),
            @intFromBool(http),
            @intFromBool(fetch_event),
            optimize,
            host_api,
            @intFromBool(debugger),
        },
    );
}

pub fn seal(
    allocator: Allocator,
    io: Io,
    engine_path: []const u8,
    weval_path: []const u8,
    cache_path: []const u8,
    canonical_cache_path: ?[]const u8,
    primer_path: []const u8,
    feature_abi: []const u8,
    manifest_path: []const u8,
) !void {
    return sealWithHooks(
        allocator,
        io,
        engine_path,
        weval_path,
        cache_path,
        canonical_cache_path,
        primer_path,
        feature_abi,
        manifest_path,
        .{},
    );
}

pub const SealHooks = struct {
    directory: ?[]const u8 = null,
    wait_at: ?[]const u8 = null,
    notify_at: ?[]const u8 = null,
    fail_at: ?[]const u8 = null,
};

pub fn sealWithHooks(
    allocator: Allocator,
    io: Io,
    engine_path: []const u8,
    weval_path: []const u8,
    cache_path: []const u8,
    canonical_cache_path: ?[]const u8,
    primer_path: []const u8,
    feature_abi: []const u8,
    manifest_path: []const u8,
    hooks: SealHooks,
) !void {
    try validateValue(feature_abi);
    var transaction = try SealTransaction.init(
        allocator,
        io,
        engine_path,
        weval_path,
        cache_path,
        canonical_cache_path,
        primer_path,
        manifest_path,
        hooks,
    );
    defer transaction.deinit(io);
    try transaction.rejectAliases();
    try transaction.rejectUnsupportedDestinations();
    try transaction.beginWorkspace(allocator, io);
    try runSealHook(allocator, io, hooks, "after-preflight");

    const engine_sha = try hashStableFileHex(allocator, io, transaction.engine);
    try runSealHook(allocator, io, hooks, "after-engine-hash");
    var source_snapshot = try stageStableCopy(
        allocator,
        io,
        transaction.cache_workspace.?,
        ".aot-source",
        transaction.source_cache,
    );
    defer source_snapshot.deinit(io);
    const source_sha = try hashStableFileHex(
        allocator,
        io,
        transaction.source_cache,
    );
    const snapshot_sha = try hashFileHandleHex(
        allocator,
        io,
        source_snapshot.file,
    );
    if (!std.mem.eql(u8, source_sha, snapshot_sha))
        return error.SealPathRace;
    try verifyCacheDatabaseFile(io, source_snapshot.file, engine_sha);

    var canonical = try stageCanonicalCache(
        allocator,
        io,
        transaction.cache_workspace.?,
        source_snapshot.file,
        engine_sha,
    );
    defer canonical.deinit(io);
    const weval_package = try inspectWevalPackage(
        allocator,
        io,
        weval_path,
    );
    if (!std.mem.eql(u8, weval_package.provenance, transaction.weval.resolved))
        return error.WevalPackageRace;
    const weval_sha = try hashStableFileHex(allocator, io, transaction.weval);
    try runSealHook(allocator, io, hooks, "after-weval-hash");
    const primer_sha = try hashStableFileHex(allocator, io, transaction.primer);
    try runSealHook(allocator, io, hooks, "after-primer-hash");
    const cache_sha = try hashFileHandleHex(allocator, io, canonical.file);
    try runSealHook(allocator, io, hooks, "after-cache-hash");
    const key = try cacheKey(
        allocator,
        engine_sha,
        weval_sha,
        weval_package.digest,
        weval_package.selected_relative,
        weval_package.selected_basename,
        feature_abi,
        primer_sha,
    );
    const contents = try std.fmt.allocPrint(
        allocator,
        "schema={s}\n" ++
            "key={s}\n" ++
            "engine_abi={s}\n" ++
            "cache_abi={s}\n" ++
            "primer_abi={s}\n" ++
            "engine_sha256={s}\n" ++
            "weval_sha256={s}\n" ++
            "cache_sha256={s}\n" ++
            "feature_abi={s}\n" ++
            "primer_sha256={s}\n" ++
            "weval_package_sha256={s}\n" ++
            "weval_selected_relative={s}\n" ++
            "weval_selected_basename={s}\n",
        .{
            schema,
            key,
            engine_abi,
            cache_abi,
            primer_abi,
            engine_sha,
            weval_sha,
            cache_sha,
            feature_abi,
            primer_sha,
            weval_package.digest,
            weval_package.selected_relative,
            weval_package.selected_basename,
        },
    );
    var manifest = try createPrivateFile(
        allocator,
        io,
        transaction.manifest_workspace.?,
        ".aot-manifest",
    );
    defer manifest.deinit(io);
    try manifest.file.writePositionalAll(io, contents, 0);
    try manifest.file.sync(io);
    manifest.identity = try manifest.file.stat(io);
    manifest.filesystem = try filesystemId(manifest.file);
    manifest.name_identity = manifest.identity;
    manifest.name_filesystem = manifest.filesystem;
    try runSealHook(allocator, io, hooks, "after-manifest-stage");
    try transaction.verifyInputsStable(
        allocator,
        io,
        engine_sha,
        weval_sha,
        source_sha,
        primer_sha,
        weval_package,
    );

    try publishBundle(
        allocator,
        io,
        &transaction.cache_output,
        &canonical,
        &transaction.manifest_output,
        &manifest,
        &transaction.guard.?,
        hooks,
    );
}

const StableInput = struct {
    role: []const u8,
    supplied: []const u8,
    absolute: []const u8,
    resolved: []const u8,
    file: File,
    identity: File.Stat,
    filesystem: u128,

    fn close(input: StableInput, io: Io) void {
        input.file.close(io);
    }
};

const DestinationState = union(enum) {
    missing,
    existing: struct {
        file: File,
        identity: File.Stat,
        filesystem: u128,
    },

    fn close(state: DestinationState, io: Io) void {
        switch (state) {
            .missing => {},
            .existing => |existing| existing.file.close(io),
        }
    }
};

const SealOutput = struct {
    role: []const u8,
    supplied: []const u8,
    absolute: []const u8,
    resolved: []const u8,
    parent_path: []const u8,
    basename: []const u8,
    parent: Dir,
    parent_identity: File.Stat,
    parent_filesystem: u128,
    initial: DestinationState,

    fn deinit(output: SealOutput, io: Io) void {
        output.initial.close(io);
        output.parent.close(io);
    }

    fn refreshInitial(output: *SealOutput, io: Io) !void {
        output.initial.close(io);
        const file = output.parent.openFile(io, output.basename, .{
            .path_only = true,
            .follow_symlinks = false,
            .allow_directory = true,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                output.initial = .missing;
                return;
            },
            else => return err,
        };
        errdefer file.close(io);
        output.initial = .{ .existing = .{
            .file = file,
            .identity = try file.stat(io),
            .filesystem = try filesystemId(file),
        } };
    }
};

fn sameOutputParent(
    left: *const SealOutput,
    right: *const SealOutput,
) bool {
    return sameObject(
        left.parent_identity,
        left.parent_filesystem,
        right.parent_identity,
        right.parent_filesystem,
    );
}

const SealTransaction = struct {
    allocator: Allocator,
    engine: StableInput,
    weval: StableInput,
    source_cache: StableInput,
    primer: StableInput,
    cache_output: SealOutput,
    manifest_output: SealOutput,
    in_place: bool,
    hooks: SealHooks,
    guard: ?SealGuard = null,
    cache_workspace: ?Dir = null,
    manifest_workspace: ?Dir = null,
    shared_workspace: bool = false,

    fn init(
        allocator: Allocator,
        io: Io,
        engine_path: []const u8,
        weval_path: []const u8,
        cache_path: []const u8,
        canonical_cache_path: ?[]const u8,
        primer_path: []const u8,
        manifest_path: []const u8,
        hooks: SealHooks,
    ) !SealTransaction {
        var cache_output = try openSealOutput(
            allocator,
            io,
            "canonical cache output",
            canonical_cache_path orelse cache_path,
            hooks,
        );
        errdefer cache_output.deinit(io);
        var manifest_output = try openSealOutput(
            allocator,
            io,
            "manifest output",
            manifest_path,
            hooks,
        );
        errdefer manifest_output.deinit(io);
        const engine = try openStableInput(allocator, io, "engine", engine_path);
        errdefer engine.close(io);
        const weval = try openWevalInput(allocator, io, weval_path);
        errdefer weval.close(io);
        const source_cache = try openStableInput(
            allocator,
            io,
            "source cache",
            cache_path,
        );
        errdefer source_cache.close(io);
        const primer = try openStableInput(allocator, io, "primer", primer_path);
        errdefer primer.close(io);
        return .{
            .allocator = allocator,
            .engine = engine,
            .weval = weval,
            .source_cache = source_cache,
            .primer = primer,
            .cache_output = cache_output,
            .manifest_output = manifest_output,
            .in_place = canonical_cache_path == null,
            .hooks = hooks,
        };
    }

    fn deinit(transaction: *SealTransaction, io: Io) void {
        if (transaction.guard) |*guard| {
            guard.finish(
                transaction.allocator,
                io,
                &transaction.cache_output,
                &transaction.manifest_output,
                transaction.cache_workspace,
                transaction.manifest_workspace,
                transaction.shared_workspace,
            ) catch |err| {
                guard.recovery_required = true;
                std.debug.print(
                    "error: AOT seal cleanup requires recovery: {t}\n",
                    .{err},
                );
            };
        }
        if (transaction.manifest_workspace) |workspace| {
            if (!transaction.shared_workspace) workspace.close(io);
        }
        if (transaction.cache_workspace) |workspace| workspace.close(io);
        transaction.manifest_output.deinit(io);
        transaction.cache_output.deinit(io);
        transaction.primer.close(io);
        transaction.source_cache.close(io);
        transaction.weval.close(io);
        transaction.engine.close(io);
        if (transaction.guard) |*guard| guard.deinit(io);
    }

    fn beginWorkspace(
        transaction: *SealTransaction,
        allocator: Allocator,
        io: Io,
    ) !void {
        try runSealHook(
            allocator,
            io,
            transaction.hooks,
            "before-destination-locks",
        );
        var guard = try SealGuard.init(
            allocator,
            io,
            &transaction.cache_output,
            &transaction.manifest_output,
        );
        errdefer guard.deinit(io);
        try guard.recover(
            allocator,
            io,
            &transaction.cache_output,
            &transaction.manifest_output,
            .{},
        );
        try transaction.cache_output.refreshInitial(io);
        try transaction.manifest_output.refreshInitial(io);
        try transaction.rejectAliases();
        try transaction.rejectUnsupportedDestinations();
        if (!try destinationMatchesStart(io, &transaction.cache_output) or
            !try destinationMatchesStart(io, &transaction.manifest_output))
            return error.SealPathRace;
        const workspaces = try guard.begin(
            allocator,
            io,
            &transaction.cache_output,
            &transaction.manifest_output,
            transaction.hooks,
        );
        transaction.cache_workspace = workspaces.cache;
        transaction.manifest_workspace = workspaces.manifest;
        transaction.shared_workspace = workspaces.shared;
        transaction.guard = guard;
    }

    fn rejectAliases(transaction: *const SealTransaction) Error!void {
        const inputs = [_]*const StableInput{
            &transaction.engine,
            &transaction.weval,
            &transaction.source_cache,
            &transaction.primer,
        };
        for (inputs, 0..) |left, left_index| {
            for (inputs[left_index + 1 ..]) |right| {
                if (sameResolvedOrIdentity(
                    left.resolved,
                    left.identity,
                    left.filesystem,
                    right.resolved,
                    right.identity,
                    right.filesystem,
                )) return reportAlias(left.role, left.supplied, right.role, right.supplied);
            }
        }
        const outputs = [_]*const SealOutput{
            &transaction.cache_output,
            &transaction.manifest_output,
        };
        for (outputs, 0..) |output, output_index| {
            for (inputs) |input| {
                const safe_in_place = transaction.in_place and
                    output == &transaction.cache_output and
                    input == &transaction.source_cache;
                if (safe_in_place) continue;
                if (outputAliasesInput(output, input))
                    return reportAlias(output.role, output.supplied, input.role, input.supplied);
            }
            for (outputs[output_index + 1 ..]) |right| {
                if (outputsAlias(output, right))
                    return reportAlias(output.role, output.supplied, right.role, right.supplied);
            }
        }
    }

    fn rejectUnsupportedDestinations(transaction: *const SealTransaction) Error!void {
        for ([_]*const SealOutput{
            &transaction.cache_output,
            &transaction.manifest_output,
        }) |output| {
            switch (output.initial) {
                .missing => {},
                .existing => |existing| {
                    if (existing.identity.kind != .file)
                        return error.InvalidDestinationKind;
                },
            }
        }
    }

    fn verifyInputsStable(
        transaction: *const SealTransaction,
        allocator: Allocator,
        io: Io,
        engine_sha: []const u8,
        weval_sha: []const u8,
        source_sha: []const u8,
        primer_sha: []const u8,
        weval_package: WevalPackageSeal,
    ) !void {
        const inputs = [_]struct {
            input: StableInput,
            digest: []const u8,
        }{
            .{ .input = transaction.engine, .digest = engine_sha },
            .{ .input = transaction.weval, .digest = weval_sha },
            .{ .input = transaction.source_cache, .digest = source_sha },
            .{ .input = transaction.primer, .digest = primer_sha },
        };
        for (inputs) |expected| {
            const current = try rehashStableFileHex(
                allocator,
                io,
                expected.input,
            );
            if (!std.mem.eql(u8, current, expected.digest))
                return error.SealPathRace;
        }
        const current_package = try inspectWevalPackage(
            allocator,
            io,
            weval_package.selected,
        );
        if (!std.mem.eql(u8, current_package.provenance, transaction.weval.resolved) or
            !std.mem.eql(u8, current_package.digest, weval_package.digest) or
            !std.mem.eql(
                u8,
                current_package.selected_relative,
                weval_package.selected_relative,
            ) or
            !std.mem.eql(
                u8,
                current_package.selected_basename,
                weval_package.selected_basename,
            ))
            return error.WevalPackageRace;
    }
};

fn openWevalInput(
    allocator: Allocator,
    io: Io,
    supplied: []const u8,
) !StableInput {
    const absolute = try absoluteSealPath(allocator, io, supplied);
    const resolved = Dir.realPathFileAbsoluteAlloc(
        io,
        absolute,
        allocator,
    ) catch return error.MissingCacheArtifact;
    var file = try Dir.openFileAbsolute(io, resolved, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    errdefer file.close(io);
    const identity = try file.stat(io);
    if (identity.kind != .file) return error.MissingCacheArtifact;
    return .{
        .role = "Weval binary",
        .supplied = supplied,
        .absolute = absolute,
        .resolved = resolved,
        .file = file,
        .identity = identity,
        .filesystem = try filesystemId(file),
    };
}

const weval_package_max_entries = 4096;
const weval_package_max_depth = 32;
const weval_package_max_bytes: u64 = 1024 * 1024 * 1024;

const WevalPackageHashState = struct {
    allocator: Allocator,
    io: Io,
    hasher: Sha256 = Sha256.init(.{}),
    entries: usize = 0,
    bytes: u64 = 0,
    symlinks: std.ArrayList([]const u8) = .empty,
};

const WevalPackageIdentity = struct {
    stat: File.Stat,
    filesystem: u128,
};

fn inspectWevalPackage(
    allocator: Allocator,
    io: Io,
    selected_path: []const u8,
) !WevalPackageSeal {
    const absolute = try absoluteSealPath(allocator, io, selected_path);
    const parent_path = std.fs.path.dirname(absolute) orelse
        return error.UnsafeWevalPackage;
    const selected_basename = std.fs.path.basename(absolute);
    try validateBundleBasename(selected_basename);
    const root = Dir.realPathFileAbsoluteAlloc(
        io,
        parent_path,
        allocator,
    ) catch return error.UnsafeWevalPackage;
    const selected = try std.fs.path.join(
        allocator,
        &.{ root, selected_basename },
    );
    var selected_name = Dir.openFileAbsolute(io, selected, .{
        .path_only = true,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.UnsafeWevalPackage;
    defer selected_name.close(io);
    const selected_stat = try selected_name.stat(io);
    if (selected_stat.kind != .file and selected_stat.kind != .sym_link)
        return error.UnsafeWevalPackage;
    const provenance = Dir.realPathFileAbsoluteAlloc(
        io,
        selected,
        allocator,
    ) catch return error.UnsafeWevalPackage;
    if (!wevalPathContains(root, provenance))
        return error.UnsafeWevalPackage;
    var executable = try Dir.openFileAbsolute(io, provenance, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer executable.close(io);
    const executable_stat = try executable.stat(io);
    if (executable_stat.kind != .file)
        return error.UnsafeWevalPackage;
    if (File.Permissions.has_executable_bit and
        executable_stat.permissions.toMode() & 0o111 == 0)
        return error.UnsafeWevalPackage;
    const selected_relative = try allocator.dupe(u8, selected_basename);
    try validateWevalSelection(selected_relative, selected_basename);
    return .{
        .root = root,
        .selected = selected,
        .provenance = provenance,
        .digest = try hashWevalPackageHex(allocator, io, root),
        .selected_relative = selected_relative,
        .selected_basename = try allocator.dupe(u8, selected_basename),
    };
}

pub fn validateWevalPackage(
    allocator: Allocator,
    io: Io,
    selected_path: []const u8,
    expected: Validated,
) !void {
    const package = try inspectWevalPackage(allocator, io, selected_path);
    if (!std.mem.eql(
        u8,
        package.digest,
        expected.weval_package_sha256,
    ) or !std.mem.eql(
        u8,
        package.selected_relative,
        expected.weval_selected_relative,
    ) or !std.mem.eql(
        u8,
        package.selected_basename,
        expected.weval_selected_basename,
    ))
        return error.StaleTool;
}

fn hashWevalPackageHex(
    allocator: Allocator,
    io: Io,
    root_path: []const u8,
) ![]const u8 {
    var root = try Dir.openDirAbsolute(io, root_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer root.close(io);
    const root_identity = try wevalDirectoryIdentity(io, root);
    if (root_identity.stat.kind != .directory)
        return error.UnsafeWevalPackage;
    var state: WevalPackageHashState = .{
        .allocator = allocator,
        .io = io,
    };
    defer state.symlinks.deinit(allocator);
    state.hasher.update("starling-weval-package-v1\x00");
    hashWevalPackageEntry(&state.hasher, 'd', "", root_identity.stat);
    try hashWevalPackageDirectory(
        &state,
        root,
        "",
        0,
        root_identity,
    );
    for (state.symlinks.items) |relative| {
        const link_path = try std.fs.path.join(
            allocator,
            &.{ root_path, relative },
        );
        const resolved = Dir.realPathFileAbsoluteAlloc(
            io,
            link_path,
            allocator,
        ) catch return error.UnsafeWevalPackage;
        if (!wevalPathContains(root_path, resolved))
            return error.UnsafeWevalPackage;
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    state.hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn hashWevalPackageDirectory(
    state: *WevalPackageHashState,
    directory: Dir,
    relative_dir: []const u8,
    depth: usize,
    initial_identity: WevalPackageIdentity,
) anyerror!void {
    if (depth > weval_package_max_depth)
        return error.WevalPackageTooDeep;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(state.allocator);
    var iterator = directory.iterate();
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
        try validateBundleBasename(name);
        const relative = if (relative_dir.len == 0)
            try state.allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(
                state.allocator,
                "{s}/{s}",
                .{ relative_dir, name },
            );
        const identity = try wevalPathIdentity(state.io, directory, name);
        switch (identity.stat.kind) {
            .file => {
                if (identity.stat.size > weval_package_max_bytes - state.bytes)
                    return error.WevalPackageTooLarge;
                state.bytes += identity.stat.size;
                hashWevalPackageEntry(
                    &state.hasher,
                    'f',
                    relative,
                    identity.stat,
                );
                var file = try directory.openFile(state.io, name, .{
                    .allow_directory = false,
                    .follow_symlinks = false,
                });
                defer file.close(state.io);
                const opened = try wevalFileIdentity(state.io, file);
                if (!sameStableWevalIdentity(identity, opened))
                    return error.WevalPackageRace;
                const digest = try hashWevalPackageFile(state.io, file);
                const final = try wevalFileIdentity(state.io, file);
                if (!sameStableWevalIdentity(identity, final))
                    return error.WevalPackageRace;
                state.hasher.update(&digest);
            },
            .directory => {
                hashWevalPackageEntry(
                    &state.hasher,
                    'd',
                    relative,
                    identity.stat,
                );
                var child = try directory.openDir(state.io, name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child.close(state.io);
                const opened = try wevalDirectoryIdentity(state.io, child);
                if (!sameStableWevalIdentity(identity, opened))
                    return error.WevalPackageRace;
                try hashWevalPackageDirectory(
                    state,
                    child,
                    relative,
                    depth + 1,
                    opened,
                );
            },
            .sym_link => {
                hashWevalPackageEntry(
                    &state.hasher,
                    'l',
                    relative,
                    identity.stat,
                );
                var target_buffer: [Dir.max_path_bytes]u8 = undefined;
                const target_len = try directory.readLink(
                    state.io,
                    name,
                    &target_buffer,
                );
                const target = target_buffer[0..target_len];
                if (target.len == 0 or std.fs.path.isAbsolute(target))
                    return error.UnsafeWevalPackage;
                var verify_buffer: [Dir.max_path_bytes]u8 = undefined;
                const verify_len = try directory.readLink(
                    state.io,
                    name,
                    &verify_buffer,
                );
                if (!std.mem.eql(u8, target, verify_buffer[0..verify_len]))
                    return error.WevalPackageRace;
                hashWevalPackageBytes(&state.hasher, target);
                state.symlinks.append(
                    state.allocator,
                    try state.allocator.dupe(u8, relative),
                ) catch @panic("out of memory");
            },
            else => return error.UnsafeWevalPackage,
        }
        try verifyWevalNameIdentity(
            state.io,
            directory,
            name,
            identity,
        );
    }
    const final_identity = try wevalDirectoryIdentity(state.io, directory);
    if (!sameStableWevalIdentity(initial_identity, final_identity))
        return error.WevalPackageRace;
}

fn hashWevalPackageEntry(
    hasher: *Sha256,
    kind: u8,
    relative: []const u8,
    stat: File.Stat,
) void {
    hasher.update(&.{kind});
    hashWevalPackageBytes(hasher, relative);
    const executable_mode: u16 = if (File.Permissions.has_executable_bit)
        @intCast(stat.permissions.toMode() & 0o111)
    else
        0;
    var encoded_mode: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded_mode, executable_mode, .little);
    hasher.update(&encoded_mode);
}

fn hashWevalPackageBytes(hasher: *Sha256, value: []const u8) void {
    var encoded_length: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded_length, value.len, .little);
    hasher.update(&encoded_length);
    hasher.update(value);
}

fn hashWevalPackageFile(
    io: Io,
    file: File,
) ![Sha256.digest_length]u8 {
    const before = try file.stat(io);
    if (before.kind != .file) return error.UnsafeWevalPackage;
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (offset != before.size or
        !sameStableContent(before, try file.stat(io)))
        return error.WevalPackageRace;
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn wevalPathIdentity(
    io: Io,
    parent: Dir,
    name: []const u8,
) !WevalPackageIdentity {
    var file = try parent.openFile(io, name, .{
        .path_only = true,
        .allow_directory = true,
        .follow_symlinks = false,
    });
    defer file.close(io);
    return wevalFileIdentity(io, file);
}

fn wevalFileIdentity(io: Io, file: File) !WevalPackageIdentity {
    return .{
        .stat = try file.stat(io),
        .filesystem = try filesystemId(file),
    };
}

fn wevalDirectoryIdentity(io: Io, dir: Dir) !WevalPackageIdentity {
    return wevalFileIdentity(io, .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    });
}

fn verifyWevalNameIdentity(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected: WevalPackageIdentity,
) !void {
    const current = try wevalPathIdentity(io, parent, name);
    if (!sameStableWevalIdentity(expected, current))
        return error.WevalPackageRace;
}

fn sameStableWevalIdentity(
    left: WevalPackageIdentity,
    right: WevalPackageIdentity,
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

fn wevalPathContains(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root) or candidate.len <= root.len)
        return false;
    return candidate[root.len] == std.fs.path.sep;
}

fn validateWevalSelection(
    relative: []const u8,
    basename: []const u8,
) Error!void {
    validateValue(relative) catch return error.InvalidManifest;
    validateValue(basename) catch return error.InvalidManifest;
    if (std.fs.path.isAbsolute(relative) or
        std.mem.indexOfScalar(u8, relative, '\\') != null or
        std.mem.indexOf(u8, relative, "//") != null or
        std.mem.eql(u8, relative, ".") or
        std.mem.eql(u8, relative, "..") or
        !std.mem.eql(u8, std.fs.path.basename(relative), basename))
        return error.InvalidManifest;
    var components = std.mem.splitScalar(u8, relative, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return error.InvalidManifest;
    }
    validateBundleBasename(basename) catch return error.InvalidManifest;
}

fn openStableInput(
    allocator: Allocator,
    io: Io,
    role: []const u8,
    supplied: []const u8,
) !StableInput {
    const absolute = try absoluteSealPath(allocator, io, supplied);
    var file = try Dir.openFileAbsolute(io, absolute, .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    errdefer file.close(io);
    const identity = try file.stat(io);
    if (identity.kind != .file) return error.MissingCacheArtifact;
    const filesystem = try filesystemId(file);
    var resolved_buffer: [Dir.max_path_bytes]u8 = undefined;
    const resolved_len = try file.realPath(io, &resolved_buffer);
    return .{
        .role = role,
        .supplied = supplied,
        .absolute = absolute,
        .resolved = try allocator.dupe(u8, resolved_buffer[0..resolved_len]),
        .file = file,
        .identity = identity,
        .filesystem = filesystem,
    };
}

fn openSealOutput(
    allocator: Allocator,
    io: Io,
    role: []const u8,
    supplied: []const u8,
    hooks: SealHooks,
) !SealOutput {
    const absolute = try absoluteSealPath(allocator, io, supplied);
    const parent_path = std.fs.path.dirname(absolute) orelse return error.InvalidManifest;
    const basename = std.fs.path.basename(absolute);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, "..")) return error.InvalidManifest;

    var observed_parent = try Dir.openDirAbsolute(
        io,
        parent_path,
        .{ .follow_symlinks = true, .iterate = true },
    );
    errdefer observed_parent.close(io);
    const observed_identity = try observed_parent.stat(io);
    if (observed_identity.kind != .directory) return error.InvalidManifest;
    const observed_filesystem = try filesystemId(.{
        .handle = observed_parent.handle,
        .flags = .{ .nonblocking = false },
    });
    var parent_buffer: [Dir.max_path_bytes]u8 = undefined;
    const parent_len = try observed_parent.realPath(io, &parent_buffer);
    const canonical_parent_path = try allocator.dupe(u8, parent_buffer[0..parent_len]);
    try runSealHook(
        allocator,
        io,
        hooks,
        if (std.mem.eql(u8, role, "canonical cache output"))
            "after-cache-parent-anchor"
        else
            "after-manifest-parent-anchor",
    );
    const parent = observed_parent;
    const parent_identity = observed_identity;
    const resolved = try std.fs.path.join(
        allocator,
        &.{ canonical_parent_path, basename },
    );
    const initial_file = parent.openFile(io, basename, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = true,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    errdefer if (initial_file) |file| file.close(io);
    const initial: DestinationState = if (initial_file) |file| .{
        .existing = .{
            .file = file,
            .identity = try file.stat(io),
            .filesystem = try filesystemId(file),
        },
    } else .missing;
    return .{
        .role = role,
        .supplied = supplied,
        .absolute = absolute,
        .resolved = resolved,
        .parent_path = canonical_parent_path,
        .basename = basename,
        .parent = parent,
        .parent_identity = parent_identity,
        .parent_filesystem = observed_filesystem,
        .initial = initial,
    };
}

fn absoluteSealPath(allocator: Allocator, io: Io, supplied: []const u8) ![]const u8 {
    if (supplied.len == 0 or std.mem.indexOfScalar(u8, supplied, 0) != null)
        return error.InvalidManifest;
    if (std.fs.path.isAbsolute(supplied)) return allocator.dupe(u8, supplied);
    const cwd = try Dir.cwd().realPathFileAlloc(io, ".", allocator);
    return joinUnresolved(allocator, cwd, supplied);
}

fn joinUnresolved(
    allocator: Allocator,
    parent: []const u8,
    child: []const u8,
) ![]const u8 {
    if (std.mem.endsWith(u8, parent, &.{std.fs.path.sep}))
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ parent, child });
    return std.fmt.allocPrint(
        allocator,
        "{s}{c}{s}",
        .{ parent, std.fs.path.sep, child },
    );
}

const c_fstat = struct {
    extern "c" fn fstat(fd: std.c.fd_t, stat: *std.c.Stat) c_int;
}.fstat;

fn filesystemId(file: File) !u128 {
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
    while (true) switch (std.c.errno(c_fstat(file.handle, &native))) {
        .SUCCESS => return @intCast(native.dev),
        .INTR => continue,
        else => return error.Unexpected,
    };
}

fn sameIdentity(left: File.Stat, right: File.Stat) bool {
    return left.kind == right.kind and
        left.inode == right.inode and
        left.nlink == right.nlink and
        left.size == right.size and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn sameObjectFields(
    left_filesystem: u128,
    left_inode: u128,
    left_kind: File.Kind,
    right_filesystem: u128,
    right_inode: u128,
    right_kind: File.Kind,
) bool {
    return left_filesystem == right_filesystem and
        left_inode == right_inode and left_kind == right_kind;
}

fn sameObject(
    left: File.Stat,
    left_filesystem: u128,
    right: File.Stat,
    right_filesystem: u128,
) bool {
    return sameObjectFields(
        left_filesystem,
        @intCast(left.inode),
        left.kind,
        right_filesystem,
        @intCast(right.inode),
        right.kind,
    );
}

fn sameStableContent(left: File.Stat, right: File.Stat) bool {
    return sameStableObjectMetadata(left, right) and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn sameStableObjectMetadata(left: File.Stat, right: File.Stat) bool {
    return left.kind == right.kind and
        left.inode == right.inode and
        left.nlink == right.nlink and
        left.size == right.size and
        left.mtime.nanoseconds == right.mtime.nanoseconds;
}

fn sameResolvedOrIdentity(
    left_resolved: []const u8,
    left_identity: File.Stat,
    left_filesystem: u128,
    right_resolved: []const u8,
    right_identity: File.Stat,
    right_filesystem: u128,
) bool {
    if (std.mem.eql(u8, left_resolved, right_resolved)) return true;
    return sameObject(
        left_identity,
        left_filesystem,
        right_identity,
        right_filesystem,
    );
}

fn outputAliasesInput(output: *const SealOutput, input: *const StableInput) bool {
    if (std.mem.eql(u8, output.resolved, input.resolved)) return true;
    return switch (output.initial) {
        .missing => false,
        .existing => |existing| sameObject(
            existing.identity,
            existing.filesystem,
            input.identity,
            input.filesystem,
        ),
    };
}

fn outputsAlias(left: *const SealOutput, right: *const SealOutput) bool {
    if (std.mem.eql(u8, left.resolved, right.resolved)) return true;
    return switch (left.initial) {
        .missing => false,
        .existing => |left_existing| switch (right.initial) {
            .missing => false,
            .existing => |right_existing| sameObject(
                left_existing.identity,
                left_existing.filesystem,
                right_existing.identity,
                right_existing.filesystem,
            ),
        },
    };
}

fn reportAlias(
    left_role: []const u8,
    left_path: []const u8,
    right_role: []const u8,
    right_path: []const u8,
) Error {
    std.debug.print(
        "error: AOT cache seal path collision: {s} '{s}' aliases {s} '{s}'\n",
        .{ left_role, left_path, right_role, right_path },
    );
    return error.SealPathAlias;
}

fn runSealHook(
    allocator: Allocator,
    io: Io,
    hooks: SealHooks,
    phase: []const u8,
) !void {
    if (hooks.fail_at) |fail_at| {
        if (hookListsPhase(fail_at, phase)) return error.AotCacheTestFailure;
    }
    const directory = hooks.directory orelse return;
    const should_wait = if (hooks.wait_at) |wait_at|
        hookListsPhase(wait_at, phase)
    else
        false;
    const should_notify = if (hooks.notify_at) |notify_at|
        hookListsPhase(notify_at, phase)
    else
        false;
    if (!should_wait and !should_notify) return;
    const ready = try std.fs.path.join(
        allocator,
        &.{ directory, try std.fmt.allocPrint(allocator, "{s}.ready", .{phase}) },
    );
    const proceed = try std.fs.path.join(
        allocator,
        &.{ directory, try std.fmt.allocPrint(allocator, "{s}.continue", .{phase}) },
    );
    try Dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "ready\n" });
    if (!should_wait) return;
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

fn hookListsPhase(list: []const u8, phase: []const u8) bool {
    var entries = std.mem.splitScalar(u8, list, ',');
    while (entries.next()) |entry| {
        if (std.mem.eql(u8, entry, phase)) return true;
    }
    return false;
}

const PrivateFile = struct {
    parent: Dir,
    name: []const u8,
    file: File,
    identity: File.Stat,
    filesystem: u128,
    name_identity: File.Stat,
    name_filesystem: u128,
    name_exists: bool = true,
    preserve: bool = false,

    fn deinit(private: *PrivateFile, io: Io) void {
        private.file.close(io);
        if (private.name_exists and !private.preserve)
            private.parent.deleteFile(io, private.name) catch {};
        private.name_exists = false;
    }
};

fn createPrivateFile(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    prefix: []const u8,
) !PrivateFile {
    for (0..32) |_| {
        var random: [16]u8 = undefined;
        io.random(&random);
        const random_hex = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            "{s}-{s}",
            .{ prefix, &random_hex },
        );
        var file = parent.createFile(io, name, .{
            .read = true,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer file.close(io);
        const identity = try file.stat(io);
        const filesystem = try filesystemId(file);
        return .{
            .parent = parent,
            .name = name,
            .file = file,
            .identity = identity,
            .filesystem = filesystem,
            .name_identity = identity,
            .name_filesystem = filesystem,
        };
    }
    return error.PathAlreadyExists;
}

fn stageStableCopy(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    prefix: []const u8,
    source: StableInput,
) !PrivateFile {
    const before = try source.file.stat(io);
    if (!sameStableContent(before, source.identity)) return error.SealPathRace;
    var snapshot = try createPrivateFile(allocator, io, parent, prefix);
    errdefer snapshot.deinit(io);
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try source.file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        try snapshot.file.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    const after = try source.file.stat(io);
    if (!sameStableContent(before, after) or offset != before.size)
        return error.SealPathRace;
    try snapshot.file.sync(io);
    snapshot.identity = try snapshot.file.stat(io);
    snapshot.filesystem = try filesystemId(snapshot.file);
    snapshot.name_identity = snapshot.identity;
    snapshot.name_filesystem = snapshot.filesystem;
    return snapshot;
}

fn stageCanonicalCache(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    source: File,
    engine_sha: []const u8,
) !PrivateFile {
    var canonical = try createPrivateFile(
        allocator,
        io,
        parent,
        ".aot-canonical",
    );
    errdefer canonical.deinit(io);
    try writeCanonicalCacheFiles(io, source, canonical.file);
    try normalizeCanonicalHeaderFile(io, canonical.file);
    try verifyCacheDatabaseFile(io, canonical.file, engine_sha);
    try canonical.file.sync(io);
    canonical.identity = try canonical.file.stat(io);
    canonical.filesystem = try filesystemId(canonical.file);
    canonical.name_identity = canonical.identity;
    canonical.name_filesystem = canonical.filesystem;
    return canonical;
}

fn hashStableFileHex(
    allocator: Allocator,
    io: Io,
    input: StableInput,
) ![]const u8 {
    const before = try input.file.stat(io);
    if (!sameStableContent(before, input.identity)) return error.SealPathRace;
    const digest = try hashFileHandleHex(allocator, io, input.file);
    const after = try input.file.stat(io);
    if (!sameStableContent(before, after)) return error.SealPathRace;
    return digest;
}

fn rehashStableFileHex(
    allocator: Allocator,
    io: Io,
    input: StableInput,
) ![]const u8 {
    const before = try input.file.stat(io);
    if (!sameStableObjectMetadata(before, input.identity) or
        input.filesystem != try filesystemId(input.file))
        return error.SealPathRace;
    const digest = try hashFileHandleHex(allocator, io, input.file);
    const after = try input.file.stat(io);
    if (!sameIdentity(before, after) or
        input.filesystem != try filesystemId(input.file))
        return error.SealPathRace;
    return digest;
}

fn hashFileHandleHex(allocator: Allocator, io: Io, file: File) ![]const u8 {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.MissingCacheArtifact;
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (offset != stat.size) return error.SealPathRace;
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

const JournalPhase = enum {
    clean,
    workspace_before,
    workspace_ready,
    prepared,
    cache_before,
    cache_after,
    manifest_before,
    manifest_after,
    rollback_manifest_before,
    rollback_manifest_quarantine,
    rollback_manifest_after,
    rollback_cache_before,
    rollback_cache_quarantine,
    rollback_cache_after,
    committed,
    rolled_back,
};

const OwnedIdentity = struct {
    filesystem: u128,
    inode: u128,
    kind: File.Kind,
    nlink: u64,
    size: u64,
    mtime: i128,
    ctime: i128,
    digest: [Sha256.digest_length]u8,

    fn capture(io: Io, file: File) !OwnedIdentity {
        const before = try file.stat(io);
        if (before.kind != .file) return error.InvalidDestinationKind;
        const digest = try hashFileHandle(io, file);
        const after = try file.stat(io);
        const filesystem = try filesystemId(file);
        if (!sameIdentity(before, after)) return error.SealPathRace;
        return .{
            .filesystem = filesystem,
            .inode = @intCast(before.inode),
            .kind = before.kind,
            .nlink = @intCast(before.nlink),
            .size = before.size,
            .mtime = before.mtime.nanoseconds,
            .ctime = before.ctime.nanoseconds,
            .digest = digest,
        };
    }

    fn matchesObject(identity: OwnedIdentity, io: Io, file: File) !bool {
        const before = try file.stat(io);
        const filesystem = try filesystemId(file);
        if ((identity.filesystem != 0 and
            identity.filesystem != filesystem) or
            identity.inode != @as(u128, @intCast(before.inode)) or
            identity.kind != before.kind or identity.size != before.size or
            identity.mtime != before.mtime.nanoseconds)
            return false;
        const digest = try hashFileHandle(io, file);
        const after = try file.stat(io);
        if (!sameIdentity(before, after) or
            filesystem != try filesystemId(file))
            return false;
        return std.mem.eql(
            u8,
            &identity.digest,
            &digest,
        );
    }

    fn matchesStart(identity: OwnedIdentity, io: Io, file: File) !bool {
        const stat = try file.stat(io);
        return identity.nlink == @as(u64, @intCast(stat.nlink)) and
            identity.ctime == stat.ctime.nanoseconds and
            try identity.matchesObject(io, file);
    }
};

fn hashFileHandle(io: Io, file: File) ![Sha256.digest_length]u8 {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidDestinationKind;
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositional(io, &.{&buffer}, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if (offset != stat.size) return error.SealPathRace;
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const JournalRecord = struct {
    phase: JournalPhase,
    cache_parent_inode: u128,
    manifest_parent_inode: u128,
    cache_workspace_inode: u128,
    manifest_workspace_inode: u128,
    cache_name: []const u8,
    manifest_name: []const u8,
    workspace_name: []const u8,
    cache_stage: []const u8,
    manifest_stage: []const u8,
    cache_old: ?OwnedIdentity,
    manifest_old: ?OwnedIdentity,
    cache_new: ?OwnedIdentity,
    manifest_new: ?OwnedIdentity,
};

const Workspaces = struct {
    cache: Dir,
    manifest: Dir,
    shared: bool,
};

const SealControlNames = struct {
    journal: []const u8,
    workspace: []const u8,
};

const DestinationLocks = struct {
    files: [2]?File = .{ null, null },
    count: usize = 0,

    fn deinit(locks: *DestinationLocks, io: Io) void {
        var index = locks.count;
        while (index != 0) {
            index -= 1;
            const file = locks.files[index].?;
            file.unlock(io);
            file.close(io);
            locks.files[index] = null;
        }
        locks.count = 0;
    }
};

const journal_magic = "AOTJNL2\x00";
const journal_header_size = 8 + 8 + 4 + 4 + Sha256.digest_length;
const journal_slot_size: u64 = 64 * 1024;

const SealGuard = struct {
    locks: DestinationLocks,
    journal: File,
    workspace_name: []const u8,
    sequence: u64 = 0,
    record: ?JournalRecord = null,
    recovery_required: bool = false,

    fn init(
        allocator: Allocator,
        io: Io,
        cache_output: *SealOutput,
        manifest_output: *SealOutput,
    ) !SealGuard {
        const names = try sealControlNames(
            allocator,
            cache_output,
            manifest_output,
        );
        var locks = try acquireDestinationLocks(
            allocator,
            io,
            cache_output,
            manifest_output,
        );
        errdefer locks.deinit(io);
        try cache_output.refreshInitial(io);
        try manifest_output.refreshInitial(io);
        const journal = try openPrivateControlFile(
            io,
            cache_output.parent,
            names.journal,
            false,
        );
        errdefer journal.close(io);
        var guard: SealGuard = .{
            .locks = locks,
            .journal = journal,
            .workspace_name = names.workspace,
        };
        if (try readLatestJournal(allocator, io, journal)) |latest| {
            guard.sequence = latest.sequence;
            guard.record = latest.record;
        } else {
            const size = (try journal.stat(io)).size;
            if (size > journal_slot_size or
                try workspaceNameExists(
                    io,
                    cache_output.parent,
                    names.workspace,
                ))
                return error.InvalidRecoveryJournal;
            try journal.setLength(io, 0);
            guard.record = cleanJournalRecord(
                cache_output,
                manifest_output,
                names.workspace,
            );
            try writeJournal(
                allocator,
                io,
                journal,
                0,
                guard.record.?,
            );
            try syncDir(io, cache_output.parent);
        }
        return guard;
    }

    fn deinit(guard: *SealGuard, io: Io) void {
        guard.journal.close(io);
        guard.locks.deinit(io);
    }

    fn setPhase(
        guard: *SealGuard,
        allocator: Allocator,
        io: Io,
        parent: Dir,
        phase: JournalPhase,
    ) !void {
        var record = guard.record orelse return error.InvalidRecoveryJournal;
        record.phase = phase;
        guard.record = record;
        _ = parent;
        guard.sequence += 1;
        try writeJournal(
            allocator,
            io,
            guard.journal,
            guard.sequence,
            record,
        );
    }

    fn begin(
        guard: *SealGuard,
        allocator: Allocator,
        io: Io,
        cache_output: *const SealOutput,
        manifest_output: *const SealOutput,
        hooks: SealHooks,
    ) !Workspaces {
        const cache_old = try captureDestination(io, cache_output);
        const manifest_old = try captureDestination(io, manifest_output);
        const prior = guard.record orelse return error.InvalidRecoveryJournal;
        guard.record = .{
            .phase = .workspace_before,
            .cache_parent_inode = @intCast(cache_output.parent_identity.inode),
            .manifest_parent_inode = @intCast(manifest_output.parent_identity.inode),
            .cache_workspace_inode = if (prior.phase == .clean)
                prior.cache_workspace_inode
            else
                0,
            .manifest_workspace_inode = if (prior.phase == .clean)
                prior.manifest_workspace_inode
            else
                0,
            .cache_name = cache_output.basename,
            .manifest_name = manifest_output.basename,
            .workspace_name = guard.workspace_name,
            .cache_stage = "",
            .manifest_stage = "",
            .cache_old = cache_old,
            .manifest_old = manifest_old,
            .cache_new = null,
            .manifest_new = null,
        };
        try guard.setPhase(
            allocator,
            io,
            cache_output.parent,
            .workspace_before,
        );
        try runSealHook(
            allocator,
            io,
            hooks,
            "journal-first-transaction-record",
        );
        const cache_workspace = try openOwnedWorkspace(
            io,
            cache_output.parent,
            guard.workspace_name,
            guard.record.?.cache_workspace_inode,
        );
        errdefer cache_workspace.close(io);
        try clearOwnedWorkspace(io, cache_workspace);
        const shared = sameOutputParent(cache_output, manifest_output);
        const manifest_workspace = if (shared)
            cache_workspace
        else
            try openOwnedWorkspace(
                io,
                manifest_output.parent,
                guard.workspace_name,
                guard.record.?.manifest_workspace_inode,
            );
        errdefer if (!shared) manifest_workspace.close(io);
        if (!shared) try clearOwnedWorkspace(io, manifest_workspace);
        var record = guard.record.?;
        record.cache_workspace_inode =
            @intCast((try cache_workspace.stat(io)).inode);
        record.manifest_workspace_inode =
            @intCast((try manifest_workspace.stat(io)).inode);
        guard.record = record;
        try syncDir(io, cache_output.parent);
        if (!shared) try syncDir(io, manifest_output.parent);
        try guard.setPhase(
            allocator,
            io,
            cache_output.parent,
            .workspace_ready,
        );
        return .{
            .cache = cache_workspace,
            .manifest = manifest_workspace,
            .shared = shared,
        };
    }

    fn prepare(
        guard: *SealGuard,
        allocator: Allocator,
        io: Io,
        cache_output: *const SealOutput,
        cache_stage: *const PrivateFile,
        manifest_stage: *const PrivateFile,
    ) !void {
        var record = guard.record orelse return error.InvalidRecoveryJournal;
        record.cache_stage = cache_stage.name;
        record.manifest_stage = manifest_stage.name;
        record.cache_new = try OwnedIdentity.capture(io, cache_stage.file);
        record.manifest_new = try OwnedIdentity.capture(io, manifest_stage.file);
        guard.record = record;
        try syncDir(io, cache_stage.parent);
        try syncDir(io, manifest_stage.parent);
        try guard.setPhase(
            allocator,
            io,
            cache_output.parent,
            .prepared,
        );
    }

    fn recover(
        guard: *SealGuard,
        allocator: Allocator,
        io: Io,
        cache_output: *const SealOutput,
        manifest_output: *const SealOutput,
        hooks: SealHooks,
    ) !void {
        const record = guard.record orelse return;
        if (record.phase == .clean) return;
        if (record.cache_parent_inode !=
            @as(u128, @intCast(cache_output.parent_identity.inode)) or
            record.manifest_parent_inode !=
                @as(u128, @intCast(manifest_output.parent_identity.inode)) or
            !std.mem.eql(u8, record.cache_name, cache_output.basename) or
            !std.mem.eql(u8, record.manifest_name, manifest_output.basename) or
            !std.mem.eql(u8, record.workspace_name, guard.workspace_name))
        {
            return error.InvalidRecoveryJournal;
        }

        const cache_workspace = openWorkspaceForRecovery(
            io,
            cache_output.parent,
            record.workspace_name,
            record.cache_workspace_inode,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (cache_workspace) |workspace| workspace.close(io);
        const shared = sameOutputParent(cache_output, manifest_output);
        const manifest_workspace = if (shared)
            cache_workspace
        else
            openWorkspaceForRecovery(
                io,
                manifest_output.parent,
                record.workspace_name,
                record.manifest_workspace_inode,
            ) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
        defer if (!shared) {
            if (manifest_workspace) |workspace| workspace.close(io);
        };

        if (record.cache_new == null or record.manifest_new == null or
            record.cache_stage.len == 0 or record.manifest_stage.len == 0)
        {
            if (cache_workspace) |workspace| {
                try clearOwnedWorkspace(io, workspace);
                try syncDir(io, workspace);
            }
            if (!shared) {
                if (manifest_workspace) |workspace| {
                    try clearOwnedWorkspace(io, workspace);
                    try syncDir(io, workspace);
                }
            }
            try syncDir(io, cache_output.parent);
            if (!shared) try syncDir(io, manifest_output.parent);
            try guard.setPhase(
                allocator,
                io,
                cache_output.parent,
                .clean,
            );
            return;
        }
        const cache_ws = cache_workspace orelse
            return error.TransactionRecoveryRequired;
        const manifest_ws = manifest_workspace orelse
            return error.TransactionRecoveryRequired;
        const cache_state = try inspectRecordedOutput(
            io,
            cache_output.parent,
            record.cache_name,
            cache_ws,
            record.cache_stage,
            record.cache_old,
            record.cache_new.?,
        );
        const manifest_state = try inspectRecordedOutput(
            io,
            manifest_output.parent,
            record.manifest_name,
            manifest_ws,
            record.manifest_stage,
            record.manifest_old,
            record.manifest_new.?,
        );
        if (cache_state == .foreign or manifest_state == .foreign or
            cache_state == .external or manifest_state == .external)
            return error.TransactionRecoveryRequired;

        if (cache_state == .published and manifest_state == .published) {
            try syncDir(io, cache_output.parent);
            if (!shared) try syncDir(io, manifest_output.parent);
            try syncDir(io, cache_ws);
            if (!shared) try syncDir(io, manifest_ws);
            try guard.setPhase(
                allocator,
                io,
                cache_output.parent,
                .committed,
            );
        } else {
            if (manifest_state == .published) {
                try guard.setPhase(
                    allocator,
                    io,
                    cache_output.parent,
                    .rollback_manifest_before,
                );
                try runSealHook(
                    allocator,
                    io,
                    hooks,
                    "before-manifest-rollback",
                );
                try restoreRecordedOutput(
                    allocator,
                    io,
                    guard,
                    cache_output.parent,
                    manifest_output.parent,
                    record.manifest_name,
                    manifest_ws,
                    record.manifest_stage,
                    record.manifest_old,
                    record.manifest_new.?,
                    .rollback_manifest_quarantine,
                    hooks,
                    "before-manifest-rollback-namespace",
                    "manifest-rollback-quarantined",
                );
                try syncDir(io, manifest_output.parent);
                try syncDir(io, manifest_ws);
                try runSealHook(
                    allocator,
                    io,
                    hooks,
                    "manifest-rollback-durable",
                );
                try guard.setPhase(
                    allocator,
                    io,
                    cache_output.parent,
                    .rollback_manifest_after,
                );
                try runSealHook(
                    allocator,
                    io,
                    hooks,
                    "after-manifest-rollback",
                );
            }
            if (cache_state == .published) {
                try guard.setPhase(
                    allocator,
                    io,
                    cache_output.parent,
                    .rollback_cache_before,
                );
                try runSealHook(
                    allocator,
                    io,
                    hooks,
                    "before-cache-rollback",
                );
                try restoreRecordedOutput(
                    allocator,
                    io,
                    guard,
                    cache_output.parent,
                    cache_output.parent,
                    record.cache_name,
                    cache_ws,
                    record.cache_stage,
                    record.cache_old,
                    record.cache_new.?,
                    .rollback_cache_quarantine,
                    hooks,
                    "before-cache-rollback-namespace",
                    "cache-rollback-quarantined",
                );
                try syncDir(io, cache_output.parent);
                try syncDir(io, cache_ws);
                try runSealHook(
                    allocator,
                    io,
                    hooks,
                    "cache-rollback-durable",
                );
                try guard.setPhase(
                    allocator,
                    io,
                    cache_output.parent,
                    .rollback_cache_after,
                );
                try runSealHook(
                    allocator,
                    io,
                    hooks,
                    "after-cache-rollback",
                );
            }
            if (!try destinationMatchesRecorded(
                io,
                cache_output.parent,
                record.cache_name,
                record.cache_old,
            ))
                return error.TransactionRecoveryRequired;
            if (!try destinationMatchesRecorded(
                io,
                manifest_output.parent,
                record.manifest_name,
                record.manifest_old,
            ))
                return error.TransactionRecoveryRequired;
            try syncDir(io, cache_output.parent);
            if (!shared) try syncDir(io, manifest_output.parent);
            try syncDir(io, cache_ws);
            if (!shared) try syncDir(io, manifest_ws);
            try guard.setPhase(
                allocator,
                io,
                cache_output.parent,
                .rolled_back,
            );
        }
        try clearOwnedWorkspace(io, cache_ws);
        if (!shared) try clearOwnedWorkspace(io, manifest_ws);
        try syncDir(io, cache_ws);
        if (!shared) try syncDir(io, manifest_ws);
        try syncDir(io, cache_output.parent);
        if (!shared) try syncDir(io, manifest_output.parent);
        try runSealHook(
            allocator,
            io,
            hooks,
            "workspace-cleanup-durable",
        );
        try guard.setPhase(
            allocator,
            io,
            cache_output.parent,
            .clean,
        );
    }

    fn finish(
        guard: *SealGuard,
        allocator: Allocator,
        io: Io,
        cache_output: *const SealOutput,
        manifest_output: *const SealOutput,
        cache_workspace: ?Dir,
        manifest_workspace: ?Dir,
        shared: bool,
    ) !void {
        if (guard.recovery_required) return;
        const record = guard.record orelse return;
        switch (record.phase) {
            .clean => return,
            .workspace_before,
            .workspace_ready,
            .prepared,
            .committed,
            .rolled_back,
            => {},
            else => {
                guard.recovery_required = true;
                return error.TransactionRecoveryRequired;
            },
        }
        if (cache_workspace) |workspace| {
            try clearOwnedWorkspace(io, workspace);
            try syncDir(io, workspace);
        }
        if (!shared) {
            if (manifest_workspace) |workspace| {
                try clearOwnedWorkspace(io, workspace);
                try syncDir(io, workspace);
            }
        }
        try syncDir(io, cache_output.parent);
        if (!shared) try syncDir(io, manifest_output.parent);
        try guard.setPhase(
            allocator,
            io,
            cache_output.parent,
            .clean,
        );
    }

    fn verifyCommitted(
        guard: *SealGuard,
        io: Io,
        cache_output: *const SealOutput,
        cache_workspace: Dir,
        manifest_output: *const SealOutput,
        manifest_workspace: Dir,
    ) !void {
        const record = guard.record orelse
            return error.InvalidRecoveryJournal;
        if (record.phase != .committed or
            record.cache_new == null or record.manifest_new == null)
            return error.InvalidRecoveryJournal;
        if (try inspectRecordedOutput(
            io,
            cache_output.parent,
            record.cache_name,
            cache_workspace,
            record.cache_stage,
            record.cache_old,
            record.cache_new.?,
        ) != .published or try inspectRecordedOutput(
            io,
            manifest_output.parent,
            record.manifest_name,
            manifest_workspace,
            record.manifest_stage,
            record.manifest_old,
            record.manifest_new.?,
        ) != .published) return error.TransactionRecoveryRequired;
    }
};

fn sealControlNames(
    allocator: Allocator,
    cache_output: *const SealOutput,
    manifest_output: *const SealOutput,
) !SealControlNames {
    const relative_parent = try std.fs.path.relative(
        allocator,
        "/",
        null,
        cache_output.parent_path,
        manifest_output.parent_path,
    );
    var hasher = Sha256.init(.{});
    hashField(&hasher, "cache", cache_output.basename);
    hashField(&hasher, "manifest-parent", relative_parent);
    hashField(&hasher, "manifest", manifest_output.basename);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    const key = try allocator.dupe(u8, encoded[0..24]);
    return .{
        .journal = try std.fmt.allocPrint(
            allocator,
            ".starling-aot-seal-{s}.journal",
            .{key},
        ),
        .workspace = try std.fmt.allocPrint(
            allocator,
            ".starling-aot-seal-{s}.txn",
            .{key},
        ),
    };
}

const DestinationLockRequest = struct {
    output: *SealOutput,
    digest: [Sha256.digest_length]u8,
    name: []const u8,
};

fn destinationLockRequest(
    allocator: Allocator,
    output: *SealOutput,
) !DestinationLockRequest {
    var hasher = Sha256.init(.{});
    hashField(
        &hasher,
        "parent-filesystem",
        try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{output.parent_filesystem},
        ),
    );
    hashField(
        &hasher,
        "parent-inode",
        try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{output.parent_identity.inode},
        ),
    );
    hashField(&hasher, "name", output.basename);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return .{
        .output = output,
        .digest = digest,
        .name = try std.fmt.allocPrint(
            allocator,
            ".starling-aot-destination-{s}.lock",
            .{encoded[0..24]},
        ),
    };
}

fn destinationLockLessThan(
    _: void,
    left: DestinationLockRequest,
    right: DestinationLockRequest,
) bool {
    return std.mem.lessThan(u8, &left.digest, &right.digest);
}

fn acquireDestinationLocks(
    allocator: Allocator,
    io: Io,
    cache_output: *SealOutput,
    manifest_output: *SealOutput,
) !DestinationLocks {
    var requests = [_]DestinationLockRequest{
        try destinationLockRequest(allocator, cache_output),
        try destinationLockRequest(allocator, manifest_output),
    };
    std.mem.sortUnstable(
        DestinationLockRequest,
        &requests,
        {},
        destinationLockLessThan,
    );
    var locks: DestinationLocks = .{};
    errdefer locks.deinit(io);
    for (requests, 0..) |request, index| {
        if (index != 0 and
            std.mem.eql(u8, &request.digest, &requests[index - 1].digest))
            continue;
        locks.files[locks.count] = try openPrivateControlFile(
            io,
            request.output.parent,
            request.name,
            true,
        );
        locks.count += 1;
    }
    return locks;
}

fn cleanJournalRecord(
    cache_output: *const SealOutput,
    manifest_output: *const SealOutput,
    workspace_name: []const u8,
) JournalRecord {
    return .{
        .phase = .clean,
        .cache_parent_inode = @intCast(cache_output.parent_identity.inode),
        .manifest_parent_inode = @intCast(manifest_output.parent_identity.inode),
        .cache_workspace_inode = 0,
        .manifest_workspace_inode = 0,
        .cache_name = cache_output.basename,
        .manifest_name = manifest_output.basename,
        .workspace_name = workspace_name,
        .cache_stage = "",
        .manifest_stage = "",
        .cache_old = null,
        .manifest_old = null,
        .cache_new = null,
        .manifest_new = null,
    };
}

fn workspaceNameExists(io: Io, parent: Dir, name: []const u8) !bool {
    const file = parent.openFile(io, name, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn controlFileExists(io: Io, parent: Dir, name: []const u8) !bool {
    const file = parent.openFile(io, name, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    return (try file.stat(io)).kind == .file;
}

fn openPrivateControlFile(
    io: Io,
    parent: Dir,
    name: []const u8,
    locked: bool,
) !File {
    while (true) {
        return parent.openFile(io, name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = if (locked) .exclusive else .none,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const created = createPrivateControlFile(
                    io,
                    parent,
                    name,
                ) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
                errdefer created.close(io);
                if (locked) try created.lock(io, .exclusive);
                break :blk created;
            },
            else => return err,
        };
    }
}

fn createPrivateControlFile(io: Io, parent: Dir, name: []const u8) !File {
    return parent.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = if (File.Permissions.has_executable_bit)
            File.Permissions.fromMode(0o600)
        else
            .default_file,
    });
}

fn captureDestination(io: Io, output: *const SealOutput) !?OwnedIdentity {
    return switch (output.initial) {
        .missing => null,
        .existing => |existing| blk: {
            if (existing.identity.kind != .file)
                return error.InvalidDestinationKind;
            var file = try output.parent.openFile(io, output.basename, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
            defer file.close(io);
            if (!sameIdentity(existing.identity, try file.stat(io)))
                return error.SealPathRace;
            break :blk try OwnedIdentity.capture(io, file);
        },
    };
}

fn openOwnedWorkspace(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected_inode: u128,
) !Dir {
    const permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    var created = true;
    parent.createDir(io, name, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => created = false,
        else => return err,
    };
    var workspace = try parent.openDir(io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer workspace.close(io);
    const stat = try workspace.stat(io);
    if (stat.kind != .directory) return error.InvalidRecoveryJournal;
    if ((!created and expected_inode == 0) or
        (expected_inode != 0 and
            expected_inode != @as(u128, @intCast(stat.inode))))
        return error.InvalidRecoveryJournal;
    if (File.Permissions.has_executable_bit)
        try workspace.setPermissions(io, File.Permissions.fromMode(0o700));
    return workspace;
}

fn openWorkspaceForRecovery(
    io: Io,
    parent: Dir,
    name: []const u8,
    inode: u128,
) !Dir {
    var workspace = try parent.openDir(io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer workspace.close(io);
    const stat = try workspace.stat(io);
    if (stat.kind != .directory or
        (inode != 0 and inode != @as(u128, @intCast(stat.inode))))
        return error.InvalidRecoveryJournal;
    return workspace;
}

fn clearOwnedWorkspace(io: Io, workspace: Dir) !void {
    while (true) {
        var iterator = workspace.iterate();
        const entry = try iterator.next(io) orelse break;
        switch (entry.kind) {
            .directory => try workspace.deleteTree(io, entry.name),
            else => try workspace.deleteFile(io, entry.name),
        }
    }
}

const RecordedState = enum { original, published, external, foreign };

fn inspectRecordedOutput(
    io: Io,
    output_parent: Dir,
    output_name: []const u8,
    workspace: Dir,
    stage_name: []const u8,
    old: ?OwnedIdentity,
    new: OwnedIdentity,
) !RecordedState {
    var destination_is_foreign = false;
    const destination = output_parent.openFile(io, output_name, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => blk: {
            destination_is_foreign = true;
            break :blk null;
        },
    };
    defer if (destination) |file| file.close(io);
    const staged = workspace.openFile(io, stage_name, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return .foreign,
    };
    defer if (staged) |file| file.close(io);

    if (old) |old_identity| {
        if (destination != null and staged != null and
            try old_identity.matchesObject(io, destination.?) and
            try new.matchesObject(io, staged.?))
            return .original;
        if (destination != null and staged == null and
            try old_identity.matchesObject(io, destination.?))
            return .original;
        if (destination != null and staged != null and
            try new.matchesObject(io, destination.?) and
            try old_identity.matchesObject(io, staged.?))
            return .published;
        if (destination != null and staged == null and
            try new.matchesObject(io, destination.?))
            return .published;
        if (staged != null and try new.matchesObject(io, staged.?))
            return .external;
    } else {
        if (destination == null and staged != null and
            try new.matchesObject(io, staged.?))
            return .original;
        if (destination == null and staged == null)
            return .original;
        if (destination != null and staged == null and
            try new.matchesObject(io, destination.?))
            return .published;
        if (staged != null and try new.matchesObject(io, staged.?))
            return .external;
    }
    if (destination_is_foreign) return .foreign;
    return .foreign;
}

fn restoreRecordedOutput(
    allocator: Allocator,
    io: Io,
    guard: *SealGuard,
    journal_parent: Dir,
    output_parent: Dir,
    output_name: []const u8,
    workspace: Dir,
    stage_name: []const u8,
    old: ?OwnedIdentity,
    new: OwnedIdentity,
    quarantine_phase: JournalPhase,
    hooks: SealHooks,
    before_namespace_hook: []const u8,
    quarantined_hook: []const u8,
) !void {
    if (try inspectRecordedOutput(
        io,
        output_parent,
        output_name,
        workspace,
        stage_name,
        old,
        new,
    ) != .published) return error.TransactionRecoveryRequired;
    try runSealHook(allocator, io, hooks, before_namespace_hook);
    if (old != null) {
        try exchangeNames(
            allocator,
            workspace,
            stage_name,
            output_parent,
            output_name,
        );
    } else {
        try output_parent.renamePreserve(
            output_name,
            workspace,
            stage_name,
            io,
        );
    }
    try syncDir(io, output_parent);
    try syncDir(io, workspace);
    if (try destinationMatchesRecorded(io, output_parent, output_name, old) and
        try destinationMatchesRecorded(
            io,
            workspace,
            stage_name,
            new,
        ))
        return;

    const displaced = qualifiedStatNoFollow(
        io,
        workspace,
        stage_name,
    ) catch return error.TransactionRecoveryRequired;
    try guard.setPhase(
        allocator,
        io,
        journal_parent,
        quarantine_phase,
    );
    try runSealHook(allocator, io, hooks, quarantined_hook);

    if (old != null) {
        try exchangeNames(
            allocator,
            workspace,
            stage_name,
            output_parent,
            output_name,
        );
    } else {
        workspace.renamePreserve(
            stage_name,
            output_parent,
            output_name,
            io,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => return error.TransactionRecoveryRequired,
            else => return err,
        };
    }
    try syncDir(io, output_parent);
    try syncDir(io, workspace);
    const restored = qualifiedStatNoFollow(
        io,
        output_parent,
        output_name,
    ) catch return error.TransactionRecoveryRequired;
    if (!sameObject(
        displaced.stat,
        displaced.filesystem,
        restored.stat,
        restored.filesystem,
    )) return error.TransactionRecoveryRequired;
    return error.TransactionRecoveryRequired;
}

fn destinationMatchesRecorded(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected: ?OwnedIdentity,
) !bool {
    const file = parent.openFile(io, name, .{
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return expected == null,
        else => return false,
    };
    defer file.close(io);
    return if (expected) |identity|
        try identity.matchesObject(io, file)
    else
        false;
}

const LatestJournal = struct {
    sequence: u64,
    record: JournalRecord,
};

fn writeJournal(
    allocator: Allocator,
    io: Io,
    file: File,
    sequence: u64,
    record: JournalRecord,
) !void {
    const payload = try encodeJournal(allocator, record);
    if (payload.len > journal_slot_size - journal_header_size)
        return error.InvalidRecoveryJournal;
    const slot_offset = (sequence % 2) * journal_slot_size;
    try file.writePositionalAll(io, payload, slot_offset + journal_header_size);
    try file.sync(io);
    var header: [journal_header_size]u8 = @splat(0);
    @memcpy(header[0..journal_magic.len], journal_magic);
    std.mem.writeInt(u64, header[8..16], sequence, .little);
    std.mem.writeInt(u32, header[16..20], @intCast(payload.len), .little);
    var hasher = Sha256.init(.{});
    hasher.update(payload);
    hasher.final(header[24 .. 24 + Sha256.digest_length]);
    try file.writePositionalAll(io, &header, slot_offset);
    try file.sync(io);
}

fn readLatestJournal(
    allocator: Allocator,
    io: Io,
    file: File,
) !?LatestJournal {
    var latest: ?LatestJournal = null;
    for (0..2) |slot| {
        var header: [journal_header_size]u8 = undefined;
        const offset = @as(u64, @intCast(slot)) * journal_slot_size;
        if (try file.readPositionalAll(io, &header, offset) != header.len)
            continue;
        if (!std.mem.eql(u8, header[0..journal_magic.len], journal_magic))
            continue;
        const sequence = std.mem.readInt(u64, header[8..16], .little);
        const length = std.mem.readInt(u32, header[16..20], .little);
        if (length == 0 or
            length > journal_slot_size - journal_header_size)
            continue;
        const payload = try allocator.alloc(u8, length);
        if (try file.readPositionalAll(
            io,
            payload,
            offset + journal_header_size,
        ) != payload.len) continue;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(
            u8,
            &digest,
            header[24 .. 24 + Sha256.digest_length],
        )) continue;
        const record = parseJournal(allocator, payload) catch continue;
        if (latest == null or sequence > latest.?.sequence)
            latest = .{ .sequence = sequence, .record = record };
    }
    return latest;
}

fn encodeJournal(
    allocator: Allocator,
    record: JournalRecord,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "version=2\nphase={s}\ncache-parent={d}\nmanifest-parent={d}\n" ++
            "cache-workspace={d}\nmanifest-workspace={d}\ncache-name={s}\n" ++
            "manifest-name={s}\nworkspace-name={s}\ncache-stage={s}\n" ++
            "manifest-stage={s}\ncache-old={s}\nmanifest-old={s}\n" ++
            "cache-new={s}\nmanifest-new={s}\n",
        .{
            @tagName(record.phase),
            record.cache_parent_inode,
            record.manifest_parent_inode,
            record.cache_workspace_inode,
            record.manifest_workspace_inode,
            try hexEncode(allocator, record.cache_name),
            try hexEncode(allocator, record.manifest_name),
            try hexEncode(allocator, record.workspace_name),
            try hexEncode(allocator, record.cache_stage),
            try hexEncode(allocator, record.manifest_stage),
            try formatIdentity(allocator, record.cache_old),
            try formatIdentity(allocator, record.manifest_old),
            try formatIdentity(allocator, record.cache_new),
            try formatIdentity(allocator, record.manifest_new),
        },
    );
}

fn parseJournal(allocator: Allocator, payload: []const u8) !JournalRecord {
    var phase: ?JournalPhase = null;
    var cache_parent: ?u128 = null;
    var manifest_parent: ?u128 = null;
    var cache_workspace: ?u128 = null;
    var manifest_workspace: ?u128 = null;
    var cache_name: ?[]const u8 = null;
    var manifest_name: ?[]const u8 = null;
    var workspace_name: ?[]const u8 = null;
    var cache_stage: ?[]const u8 = null;
    var manifest_stage: ?[]const u8 = null;
    var cache_old: ?OwnedIdentity = null;
    var manifest_old: ?OwnedIdentity = null;
    var cache_new: ?OwnedIdentity = null;
    var manifest_new: ?OwnedIdentity = null;
    var seen: u16 = 0;
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidRecoveryJournal;
        const name = line[0..split];
        const value = line[split + 1 ..];
        if (std.mem.eql(u8, name, "version")) {
            if (seen & 1 != 0 or !std.mem.eql(u8, value, "2"))
                return error.InvalidRecoveryJournal;
            seen |= 1;
        } else if (std.mem.eql(u8, name, "phase")) {
            if (seen & 2 != 0) return error.InvalidRecoveryJournal;
            phase = std.meta.stringToEnum(JournalPhase, value) orelse
                return error.InvalidRecoveryJournal;
            seen |= 2;
        } else if (std.mem.eql(u8, name, "cache-parent")) {
            cache_parent = try parseInteger(u128, value, seen, 4);
            seen |= 4;
        } else if (std.mem.eql(u8, name, "manifest-parent")) {
            manifest_parent = try parseInteger(u128, value, seen, 8);
            seen |= 8;
        } else if (std.mem.eql(u8, name, "cache-workspace")) {
            cache_workspace = try parseInteger(u128, value, seen, 16);
            seen |= 16;
        } else if (std.mem.eql(u8, name, "manifest-workspace")) {
            manifest_workspace = try parseInteger(u128, value, seen, 32);
            seen |= 32;
        } else if (std.mem.eql(u8, name, "cache-name")) {
            if (seen & 64 != 0) return error.InvalidRecoveryJournal;
            cache_name = try hexDecode(allocator, value);
            seen |= 64;
        } else if (std.mem.eql(u8, name, "manifest-name")) {
            if (seen & 128 != 0) return error.InvalidRecoveryJournal;
            manifest_name = try hexDecode(allocator, value);
            seen |= 128;
        } else if (std.mem.eql(u8, name, "workspace-name")) {
            if (seen & 256 != 0) return error.InvalidRecoveryJournal;
            workspace_name = try hexDecode(allocator, value);
            seen |= 256;
        } else if (std.mem.eql(u8, name, "cache-stage")) {
            if (seen & 512 != 0) return error.InvalidRecoveryJournal;
            cache_stage = try hexDecode(allocator, value);
            seen |= 512;
        } else if (std.mem.eql(u8, name, "manifest-stage")) {
            if (seen & 1024 != 0) return error.InvalidRecoveryJournal;
            manifest_stage = try hexDecode(allocator, value);
            seen |= 1024;
        } else if (std.mem.eql(u8, name, "cache-old")) {
            if (seen & 2048 != 0) return error.InvalidRecoveryJournal;
            cache_old = try parseIdentity(value);
            seen |= 2048;
        } else if (std.mem.eql(u8, name, "manifest-old")) {
            if (seen & 4096 != 0) return error.InvalidRecoveryJournal;
            manifest_old = try parseIdentity(value);
            seen |= 4096;
        } else if (std.mem.eql(u8, name, "cache-new")) {
            if (seen & 8192 != 0) return error.InvalidRecoveryJournal;
            cache_new = try parseIdentity(value);
            seen |= 8192;
        } else if (std.mem.eql(u8, name, "manifest-new")) {
            if (seen & 16384 != 0) return error.InvalidRecoveryJournal;
            manifest_new = try parseIdentity(value);
            seen |= 16384;
        } else {
            return error.InvalidRecoveryJournal;
        }
    }
    if (seen != 0x7fff) return error.InvalidRecoveryJournal;
    return .{
        .phase = phase.?,
        .cache_parent_inode = cache_parent.?,
        .manifest_parent_inode = manifest_parent.?,
        .cache_workspace_inode = cache_workspace.?,
        .manifest_workspace_inode = manifest_workspace.?,
        .cache_name = cache_name.?,
        .manifest_name = manifest_name.?,
        .workspace_name = workspace_name.?,
        .cache_stage = cache_stage.?,
        .manifest_stage = manifest_stage.?,
        .cache_old = cache_old,
        .manifest_old = manifest_old,
        .cache_new = cache_new,
        .manifest_new = manifest_new,
    };
}

fn parseInteger(
    comptime T: type,
    value: []const u8,
    seen: u16,
    bit: u16,
) !T {
    if (seen & bit != 0) return error.InvalidRecoveryJournal;
    return std.fmt.parseInt(T, value, 10) catch
        return error.InvalidRecoveryJournal;
}

fn hexEncode(allocator: Allocator, value: []const u8) ![]const u8 {
    const encoded = try allocator.alloc(u8, value.len * 2);
    const alphabet = "0123456789abcdef";
    for (value, 0..) |byte, index| {
        encoded[index * 2] = alphabet[byte >> 4];
        encoded[index * 2 + 1] = alphabet[byte & 0xf];
    }
    return encoded;
}

fn hexDecode(allocator: Allocator, value: []const u8) ![]const u8 {
    if (value.len % 2 != 0) return error.InvalidRecoveryJournal;
    const decoded = try allocator.alloc(u8, value.len / 2);
    _ = std.fmt.hexToBytes(decoded, value) catch
        return error.InvalidRecoveryJournal;
    if (std.mem.indexOfScalar(u8, decoded, 0) != null or
        std.mem.indexOfScalar(u8, decoded, std.fs.path.sep) != null)
        return error.InvalidRecoveryJournal;
    return decoded;
}

fn formatIdentity(
    allocator: Allocator,
    identity: ?OwnedIdentity,
) ![]const u8 {
    const value = identity orelse return allocator.dupe(u8, "-");
    const digest = std.fmt.bytesToHex(value.digest, .lower);
    return std.fmt.allocPrint(
        allocator,
        "{d},{d},{s},{d},{d},{d},{d},{s}",
        .{
            value.filesystem,
            value.inode,
            @tagName(value.kind),
            value.nlink,
            value.size,
            value.mtime,
            value.ctime,
            &digest,
        },
    );
}

fn parseIdentity(value: []const u8) !?OwnedIdentity {
    if (std.mem.eql(u8, value, "-")) return null;
    var fields = std.mem.splitScalar(u8, value, ',');
    const legacy = std.mem.count(u8, value, ",") == 5;
    const filesystem = if (legacy)
        0
    else
        std.fmt.parseInt(u128, fields.next() orelse
            return error.InvalidRecoveryJournal, 10) catch
            return error.InvalidRecoveryJournal;
    const inode = std.fmt.parseInt(u128, fields.next() orelse
        return error.InvalidRecoveryJournal, 10) catch
        return error.InvalidRecoveryJournal;
    const kind = if (legacy)
        File.Kind.file
    else
        std.meta.stringToEnum(
            File.Kind,
            fields.next() orelse return error.InvalidRecoveryJournal,
        ) orelse return error.InvalidRecoveryJournal;
    const nlink = std.fmt.parseInt(u64, fields.next() orelse
        return error.InvalidRecoveryJournal, 10) catch
        return error.InvalidRecoveryJournal;
    const size = std.fmt.parseInt(u64, fields.next() orelse
        return error.InvalidRecoveryJournal, 10) catch
        return error.InvalidRecoveryJournal;
    const mtime = std.fmt.parseInt(i128, fields.next() orelse
        return error.InvalidRecoveryJournal, 10) catch
        return error.InvalidRecoveryJournal;
    const ctime = std.fmt.parseInt(i128, fields.next() orelse
        return error.InvalidRecoveryJournal, 10) catch
        return error.InvalidRecoveryJournal;
    const digest_text = fields.next() orelse
        return error.InvalidRecoveryJournal;
    if (fields.next() != null or digest_text.len != Sha256.digest_length * 2)
        return error.InvalidRecoveryJournal;
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, digest_text) catch
        return error.InvalidRecoveryJournal;
    return .{
        .filesystem = filesystem,
        .inode = inode,
        .kind = kind,
        .nlink = nlink,
        .size = size,
        .mtime = mtime,
        .ctime = ctime,
        .digest = digest,
    };
}

fn publishBundle(
    allocator: Allocator,
    io: Io,
    cache_output: *const SealOutput,
    cache_stage: *PrivateFile,
    manifest_output: *const SealOutput,
    manifest_stage: *PrivateFile,
    guard: *SealGuard,
    hooks: SealHooks,
) !void {
    if (!try destinationMatchesStart(io, cache_output) or
        !try destinationMatchesStart(io, manifest_output))
        return error.SealPathRace;

    try guard.prepare(
        allocator,
        io,
        cache_output,
        cache_stage,
        manifest_stage,
    );
    runSealHook(allocator, io, hooks, "journal-prepared") catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };

    guard.setPhase(
        allocator,
        io,
        cache_output.parent,
        .cache_before,
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(allocator, io, hooks, "before-cache-publish") catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };
    publishOne(allocator, io, cache_output, cache_stage) catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };
    syncDir(io, cache_output.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    syncDir(io, cache_stage.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(
        allocator,
        io,
        hooks,
        "cache-publication-durable",
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    guard.setPhase(
        allocator,
        io,
        cache_output.parent,
        .cache_after,
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(allocator, io, hooks, "after-cache-publish") catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };
    runSealHook(allocator, io, hooks, "after-first-publish") catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };

    if (!try destinationHasIdentity(
        io,
        cache_output,
        cache_stage.identity,
        cache_stage.filesystem,
    ) or
        !try destinationMatchesStart(io, manifest_output))
    {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return error.SealPathRace;
    }

    guard.setPhase(
        allocator,
        io,
        cache_output.parent,
        .manifest_before,
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(allocator, io, hooks, "before-manifest-publish") catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };
    publishOne(allocator, io, manifest_output, manifest_stage) catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };

    syncDir(io, manifest_output.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    syncDir(io, manifest_stage.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(
        allocator,
        io,
        hooks,
        "manifest-publication-durable",
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    guard.setPhase(
        allocator,
        io,
        cache_output.parent,
        .manifest_after,
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(allocator, io, hooks, "after-manifest-publish") catch |err| {
        if (!recoverPublication(
            allocator,
            io,
            guard,
            cache_output,
            cache_stage,
            manifest_output,
            manifest_stage,
            hooks,
        )) return error.TransactionRecoveryRequired;
        return err;
    };
    if (!try destinationHasIdentity(
        io,
        cache_output,
        cache_stage.identity,
        cache_stage.filesystem,
    ) or !try destinationHasIdentity(
        io,
        manifest_output,
        manifest_stage.identity,
        manifest_stage.filesystem,
    ))
        return preserveRecovery(guard, cache_stage, manifest_stage);
    syncDir(io, cache_output.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    syncDir(io, manifest_output.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    syncDir(io, cache_stage.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    syncDir(io, manifest_stage.parent) catch
        return preserveRecovery(guard, cache_stage, manifest_stage);
    runSealHook(
        allocator,
        io,
        hooks,
        "publication-pair-durable",
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    guard.setPhase(
        allocator,
        io,
        cache_output.parent,
        .committed,
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
    cache_stage.preserve = true;
    manifest_stage.preserve = true;
    try runSealHook(allocator, io, hooks, "committed");
    guard.verifyCommitted(
        io,
        cache_output,
        cache_stage.parent,
        manifest_output,
        manifest_stage.parent,
    ) catch return preserveRecovery(guard, cache_stage, manifest_stage);
}

fn preserveRecovery(
    guard: *SealGuard,
    cache_stage: *PrivateFile,
    manifest_stage: *PrivateFile,
) Error {
    guard.recovery_required = true;
    cache_stage.preserve = true;
    manifest_stage.preserve = true;
    return error.TransactionRecoveryRequired;
}

fn recoverPublication(
    allocator: Allocator,
    io: Io,
    guard: *SealGuard,
    cache_output: *const SealOutput,
    cache_stage: *PrivateFile,
    manifest_output: *const SealOutput,
    manifest_stage: *PrivateFile,
    hooks: SealHooks,
) bool {
    guard.recover(
        allocator,
        io,
        cache_output,
        manifest_output,
        hooks,
    ) catch {
        guard.recovery_required = true;
        cache_stage.preserve = true;
        manifest_stage.preserve = true;
        return false;
    };
    cache_stage.name_exists = false;
    manifest_stage.name_exists = false;
    return true;
}

fn destinationMatchesStart(io: Io, output: *const SealOutput) !bool {
    const current = output.parent.openFile(io, output.basename, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return output.initial == .missing,
        else => return err,
    };
    defer current.close(io);
    return switch (output.initial) {
        .missing => false,
        .existing => |existing| sameIdentity(
            existing.identity,
            try current.stat(io),
        ),
    };
}

fn destinationHasIdentity(
    io: Io,
    output: *const SealOutput,
    identity: File.Stat,
    filesystem: u128,
) !bool {
    var current = output.parent.openFile(io, output.basename, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer current.close(io);
    return sameObject(
        identity,
        filesystem,
        try current.stat(io),
        try filesystemId(current),
    );
}

fn publishOne(
    allocator: Allocator,
    io: Io,
    output: *const SealOutput,
    staged: *PrivateFile,
) !void {
    if (!try destinationMatchesStart(io, output)) return error.SealPathRace;
    switch (output.initial) {
        .missing => {
            try staged.parent.renamePreserve(
                staged.name,
                output.parent,
                output.basename,
                io,
            );
            staged.name_exists = false;
        },
        .existing => |existing| {
            var proven_destination = try output.parent.openFile(
                io,
                output.basename,
                .{
                    .follow_symlinks = false,
                    .allow_directory = false,
                },
            );
            defer proven_destination.close(io);
            if (!sameIdentity(
                existing.identity,
                try proven_destination.stat(io),
            )) return error.SealPathRace;
            try exchangeNames(
                allocator,
                staged.parent,
                staged.name,
                output.parent,
                output.basename,
            );
            const displaced = qualifiedStatNoFollow(
                io,
                staged.parent,
                staged.name,
            ) catch {
                return error.TransactionRecoveryRequired;
            };
            if (!sameObject(
                try proven_destination.stat(io),
                try filesystemId(proven_destination),
                displaced.stat,
                displaced.filesystem,
            )) {
                exchangeNames(
                    allocator,
                    staged.parent,
                    staged.name,
                    output.parent,
                    output.basename,
                ) catch return error.TransactionRecoveryRequired;
                const restored_stage = qualifiedStatNoFollow(
                    io,
                    staged.parent,
                    staged.name,
                ) catch return error.TransactionRecoveryRequired;
                const restored_destination = qualifiedStatNoFollow(
                    io,
                    output.parent,
                    output.basename,
                ) catch return error.TransactionRecoveryRequired;
                if (!sameObject(
                    restored_stage.stat,
                    restored_stage.filesystem,
                    staged.identity,
                    staged.filesystem,
                ) or !sameObject(
                    restored_destination.stat,
                    restored_destination.filesystem,
                    displaced.stat,
                    displaced.filesystem,
                ))
                    return error.TransactionRecoveryRequired;
                staged.name_identity = restored_stage.stat;
                staged.name_filesystem = restored_stage.filesystem;
                return error.SealPathRace;
            }
            staged.name_identity = displaced.stat;
            staged.name_filesystem = displaced.filesystem;
        },
    }
}

const QualifiedStat = struct {
    stat: File.Stat,
    filesystem: u128,
};

fn qualifiedStatNoFollow(io: Io, parent: Dir, name: []const u8) !QualifiedStat {
    var file = try parent.openFile(io, name, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = true,
    });
    defer file.close(io);
    return .{
        .stat = try file.stat(io),
        .filesystem = try filesystemId(file),
    };
}

fn syncDir(io: Io, dir: Dir) !void {
    const file: File = .{
        .handle = dir.handle,
        .flags = .{ .nonblocking = false },
    };
    try file.sync(io);
}

fn exchangeNames(
    allocator: Allocator,
    left_dir: Dir,
    left_name: []const u8,
    right_dir: Dir,
    right_name: []const u8,
) !void {
    const left_z = try allocator.dupeSentinel(u8, left_name, 0);
    const right_z = try allocator.dupeSentinel(u8, right_name, 0);
    if (builtin.os.tag == .driverkit or builtin.os.tag == .ios or
        builtin.os.tag == .maccatalyst or builtin.os.tag == .macos or
        builtin.os.tag == .tvos or builtin.os.tag == .visionos or
        builtin.os.tag == .watchos)
    {
        while (true) switch (std.c.errno(std.c.renameatx_np(
            left_dir.handle,
            left_z,
            right_dir.handle,
            right_z,
            .{ .SWAP = true },
        ))) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .BUSY => return error.FileBusy,
            .DQUOT => return error.DiskQuota,
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .ROFS => return error.ReadOnlyFileSystem,
            .XDEV => return error.CrossDevice,
            .OPNOTSUPP => return error.OperationUnsupported,
            else => return error.Unexpected,
        };
    }
    if (builtin.os.tag != .linux) return error.OperationUnsupported;
    const linux = std.os.linux;
    while (true) switch (linux.errno(linux.renameat2(
        left_dir.handle,
        left_z,
        right_dir.handle,
        right_z,
        .{ .EXCHANGE = true },
    ))) {
        .SUCCESS => return,
        .INTR => continue,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .BUSY => return error.FileBusy,
        .DQUOT => return error.DiskQuota,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .MLINK => return error.LinkQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .NOTEMPTY => return error.DirNotEmpty,
        .ROFS => return error.ReadOnlyFileSystem,
        .XDEV => return error.CrossDevice,
        else => return error.Unexpected,
    };
}

const BundlePhase = enum {
    clean,
    stage_before,
    staging,
    prepared,
    switch_before,
    switch_after,
    rollback_before,
    rollback_after,
    committed,
    cleanup_before,
};

const BundleRecord = struct {
    phase: BundlePhase,
    target_name: []const u8,
    stage_name: []const u8,
    old_inode: ?u128,
    new_inode: u128,
};

const BundleLatest = struct {
    sequence: u64,
    record: BundleRecord,
};

const BundleControl = struct {
    lock_name: []const u8,
    journal_name: []const u8,
};

const managed_prefix_name = ".starling-aot-engine";
const managed_prefix_owner_name = "owner";
const managed_prefix_owner = "starling-aot-prefix-owner-v1\n";
const managed_prefix_manifest_name = "ownership.manifest";
const managed_prefix_manifest_schema = "starling-aot-prefix-ownership-v1";
const managed_prefix_generation_name = "current";

pub fn publishPrefixDirectory(
    allocator: Allocator,
    io: Io,
    target_path: []const u8,
    generation_path: []const u8,
    expected_feature_abi: []const u8,
    hooks: SealHooks,
) !void {
    const target_absolute = try absoluteSealPath(allocator, io, target_path);
    try Dir.cwd().createDirPath(io, target_absolute);
    var prefix = Dir.openDirAbsolute(io, target_absolute, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.InstallOwnershipConflict;
    defer prefix.close(io);
    if ((try prefix.stat(io)).kind != .directory)
        return error.InstallOwnershipConflict;
    var managed = try openManagedPrefix(allocator, io, prefix);
    defer managed.close(io);
    const expected = try managedPrefixEntries(
        allocator,
        io,
        generation_path,
    );
    try verifyManagedPrefixOwnership(
        allocator,
        io,
        prefix,
        managed,
        expected,
        false,
    );
    const managed_absolute = try std.fs.path.join(
        allocator,
        &.{ target_absolute, managed_prefix_name },
    );
    const current_path = try std.fs.path.join(
        allocator,
        &.{ managed_absolute, managed_prefix_generation_name },
    );
    try publishGenerationDirectory(
        allocator,
        io,
        current_path,
        generation_path,
        expected_feature_abi,
        hooks,
    );
    try ensureManagedPrefixOwnership(
        allocator,
        io,
        prefix,
        managed,
        expected,
    );
}

const ManagedPrefixEntries = struct {
    names: []const []const u8,
    manifest: []const u8,
};

fn openManagedPrefix(
    allocator: Allocator,
    io: Io,
    prefix: Dir,
) !Dir {
    _ = allocator;
    const permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    var created = true;
    prefix.createDir(io, managed_prefix_name, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => created = false,
        else => return err,
    };
    var managed = prefix.openDir(io, managed_prefix_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.InstallOwnershipConflict;
    errdefer managed.close(io);
    if ((try managed.stat(io)).kind != .directory)
        return error.InstallOwnershipConflict;
    if (created) {
        var owner = try managed.createFile(io, managed_prefix_owner_name, .{
            .read = true,
            .exclusive = true,
            .permissions = if (File.Permissions.has_executable_bit)
                File.Permissions.fromMode(0o600)
            else
                .default_file,
        });
        defer owner.close(io);
        try owner.writePositionalAll(io, managed_prefix_owner, 0);
        try owner.sync(io);
        try syncDir(io, managed);
    } else {
        try verifyManagedOwner(io, managed);
    }
    return managed;
}

fn verifyManagedOwner(io: Io, managed: Dir) !void {
    var owner = managed.openFile(io, managed_prefix_owner_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return error.InstallOwnershipConflict;
    defer owner.close(io);
    const stat = try owner.stat(io);
    if (stat.kind != .file or stat.size != managed_prefix_owner.len)
        return error.InstallOwnershipConflict;
    var contents: [managed_prefix_owner.len]u8 = undefined;
    if (try owner.readPositionalAll(io, &contents, 0) != contents.len or
        !std.mem.eql(u8, &contents, managed_prefix_owner))
        return error.InstallOwnershipConflict;
}

fn managedPrefixEntries(
    allocator: Allocator,
    io: Io,
    generation_path: []const u8,
) !ManagedPrefixEntries {
    const generation_absolute = try absoluteSealPath(
        allocator,
        io,
        generation_path,
    );
    var generation = try Dir.openDirAbsolute(io, generation_absolute, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer generation.close(io);
    try validateSealedSymlinkTree(allocator, io, generation);
    var bin = generation.openDir(io, "bin", .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return error.MissingCacheArtifact;
    defer bin.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = bin.iterate();
    while (try iterator.next(io)) |entry| {
        try validateBundleBasename(entry.name);
        switch (entry.kind) {
            .file, .directory, .sym_link => {},
            else => return error.InvalidDestinationKind,
        }
        names.append(
            allocator,
            try allocator.dupe(u8, entry.name),
        ) catch @panic("out of memory");
    }
    if (names.items.len == 0) return error.MissingCacheArtifact;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    var manifest: std.ArrayList(u8) = .empty;
    manifest.appendSlice(
        allocator,
        "schema=" ++ managed_prefix_manifest_schema ++ "\n",
    ) catch @panic("out of memory");
    for (names.items) |name| {
        manifest.appendSlice(allocator, "entry=bin/") catch
            @panic("out of memory");
        manifest.appendSlice(allocator, name) catch @panic("out of memory");
        manifest.append(allocator, '\n') catch @panic("out of memory");
    }
    return .{
        .names = try names.toOwnedSlice(allocator),
        .manifest = try manifest.toOwnedSlice(allocator),
    };
}

fn managedCurrentExists(io: Io, managed: Dir) !bool {
    var current = managed.openDir(io, managed_prefix_generation_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.InstallOwnershipConflict,
    };
    defer current.close(io);
    return (try current.stat(io)).kind == .directory;
}

fn openManagedBin(io: Io, prefix: Dir, create: bool) !?Dir {
    if (create) {
        const permissions: File.Permissions = if (File.Permissions.has_executable_bit)
            File.Permissions.fromMode(0o755)
        else
            .default_dir;
        prefix.createDir(io, "bin", permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    return prefix.openDir(io, "bin", .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => if (create)
            return error.InstallOwnershipConflict
        else
            return null,
        else => return error.InstallOwnershipConflict,
    };
}

fn managedLinkTarget(
    allocator: Allocator,
    name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "../{s}/{s}/bin/{s}",
        .{
            managed_prefix_name,
            managed_prefix_generation_name,
            name,
        },
    );
}

fn managedLinkState(
    allocator: Allocator,
    io: Io,
    bin: Dir,
    name: []const u8,
) !bool {
    var link = bin.openFile(io, name, .{
        .path_only = true,
        .allow_directory = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.InstallOwnershipConflict,
    };
    defer link.close(io);
    if ((try link.stat(io)).kind != .sym_link)
        return error.InstallOwnershipConflict;
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const length = bin.readLink(io, name, &buffer) catch
        return error.InstallOwnershipConflict;
    const expected = try managedLinkTarget(allocator, name);
    if (!std.mem.eql(u8, buffer[0..length], expected))
        return error.InstallOwnershipConflict;
    return true;
}

fn readManagedManifest(
    allocator: Allocator,
    io: Io,
    managed: Dir,
) !?[]const u8 {
    var file = managed.openFile(io, managed_prefix_manifest_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InstallOwnershipConflict,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 64 * 1024)
        return error.InstallOwnershipConflict;
    const contents = try allocator.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, contents, 0) != contents.len)
        return error.InstallOwnershipConflict;
    return contents;
}

fn verifyManagedPrefixOwnership(
    allocator: Allocator,
    io: Io,
    prefix: Dir,
    managed: Dir,
    expected: ManagedPrefixEntries,
    require_manifest: bool,
) !void {
    const manifest = try readManagedManifest(allocator, io, managed);
    if (manifest) |contents| {
        if (!std.mem.eql(u8, contents, expected.manifest))
            return error.InstallOwnershipConflict;
    } else if (require_manifest) {
        return error.InstallOwnershipConflict;
    }
    var bin = (try openManagedBin(io, prefix, false)) orelse {
        if (manifest != null) return error.InstallOwnershipConflict;
        return;
    };
    defer bin.close(io);
    const recovering = manifest == null and try managedCurrentExists(io, managed);
    for (expected.names) |name| {
        const exists = try managedLinkState(allocator, io, bin, name);
        if (manifest != null and !exists)
            return error.InstallOwnershipConflict;
        if (manifest == null and exists and !recovering)
            return error.InstallOwnershipConflict;
    }
}

fn ensureManagedPrefixOwnership(
    allocator: Allocator,
    io: Io,
    prefix: Dir,
    managed: Dir,
    expected: ManagedPrefixEntries,
) !void {
    var bin = (try openManagedBin(io, prefix, true)).?;
    defer bin.close(io);
    for (expected.names) |name| {
        if (!try managedLinkState(allocator, io, bin, name)) {
            const target = try managedLinkTarget(allocator, name);
            bin.symLink(io, target, name, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (!try managedLinkState(allocator, io, bin, name))
                        return error.InstallOwnershipConflict;
                },
                else => return err,
            };
        }
    }
    try syncDir(io, bin);
    if (try readManagedManifest(allocator, io, managed) == null) {
        var staged = try createPrivateFile(
            allocator,
            io,
            managed,
            ".ownership-manifest",
        );
        defer staged.deinit(io);
        try staged.file.writePositionalAll(io, expected.manifest, 0);
        try staged.file.sync(io);
        var renamed = true;
        managed.renamePreserve(
            staged.name,
            managed,
            managed_prefix_manifest_name,
            io,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                renamed = false;
                const existing = (try readManagedManifest(
                    allocator,
                    io,
                    managed,
                )) orelse return error.InstallOwnershipConflict;
                if (!std.mem.eql(u8, existing, expected.manifest))
                    return error.InstallOwnershipConflict;
            },
            else => return err,
        };
        if (renamed) staged.name_exists = false;
        try syncDir(io, managed);
    }
    try verifyManagedPrefixOwnership(
        allocator,
        io,
        prefix,
        managed,
        expected,
        true,
    );
}

fn publishGenerationDirectory(
    allocator: Allocator,
    io: Io,
    target_path: []const u8,
    generation_path: []const u8,
    expected_feature_abi: []const u8,
    hooks: SealHooks,
) !void {
    const target_absolute = try absoluteSealPath(allocator, io, target_path);
    const target_parent_path = std.fs.path.dirname(target_absolute) orelse
        return error.InvalidManifest;
    const target_name = std.fs.path.basename(target_absolute);
    try validateBundleBasename(target_name);
    try Dir.cwd().createDirPath(io, target_parent_path);
    const generation_absolute = try absoluteSealPath(
        allocator,
        io,
        generation_path,
    );
    var source_generation = try Dir.openDirAbsolute(
        io,
        generation_absolute,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source_generation.close(io);
    const source_generation_stat = try source_generation.stat(io);
    if (source_generation_stat.kind != .directory)
        return error.InvalidDestinationKind;

    var parent = try Dir.openDirAbsolute(io, target_parent_path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer parent.close(io);

    const control = try bundleControlNames(allocator, target_name);
    var lock = try openPrivateControlFile(
        io,
        parent,
        control.lock_name,
        false,
    );
    try runSealHook(allocator, io, hooks, "prefix-lock-attempt");
    try lock.lock(io, .exclusive);
    defer {
        lock.unlock(io);
        lock.close(io);
    }
    var journal = try openPrivateControlFile(
        io,
        parent,
        control.journal_name,
        false,
    );
    defer journal.close(io);
    var sequence: u64 = 0;
    if (try readLatestBundleJournal(allocator, io, journal)) |latest| {
        if (!std.mem.eql(u8, latest.record.target_name, target_name))
            return error.InvalidRecoveryJournal;
        sequence = latest.sequence;
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            latest.record,
            hooks,
        );
    } else {
        if ((try journal.stat(io)).size > journal_slot_size)
            return error.InvalidRecoveryJournal;
        try initializeBundleJournal(
            allocator,
            io,
            parent,
            journal,
            target_name,
        );
    }

    const old_inode = try targetDirectoryInode(io, parent, target_name);
    const stage_name = try randomBundleStageName(allocator, io, target_name);
    var record: BundleRecord = .{
        .phase = .stage_before,
        .target_name = target_name,
        .stage_name = stage_name,
        .old_inode = old_inode,
        .new_inode = 0,
    };
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .stage_before,
    );
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    try parent.createDir(io, stage_name, private_permissions);
    try syncDir(io, parent);
    var generation = try parent.openDir(io, stage_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    var generation_closed = false;
    defer if (!generation_closed) generation.close(io);
    record.new_inode = @intCast((try generation.stat(io)).inode);
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .staging,
    );
    try copyDirectoryContents(io, source_generation, generation);
    try generation.setPermissions(io, source_generation_stat.permissions);
    try syncDirectoryTree(io, generation);
    try validateSealedSymlinkTree(allocator, io, generation);
    try runSealHook(allocator, io, hooks, "prefix-files-durable");
    try validateInstalledPrefix(
        allocator,
        io,
        generation,
        expected_feature_abi,
    );
    try syncDirectoryTree(io, generation);
    try runSealHook(allocator, io, hooks, "prefix-validated");
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .prepared,
    );
    runSealHook(allocator, io, hooks, "prefix-prepared") catch |err| {
        generation.close(io);
        generation_closed = true;
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            record,
            .{},
        );
        return err;
    };
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .switch_before,
    );
    runSealHook(allocator, io, hooks, "before-prefix-switch") catch |err| {
        generation.close(io);
        generation_closed = true;
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            record,
            .{},
        );
        return err;
    };
    if (try targetDirectoryInode(io, parent, stage_name) != record.new_inode)
        return error.SealPathRace;
    if (old_inode != null)
        try exchangeNames(allocator, parent, stage_name, parent, target_name)
    else
        try parent.renamePreserve(stage_name, parent, target_name, io);
    try syncDir(io, parent);
    if (try targetDirectoryInode(io, parent, target_name) != record.new_inode or
        @as(u128, @intCast((try generation.stat(io)).inode)) != record.new_inode)
    {
        try rollbackUnexpectedDirectorySwitch(
            allocator,
            io,
            parent,
            record,
        );
        return error.SealPathRace;
    }
    generation.close(io);
    generation_closed = true;
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .switch_after,
    );
    runSealHook(allocator, io, hooks, "after-prefix-switch") catch |err| {
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            record,
            .{},
        );
        return err;
    };
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .committed,
    );
    try runSealHook(allocator, io, hooks, "prefix-committed");
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .cleanup_before,
    );
    try runSealHook(allocator, io, hooks, "before-prefix-cleanup");
    try removeBundleStage(io, parent, record);
    try syncDir(io, parent);
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .clean,
    );
    try runSealHook(allocator, io, hooks, "after-prefix-cleanup");
}

pub fn publishBundleDirectory(
    allocator: Allocator,
    io: Io,
    target_path: []const u8,
    engine_path: []const u8,
    engine_name: []const u8,
    weval_path: []const u8,
    cache_path: []const u8,
    manifest_path: []const u8,
    expected_feature_abi: ?[]const u8,
    hooks: SealHooks,
) !void {
    try validateBundleBasename(engine_name);
    const target_absolute = try absoluteSealPath(allocator, io, target_path);
    const parent_path = std.fs.path.dirname(target_absolute) orelse
        return error.InvalidManifest;
    const target_name = std.fs.path.basename(target_absolute);
    try validateBundleBasename(target_name);
    var parent = try Dir.openDirAbsolute(io, parent_path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer parent.close(io);
    const control = try bundleControlNames(allocator, target_name);
    var lock = try openPrivateControlFile(
        io,
        parent,
        control.lock_name,
        false,
    );
    try runSealHook(allocator, io, hooks, "bundle-lock-attempt");
    try lock.lock(io, .exclusive);
    defer {
        lock.unlock(io);
        lock.close(io);
    }
    var journal = try openPrivateControlFile(
        io,
        parent,
        control.journal_name,
        false,
    );
    defer journal.close(io);
    var sequence: u64 = 0;
    if (try readLatestBundleJournal(allocator, io, journal)) |latest| {
        if (!std.mem.eql(u8, latest.record.target_name, target_name))
            return error.InvalidRecoveryJournal;
        sequence = latest.sequence;
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            latest.record,
            hooks,
        );
    } else {
        if ((try journal.stat(io)).size > journal_slot_size)
            return error.InvalidRecoveryJournal;
        try initializeBundleJournal(
            allocator,
            io,
            parent,
            journal,
            target_name,
        );
    }

    const old_inode = try targetDirectoryInode(io, parent, target_name);
    const stage_name = try randomBundleStageName(allocator, io, target_name);
    var record: BundleRecord = .{
        .phase = .stage_before,
        .target_name = target_name,
        .stage_name = stage_name,
        .old_inode = old_inode,
        .new_inode = 0,
    };
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .stage_before,
    );
    try runSealHook(allocator, io, hooks, "before-bundle-stage");
    const private_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o700)
    else
        .default_dir;
    parent.createDir(io, stage_name, private_permissions) catch |err| {
        try writeBundlePhase(
            allocator,
            io,
            journal,
            &sequence,
            &record,
            .clean,
        );
        return err;
    };
    try syncDir(io, parent);
    var stage = try parent.openDir(io, stage_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    var stage_closed = false;
    defer if (!stage_closed) stage.close(io);
    record.new_inode = @intCast((try stage.stat(io)).inode);
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .staging,
    );
    try runSealHook(allocator, io, hooks, "after-bundle-stage");

    var target_permissions: File.Permissions = if (File.Permissions.has_executable_bit)
        File.Permissions.fromMode(0o755)
    else
        .default_dir;
    if (old_inode != null) {
        var target = try parent.openDir(io, target_name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        defer target.close(io);
        target_permissions = (try target.stat(io)).permissions;
        try copyDirectoryContents(io, target, stage);
    }

    const engine = try openStableInput(
        allocator,
        io,
        "bundle engine",
        engine_path,
    );
    defer engine.close(io);
    const weval = try openStableInput(
        allocator,
        io,
        "bundle Weval binary",
        weval_path,
    );
    defer weval.close(io);
    const initial_weval_sha = try hashStableFileHex(allocator, io, weval);
    const cache = try openStableInput(
        allocator,
        io,
        "bundle cache",
        cache_path,
    );
    defer cache.close(io);
    const manifest = try openStableInput(
        allocator,
        io,
        "bundle manifest",
        manifest_path,
    );
    defer manifest.close(io);

    try replacePrivateFile(io, stage, engine_name, engine);
    try runSealHook(allocator, io, hooks, "bundle-engine-staged");
    try replacePrivateFile(io, stage, cache_basename, cache);
    try runSealHook(allocator, io, hooks, "bundle-cache-staged");
    try replacePrivateFile(io, stage, manifest_basename, manifest);
    try runSealHook(allocator, io, hooks, "bundle-manifest-staged");
    try syncDir(io, stage);

    try validateSealedSymlinkTree(allocator, io, stage);
    const stage_absolute = try descriptorDirectoryPath(allocator, stage);
    const staged_engine = try std.fs.path.join(
        allocator,
        &.{ stage_absolute, engine_name },
    );
    const staged_cache = try std.fs.path.join(
        allocator,
        &.{ stage_absolute, cache_basename },
    );
    const staged_manifest = try std.fs.path.join(
        allocator,
        &.{ stage_absolute, manifest_basename },
    );
    _ = try validate(
        allocator,
        io,
        staged_engine,
        weval_path,
        staged_cache,
        staged_manifest,
        expected_feature_abi,
    );
    const final_weval_sha = try rehashStableFileHex(allocator, io, weval);
    if (!std.mem.eql(u8, initial_weval_sha, final_weval_sha))
        return error.SealPathRace;
    try stage.setPermissions(io, target_permissions);
    try syncDir(io, stage);
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .prepared,
    );
    runSealHook(allocator, io, hooks, "bundle-prepared") catch |err| {
        stage.close(io);
        stage_closed = true;
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            record,
            .{},
        );
        return err;
    };
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .switch_before,
    );
    runSealHook(allocator, io, hooks, "before-bundle-switch") catch |err| {
        stage.close(io);
        stage_closed = true;
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            record,
            .{},
        );
        return err;
    };
    if (try targetDirectoryInode(io, parent, stage_name) != record.new_inode)
        return error.SealPathRace;
    if (old_inode) |_|
        try exchangeNames(allocator, parent, stage_name, parent, target_name)
    else
        try parent.renamePreserve(stage_name, parent, target_name, io);
    try syncDir(io, parent);
    if (try targetDirectoryInode(io, parent, target_name) != record.new_inode or
        @as(u128, @intCast((try stage.stat(io)).inode)) != record.new_inode)
    {
        try rollbackUnexpectedDirectorySwitch(
            allocator,
            io,
            parent,
            record,
        );
        return error.SealPathRace;
    }
    stage.close(io);
    stage_closed = true;
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .switch_after,
    );
    runSealHook(allocator, io, hooks, "after-bundle-switch") catch |err| {
        try recoverBundleLocked(
            allocator,
            io,
            parent,
            journal,
            &sequence,
            record,
            .{},
        );
        return err;
    };
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .committed,
    );
    try runSealHook(allocator, io, hooks, "bundle-committed");
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .cleanup_before,
    );
    try runSealHook(allocator, io, hooks, "before-bundle-cleanup");
    try removeBundleStage(io, parent, record);
    try syncDir(io, parent);
    try writeBundlePhase(
        allocator,
        io,
        journal,
        &sequence,
        &record,
        .clean,
    );
    try runSealHook(allocator, io, hooks, "after-bundle-cleanup");
}

pub fn recoverBundleDirectory(
    allocator: Allocator,
    io: Io,
    target_path: []const u8,
    hooks: SealHooks,
) !void {
    const target_absolute = try absoluteSealPath(allocator, io, target_path);
    var prefix = Dir.openDirAbsolute(io, target_absolute, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return recoverGenerationDirectory(
            allocator,
            io,
            target_path,
            hooks,
        ),
        else => return recoverGenerationDirectory(
            allocator,
            io,
            target_path,
            hooks,
        ),
    };
    defer prefix.close(io);
    var managed = prefix.openDir(io, managed_prefix_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return recoverGenerationDirectory(
            allocator,
            io,
            target_path,
            hooks,
        ),
        else => return error.InstallOwnershipConflict,
    };
    defer managed.close(io);
    try verifyManagedOwner(io, managed);
    const managed_absolute = try std.fs.path.join(
        allocator,
        &.{ target_absolute, managed_prefix_name },
    );
    const current_path = try std.fs.path.join(
        allocator,
        &.{ managed_absolute, managed_prefix_generation_name },
    );
    try recoverGenerationDirectory(allocator, io, current_path, hooks);
    if (!try managedCurrentExists(io, managed)) return;
    const expected = try managedPrefixEntries(allocator, io, current_path);
    try verifyManagedPrefixOwnership(
        allocator,
        io,
        prefix,
        managed,
        expected,
        false,
    );
    try ensureManagedPrefixOwnership(
        allocator,
        io,
        prefix,
        managed,
        expected,
    );
}

fn recoverGenerationDirectory(
    allocator: Allocator,
    io: Io,
    target_path: []const u8,
    hooks: SealHooks,
) !void {
    const target_absolute = try absoluteSealPath(allocator, io, target_path);
    const parent_path = std.fs.path.dirname(target_absolute) orelse
        return error.InvalidManifest;
    const target_name = std.fs.path.basename(target_absolute);
    try validateBundleBasename(target_name);
    var parent = try Dir.openDirAbsolute(io, parent_path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer parent.close(io);
    const control = try bundleControlNames(allocator, target_name);
    const probe = parent.openFile(io, control.journal_name, .{
        .path_only = true,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    probe.close(io);
    var lock = try openPrivateControlFile(
        io,
        parent,
        control.lock_name,
        false,
    );
    try runSealHook(allocator, io, hooks, "bundle-lock-attempt");
    try lock.lock(io, .exclusive);
    defer {
        lock.unlock(io);
        lock.close(io);
    }
    var journal = try openPrivateControlFile(
        io,
        parent,
        control.journal_name,
        false,
    );
    defer journal.close(io);
    const latest = (try readLatestBundleJournal(
        allocator,
        io,
        journal,
    )) orelse {
        if ((try journal.stat(io)).size > journal_slot_size)
            return error.InvalidRecoveryJournal;
        try initializeBundleJournal(
            allocator,
            io,
            parent,
            journal,
            target_name,
        );
        return;
    };
    if (!std.mem.eql(u8, latest.record.target_name, target_name))
        return error.InvalidRecoveryJournal;
    var sequence = latest.sequence;
    try recoverBundleLocked(
        allocator,
        io,
        parent,
        journal,
        &sequence,
        latest.record,
        hooks,
    );
}

fn recoverBundleLocked(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    journal: File,
    sequence: *u64,
    initial_record: BundleRecord,
    hooks: SealHooks,
) !void {
    var record = initial_record;
    if (record.phase == .clean) return;
    const target_inode = try targetDirectoryInode(
        io,
        parent,
        record.target_name,
    );
    const stage_inode = try targetDirectoryInode(
        io,
        parent,
        record.stage_name,
    );
    const target_is_old = if (record.old_inode) |old|
        target_inode != null and target_inode.? == old
    else
        target_inode == null;
    const target_is_new = record.new_inode != 0 and
        target_inode != null and target_inode.? == record.new_inode;
    const stage_is_new = record.new_inode != 0 and
        stage_inode != null and stage_inode.? == record.new_inode;
    const stage_is_old = if (record.old_inode) |old|
        stage_inode != null and stage_inode.? == old
    else
        stage_inode == null;

    const committed = record.phase == .committed or
        record.phase == .cleanup_before;
    if (record.phase == .stage_before and target_is_old) {
        if (stage_inode != null)
            return error.TransactionRecoveryRequired;
    } else if (target_is_new and stage_is_old) {
        if (!committed) {
            try writeBundlePhase(
                allocator,
                io,
                journal,
                sequence,
                &record,
                .rollback_before,
            );
            try runSealHook(
                allocator,
                io,
                hooks,
                "before-bundle-rollback",
            );
            if (record.old_inode != null)
                try exchangeNames(
                    allocator,
                    parent,
                    record.stage_name,
                    parent,
                    record.target_name,
                )
            else
                try parent.renamePreserve(
                    record.target_name,
                    parent,
                    record.stage_name,
                    io,
                );
            try syncDir(io, parent);
            try writeBundlePhase(
                allocator,
                io,
                journal,
                sequence,
                &record,
                .rollback_after,
            );
            try runSealHook(
                allocator,
                io,
                hooks,
                "after-bundle-rollback",
            );
        }
        try removeBundleStage(io, parent, record);
    } else if (target_is_old and stage_is_new) {
        try removeBundleStage(io, parent, record);
    } else if (target_is_new and stage_inode == null and committed) {
        // Cleanup completed before the final clean journal record.
    } else if (target_is_old and stage_inode == null and
        record.phase == .rollback_after)
    {
        // Rolled-back cleanup completed before the final clean record.
    } else {
        return error.TransactionRecoveryRequired;
    }
    try syncDir(io, parent);
    try writeBundlePhase(
        allocator,
        io,
        journal,
        sequence,
        &record,
        .clean,
    );
}

fn validateBundleBasename(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfScalar(u8, name, 0) != null or
        std.mem.indexOfScalar(u8, name, std.fs.path.sep) != null)
        return error.InvalidManifest;
}

fn targetDirectoryInode(
    io: Io,
    parent: Dir,
    name: []const u8,
) !?u128 {
    var directory = parent.openDir(io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InvalidDestinationKind,
    };
    defer directory.close(io);
    const stat = try directory.stat(io);
    if (stat.kind != .directory) return error.InvalidDestinationKind;
    return @intCast(stat.inode);
}

fn syncDirectoryTree(io: Io, directory: Dir) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                var file = try directory.openFile(io, entry.name, .{
                    .follow_symlinks = false,
                    .allow_directory = false,
                });
                defer file.close(io);
                try file.sync(io);
            },
            .directory => {
                var child = try directory.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child.close(io);
                try syncDirectoryTree(io, child);
            },
            .sym_link => {},
            else => return error.InvalidDestinationKind,
        }
    }
    try syncDir(io, directory);
}

fn descriptorDirectoryPath(allocator: Allocator, directory: Dir) ![]const u8 {
    if (builtin.os.tag != .linux) return error.InvalidDestinationKind;
    return std.fmt.allocPrint(
        allocator,
        "/proc/self/fd/{d}",
        .{directory.handle},
    );
}

fn normalizeSealedPath(
    allocator: Allocator,
    parts: []const []const u8,
) ![]const u8 {
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    for (parts) |part| {
        if (std.fs.path.isAbsolute(part) or
            std.mem.indexOfScalar(u8, part, 0) != null)
        {
            return error.InvalidDestinationKind;
        }
        var iterator = std.mem.splitScalar(u8, part, '/');
        while (iterator.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                if (components.items.len == 0)
                    return error.InvalidDestinationKind;
                _ = components.pop();
                continue;
            }
            if (components.items.len == 64)
                return error.InvalidDestinationKind;
            components.append(allocator, component) catch
                @panic("out of memory");
        }
    }
    var result: std.ArrayList(u8) = .empty;
    for (components.items, 0..) |component, index| {
        if (index != 0) result.append(allocator, '/') catch
            @panic("out of memory");
        result.appendSlice(allocator, component) catch
            @panic("out of memory");
    }
    return result.toOwnedSlice(allocator) catch @panic("out of memory");
}

fn joinSealedComponents(
    allocator: Allocator,
    components: []const []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (components, 0..) |component, index| {
        if (index != 0) result.append(allocator, '/') catch
            @panic("out of memory");
        result.appendSlice(allocator, component) catch
            @panic("out of memory");
    }
    return result.toOwnedSlice(allocator) catch @panic("out of memory");
}

fn resolveSealedPath(
    allocator: Allocator,
    io: Io,
    root: Dir,
    path: []const u8,
    depth: usize,
) !void {
    if (depth == 64) return error.InvalidDestinationKind;
    const normalized = try normalizeSealedPath(allocator, &.{path});
    if (normalized.len == 0) return;
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);
    var split = std.mem.splitScalar(u8, normalized, '/');
    while (split.next()) |component| {
        components.append(allocator, component) catch
            @panic("out of memory");
    }

    var opened: [64]Dir = undefined;
    var opened_count: usize = 0;
    defer while (opened_count != 0) {
        opened_count -= 1;
        opened[opened_count].close(io);
    };
    var current = root;
    for (components.items, 0..) |component, index| {
        const stat = current.statFile(
            io,
            component,
            .{ .follow_symlinks = false },
        ) catch return error.InvalidDestinationKind;
        if (stat.kind == .sym_link) {
            var target_buffer: [Dir.max_path_bytes]u8 = undefined;
            const target_length = current.readLink(
                io,
                component,
                &target_buffer,
            ) catch return error.InvalidDestinationKind;
            const prefix = try joinSealedComponents(
                allocator,
                components.items[0..index],
            );
            const suffix = try joinSealedComponents(
                allocator,
                components.items[index + 1 ..],
            );
            const target = target_buffer[0..target_length];
            const resolved = try normalizeSealedPath(
                allocator,
                &.{ prefix, target, suffix },
            );
            return resolveSealedPath(
                allocator,
                io,
                root,
                resolved,
                depth + 1,
            );
        }
        if (index + 1 == components.items.len) {
            if (stat.kind != .file and stat.kind != .directory)
                return error.InvalidDestinationKind;
            return;
        }
        if (stat.kind != .directory) return error.InvalidDestinationKind;
        opened[opened_count] = current.openDir(io, component, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch return error.InvalidDestinationKind;
        current = opened[opened_count];
        opened_count += 1;
    }
}

fn validateSealedSymlinkDirectory(
    allocator: Allocator,
    io: Io,
    root: Dir,
    directory: Dir,
    relative: []const u8,
) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const child_relative = if (relative.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ relative, entry.name });
        switch (entry.kind) {
            .file => {},
            .directory => {
                var child = try directory.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer child.close(io);
                try validateSealedSymlinkDirectory(
                    allocator,
                    io,
                    root,
                    child,
                    child_relative,
                );
            },
            .sym_link => try resolveSealedPath(
                allocator,
                io,
                root,
                child_relative,
                0,
            ),
            else => return error.InvalidDestinationKind,
        }
    }
}

fn validateSealedSymlinkTree(
    allocator: Allocator,
    io: Io,
    root: Dir,
) !void {
    return validateSealedSymlinkDirectory(
        allocator,
        io,
        root,
        root,
        "",
    );
}

fn validateInstalledPrefix(
    allocator: Allocator,
    io: Io,
    generation: Dir,
    expected_feature_abi: []const u8,
) !void {
    const generation_path = try descriptorDirectoryPath(allocator, generation);
    const bin_path = try std.fs.path.join(
        allocator,
        &.{ generation_path, "bin" },
    );
    const required = [_][]const u8{
        "starling-raw.wasm",
        cache_basename,
        manifest_basename,
        "starling-aot-cache",
        "starling-componentize",
        "componentize.sh",
        "preview1-adapter.wasm",
        "features.json",
        "smoke.js",
        "wabt",
        "wasm-tools",
        "wasmtime",
        "weval",
    };
    for (required) |name| {
        const path = try std.fs.path.join(allocator, &.{ bin_path, name });
        const input = try openStableInput(
            allocator,
            io,
            "installed prefix artifact",
            path,
        );
        defer input.close(io);
        if (input.identity.size == 0) return error.MissingCacheArtifact;
    }
    const engine = try std.fs.path.join(
        allocator,
        &.{ bin_path, "starling-raw.wasm" },
    );
    const weval = try std.fs.path.join(
        allocator,
        &.{ generation_path, "weval-package", "weval" },
    );
    const cache = try std.fs.path.join(
        allocator,
        &.{ bin_path, cache_basename },
    );
    const manifest = try std.fs.path.join(
        allocator,
        &.{ bin_path, manifest_basename },
    );
    _ = try validate(
        allocator,
        io,
        engine,
        weval,
        cache,
        manifest,
        expected_feature_abi,
    );
}

fn randomBundleStageName(
    allocator: Allocator,
    io: Io,
    target_name: []const u8,
) ![]const u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    const encoded = std.fmt.bytesToHex(random, .lower);
    return std.fmt.allocPrint(
        allocator,
        ".{s}.starling-aot-generation-{s}",
        .{ target_name, &encoded },
    );
}

fn bundleControlNames(
    allocator: Allocator,
    target_name: []const u8,
) !BundleControl {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(target_name, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return .{
        .lock_name = try std.fmt.allocPrint(
            allocator,
            ".starling-aot-publish-{s}.lock",
            .{encoded[0..24]},
        ),
        .journal_name = try std.fmt.allocPrint(
            allocator,
            ".starling-aot-publish-{s}.journal",
            .{encoded[0..24]},
        ),
    };
}

fn rollbackUnexpectedDirectorySwitch(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    record: BundleRecord,
) !void {
    const target_inode = try targetDirectoryInode(
        io,
        parent,
        record.target_name,
    );
    const stage_inode = try targetDirectoryInode(
        io,
        parent,
        record.stage_name,
    );
    if (record.old_inode) |old_inode| {
        if (stage_inode == null or stage_inode.? != old_inode)
            return error.TransactionRecoveryRequired;
        try exchangeNames(
            allocator,
            parent,
            record.target_name,
            parent,
            record.stage_name,
        );
        try syncDir(io, parent);
        if (try targetDirectoryInode(io, parent, record.target_name) != old_inode)
            return error.TransactionRecoveryRequired;
        return;
    }
    if (target_inode == null or stage_inode != null)
        return error.TransactionRecoveryRequired;
    try parent.renamePreserve(
        record.target_name,
        parent,
        record.stage_name,
        io,
    );
    try syncDir(io, parent);
    if (try targetDirectoryInode(io, parent, record.target_name) != null)
        return error.TransactionRecoveryRequired;
}

fn removeBundleStage(io: Io, parent: Dir, record: BundleRecord) !void {
    const inode = try targetDirectoryInode(io, parent, record.stage_name);
    if (inode == null) return;
    const expected = if (record.old_inode) |old|
        if (inode.? == old) old else record.new_inode
    else
        record.new_inode;
    if (inode.? != expected) return error.TransactionRecoveryRequired;
    try parent.deleteTree(io, record.stage_name);
}

fn replacePrivateFile(
    io: Io,
    destination: Dir,
    name: []const u8,
    source: StableInput,
) !void {
    try destination.deleteTree(io, name);
    var output = try destination.createFile(io, name, .{
        .read = true,
        .exclusive = true,
    });
    defer output.close(io);
    const before = try source.file.stat(io);
    if (!sameStableContent(before, source.identity))
        return error.SealPathRace;
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try source.file.readPositional(
            io,
            &.{&buffer},
            offset,
        );
        if (count == 0) break;
        try output.writePositionalAll(io, buffer[0..count], offset);
        offset += count;
    }
    if (offset != before.size or
        !sameStableContent(before, try source.file.stat(io)))
        return error.SealPathRace;
    try output.setPermissions(io, before.permissions);
    try output.sync(io);
}

fn copyDirectoryContents(io: Io, source: Dir, destination: Dir) !void {
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                var input = try source.openFile(io, entry.name, .{
                    .follow_symlinks = false,
                    .allow_directory = false,
                });
                defer input.close(io);
                const stat = try input.stat(io);
                var output = try destination.createFile(io, entry.name, .{
                    .read = true,
                    .exclusive = true,
                    .permissions = stat.permissions,
                });
                defer output.close(io);
                var buffer: [64 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (true) {
                    const count = try input.readPositional(
                        io,
                        &.{&buffer},
                        offset,
                    );
                    if (count == 0) break;
                    try output.writePositionalAll(
                        io,
                        buffer[0..count],
                        offset,
                    );
                    offset += count;
                }
                if (offset != stat.size) return error.SealPathRace;
                try output.sync(io);
            },
            .directory => {
                var input_dir = try source.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer input_dir.close(io);
                const stat = try input_dir.stat(io);
                try destination.createDir(
                    io,
                    entry.name,
                    if (File.Permissions.has_executable_bit)
                        File.Permissions.fromMode(0o700)
                    else
                        .default_dir,
                );
                var output_dir = try destination.openDir(io, entry.name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                });
                defer output_dir.close(io);
                try copyDirectoryContents(io, input_dir, output_dir);
                try output_dir.setPermissions(io, stat.permissions);
                try syncDir(io, output_dir);
            },
            .sym_link => {
                var buffer: [Dir.max_path_bytes]u8 = undefined;
                const length = try source.readLink(
                    io,
                    entry.name,
                    &buffer,
                );
                try destination.symLink(
                    io,
                    buffer[0..length],
                    entry.name,
                    .{},
                );
            },
            else => return error.InvalidDestinationKind,
        }
    }
    try syncDir(io, destination);
}

const bundle_journal_magic = "AOTBND2\x00";

fn initializeBundleJournal(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    journal: File,
    target_name: []const u8,
) !void {
    const baseline: BundleRecord = .{
        .phase = .clean,
        .target_name = target_name,
        .stage_name = "",
        .old_inode = null,
        .new_inode = 0,
    };
    try journal.setLength(io, 0);
    const payload = try encodeBundleJournal(allocator, baseline);
    try writeBundleJournalPayload(io, journal, 0, payload);
    try syncDir(io, parent);
}

fn writeBundlePhase(
    allocator: Allocator,
    io: Io,
    journal: File,
    sequence: *u64,
    record: *BundleRecord,
    phase: BundlePhase,
) !void {
    record.phase = phase;
    sequence.* += 1;
    const payload = try encodeBundleJournal(allocator, record.*);
    try writeBundleJournalPayload(
        io,
        journal,
        sequence.*,
        payload,
    );
}

fn encodeBundleJournal(
    allocator: Allocator,
    record: BundleRecord,
) ![]const u8 {
    const old = if (record.old_inode) |inode|
        try std.fmt.allocPrint(allocator, "{d}", .{inode})
    else
        try allocator.dupe(u8, "-");
    return std.fmt.allocPrint(
        allocator,
        "version=2\nphase={s}\ntarget={s}\nstage={s}\nold={s}\nnew={d}\n",
        .{
            @tagName(record.phase),
            try hexEncode(allocator, record.target_name),
            try hexEncode(allocator, record.stage_name),
            old,
            record.new_inode,
        },
    );
}

fn writeBundleJournalPayload(
    io: Io,
    file: File,
    sequence: u64,
    payload: []const u8,
) !void {
    if (payload.len > journal_slot_size - journal_header_size)
        return error.InvalidRecoveryJournal;
    const slot_offset = (sequence % 2) * journal_slot_size;
    try file.writePositionalAll(io, payload, slot_offset + journal_header_size);
    try file.sync(io);
    var header: [journal_header_size]u8 = @splat(0);
    @memcpy(header[0..bundle_journal_magic.len], bundle_journal_magic);
    std.mem.writeInt(u64, header[8..16], sequence, .little);
    std.mem.writeInt(u32, header[16..20], @intCast(payload.len), .little);
    Sha256.hash(
        payload,
        header[24 .. 24 + Sha256.digest_length],
        .{},
    );
    try file.writePositionalAll(io, &header, slot_offset);
    try file.sync(io);
}

fn readLatestBundleJournal(
    allocator: Allocator,
    io: Io,
    file: File,
) !?BundleLatest {
    var latest: ?BundleLatest = null;
    for (0..2) |slot| {
        var header: [journal_header_size]u8 = undefined;
        const offset = @as(u64, @intCast(slot)) * journal_slot_size;
        if (try file.readPositionalAll(io, &header, offset) != header.len)
            continue;
        if (!std.mem.eql(
            u8,
            header[0..bundle_journal_magic.len],
            bundle_journal_magic,
        )) continue;
        const sequence = std.mem.readInt(u64, header[8..16], .little);
        const length = std.mem.readInt(u32, header[16..20], .little);
        if (length == 0 or
            length > journal_slot_size - journal_header_size)
            continue;
        const payload = try allocator.alloc(u8, length);
        if (try file.readPositionalAll(
            io,
            payload,
            offset + journal_header_size,
        ) != payload.len) continue;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(
            u8,
            &digest,
            header[24 .. 24 + Sha256.digest_length],
        )) continue;
        const record = parseBundleJournal(allocator, payload) catch continue;
        if (latest == null or sequence > latest.?.sequence)
            latest = .{ .sequence = sequence, .record = record };
    }
    return latest;
}

fn parseBundleJournal(
    allocator: Allocator,
    payload: []const u8,
) !BundleRecord {
    var phase: ?BundlePhase = null;
    var target: ?[]const u8 = null;
    var stage: ?[]const u8 = null;
    var old: ?u128 = null;
    var old_seen = false;
    var new: ?u128 = null;
    var version_seen = false;
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidRecoveryJournal;
        const name = line[0..split];
        const value = line[split + 1 ..];
        if (std.mem.eql(u8, name, "version")) {
            if (version_seen or !std.mem.eql(u8, value, "2"))
                return error.InvalidRecoveryJournal;
            version_seen = true;
        } else if (std.mem.eql(u8, name, "phase")) {
            if (phase != null) return error.InvalidRecoveryJournal;
            phase = std.meta.stringToEnum(BundlePhase, value) orelse
                return error.InvalidRecoveryJournal;
        } else if (std.mem.eql(u8, name, "target")) {
            if (target != null) return error.InvalidRecoveryJournal;
            target = try hexDecode(allocator, value);
        } else if (std.mem.eql(u8, name, "stage")) {
            if (stage != null) return error.InvalidRecoveryJournal;
            stage = try hexDecode(allocator, value);
        } else if (std.mem.eql(u8, name, "old")) {
            if (old_seen) return error.InvalidRecoveryJournal;
            old_seen = true;
            if (!std.mem.eql(u8, value, "-"))
                old = std.fmt.parseInt(u128, value, 10) catch
                    return error.InvalidRecoveryJournal;
        } else if (std.mem.eql(u8, name, "new")) {
            if (new != null) return error.InvalidRecoveryJournal;
            new = std.fmt.parseInt(u128, value, 10) catch
                return error.InvalidRecoveryJournal;
        } else {
            return error.InvalidRecoveryJournal;
        }
    }
    if (!version_seen or phase == null or target == null or stage == null or
        !old_seen or new == null)
        return error.InvalidRecoveryJournal;
    return .{
        .phase = phase.?,
        .target_name = target.?,
        .stage_name = stage.?,
        .old_inode = old,
        .new_inode = new.?,
    };
}

pub fn recover(
    allocator: Allocator,
    io: Io,
    cache_path: []const u8,
    manifest_path: []const u8,
) !void {
    return recoverWithHooks(
        allocator,
        io,
        cache_path,
        manifest_path,
        .{},
    );
}

pub fn recoverWithHooks(
    allocator: Allocator,
    io: Io,
    cache_path: []const u8,
    manifest_path: []const u8,
    hooks: SealHooks,
) !void {
    var cache_output = try openSealOutput(
        allocator,
        io,
        "cache",
        cache_path,
        hooks,
    );
    defer cache_output.deinit(io);
    var manifest_output = try openSealOutput(
        allocator,
        io,
        "manifest",
        manifest_path,
        hooks,
    );
    defer manifest_output.deinit(io);
    if (outputsAlias(&cache_output, &manifest_output))
        return error.SealPathAlias;
    if (try hasLegacySealJournal(io, cache_output.parent))
        return error.InvalidRecoveryJournal;
    var guard = try SealGuard.init(
        allocator,
        io,
        &cache_output,
        &manifest_output,
    );
    defer guard.deinit(io);
    try runSealHook(allocator, io, hooks, "recovery-locked");
    try guard.recover(
        allocator,
        io,
        &cache_output,
        &manifest_output,
        hooks,
    );
}

fn hasLegacySealJournal(io: Io, parent: Dir) !bool {
    var iterator = parent.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".aot-transaction-"))
            return true;
    }
    return false;
}

pub fn validate(
    allocator: Allocator,
    io: Io,
    engine_path: []const u8,
    weval_path: []const u8,
    cache_path: []const u8,
    manifest_path: []const u8,
    expected_feature_abi: ?[]const u8,
) !Validated {
    return validateWithHooks(
        allocator,
        io,
        engine_path,
        weval_path,
        cache_path,
        manifest_path,
        expected_feature_abi,
        .{},
    );
}

pub fn validateWithHooks(
    allocator: Allocator,
    io: Io,
    engine_path: []const u8,
    weval_path: []const u8,
    cache_path: []const u8,
    manifest_path: []const u8,
    expected_feature_abi: ?[]const u8,
    hooks: SealHooks,
) !Validated {
    var cache_output = try openSealOutput(
        allocator,
        io,
        "cache",
        cache_path,
        hooks,
    );
    defer cache_output.deinit(io);
    var manifest_output = try openSealOutput(
        allocator,
        io,
        "manifest",
        manifest_path,
        hooks,
    );
    defer manifest_output.deinit(io);
    if (outputsAlias(&cache_output, &manifest_output))
        return error.SealPathAlias;
    if (try hasLegacySealJournal(io, cache_output.parent))
        return error.InvalidRecoveryJournal;
    const names = try sealControlNames(
        allocator,
        &cache_output,
        &manifest_output,
    );
    var guard: ?SealGuard = null;
    defer if (guard) |*active| active.deinit(io);
    if (try controlFileExists(io, cache_output.parent, names.journal)) {
        guard = try SealGuard.init(
            allocator,
            io,
            &cache_output,
            &manifest_output,
        );
        try guard.?.recover(
            allocator,
            io,
            &cache_output,
            &manifest_output,
            .{},
        );
    }
    const engine = openStableInput(
        allocator,
        io,
        "engine",
        engine_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    defer engine.close(io);
    const weval = openWevalInput(
        allocator,
        io,
        weval_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    defer weval.close(io);
    const cache = openStableInput(
        allocator,
        io,
        "cache",
        cache_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    defer cache.close(io);
    const manifest = openStableInput(
        allocator,
        io,
        "manifest",
        manifest_path,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    defer manifest.close(io);

    try runSealHook(allocator, io, hooks, "validation-opened");
    try verifyCacheFormatFile(io, cache.file);
    const data = try readStableFileAlloc(
        allocator,
        io,
        manifest,
        16 * 1024,
    );
    const parsed = try parseManifest(data);
    const engine_sha = try rehashStableFileHex(allocator, io, engine);
    if (!std.mem.eql(u8, parsed.engine_sha256, engine_sha)) return error.StaleEngine;
    const weval_package = try inspectWevalPackage(
        allocator,
        io,
        weval_path,
    );
    var package_executable = try Dir.openFileAbsolute(
        io,
        weval_package.provenance,
        .{ .allow_directory = false, .follow_symlinks = false },
    );
    defer package_executable.close(io);
    if (!sameIdentity(try package_executable.stat(io), weval.identity))
        return error.StaleTool;
    if (!std.mem.eql(
        u8,
        parsed.weval_package_sha256,
        weval_package.digest,
    ) or !std.mem.eql(
        u8,
        parsed.weval_selected_relative,
        weval_package.selected_relative,
    ) or !std.mem.eql(
        u8,
        parsed.weval_selected_basename,
        weval_package.selected_basename,
    )) return error.StaleTool;
    const weval_sha = try rehashStableFileHex(allocator, io, weval);
    if (!std.mem.eql(u8, parsed.weval_sha256, weval_sha)) return error.StaleTool;
    if (expected_feature_abi) |expected| {
        if (!std.mem.eql(u8, parsed.feature_abi, expected)) return error.StaleFeatureAbi;
    }
    const expected_key = try cacheKey(
        allocator,
        parsed.engine_sha256,
        parsed.weval_sha256,
        parsed.weval_package_sha256,
        parsed.weval_selected_relative,
        parsed.weval_selected_basename,
        parsed.feature_abi,
        parsed.primer_sha256,
    );
    if (!std.mem.eql(u8, parsed.key, expected_key)) return error.InvalidManifest;
    const cache_sha = try rehashStableFileHex(allocator, io, cache);
    if (!std.mem.eql(u8, parsed.cache_sha256, cache_sha)) return error.CorruptCache;
    try verifyCacheDatabaseFile(io, cache.file, engine_sha);
    for ([_]struct {
        input: StableInput,
        digest: []const u8,
    }{
        .{ .input = engine, .digest = engine_sha },
        .{ .input = weval, .digest = weval_sha },
        .{ .input = cache, .digest = cache_sha },
    }) |expected| {
        const current = try rehashStableFileHex(
            allocator,
            io,
            expected.input,
        );
        if (!std.mem.eql(u8, current, expected.digest))
            return error.SealPathRace;
    }
    const final_manifest = try rereadStableFileAlloc(
        allocator,
        io,
        manifest,
        16 * 1024,
    );
    if (!std.mem.eql(u8, data, final_manifest))
        return error.SealPathRace;
    const final_package = try inspectWevalPackage(
        allocator,
        io,
        weval_path,
    );
    if (!std.mem.eql(u8, final_package.digest, parsed.weval_package_sha256) or
        !std.mem.eql(
            u8,
            final_package.selected_relative,
            parsed.weval_selected_relative,
        ) or
        !std.mem.eql(
            u8,
            final_package.selected_basename,
            parsed.weval_selected_basename,
        ))
        return error.WevalPackageRace;
    return .{
        .key = parsed.key,
        .feature_abi = parsed.feature_abi,
        .weval_package_sha256 = parsed.weval_package_sha256,
        .weval_selected_relative = parsed.weval_selected_relative,
        .weval_selected_basename = parsed.weval_selected_basename,
    };
}

fn readStableFileAlloc(
    allocator: Allocator,
    io: Io,
    input: StableInput,
    limit: usize,
) ![]u8 {
    const before = try input.file.stat(io);
    if (!sameStableObjectMetadata(before, input.identity) or
        input.filesystem != try filesystemId(input.file) or
        before.size > limit)
        return error.InvalidManifest;
    const data = try allocator.alloc(u8, @intCast(before.size));
    if (try input.file.readPositionalAll(io, data, 0) != data.len)
        return error.SealPathRace;
    if (!sameStableContent(before, try input.file.stat(io)))
        return error.SealPathRace;
    return data;
}

fn rereadStableFileAlloc(
    allocator: Allocator,
    io: Io,
    input: StableInput,
    limit: usize,
) ![]u8 {
    const before = try input.file.stat(io);
    if (!sameStableObjectMetadata(before, input.identity) or
        input.filesystem != try filesystemId(input.file) or
        before.size > limit)
        return error.SealPathRace;
    const data = try allocator.alloc(u8, @intCast(before.size));
    if (try input.file.readPositionalAll(io, data, 0) != data.len)
        return error.SealPathRace;
    const after = try input.file.stat(io);
    if (!sameIdentity(before, after) or
        input.filesystem != try filesystemId(input.file))
        return error.SealPathRace;
    return data;
}

fn parseManifest(data: []const u8) Error!Manifest {
    var manifest = Manifest{};
    var seen: u16 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.InvalidManifest;
        const name = line[0..split];
        const value = line[split + 1 ..];
        if (value.len == 0) return error.InvalidManifest;
        if (std.mem.eql(u8, name, "schema")) {
            if (seen & 1 != 0 or !std.mem.eql(u8, value, schema)) return error.InvalidManifest;
            seen |= 1;
        } else if (std.mem.eql(u8, name, "key")) {
            if (seen & 2 != 0 or !isDigest(value)) return error.InvalidManifest;
            seen |= 2;
            manifest.key = value;
        } else if (std.mem.eql(u8, name, "engine_abi")) {
            if (seen & 4 != 0 or !std.mem.eql(u8, value, engine_abi)) return error.InvalidManifest;
            seen |= 4;
        } else if (std.mem.eql(u8, name, "cache_abi")) {
            if (seen & 8 != 0 or !std.mem.eql(u8, value, cache_abi)) return error.InvalidManifest;
            seen |= 8;
        } else if (std.mem.eql(u8, name, "primer_abi")) {
            if (seen & 16 != 0 or !std.mem.eql(u8, value, primer_abi)) return error.InvalidManifest;
            seen |= 16;
        } else if (std.mem.eql(u8, name, "engine_sha256")) {
            if (seen & 32 != 0 or !isDigest(value)) return error.InvalidManifest;
            seen |= 32;
            manifest.engine_sha256 = value;
        } else if (std.mem.eql(u8, name, "weval_sha256")) {
            if (seen & 64 != 0 or !isDigest(value)) return error.InvalidManifest;
            seen |= 64;
            manifest.weval_sha256 = value;
        } else if (std.mem.eql(u8, name, "cache_sha256")) {
            if (seen & 128 != 0 or !isDigest(value)) return error.InvalidManifest;
            seen |= 128;
            manifest.cache_sha256 = value;
        } else if (std.mem.eql(u8, name, "feature_abi")) {
            if (seen & 256 != 0) return error.InvalidManifest;
            validateValue(value) catch return error.InvalidManifest;
            seen |= 256;
            manifest.feature_abi = value;
        } else if (std.mem.eql(u8, name, "primer_sha256")) {
            if (seen & 512 != 0 or !isDigest(value)) return error.InvalidManifest;
            seen |= 512;
            manifest.primer_sha256 = value;
        } else if (std.mem.eql(u8, name, "weval_package_sha256")) {
            if (seen & 1024 != 0 or !isDigest(value)) return error.InvalidManifest;
            seen |= 1024;
            manifest.weval_package_sha256 = value;
        } else if (std.mem.eql(u8, name, "weval_selected_relative")) {
            if (seen & 2048 != 0) return error.InvalidManifest;
            seen |= 2048;
            manifest.weval_selected_relative = value;
        } else if (std.mem.eql(u8, name, "weval_selected_basename")) {
            if (seen & 4096 != 0) return error.InvalidManifest;
            seen |= 4096;
            manifest.weval_selected_basename = value;
        } else {
            return error.InvalidManifest;
        }
    }
    if (seen != 0x1fff) return error.InvalidManifest;
    try validateWevalSelection(
        manifest.weval_selected_relative,
        manifest.weval_selected_basename,
    );
    return manifest;
}

fn cacheKey(
    allocator: Allocator,
    engine_sha: []const u8,
    weval_sha: []const u8,
    weval_package_sha: []const u8,
    weval_selected_relative: []const u8,
    weval_selected_basename: []const u8,
    feature_abi: []const u8,
    primer_sha: []const u8,
) ![]const u8 {
    var hasher = Sha256.init(.{});
    hashField(&hasher, "schema", schema);
    hashField(&hasher, "engine-abi", engine_abi);
    hashField(&hasher, "cache-abi", cache_abi);
    hashField(&hasher, "primer-abi", primer_abi);
    hashField(&hasher, "engine-sha256", engine_sha);
    hashField(&hasher, "weval-sha256", weval_sha);
    hashField(&hasher, "weval-package-sha256", weval_package_sha);
    hashField(&hasher, "weval-selected-relative", weval_selected_relative);
    hashField(&hasher, "weval-selected-basename", weval_selected_basename);
    hashField(&hasher, "feature-abi", feature_abi);
    hashField(&hasher, "primer-sha256", primer_sha);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn hashField(hasher: *Sha256, name: []const u8, value: []const u8) void {
    hasher.update(name);
    hasher.update(&.{0});
    hasher.update(value);
    hasher.update(&.{0xff});
}

fn verifyCacheFormatFile(io: Io, file: File) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size < 100) return error.InvalidCacheFormat;
    var header: [16]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len)
        return error.InvalidCacheFormat;
    if (!std.mem.eql(u8, &header, "SQLite format 3\x00"))
        return error.InvalidCacheFormat;
}

const SqliteDb = opaque {};
const SqliteStmt = opaque {};
const SqliteDestructor = ?*const fn (?*anyopaque) callconv(.c) void;

fn freeSqliteBlob(pointer: ?*anyopaque) callconv(.c) void {
    std.c.free(pointer);
}

const Sqlite = struct {
    library: std.DynLib,
    open_v2: *const fn ([*:0]const u8, *?*SqliteDb, c_int, ?[*:0]const u8) callconv(.c) c_int,
    close: *const fn (*SqliteDb) callconv(.c) c_int,
    prepare_v2: *const fn (*SqliteDb, [*]const u8, c_int, *?*SqliteStmt, ?*?[*]const u8) callconv(.c) c_int,
    step: *const fn (*SqliteStmt) callconv(.c) c_int,
    reset: *const fn (*SqliteStmt) callconv(.c) c_int,
    finalize: *const fn (*SqliteStmt) callconv(.c) c_int,
    column_int: *const fn (*SqliteStmt, c_int) callconv(.c) c_int,
    column_type: *const fn (*SqliteStmt, c_int) callconv(.c) c_int,
    column_text: *const fn (*SqliteStmt, c_int) callconv(.c) ?[*]const u8,
    column_blob: *const fn (*SqliteStmt, c_int) callconv(.c) ?*const anyopaque,
    column_bytes: *const fn (*SqliteStmt, c_int) callconv(.c) c_int,
    bind_blob: *const fn (*SqliteStmt, c_int, ?*const anyopaque, c_int, SqliteDestructor) callconv(.c) c_int,
    deserialize: *const fn (*SqliteDb, [*:0]const u8, [*]u8, i64, i64, c_uint) callconv(.c) c_int,
    serialize: *const fn (*SqliteDb, [*:0]const u8, *i64, c_uint) callconv(.c) ?[*]u8,
    free: *const fn (?*anyopaque) callconv(.c) void,

    fn load() Error!Sqlite {
        const candidates: []const []const u8 = switch (builtin.os.tag) {
            .linux => &.{ "libsqlite3.so.0", "libsqlite3.so" },
            .macos => &.{ "libsqlite3.dylib", "/usr/lib/libsqlite3.dylib" },
            .windows => &.{"sqlite3.dll"},
            else => return error.SqliteUnavailable,
        };
        var library = for (candidates) |candidate| {
            break std.DynLib.open(candidate) catch continue;
        } else return error.SqliteUnavailable;
        errdefer library.close();
        return .{
            .library = library,
            .open_v2 = library.lookup(
                @FieldType(Sqlite, "open_v2"),
                "sqlite3_open_v2",
            ) orelse return error.SqliteUnavailable,
            .close = library.lookup(
                @FieldType(Sqlite, "close"),
                "sqlite3_close",
            ) orelse return error.SqliteUnavailable,
            .prepare_v2 = library.lookup(
                @FieldType(Sqlite, "prepare_v2"),
                "sqlite3_prepare_v2",
            ) orelse return error.SqliteUnavailable,
            .step = library.lookup(
                @FieldType(Sqlite, "step"),
                "sqlite3_step",
            ) orelse return error.SqliteUnavailable,
            .reset = library.lookup(
                @FieldType(Sqlite, "reset"),
                "sqlite3_reset",
            ) orelse return error.SqliteUnavailable,
            .finalize = library.lookup(
                @FieldType(Sqlite, "finalize"),
                "sqlite3_finalize",
            ) orelse return error.SqliteUnavailable,
            .column_int = library.lookup(
                @FieldType(Sqlite, "column_int"),
                "sqlite3_column_int",
            ) orelse return error.SqliteUnavailable,
            .column_type = library.lookup(
                @FieldType(Sqlite, "column_type"),
                "sqlite3_column_type",
            ) orelse return error.SqliteUnavailable,
            .column_text = library.lookup(
                @FieldType(Sqlite, "column_text"),
                "sqlite3_column_text",
            ) orelse return error.SqliteUnavailable,
            .column_blob = library.lookup(
                @FieldType(Sqlite, "column_blob"),
                "sqlite3_column_blob",
            ) orelse return error.SqliteUnavailable,
            .column_bytes = library.lookup(
                @FieldType(Sqlite, "column_bytes"),
                "sqlite3_column_bytes",
            ) orelse return error.SqliteUnavailable,
            .bind_blob = library.lookup(
                @FieldType(Sqlite, "bind_blob"),
                "sqlite3_bind_blob",
            ) orelse return error.SqliteUnavailable,
            .deserialize = library.lookup(
                @FieldType(Sqlite, "deserialize"),
                "sqlite3_deserialize",
            ) orelse return error.SqliteUnavailable,
            .serialize = library.lookup(
                @FieldType(Sqlite, "serialize"),
                "sqlite3_serialize",
            ) orelse return error.SqliteUnavailable,
            .free = library.lookup(
                @FieldType(Sqlite, "free"),
                "sqlite3_free",
            ) orelse return error.SqliteUnavailable,
        };
    }

    fn deinit(sqlite: *Sqlite) void {
        sqlite.library.close();
    }
};

const sqlite_ok = 0;
const sqlite_open_readwrite = 0x00000002;
const sqlite_open_create = 0x00000004;
const sqlite_integer = 1;
const sqlite_blob = 4;
const sqlite_row = 100;
const sqlite_done = 101;
const canonical_sqlite_version = [4]u8{ 0x00, 0x2e, 0x72, 0xa0 };

const MemoryDatabase = struct {
    db: *SqliteDb,
    data: ?*anyopaque,

    fn deinit(memory: *MemoryDatabase, sqlite: *const Sqlite) void {
        _ = sqlite.close(memory.db);
        std.c.free(memory.data);
    }
};

fn openMemoryDatabaseFromFile(
    io: Io,
    sqlite: *const Sqlite,
    file: File,
) !MemoryDatabase {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or
        stat.size > std.math.maxInt(i64) or stat.size > std.math.maxInt(usize))
        return error.InvalidCacheFormat;
    const allocation = std.c.malloc(@intCast(stat.size)) orelse
        return error.OutOfMemory;
    errdefer std.c.free(allocation);
    const data: [*]u8 = @ptrCast(allocation);
    if (try file.readPositionalAll(io, data[0..@intCast(stat.size)], 0) != stat.size)
        return error.InvalidCacheFormat;

    var optional_db: ?*SqliteDb = null;
    if (sqlite.open_v2(
        ":memory:",
        &optional_db,
        sqlite_open_readwrite | sqlite_open_create,
        null,
    ) != sqlite_ok) {
        if (optional_db) |db| _ = sqlite.close(db);
        return error.InvalidCacheFormat;
    }
    const db = optional_db orelse return error.InvalidCacheFormat;
    errdefer _ = sqlite.close(db);
    if (sqlite.deserialize(
        db,
        "main",
        data,
        @intCast(stat.size),
        @intCast(stat.size),
        0,
    ) != sqlite_ok) return error.InvalidCacheFormat;
    return .{ .db = db, .data = allocation };
}

fn writeCanonicalCacheFiles(
    io: Io,
    source_file: File,
    output_file: File,
) !void {
    var sqlite = try Sqlite.load();
    defer sqlite.deinit();

    var source_memory = try openMemoryDatabaseFromFile(
        io,
        &sqlite,
        source_file,
    );
    defer source_memory.deinit(&sqlite);
    const source = source_memory.db;

    var optional_output: ?*SqliteDb = null;
    if (sqlite.open_v2(
        ":memory:",
        &optional_output,
        sqlite_open_readwrite | sqlite_open_create,
        null,
    ) != sqlite_ok) {
        if (optional_output) |db| _ = sqlite.close(db);
        return error.InvalidCacheFormat;
    }
    const output = optional_output orelse return error.InvalidCacheFormat;
    defer _ = sqlite.close(output);

    try execute(&sqlite, output, "PRAGMA page_size=4096");
    try execute(&sqlite, output, "PRAGMA auto_vacuum=NONE");
    try execute(&sqlite, output, "PRAGMA encoding='UTF-8'");
    try execute(&sqlite, output, "BEGIN IMMEDIATE");
    try execute(&sqlite, output,
        \\CREATE TABLE weval_cache(
        \\    module_hash BLOB NOT NULL,
        \\    key BLOB NOT NULL,
        \\    result BLOB NOT NULL,
        \\    created_time INTEGER NOT NULL
        \\)
    );

    const rows = try prepare(&sqlite, source,
        \\SELECT module_hash, key, result, created_time
        \\FROM weval_cache
        \\ORDER BY module_hash, key, result
    );
    defer _ = sqlite.finalize(rows);
    const insert = try prepare(&sqlite, output,
        \\INSERT INTO weval_cache(module_hash, key, result, created_time)
        \\VALUES(?1, ?2, ?3, 0)
    );
    defer _ = sqlite.finalize(insert);
    while (true) {
        switch (sqlite.step(rows)) {
            sqlite_row => {
                if (sqlite.column_type(rows, 3) != sqlite_integer)
                    return error.InvalidCacheFormat;
                for (0..3) |column| {
                    if (sqlite.column_type(rows, @intCast(column)) != sqlite_blob)
                        return error.InvalidCacheFormat;
                    const length = sqlite.column_bytes(rows, @intCast(column));
                    if (length < 0) return error.InvalidCacheFormat;
                    const source_blob = sqlite.column_blob(
                        rows,
                        @intCast(column),
                    );
                    const allocation = std.c.malloc(@max(
                        @as(usize, @intCast(length)),
                        1,
                    )) orelse return error.OutOfMemory;
                    if (length > 0) {
                        const bytes: [*]const u8 = @ptrCast(
                            source_blob orelse {
                                std.c.free(allocation);
                                return error.InvalidCacheFormat;
                            },
                        );
                        const copy: [*]u8 = @ptrCast(allocation);
                        @memcpy(
                            copy[0..@intCast(length)],
                            bytes[0..@intCast(length)],
                        );
                    }
                    if (sqlite.bind_blob(
                        insert,
                        @intCast(column + 1),
                        allocation,
                        length,
                        freeSqliteBlob,
                    ) != sqlite_ok) return error.InvalidCacheFormat;
                }
                if (sqlite.step(insert) != sqlite_done)
                    return error.InvalidCacheFormat;
                if (sqlite.reset(insert) != sqlite_ok)
                    return error.InvalidCacheFormat;
            },
            sqlite_done => break,
            else => return error.InvalidCacheFormat,
        }
    }
    try execute(
        &sqlite,
        output,
        "CREATE INDEX idx ON weval_cache(module_hash, key)",
    );
    try execute(&sqlite, output, "COMMIT");
    var serialized_size: i64 = 0;
    const serialized = sqlite.serialize(
        output,
        "main",
        &serialized_size,
        0,
    ) orelse return error.InvalidCacheFormat;
    defer sqlite.free(serialized);
    if (serialized_size < 0) return error.InvalidCacheFormat;
    try output_file.writePositionalAll(
        io,
        serialized[0..@intCast(serialized_size)],
        0,
    );
}

fn normalizeCanonicalHeaderFile(io: Io, file: File) !void {
    var header: [100]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len)
        return error.InvalidCacheFormat;
    try normalizeCanonicalHeaderBytes(&header);
    try file.writePositionalAll(io, &canonical_sqlite_version, 96);
    try file.sync(io);
}

fn normalizeCanonicalHeaderBytes(header: *[100]u8) Error!void {
    if (!std.mem.eql(u8, header[0..16], "SQLite format 3\x00"))
        return error.InvalidCacheFormat;
    @memcpy(header[96..100], &canonical_sqlite_version);
}

fn execute(sqlite: *const Sqlite, db: *SqliteDb, sql: []const u8) Error!void {
    const stmt = try prepare(sqlite, db, sql);
    defer _ = sqlite.finalize(stmt);
    if (sqlite.step(stmt) != sqlite_done) return error.InvalidCacheFormat;
}

fn verifyCacheDatabaseFile(
    io: Io,
    file: File,
    engine_sha: []const u8,
) !void {
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, engine_sha) catch
        return error.InvalidManifest;
    var sqlite = try Sqlite.load();
    defer sqlite.deinit();
    var memory = try openMemoryDatabaseFromFile(io, &sqlite, file);
    defer memory.deinit(&sqlite);
    try verifyIntegrity(&sqlite, memory.db);
    try verifySchema(&sqlite, memory.db);
    try verifyLiveEngineRow(&sqlite, memory.db, &digest);
}

fn prepare(sqlite: *const Sqlite, db: *SqliteDb, sql: []const u8) Error!*SqliteStmt {
    var optional_stmt: ?*SqliteStmt = null;
    if (sqlite.prepare_v2(
        db,
        sql.ptr,
        @intCast(sql.len),
        &optional_stmt,
        null,
    ) != sqlite_ok) return error.InvalidCacheFormat;
    return optional_stmt orelse error.InvalidCacheFormat;
}

fn columnText(
    sqlite: *const Sqlite,
    stmt: *SqliteStmt,
    column: c_int,
) Error![]const u8 {
    const pointer = sqlite.column_text(stmt, column) orelse
        return error.InvalidCacheSchema;
    const length = sqlite.column_bytes(stmt, column);
    if (length < 0) return error.InvalidCacheSchema;
    return pointer[0..@intCast(length)];
}

fn verifyIntegrity(sqlite: *const Sqlite, db: *SqliteDb) Error!void {
    const stmt = try prepare(sqlite, db, "PRAGMA integrity_check");
    defer _ = sqlite.finalize(stmt);
    if (sqlite.step(stmt) != sqlite_row) return error.CorruptCache;
    const result = columnText(sqlite, stmt, 0) catch return error.CorruptCache;
    if (!std.mem.eql(u8, result, "ok")) return error.CorruptCache;
    if (sqlite.step(stmt) != sqlite_done) return error.CorruptCache;
}

fn verifySchema(sqlite: *const Sqlite, db: *SqliteDb) Error!void {
    const objects = try prepare(sqlite, db,
        \\SELECT type, name, tbl_name
        \\FROM sqlite_schema
        \\WHERE name NOT LIKE 'sqlite_%'
        \\ORDER BY type, name
    );
    defer _ = sqlite.finalize(objects);
    const expected_objects = [_][3][]const u8{
        .{ "index", "idx", "weval_cache" },
        .{ "table", "weval_cache", "weval_cache" },
    };
    for (expected_objects) |expected| {
        if (sqlite.step(objects) != sqlite_row) return error.InvalidCacheSchema;
        for (expected, 0..) |value, column| {
            if (!std.mem.eql(
                u8,
                try columnText(sqlite, objects, @intCast(column)),
                value,
            )) return error.InvalidCacheSchema;
        }
    }
    if (sqlite.step(objects) != sqlite_done) return error.InvalidCacheSchema;

    const expected_columns = [_]struct {
        name: []const u8,
        declared_type: []const u8,
    }{
        .{ .name = "module_hash", .declared_type = "BLOB" },
        .{ .name = "key", .declared_type = "BLOB" },
        .{ .name = "result", .declared_type = "BLOB" },
        .{ .name = "created_time", .declared_type = "INTEGER" },
    };
    const table = try prepare(sqlite, db, "PRAGMA table_info('weval_cache')");
    defer _ = sqlite.finalize(table);
    for (expected_columns, 0..) |expected, index| {
        if (sqlite.step(table) != sqlite_row) return error.InvalidCacheSchema;
        if (sqlite.column_int(table, 0) != index or
            !std.mem.eql(u8, try columnText(sqlite, table, 1), expected.name) or
            !std.mem.eql(u8, try columnText(sqlite, table, 2), expected.declared_type) or
            sqlite.column_int(table, 3) != 1 or
            sqlite.column_int(table, 5) != 0)
        {
            return error.InvalidCacheSchema;
        }
    }
    if (sqlite.step(table) != sqlite_done) return error.InvalidCacheSchema;

    const indexes = try prepare(sqlite, db, "PRAGMA index_list('weval_cache')");
    defer _ = sqlite.finalize(indexes);
    var found_index = false;
    while (true) {
        switch (sqlite.step(indexes)) {
            sqlite_row => {
                if (std.mem.eql(u8, try columnText(sqlite, indexes, 1), "idx")) {
                    if (found_index or
                        sqlite.column_int(indexes, 2) != 0 or
                        sqlite.column_int(indexes, 4) != 0)
                    {
                        return error.InvalidCacheSchema;
                    }
                    found_index = true;
                }
            },
            sqlite_done => break,
            else => return error.InvalidCacheSchema,
        }
    }
    if (!found_index) return error.InvalidCacheSchema;

    const index = try prepare(sqlite, db, "PRAGMA index_info('idx')");
    defer _ = sqlite.finalize(index);
    for ([_][]const u8{ "module_hash", "key" }, 0..) |expected, position| {
        if (sqlite.step(index) != sqlite_row or
            sqlite.column_int(index, 0) != position or
            !std.mem.eql(u8, try columnText(sqlite, index, 2), expected))
        {
            return error.InvalidCacheSchema;
        }
    }
    if (sqlite.step(index) != sqlite_done) return error.InvalidCacheSchema;
}

fn verifyLiveEngineRow(
    sqlite: *const Sqlite,
    db: *SqliteDb,
    digest: *const [Sha256.digest_length]u8,
) Error!void {
    const stmt = try prepare(sqlite, db,
        \\SELECT 1 FROM weval_cache
        \\WHERE module_hash = ?1
        \\  AND typeof(module_hash) = 'blob'
        \\  AND length(module_hash) = 32
        \\  AND typeof(key) = 'blob'
        \\  AND length(key) > 0
        \\  AND typeof(result) = 'blob'
        \\  AND length(result) > 0
        \\  AND typeof(created_time) = 'integer'
        \\LIMIT 1
    );
    defer _ = sqlite.finalize(stmt);
    if (sqlite.bind_blob(
        stmt,
        1,
        @ptrCast(digest),
        digest.len,
        null,
    ) != sqlite_ok) return error.InvalidCacheFormat;
    if (sqlite.step(stmt) != sqlite_row) return error.IncompleteCache;
    if (sqlite.step(stmt) != sqlite_done) return error.InvalidCacheFormat;
}

fn validateValue(value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\x00\r\n") != null)
        return error.InvalidManifest;
}

fn isDigest(value: []const u8) bool {
    if (value.len != Sha256.digest_length * 2) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }

    return true;
}

test "filesystem-qualified object identity" {
    try std.testing.expect(sameObjectFields(
        7,
        42,
        .file,
        7,
        42,
        .file,
    ));
    try std.testing.expect(!sameObjectFields(
        7,
        42,
        .file,
        8,
        42,
        .file,
    ));
    try std.testing.expect(!sameObjectFields(
        7,
        42,
        .file,
        7,
        42,
        .directory,
    ));
}

test "cache key covers every declared semantic input" {
    const first = try cacheKey(
        std.testing.allocator,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "bin/weval",
        "weval",
        "features-a",
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    defer std.testing.allocator.free(first);
    const second = try cacheKey(
        std.testing.allocator,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "bin/weval",
        "weval",
        "features-b",
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "canonical SQLite header produces identical bytes and seals across versions" {
    var older: [128]u8 = @splat(0);
    @memcpy(older[0..16], "SQLite format 3\x00");
    @memcpy(older[96..100], &[4]u8{ 0x00, 0x2e, 0x72, 0xa0 });
    var newer = older;
    @memcpy(newer[96..100], &[4]u8{ 0x00, 0x2e, 0x76, 0x8b });

    try normalizeCanonicalHeaderBytes(older[0..100]);
    try normalizeCanonicalHeaderBytes(newer[0..100]);
    try std.testing.expectEqualSlices(u8, &older, &newer);

    var older_hasher = Sha256.init(.{});
    older_hasher.update(&older);
    var older_seal: [Sha256.digest_length]u8 = undefined;
    older_hasher.final(&older_seal);
    var newer_hasher = Sha256.init(.{});
    newer_hasher.update(&newer);
    var newer_seal: [Sha256.digest_length]u8 = undefined;
    newer_hasher.final(&newer_seal);
    try std.testing.expectEqualSlices(u8, &older_seal, &newer_seal);
}
