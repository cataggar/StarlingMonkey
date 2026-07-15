const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema = "starling-weval-cache-v1";
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
    InvalidCacheFormat,
    InvalidCacheSchema,
    InvalidManifest,
    MissingCacheArtifact,
    SealPathAlias,
    SealPathRace,
    SqliteUnavailable,
    StaleEngine,
    StaleFeatureAbi,
    StaleTool,
    TransactionRecoveryRequired,
};

pub const Validated = struct {
    key: []const u8,
    feature_abi: []const u8,
};

const Manifest = struct {
    key: []const u8 = "",
    engine_sha256: []const u8 = "",
    weval_sha256: []const u8 = "",
    cache_sha256: []const u8 = "",
    feature_abi: []const u8 = "",
    primer_sha256: []const u8 = "",
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
    );
    defer transaction.deinit(io);
    try transaction.rejectAliases();
    try runSealHook(allocator, io, hooks, "after-preflight");

    const engine_sha = try hashStableFileHex(allocator, io, transaction.engine);
    var source_snapshot = try stageStableCopy(
        allocator,
        io,
        transaction.cache_output.parent,
        ".aot-source",
        transaction.source_cache,
    );
    defer source_snapshot.deinit(io);
    try verifyCacheDatabaseFile(io, source_snapshot.file, engine_sha);

    var canonical = try stageCanonicalCache(
        allocator,
        io,
        transaction.cache_output.parent,
        source_snapshot.file,
        engine_sha,
    );
    defer canonical.deinit(io);
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
            "primer_sha256={s}\n",
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
        },
    );
    var manifest = try createPrivateFile(
        allocator,
        io,
        transaction.manifest_output.parent,
        ".aot-manifest",
    );
    defer manifest.deinit(io);
    try manifest.file.writePositionalAll(io, contents, 0);
    try manifest.file.sync(io);
    manifest.identity = try manifest.file.stat(io);
    manifest.name_identity = manifest.identity;
    try runSealHook(allocator, io, hooks, "after-manifest-stage");

    try publishBundle(
        allocator,
        io,
        &transaction.cache_output,
        &canonical,
        &transaction.manifest_output,
        &manifest,
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

    fn close(input: StableInput, io: Io) void {
        input.file.close(io);
    }
};

const DestinationState = union(enum) {
    missing,
    existing: struct {
        file: File,
        identity: File.Stat,
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
    initial: DestinationState,

    fn deinit(output: SealOutput, io: Io) void {
        output.initial.close(io);
        output.parent.close(io);
    }
};

const SealTransaction = struct {
    engine: StableInput,
    weval: StableInput,
    source_cache: StableInput,
    primer: StableInput,
    cache_output: SealOutput,
    manifest_output: SealOutput,
    in_place: bool,

    fn init(
        allocator: Allocator,
        io: Io,
        engine_path: []const u8,
        weval_path: []const u8,
        cache_path: []const u8,
        canonical_cache_path: ?[]const u8,
        primer_path: []const u8,
        manifest_path: []const u8,
    ) !SealTransaction {
        const engine = try openStableInput(allocator, io, "engine", engine_path);
        errdefer engine.close(io);
        const weval = try openStableInput(allocator, io, "Weval binary", weval_path);
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
        const cache_output = try openSealOutput(
            allocator,
            io,
            "canonical cache output",
            canonical_cache_path orelse cache_path,
        );
        errdefer cache_output.deinit(io);
        const manifest_output = try openSealOutput(
            allocator,
            io,
            "manifest output",
            manifest_path,
        );
        errdefer manifest_output.deinit(io);
        return .{
            .engine = engine,
            .weval = weval,
            .source_cache = source_cache,
            .primer = primer,
            .cache_output = cache_output,
            .manifest_output = manifest_output,
            .in_place = canonical_cache_path == null,
        };
    }

    fn deinit(transaction: *SealTransaction, io: Io) void {
        transaction.manifest_output.deinit(io);
        transaction.cache_output.deinit(io);
        transaction.primer.close(io);
        transaction.source_cache.close(io);
        transaction.weval.close(io);
        transaction.engine.close(io);
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
                    right.resolved,
                    right.identity,
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
};

fn openStableInput(
    allocator: Allocator,
    io: Io,
    role: []const u8,
    supplied: []const u8,
) !StableInput {
    const absolute = try absoluteSealPath(allocator, io, supplied);
    var file = try Dir.openFileAbsolute(io, absolute, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    errdefer file.close(io);
    const identity = try file.stat(io);
    if (identity.kind != .file) return error.MissingCacheArtifact;
    var resolved_buffer: [Dir.max_path_bytes]u8 = undefined;
    const resolved_len = try file.realPath(io, &resolved_buffer);
    return .{
        .role = role,
        .supplied = supplied,
        .absolute = absolute,
        .resolved = try allocator.dupe(u8, resolved_buffer[0..resolved_len]),
        .file = file,
        .identity = identity,
    };
}

fn openSealOutput(
    allocator: Allocator,
    io: Io,
    role: []const u8,
    supplied: []const u8,
) !SealOutput {
    const absolute = try absoluteSealPath(allocator, io, supplied);
    const parent_path = std.fs.path.dirname(absolute) orelse return error.InvalidManifest;
    const basename = std.fs.path.basename(absolute);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, "..")) return error.InvalidManifest;

    var observed_parent = try Dir.openDirAbsolute(io, parent_path, .{});
    defer observed_parent.close(io);
    const observed_identity = try observed_parent.stat(io);
    if (observed_identity.kind != .directory) return error.InvalidManifest;
    var parent_buffer: [Dir.max_path_bytes]u8 = undefined;
    const parent_len = try observed_parent.realPath(io, &parent_buffer);
    const canonical_parent_path = try allocator.dupe(u8, parent_buffer[0..parent_len]);
    var parent = try Dir.openDirAbsolute(
        io,
        canonical_parent_path,
        .{ .follow_symlinks = false, .iterate = true },
    );
    errdefer parent.close(io);
    const parent_identity = try parent.stat(io);
    if (!sameIdentity(observed_identity, parent_identity))
        return error.SealPathAlias;

    const resolved = try resolveSealDestination(allocator, io, absolute, 0);
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

fn resolveSealDestination(
    allocator: Allocator,
    io: Io,
    absolute: []const u8,
    depth: usize,
) ![]const u8 {
    if (depth == 40) return error.InvalidManifest;
    return Dir.realPathFileAbsoluteAlloc(io, absolute, allocator) catch |err| switch (err) {
        error.FileNotFound => {
            const parent = std.fs.path.dirname(absolute) orelse
                return error.InvalidManifest;
            if (std.mem.eql(u8, parent, absolute)) return err;
            const link_stat = Dir.cwd().statFile(
                io,
                absolute,
                .{ .follow_symlinks = false },
            ) catch |stat_err| switch (stat_err) {
                error.FileNotFound => null,
                else => return stat_err,
            };
            if (link_stat != null and link_stat.?.kind == .sym_link) {
                var buffer: [Dir.max_path_bytes]u8 = undefined;
                const length = try Dir.readLinkAbsolute(io, absolute, &buffer);
                const target = buffer[0..length];
                const target_absolute = if (std.fs.path.isAbsolute(target))
                    try allocator.dupe(u8, target)
                else
                    try joinUnresolved(allocator, parent, target);
                return resolveSealDestination(
                    allocator,
                    io,
                    target_absolute,
                    depth + 1,
                );
            }
            const resolved_parent = try resolveSealDestination(
                allocator,
                io,
                parent,
                depth + 1,
            );
            return std.fs.path.join(
                allocator,
                &.{ resolved_parent, std.fs.path.basename(absolute) },
            );
        },
        else => return err,
    };
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

fn sameIdentity(left: File.Stat, right: File.Stat) bool {
    return left.kind == right.kind and
        left.inode == right.inode and
        left.nlink == right.nlink and
        left.size == right.size and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn sameObject(left: File.Stat, right: File.Stat) bool {
    return left.kind == right.kind and left.inode == right.inode;
}

fn sameResolvedOrIdentity(
    left_resolved: []const u8,
    left_identity: File.Stat,
    right_resolved: []const u8,
    right_identity: File.Stat,
) bool {
    if (std.mem.eql(u8, left_resolved, right_resolved)) return true;
    return left_identity.nlink > 1 and right_identity.nlink > 1 and
        sameIdentity(left_identity, right_identity);
}

fn outputAliasesInput(output: *const SealOutput, input: *const StableInput) bool {
    if (std.mem.eql(u8, output.resolved, input.resolved)) return true;
    return switch (output.initial) {
        .missing => false,
        .existing => |existing| existing.identity.nlink > 1 and
            input.identity.nlink > 1 and sameIdentity(existing.identity, input.identity),
    };
}

fn outputsAlias(left: *const SealOutput, right: *const SealOutput) bool {
    if (std.mem.eql(u8, left.resolved, right.resolved)) return true;
    return switch (left.initial) {
        .missing => false,
        .existing => |left_existing| switch (right.initial) {
            .missing => false,
            .existing => |right_existing| left_existing.identity.nlink > 1 and
                right_existing.identity.nlink > 1 and
                sameIdentity(left_existing.identity, right_existing.identity),
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
        if (std.mem.eql(u8, fail_at, phase)) return error.AotCacheTestFailure;
    }
    const directory = hooks.directory orelse return;
    if (hooks.wait_at) |wait_at| {
        if (!std.mem.eql(u8, wait_at, phase)) return;
    }
    const ready = try std.fs.path.join(
        allocator,
        &.{ directory, try std.fmt.allocPrint(allocator, "{s}.ready", .{phase}) },
    );
    const proceed = try std.fs.path.join(
        allocator,
        &.{ directory, try std.fmt.allocPrint(allocator, "{s}.continue", .{phase}) },
    );
    try Dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "ready\n" });
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

const PrivateFile = struct {
    parent: Dir,
    name: []const u8,
    file: File,
    identity: File.Stat,
    name_identity: File.Stat,
    name_exists: bool = true,
    preserve: bool = false,

    fn deinit(private: *PrivateFile, io: Io) void {
        private.file.close(io);
        if (private.name_exists and !private.preserve)
            deleteOwnedFile(io, private.parent, private.name, private.name_identity);
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
        return .{
            .parent = parent,
            .name = name,
            .file = file,
            .identity = identity,
            .name_identity = identity,
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
    if (!sameIdentity(before, source.identity)) return error.SealPathRace;
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
    if (!sameIdentity(before, after) or offset != before.size)
        return error.SealPathRace;
    try snapshot.file.sync(io);
    snapshot.identity = try snapshot.file.stat(io);
    snapshot.name_identity = snapshot.identity;
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
    canonical.name_identity = canonical.identity;
    return canonical;
}

fn hashStableFileHex(
    allocator: Allocator,
    io: Io,
    input: StableInput,
) ![]const u8 {
    const before = try input.file.stat(io);
    if (!sameIdentity(before, input.identity)) return error.SealPathRace;
    const digest = try hashFileHandleHex(allocator, io, input.file);
    const after = try input.file.stat(io);
    if (!sameIdentity(before, after)) return error.SealPathRace;
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

fn publishBundle(
    allocator: Allocator,
    io: Io,
    cache_output: *const SealOutput,
    cache_stage: *PrivateFile,
    manifest_output: *const SealOutput,
    manifest_stage: *PrivateFile,
    hooks: SealHooks,
) !void {
    if (!try destinationMatchesStart(io, cache_output) or
        !try destinationMatchesStart(io, manifest_output))
        return error.SealPathRace;

    var journal = try createPrivateFile(
        allocator,
        io,
        cache_output.parent,
        ".aot-transaction",
    );
    var journal_closed = false;
    defer if (!journal_closed) journal.deinit(io);
    const journal_contents = try std.fmt.allocPrint(
        allocator,
        "state=prepared\ncache-parent={s}\ncache={s}\ncache-stage={s}\n" ++
            "manifest-parent={s}\nmanifest={s}\nmanifest-stage={s}\n",
        .{
            cache_output.parent_path,
            cache_output.basename,
            cache_stage.name,
            manifest_output.parent_path,
            manifest_output.basename,
            manifest_stage.name,
        },
    );
    try journal.file.writePositionalAll(io, journal_contents, 0);
    try journal.file.sync(io);
    journal.identity = try journal.file.stat(io);
    journal.name_identity = journal.identity;
    try syncDir(io, cache_output.parent);
    if (manifest_output.parent.handle != cache_output.parent.handle)
        try syncDir(io, manifest_output.parent);

    publishOne(allocator, io, cache_output, cache_stage) catch |err| {
        if (err == error.TransactionRecoveryRequired) {
            journal.preserve = true;
            cache_stage.preserve = true;
            manifest_stage.preserve = true;
        }
        return err;
    };
    syncDir(io, cache_output.parent) catch {
        return preserveRecovery(&journal, cache_stage, manifest_stage);
    };
    runSealHook(allocator, io, hooks, "after-first-publish") catch |err| {
        if (!rollbackOne(allocator, io, cache_output, cache_stage)) {
            journal.preserve = true;
            cache_stage.preserve = true;
            manifest_stage.preserve = true;
            return error.TransactionRecoveryRequired;
        }
        try syncDir(io, cache_output.parent);
        return err;
    };

    if (!try destinationHasIdentity(io, cache_output, cache_stage.identity) or
        !try destinationMatchesStart(io, manifest_output))
    {
        if (!rollbackOne(allocator, io, cache_output, cache_stage)) {
            journal.preserve = true;
            cache_stage.preserve = true;
            manifest_stage.preserve = true;
            return error.TransactionRecoveryRequired;
        }
        try syncDir(io, cache_output.parent);
        return error.SealPathRace;
    }

    publishOne(allocator, io, manifest_output, manifest_stage) catch |err| {
        if (!rollbackOne(allocator, io, cache_output, cache_stage)) {
            journal.preserve = true;
            cache_stage.preserve = true;
            manifest_stage.preserve = true;
            return error.TransactionRecoveryRequired;
        }
        try syncDir(io, cache_output.parent);
        if (err == error.TransactionRecoveryRequired) {
            journal.preserve = true;
            manifest_stage.preserve = true;
        }
        return err;
    };

    syncDir(io, manifest_output.parent) catch {
        return preserveRecovery(&journal, cache_stage, manifest_stage);
    };
    if (!try destinationHasIdentity(io, cache_output, cache_stage.identity) or
        !try destinationHasIdentity(io, manifest_output, manifest_stage.identity))
        return preserveRecovery(&journal, cache_stage, manifest_stage);

    journal.deinit(io);
    journal_closed = true;
    try syncDir(io, cache_output.parent);
    if (manifest_output.parent.handle != cache_output.parent.handle)
        try syncDir(io, manifest_output.parent);
}

fn preserveRecovery(
    journal: *PrivateFile,
    cache_stage: *PrivateFile,
    manifest_stage: *PrivateFile,
) Error {
    journal.preserve = true;
    cache_stage.preserve = true;
    manifest_stage.preserve = true;
    return error.TransactionRecoveryRequired;
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
    return sameObject(identity, try current.stat(io));
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
            try output.parent.renamePreserve(
                staged.name,
                output.parent,
                output.basename,
                io,
            );
            staged.name_exists = false;
        },
        .existing => |existing| {
            try exchangeNames(
                allocator,
                staged.parent,
                staged.name,
                output.parent,
                output.basename,
            );
            const displaced = statNoFollow(io, staged.parent, staged.name) catch {
                return error.TransactionRecoveryRequired;
            };
            if (!sameObject(existing.identity, displaced)) {
                exchangeNames(
                    allocator,
                    staged.parent,
                    staged.name,
                    output.parent,
                    output.basename,
                ) catch return error.TransactionRecoveryRequired;
                const restored_stage = statNoFollow(
                    io,
                    staged.parent,
                    staged.name,
                ) catch return error.TransactionRecoveryRequired;
                const restored_destination = statNoFollow(
                    io,
                    output.parent,
                    output.basename,
                ) catch return error.TransactionRecoveryRequired;
                if (!sameObject(restored_stage, staged.identity) or
                    !sameObject(restored_destination, displaced))
                    return error.TransactionRecoveryRequired;
                staged.name_identity = restored_stage;
                return error.SealPathRace;
            }
            staged.name_identity = displaced;
        },
    }
}

fn rollbackOne(
    allocator: Allocator,
    io: Io,
    output: *const SealOutput,
    staged: *PrivateFile,
) bool {
    switch (output.initial) {
        .missing => {
            output.parent.renamePreserve(
                output.basename,
                staged.parent,
                staged.name,
                io,
            ) catch return false;
            staged.name_exists = true;
            const displaced = statNoFollow(io, staged.parent, staged.name) catch
                return false;
            const artifact_identity = staged.file.stat(io) catch return false;
            if (sameObject(displaced, artifact_identity)) {
                staged.name_identity = displaced;
                return true;
            }
            staged.parent.renamePreserve(
                staged.name,
                output.parent,
                output.basename,
                io,
            ) catch return false;
            staged.name_exists = false;
            return false;
        },
        .existing => |existing| {
            exchangeNames(
                allocator,
                staged.parent,
                staged.name,
                output.parent,
                output.basename,
            ) catch return false;
            const displaced = statNoFollow(io, staged.parent, staged.name) catch
                return false;
            const artifact_identity = staged.file.stat(io) catch return false;
            if (sameObject(displaced, artifact_identity)) {
                staged.name_identity = displaced;
                return true;
            }
            exchangeNames(
                allocator,
                staged.parent,
                staged.name,
                output.parent,
                output.basename,
            ) catch return false;
            const restored_stage = statNoFollow(
                io,
                staged.parent,
                staged.name,
            ) catch return false;
            const restored_destination = statNoFollow(
                io,
                output.parent,
                output.basename,
            ) catch return false;
            if (!sameObject(restored_stage, existing.identity) or
                !sameObject(restored_destination, displaced))
                return false;
            staged.name_identity = restored_stage;
            return false;
        },
    }
}

fn statNoFollow(io: Io, parent: Dir, name: []const u8) !File.Stat {
    var file = try parent.openFile(io, name, .{
        .path_only = true,
        .follow_symlinks = false,
        .allow_directory = true,
    });
    defer file.close(io);
    return file.stat(io);
}

fn deleteOwnedFile(
    io: Io,
    parent: Dir,
    name: []const u8,
    identity: File.Stat,
) void {
    const current = statNoFollow(io, parent, name) catch return;
    if (!sameIdentity(current, identity)) return;
    parent.deleteFile(io, name) catch {};
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

pub fn validate(
    allocator: Allocator,
    io: Io,
    engine_path: []const u8,
    weval_path: []const u8,
    cache_path: []const u8,
    manifest_path: []const u8,
    expected_feature_abi: ?[]const u8,
) !Validated {
    verifyCacheFormat(io, cache_path) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    const data = Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(16 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    const parsed = try parseManifest(data);
    const engine_sha = hashFileHex(allocator, io, engine_path) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    if (!std.mem.eql(u8, parsed.engine_sha256, engine_sha)) return error.StaleEngine;
    const weval_sha = hashFileHex(allocator, io, weval_path) catch |err| switch (err) {
        error.FileNotFound => return error.MissingCacheArtifact,
        else => return err,
    };
    if (!std.mem.eql(u8, parsed.weval_sha256, weval_sha)) return error.StaleTool;
    if (expected_feature_abi) |expected| {
        if (!std.mem.eql(u8, parsed.feature_abi, expected)) return error.StaleFeatureAbi;
    }
    const expected_key = try cacheKey(
        allocator,
        parsed.engine_sha256,
        parsed.weval_sha256,
        parsed.feature_abi,
        parsed.primer_sha256,
    );
    if (!std.mem.eql(u8, parsed.key, expected_key)) return error.InvalidManifest;
    const cache_sha = try hashFileHex(allocator, io, cache_path);
    if (!std.mem.eql(u8, parsed.cache_sha256, cache_sha)) return error.CorruptCache;
    try verifyCacheDatabase(allocator, cache_path, engine_sha);
    return .{ .key = parsed.key, .feature_abi = parsed.feature_abi };
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
        } else {
            return error.InvalidManifest;
        }
    }
    if (seen != 0x3ff) return error.InvalidManifest;
    return manifest;
}

fn cacheKey(
    allocator: Allocator,
    engine_sha: []const u8,
    weval_sha: []const u8,
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

fn hashFileHex(allocator: Allocator, io: Io, path: []const u8) ![]const u8 {
    var file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
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
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn verifyCacheFormat(io: Io, path: []const u8) !void {
    var file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
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
const sqlite_open_readonly = 0x00000001;
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

fn verifyCacheDatabase(
    allocator: Allocator,
    path: []const u8,
    engine_sha: []const u8,
) !void {
    return verifyCacheDatabasePath(allocator, path, engine_sha);
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

fn verifyCacheDatabasePath(
    allocator: Allocator,
    path: []const u8,
    engine_sha: []const u8,
) !void {
    var digest: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, engine_sha) catch return error.InvalidManifest;
    var sqlite = try Sqlite.load();
    defer sqlite.deinit();

    const path_z = allocator.dupeSentinel(u8, path, 0) catch
        return error.InvalidCacheFormat;
    var optional_db: ?*SqliteDb = null;
    if (sqlite.open_v2(path_z, &optional_db, sqlite_open_readonly, null) != sqlite_ok) {
        if (optional_db) |db| _ = sqlite.close(db);
        return error.InvalidCacheFormat;
    }
    const db = optional_db orelse return error.InvalidCacheFormat;
    defer _ = sqlite.close(db);

    try verifyIntegrity(&sqlite, db);
    try verifySchema(&sqlite, db);
    try verifyLiveEngineRow(&sqlite, db, &digest);
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

test "cache key covers every declared semantic input" {
    const first = try cacheKey(
        std.testing.allocator,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "features-a",
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    );
    defer std.testing.allocator.free(first);
    const second = try cacheKey(
        std.testing.allocator,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
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
