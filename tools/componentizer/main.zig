const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const aot_cache = @import("aot_cache.zig");
const aot_pipeline = @import("aot_pipeline.zig");
const cli = @import("cli.zig");
const diagnostics = @import("diagnostics.zig");
const metadata = @import("metadata.zig");
const feature_surface = @import("feature_surface");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const File = Io.File;
const required_zig_version = "0.17.0-dev.902+7255f3e72";
const runtime_build_manifest = "tools/componentizer/runtime-build-inputs.txt";

const PipelineError = error{
    CacheDirectoryChanged,
    CommandFailed,
    CorruptAotCache,
    DebugOutputCollision,
    EmptyRuntimeArgument,
    EngineProvenanceMismatch,
    IncompatibleEngineOptions,
    InvalidEngineProvenance,
    InvalidBuildRoot,
    InvalidBindingsManifest,
    InvalidMetadataDestination,
    InvalidPath,
    InvalidAotCache,
    InvalidToolManifest,
    InvalidUtf8Path,
    MetadataUnavailable,
    MissingAotCache,
    MissingBuildArtifact,
    MissingEngineProvenance,
    MissingWitFiles,
    PublicationDirectoryChanged,
    RollbackIncomplete,
    StaleAotCache,
    UnrepresentableRuntimeArgument,
    UnsupportedWitEntry,
    UnsupportedZigVersion,
};

const StagedWit = struct {
    absolute: []const u8,
    digest: []const u8,
};

const RetainedDirectory = struct {
    absolute: []const u8,
    guest: []const u8,
    digest: []const u8,
};

const BuildSelections = struct {
    paths: []const []const u8,
    manifest_digest: ?[]const u8,
};

const SnapshotSymlinkPolicy = enum {
    reject,
    preserve_internal,
    dereference_files,
};

const AnchoredTargetDirectory = struct {
    name: []const u8,
    identity: SourceIdentity,
    device: DeviceIdentity = .{ .major = 0, .minor = 0 },
    directory: Dir,
};

const RetainedInputPathNode = struct {
    parent: ?usize,
    name: []const u8,
    identity: SourceIdentity,
    device: DeviceIdentity,
    directory: ?Dir = null,
    symlink: ?File = null,
    link_target: ?[]const u8 = null,
};

const RetainedInputKind = enum { file, directory };
const RetainedInputHandle = union(RetainedInputKind) {
    file: File,
    directory: Dir,
};

const RetainedInputPath = struct {
    root: Dir,
    root_identity: SourceIdentity,
    root_device: DeviceIdentity,
    nodes: []const RetainedInputPathNode,
    parent: ?usize,
    basename: []const u8,
    entry_identity: SourceIdentity,
    entry_device: DeviceIdentity,
    entry: RetainedInputHandle,
    retained_identity: SourceIdentity,
    retained_device: DeviceIdentity,
    resolved_path: []const u8,

    fn verify(self: *const RetainedInputPath, io: Io) !void {
        if (!self.root_identity.matches(try self.root.stat(io)) or
            !deviceIdentityMatches(
                self.root_device,
                try linuxDeviceForHandle(self.root.handle),
            ))
        {
            return error.InputChanged;
        }
        for (self.nodes) |node| {
            const parent = self.parentDirectory(node.parent);
            if (!node.identity.matches(try parent.statFile(
                io,
                node.name,
                .{ .follow_symlinks = false },
            )) or
                !deviceIdentityMatches(
                    node.device,
                    try linuxDeviceAt(parent, node.name),
                ))
            {
                return error.InputChanged;
            }
            if (node.directory) |directory| {
                if (!node.identity.matches(try directory.stat(io)) or
                    !deviceIdentityMatches(
                        node.device,
                        try linuxDeviceForHandle(directory.handle),
                    ))
                {
                    return error.InputChanged;
                }
            } else if (node.symlink) |link| {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const length = try readBoundSymlink(
                    io,
                    node.identity,
                    link,
                    &buffer,
                );
                if (!std.mem.eql(
                    u8,
                    node.link_target.?,
                    buffer[0..length],
                ) or
                    !deviceIdentityMatches(
                        node.device,
                        try linuxDeviceForHandle(link.handle),
                    ))
                {
                    return error.InputChanged;
                }
            } else unreachable;
        }
        const parent = self.parentDirectory(self.parent);
        if (!self.entry_identity.matches(try parent.statFile(
            io,
            self.basename,
            .{ .follow_symlinks = false },
        )) or !deviceIdentityMatches(
            self.entry_device,
            try linuxDeviceAt(parent, self.basename),
        )) {
            return error.InputChanged;
        }
        switch (self.entry) {
            .file => |file| {
                if (!self.retained_identity.matchesRetained(try file.stat(io)) or
                    !deviceIdentityMatches(
                        self.retained_device,
                        try linuxDeviceForHandle(file.handle),
                    ))
                {
                    return error.InputChanged;
                }
            },
            .directory => |directory| {
                if (!self.retained_identity.matches(try directory.stat(io)) or
                    !deviceIdentityMatches(
                        self.retained_device,
                        try linuxDeviceForHandle(directory.handle),
                    ))
                {
                    return error.InputChanged;
                }
            },
        }
    }

    fn parentDirectory(self: *const RetainedInputPath, parent: ?usize) Dir {
        return if (parent) |index| self.nodes[index].directory.? else self.root;
    }

    fn verifyMutableDirectory(self: *const RetainedInputPath, io: Io) !void {
        if (!self.root_identity.entry.matches(try self.root.stat(io)) or
            !deviceIdentityMatches(
                self.root_device,
                try linuxDeviceForHandle(self.root.handle),
            ))
        {
            return error.InputChanged;
        }
        for (self.nodes) |node| {
            const parent = self.parentDirectory(node.parent);
            const namespace_stat = try parent.statFile(
                io,
                node.name,
                .{ .follow_symlinks = false },
            );
            if (!node.identity.entry.matches(namespace_stat) or
                !deviceIdentityMatches(
                    node.device,
                    try linuxDeviceAt(parent, node.name),
                ))
            {
                return error.InputChanged;
            }
            if (node.directory) |directory| {
                if (!node.identity.entry.matches(try directory.stat(io)) or
                    !deviceIdentityMatches(
                        node.device,
                        try linuxDeviceForHandle(directory.handle),
                    ))
                {
                    return error.InputChanged;
                }
            } else if (node.symlink) |link| {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const length = try readBoundSymlink(
                    io,
                    node.identity,
                    link,
                    &buffer,
                );
                if (!std.mem.eql(u8, node.link_target.?, buffer[0..length]) or
                    !deviceIdentityMatches(
                        node.device,
                        try linuxDeviceForHandle(link.handle),
                    ))
                {
                    return error.InputChanged;
                }
            } else unreachable;
        }
        const directory = switch (self.entry) {
            .directory => |value| value,
            .file => return error.InputChanged,
        };
        const parent = self.parentDirectory(self.parent);
        const namespace_stat = try parent.statFile(
            io,
            self.basename,
            .{ .follow_symlinks = false },
        );
        const retained_stat = try directory.stat(io);
        if (!self.entry_identity.entry.matches(namespace_stat) or
            !self.retained_identity.entry.matches(retained_stat) or
            !self.entry_identity.entry.matches(retained_stat) or
            !deviceIdentityMatches(
                self.entry_device,
                try linuxDeviceAt(parent, self.basename),
            ) or
            !deviceIdentityMatches(
                self.retained_device,
                try linuxDeviceForHandle(directory.handle),
            ))
        {
            return error.InputChanged;
        }
    }

    fn refreshRetainedDirectoryBaseline(
        self: *RetainedInputPath,
        io: Io,
    ) !void {
        const directory = switch (self.entry) {
            .directory => |value| value,
            .file => return error.InputChanged,
        };
        const parent = self.parentDirectory(self.parent);
        const namespace_stat = try parent.statFile(
            io,
            self.basename,
            .{ .follow_symlinks = false },
        );
        const retained_stat = try directory.stat(io);
        if (!self.entry_identity.entry.matches(namespace_stat) or
            !self.retained_identity.entry.matches(retained_stat) or
            !self.entry_identity.entry.matches(retained_stat))
        {
            return error.InputChanged;
        }
        self.entry_identity = SourceIdentity.fromStat(namespace_stat);
        self.retained_identity = SourceIdentity.fromStat(retained_stat);
        self.entry_device = try linuxDeviceAt(parent, self.basename);
        self.retained_device = try linuxDeviceForHandle(directory.handle);
    }

    fn deinit(self: *RetainedInputPath, allocator: Allocator, io: Io) void {
        switch (self.entry) {
            .file => |file| file.close(io),
            .directory => |directory| directory.close(io),
        }
        var index = self.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = self.nodes[index];
            if (node.directory) |directory| directory.close(io);
            if (node.symlink) |link| link.close(io);
            if (node.link_target) |target| allocator.free(target);
            allocator.free(node.name);
        }
        allocator.free(self.nodes);
        allocator.free(self.basename);
        allocator.free(self.resolved_path);
        self.root.close(io);
    }
};

const CapturedInputFile = struct {
    snapshot: Snapshot,
    resolved_path: []const u8,
};

const DereferencedTarget = struct {
    link_path: []const u8,
    link_target: []const u8,
    link_identity: SourceIdentity,
    link_handle: File,
    root: Dir,
    root_identity: SourceIdentity,
    directories: []const AnchoredTargetDirectory,
    basename: []const u8,
    entry_identity: SourceIdentity,
    file: File,
    file_identity: SourceIdentity,
    guard_root: []const u8,
    guard_index: usize,

    fn verify(
        self: *DereferencedTarget,
        allocator: Allocator,
        io: Io,
        monitor: *MutationMonitor,
        protections: []ProtectedTree,
    ) !void {
        monitor.check(protections, null, null) catch
            return error.InputChanged;
        const current = buildTreeManifest(
            allocator,
            io,
            .cwd(),
            self.guard_root,
        ) catch return error.InputChanged;
        const protected = &protections[self.guard_index];
        if (!protected.manifest.matches(current) and
            !(protected.namespace_changed and
                protected.manifest.matchesAfterRootRename(current)))
        {
            return error.InputChanged;
        }
        monitor.check(protections, null, null) catch
            return error.InputChanged;
        if (!self.root_identity.entry.matches(try self.root.stat(io))) {
            return error.InputChanged;
        }
        var parent = self.root;
        for (self.directories) |anchored| {
            if (!anchored.identity.entry.matches(try parent.statFile(
                io,
                anchored.name,
                .{ .follow_symlinks = false },
            )) or
                !anchored.identity.entry.matches(try anchored.directory.stat(io)))
            {
                return error.InputChanged;
            }
            parent = anchored.directory;
        }
        if (!self.entry_identity.entry.matches(try parent.statFile(
            io,
            self.basename,
            .{ .follow_symlinks = false },
        )) or
            !self.file_identity.matchesRetained(try self.file.stat(io)))
        {
            return error.InputChanged;
        }
    }
    fn deinit(self: *DereferencedTarget, allocator: Allocator, io: Io) void {
        self.link_handle.close(io);
        self.file.close(io);
        var index = self.directories.len;
        while (index > 0) {
            index -= 1;
            self.directories[index].directory.close(io);
        }
        allocator.free(self.directories);
        self.root.close(io);
    }
};

const SymlinkReadBarrierPoint = enum {
    first_before,
    first_after,
    second_before,
    second_after,
};

const Snapshot = struct {
    path: []const u8,
    storage_path: []const u8,
    digest: []const u8,
    protection: usize,
};

const ChildOutput = struct {
    path: []const u8,
    storage_path: []const u8,
    relative: []const u8,
    protection: ?usize = null,
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

const InputSnapshots = struct {
    source: InputSnapshot,
    initializer: ?InputSnapshot,
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

const AotRuntime = struct {
    weval: Snapshot,
    weval_tree_digest: []const u8,
    retained_weval: aot_pipeline.RetainedSnapshotExecutable,
    weval_is_bash_script: bool,
    cache: Snapshot,
    manifest: Snapshot,
    validated: aot_cache.Validated,
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

const ManifestEntry = struct {
    path: []const u8,
    kind: File.Kind,
    device_major: u32,
    device_minor: u32,
    inode: File.INode,
    nlink: File.NLink,
    size: u64,
    mode: std.posix.mode_t,
    mtime: Io.Timestamp,
    ctime: Io.Timestamp,
    link_target: ?[]const u8,
    content_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    fn matches(self: ManifestEntry, other: ManifestEntry) bool {
        return std.mem.eql(u8, self.path, other.path) and
            self.kind == other.kind and
            self.device_major == other.device_major and
            self.device_minor == other.device_minor and
            self.inode == other.inode and
            self.nlink == other.nlink and
            self.size == other.size and
            self.mode == other.mode and
            self.mtime.nanoseconds == other.mtime.nanoseconds and
            self.ctime.nanoseconds == other.ctime.nanoseconds and
            optionalBytesEqual(self.link_target, other.link_target) and
            std.mem.eql(
                u8,
                &self.content_digest,
                &other.content_digest,
            );
    }
};

const TreeManifest = struct {
    entries: []const ManifestEntry,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,

    fn matches(self: TreeManifest, other: TreeManifest) bool {
        if (!std.mem.eql(u8, &self.digest, &other.digest) or
            self.entries.len != other.entries.len)
        {
            return false;
        }
        for (self.entries, other.entries) |expected, actual| {
            if (!expected.matches(actual)) return false;
        }
        return true;
    }

    fn matchesAfterRootRename(
        self: TreeManifest,
        other: TreeManifest,
    ) bool {
        if (self.entries.len != other.entries.len) return false;
        for (self.entries, other.entries) |expected, actual| {
            if (!std.mem.eql(u8, expected.path, actual.path) or
                expected.kind != actual.kind or
                expected.device_major != actual.device_major or
                expected.device_minor != actual.device_minor or
                expected.inode != actual.inode or
                expected.nlink != actual.nlink or
                expected.size != actual.size or
                expected.mode != actual.mode or
                expected.mtime.nanoseconds != actual.mtime.nanoseconds or
                (!std.mem.eql(u8, expected.path, ".") and
                    expected.ctime.nanoseconds != actual.ctime.nanoseconds) or
                !optionalBytesEqual(
                    expected.link_target,
                    actual.link_target,
                ) or
                !std.mem.eql(
                    u8,
                    &expected.content_digest,
                    &actual.content_digest,
                ))
            {
                return false;
            }
        }
        return true;
    }

    fn matchesAfterObservedRootRename(
        self: TreeManifest,
        other: TreeManifest,
        rename_observed: bool,
    ) bool {
        return rename_observed and self.matchesAfterRootRename(other);
    }

    fn matchesWithAdditions(
        self: TreeManifest,
        other: TreeManifest,
    ) bool {
        if (other.entries.len < self.entries.len) return false;
        for (self.entries) |expected| {
            var actual: ?ManifestEntry = null;
            for (other.entries) |candidate| {
                if (std.mem.eql(u8, expected.path, candidate.path)) {
                    actual = candidate;
                    break;
                }
            }
            const retained = actual orelse return false;
            if (std.mem.eql(u8, expected.path, ".")) {
                if (expected.kind != retained.kind or
                    expected.device_major != retained.device_major or
                    expected.device_minor != retained.device_minor or
                    expected.inode != retained.inode or
                    expected.mode != retained.mode or
                    !optionalBytesEqual(
                        expected.link_target,
                        retained.link_target,
                    ))
                {
                    return false;
                }
            } else if (!expected.matches(retained)) {
                return false;
            }
        }
        return true;
    }

    fn matchesDebugMerge(
        self: TreeManifest,
        backup: ?TreeManifest,
        other: TreeManifest,
    ) bool {
        if (!self.matchesWithAdditions(other)) return false;
        const source = backup orelse
            return self.entries.len == other.entries.len;
        var expected_count = self.entries.len;
        for (source.entries) |expected| {
            if (std.mem.eql(u8, expected.path, ".") or
                isGeneratedDebugPath(expected.path))
            {
                continue;
            }
            expected_count += 1;
            var matched = false;
            for (other.entries) |actual| {
                if (!std.mem.eql(u8, expected.path, actual.path)) continue;
                if (!copiedManifestEntryMatches(expected, actual)) {
                    return false;
                }
                matched = true;
                break;
            }
            if (!matched) return false;
        }
        return expected_count == other.entries.len;
    }
};

fn isGeneratedDebugPath(path: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    return isGeneratedDebugName(path[0..end]);
}

fn copiedManifestEntryMatches(
    expected: ManifestEntry,
    actual: ManifestEntry,
) bool {
    if (expected.kind != actual.kind or
        expected.mode != actual.mode or
        (expected.kind != .directory and expected.size != actual.size) or
        !optionalBytesEqual(expected.link_target, actual.link_target))
    {
        return false;
    }
    return expected.kind == .directory or std.mem.eql(
        u8,
        &expected.content_digest,
        &actual.content_digest,
    );
}

fn manifestContainsPath(manifest: TreeManifest, path: []const u8) bool {
    for (manifest.entries) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

const ProtectionLocation = enum {
    storage,
    publication,
};

const ProtectedTree = struct {
    location: ProtectionLocation,
    path: []const u8,
    manifest: TreeManifest,
    active: bool = true,
    strict: bool = false,
    namespace_changed: bool = false,
    attribute_changed: bool = false,
};

const IntegrityWatch = struct {
    descriptor: i32,
    protection: usize,
    root: bool,
};

const MutationMonitor = struct {
    descriptor: ?std.posix.fd_t,
    watches: std.ArrayList(IntegrityWatch) = .empty,

    fn init() !MutationMonitor {
        if (builtin.os.tag != .linux) return .{ .descriptor = null };
        const linux = std.os.linux;
        while (true) {
            const result = linux.inotify_init1(
                linux.IN.CLOEXEC | linux.IN.NONBLOCK,
            );
            switch (linux.errno(result)) {
                .SUCCESS => return .{
                    .descriptor = @intCast(result),
                },
                .INTR => continue,
                .MFILE, .NFILE, .NOMEM => return error.SystemResources,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn deinit(self: *MutationMonitor, allocator: Allocator) void {
        if (self.descriptor) |descriptor| {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.close(descriptor);
            }
        }
        self.watches.deinit(allocator);
    }

    fn add(
        self: *MutationMonitor,
        allocator: Allocator,
        path: []const u8,
        protection: usize,
        root: bool,
    ) !void {
        const descriptor = self.descriptor orelse return;
        const linux = std.os.linux;
        const path_z = try std.posix.toPosixPath(path);
        const mask = linux.IN.MODIFY |
            linux.IN.ATTRIB |
            linux.IN.CLOSE_WRITE |
            linux.IN.MOVED_FROM |
            linux.IN.MOVED_TO |
            linux.IN.CREATE |
            linux.IN.DELETE |
            linux.IN.DELETE_SELF |
            linux.IN.MOVE_SELF |
            linux.IN.UNMOUNT |
            linux.IN.DONT_FOLLOW;
        while (true) {
            const result = linux.inotify_add_watch(
                descriptor,
                &path_z,
                mask,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    self.watches.append(allocator, .{
                        .descriptor = @intCast(result),
                        .protection = protection,
                        .root = root,
                    }) catch @panic("out of memory");
                    return;
                },
                .INTR => continue,
                .ACCES => return error.AccessDenied,
                .NOENT, .NOTDIR => return error.TransactionChanged,
                .NOSPC, .NOMEM => return error.SystemResources,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn check(
        self: *MutationMonitor,
        protections: []ProtectedTree,
        allowed_move: ?usize,
        allowed_additions: ?usize,
    ) !void {
        const descriptor = self.descriptor orelse return;
        const linux = std.os.linux;
        var buffer: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) =
            undefined;
        read_events: while (true) {
            const count = std.posix.read(descriptor, &buffer) catch |err| switch (err) {
                error.WouldBlock => break :read_events,
                else => return err,
            };
            if (count == 0) return error.TransactionChanged;
            var offset: usize = 0;
            while (offset < count) {
                if (count - offset < @sizeOf(linux.inotify_event)) {
                    return error.TransactionChanged;
                }
                const event: *align(1) const linux.inotify_event =
                    @ptrCast(buffer[offset..].ptr);
                const event_size = @sizeOf(linux.inotify_event) + event.len;
                if (event_size > count - offset) {
                    return error.TransactionChanged;
                }
                offset += event_size;
                if (event.mask & linux.IN.Q_OVERFLOW != 0) {
                    return error.TransactionChanged;
                }
                var matched: ?IntegrityWatch = null;
                for (self.watches.items) |watch| {
                    if (watch.descriptor != event.wd) continue;
                    if (matched != null and
                        matched.?.protection != watch.protection)
                    {
                        return error.TransactionChanged;
                    }
                    matched = watch;
                }
                const watch = matched orelse return error.TransactionChanged;
                if (!protections[watch.protection].active) {
                    continue;
                }
                if (allowed_move) |protection| {
                    if (watch.protection == protection and watch.root and
                        event.mask & ~@as(u32, linux.IN.MOVE_SELF) == 0)
                    {
                        continue;
                    }
                }
                if (allowed_additions) |protection| {
                    if (watch.protection == protection and watch.root and
                        event.len != 0)
                    {
                        const name_bytes = buffer[offset - event.len .. offset];
                        const name_end = std.mem.indexOfScalar(
                            u8,
                            name_bytes,
                            0,
                        ) orelse name_bytes.len;
                        if (name_end != 0 and
                            !isGeneratedDebugName(name_bytes[0..name_end]))
                        {
                            continue;
                        }
                    }
                }
                if (isNamespaceOnlyMutation(event.mask)) {
                    if (watch.root and
                        event.mask & std.os.linux.IN.MOVE_SELF != 0)
                    {
                        protections[watch.protection].namespace_changed = true;
                    }
                    continue;
                }
                if (watch.root and
                    event.mask & ~@as(u32, std.os.linux.IN.ATTRIB) == 0)
                {
                    protections[watch.protection].attribute_changed = true;
                    continue;
                }
                return error.TransactionChanged;
            }
        }
        for (protections) |protected| {
            if (protected.active and protected.attribute_changed and
                !protected.namespace_changed)
            {
                return error.TransactionChanged;
            }
        }
    }
};

fn isNamespaceOnlyMutation(mask: u32) bool {
    if (builtin.os.tag != .linux) return false;
    const linux = std.os.linux;
    const namespace_actions = linux.IN.MOVED_FROM |
        linux.IN.MOVED_TO |
        linux.IN.MOVE_SELF |
        linux.IN.CREATE |
        linux.IN.DELETE;
    const namespace_events = namespace_actions | linux.IN.ISDIR;
    return mask & namespace_actions != 0 and
        mask & ~@as(u32, namespace_events) == 0;
}

const SourceManifestGuard = struct {
    root: []const u8,
    protected: [1]ProtectedTree,
    monitor: MutationMonitor,

    fn init(
        allocator: Allocator,
        io: Io,
        root: []const u8,
    ) !SourceManifestGuard {
        if (!std.fs.path.isAbsolute(root)) return error.InvalidPath;
        const manifest = try buildTreeManifest(
            allocator,
            io,
            .cwd(),
            root,
        );
        var guard = SourceManifestGuard{
            .root = try allocator.dupe(u8, root),
            .protected = .{.{
                .location = .storage,
                .path = root,
                .manifest = manifest,
            }},
            .monitor = try MutationMonitor.init(),
        };
        errdefer guard.monitor.deinit(allocator);
        for (manifest.entries) |entry| {
            if (entry.kind == .sym_link and
                !std.mem.eql(u8, entry.path, "."))
            {
                continue;
            }
            const absolute = if (std.mem.eql(u8, entry.path, "."))
                root
            else
                try std.fs.path.join(
                    allocator,
                    &.{ root, entry.path },
                );
            try guard.monitor.add(
                allocator,
                absolute,
                0,
                std.mem.eql(u8, entry.path, "."),
            );
        }
        try guard.monitor.check(&guard.protected, null, null);
        const confirmed = try buildTreeManifest(
            allocator,
            io,
            .cwd(),
            root,
        );
        if (!manifest.matches(confirmed)) return error.InputChanged;
        try guard.monitor.check(&guard.protected, null, null);
        return guard;
    }

    fn verify(
        self: *SourceManifestGuard,
        allocator: Allocator,
        io: Io,
    ) !void {
        self.monitor.check(&self.protected, null, null) catch
            return error.InputChanged;
        const current = buildTreeManifest(
            allocator,
            io,
            .cwd(),
            self.root,
        ) catch return error.InputChanged;
        if (!self.protected[0].manifest.matches(current)) {
            return error.InputChanged;
        }
        self.monitor.check(&self.protected, null, null) catch
            return error.InputChanged;
    }

    fn deinit(self: *SourceManifestGuard, allocator: Allocator) void {
        self.monitor.deinit(allocator);
    }
};

const ChildAnchor = struct {
    storage_path: []const u8,
    child_path: []const u8,
    identity: EntryIdentity,
    source_identity: ?SourceIdentity,
    handle: union(enum) {
        file: File,
        directory: Dir,

        fn raw(self: @This()) std.posix.fd_t {
            return switch (self) {
                .file => |file| file.handle,
                .directory => |directory| directory.handle,
            };
        }

        fn stat(self: @This(), io: Io) !File.Stat {
            return switch (self) {
                .file => |file| file.stat(io),
                .directory => |directory| directory.stat(io),
            };
        }

        fn close(self: @This(), io: Io) void {
            switch (self) {
                .file => |file| file.close(io),
                .directory => |directory| directory.close(io),
            }
        }
    },
};

const EffectiveCache = struct {
    path: []const u8,
    identity: EntryIdentity,
    directory: Dir,
    anchor: ?RetainedInputPath = null,

    fn verifyCanonical(self: *const EffectiveCache, io: Io) !void {
        if (!self.identity.matches(try self.directory.stat(io))) {
            return error.CacheDirectoryChanged;
        }
        if (self.anchor) |*anchor| {
            anchor.verifyMutableDirectory(io) catch
                return error.CacheDirectoryChanged;
        }
    }

    fn deinit(self: *EffectiveCache, allocator: Allocator, io: Io) void {
        if (self.anchor) |*anchor| {
            anchor.deinit(allocator, io);
        } else {
            self.directory.close(io);
        }
    }
};

const CacheDirectory = struct {
    name: []const u8,
    path: []const u8,
    identity: EntryIdentity,
    directory: Dir,

    fn close(self: CacheDirectory, io: Io) void {
        self.directory.close(io);
    }

    fn verify(
        self: *const CacheDirectory,
        parent: Dir,
        io: Io,
    ) !void {
        if (!self.identity.matches(try self.directory.stat(io)) or
            !try entryHasIdentity(parent, io, self.name, self.identity))
        {
            return error.CacheDirectoryChanged;
        }
    }
};

const CacheLock = struct {
    name: []const u8,
    identity: EntryIdentity,
    file: File,
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
    allocator: Allocator,
    name: []const u8,
    cleanup_name: []const u8,
    storage_path: []const u8,
    publication_path: []const u8,
    publication: Dir,
    publication_anchor: RetainedInputPath,
    root: Dir,
    storage: Dir,
    publication_identity: EntryIdentity,
    root_identity: EntryIdentity,
    storage_identity: EntryIdentity,
    owner_identity: EntryIdentity,
    environ: *std.process.Environ.Map,
    owned: std.ArrayList(OwnedEntry) = .empty,
    child_anchors: std.ArrayList(ChildAnchor) = .empty,
    protected: std.ArrayList(ProtectedTree) = .empty,
    mutation_monitor: MutationMonitor,

    fn create(
        allocator: Allocator,
        io: Io,
        publication_anchor: RetainedInputPath,
        name: []const u8,
        owner: []const u8,
        environ: *std.process.Environ.Map,
    ) !Transaction {
        const publication = switch (publication_anchor.entry) {
            .directory => |directory| directory,
            .file => return error.PublicationDirectoryChanged,
        };
        publication_anchor.verifyMutableDirectory(io) catch
            return error.PublicationDirectoryChanged;
        const publication_path = publication_anchor.resolved_path;
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
        var mutation_monitor = try MutationMonitor.init();
        errdefer mutation_monitor.deinit(allocator);

        return .{
            .allocator = allocator,
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
            .publication_anchor = publication_anchor,
            .root = root,
            .storage = storage,
            .publication_identity = publication_identity,
            .root_identity = root_identity,
            .storage_identity = storage_identity,
            .owner_identity = owner_identity,
            .environ = environ,
            .mutation_monitor = mutation_monitor,
        };
    }

    fn deinit(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        safe_to_remove: bool,
    ) void {
        if (safe_to_remove) self.cleanup(allocator, io) catch {};
        for (self.child_anchors.items) |anchor| anchor.handle.close(io);
        self.storage.close(io);
        self.root.close(io);
        self.publication_anchor.deinit(allocator, io);
        self.child_anchors.deinit(allocator);
        self.owned.deinit(allocator);
        self.mutation_monitor.deinit(allocator);
        self.protected.deinit(allocator);
    }

    fn retainStorageFile(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
        mutable: bool,
    ) ![]const u8 {
        for (self.child_anchors.items) |anchor| {
            if (std.mem.eql(u8, anchor.storage_path, path)) {
                if (anchor.handle != .file) return error.TransactionChanged;
                return anchor.child_path;
            }
        }
        const expected = self.ownedIdentity(path) orelse
            return error.TransactionChanged;
        var file = try self.storage.openFile(io, path, .{
            .mode = if (mutable) .read_write else .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        });
        errdefer file.close(io);
        const stat = file.stat(io) catch |err| {
            file.close(io);
            return err;
        };
        if (!expected.matches(stat) or
            !try entryHasIdentity(self.storage, io, path, expected))
        {
            return error.TransactionChanged;
        }
        try setFileInherited(file, false);
        const child_path = try stableHandlePath(
            allocator,
            file.handle,
            try std.fs.path.join(allocator, &.{ self.storage_path, path }),
        );
        self.child_anchors.append(allocator, .{
            .storage_path = try allocator.dupe(u8, path),
            .child_path = child_path,
            .identity = expected,
            .source_identity = if (mutable)
                null
            else
                SourceIdentity.fromStat(stat),
            .handle = .{ .file = file },
        }) catch @panic("out of memory");
        return child_path;
    }

    fn retainStorageDirectory(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) ![]const u8 {
        for (self.child_anchors.items) |anchor| {
            if (std.mem.eql(u8, anchor.storage_path, path)) {
                if (anchor.handle != .directory) return error.TransactionChanged;
                return anchor.child_path;
            }
        }
        const expected = self.ownedIdentity(path) orelse
            return error.TransactionChanged;
        var directory = try self.storage.openDir(
            io,
            path,
            .{ .iterate = true, .follow_symlinks = false },
        );
        errdefer directory.close(io);
        const stat = try directory.stat(io);
        if (!expected.matches(stat) or
            !try entryHasIdentity(self.storage, io, path, expected))
        {
            return error.TransactionChanged;
        }
        try setDirectoryInherited(directory, false);
        const child_path = try stableHandlePath(
            allocator,
            directory.handle,
            try std.fs.path.join(allocator, &.{ self.storage_path, path }),
        );
        self.child_anchors.append(allocator, .{
            .storage_path = try allocator.dupe(u8, path),
            .child_path = child_path,
            .identity = expected,
            .source_identity = null,
            .handle = .{ .directory = directory },
        }) catch @panic("out of memory");
        return child_path;
    }

    fn retainStorageDirectoryForDescendants(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) ![]const u8 {
        const child_path = try self.retainStorageDirectory(
            allocator,
            io,
            path,
        );
        if (builtin.os.tag != .linux) return child_path;
        for (self.child_anchors.items) |anchor| {
            if (!std.mem.eql(u8, anchor.storage_path, path)) continue;
            const directory = switch (anchor.handle) {
                .directory => |value| value,
                .file => return error.TransactionChanged,
            };
            return stableDescendantHandlePath(
                allocator,
                directory.handle,
                child_path,
            );
        }
        unreachable;
    }

    fn sealChildOutput(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        output: *ChildOutput,
    ) !void {
        if (output.protection != null) return error.TransactionChanged;
        for (self.child_anchors.items) |*anchor| {
            if (!std.mem.eql(u8, anchor.storage_path, output.relative)) {
                continue;
            }
            const old_file = switch (anchor.handle) {
                .file => |file| file,
                .directory => return error.TransactionChanged,
            };
            try old_file.sync(io);
            const initial = try old_file.stat(io);
            if (!anchor.identity.matches(initial) or initial.kind != .file) {
                return error.TransactionChanged;
            }
            try old_file.setPermissions(
                io,
                .fromMode(
                    initial.permissions.toMode() &
                        ~@as(std.posix.mode_t, 0o222),
                ),
            );
            try old_file.sync(io);
            const sealed_stat = try old_file.stat(io);
            if (!anchor.identity.matches(sealed_stat) or
                !try entryHasIdentity(
                    self.storage,
                    io,
                    output.relative,
                    anchor.identity,
                ))
            {
                return error.TransactionChanged;
            }
            var replacement = try self.storage.openFile(
                io,
                output.relative,
                .{
                    .mode = .read_only,
                    .allow_directory = false,
                    .follow_symlinks = false,
                },
            );
            errdefer replacement.close(io);
            const replacement_stat = try replacement.stat(io);
            if (!SourceIdentity.fromStat(sealed_stat).matches(
                replacement_stat,
            )) {
                return error.TransactionChanged;
            }
            try setFileInherited(replacement, false);
            const child_path = try stableHandlePath(
                allocator,
                replacement.handle,
                output.storage_path,
            );
            try setFileInherited(old_file, false);
            old_file.close(io);
            anchor.handle = .{ .file = replacement };
            anchor.child_path = child_path;
            anchor.source_identity = SourceIdentity.fromStat(
                replacement_stat,
            );
            output.path = child_path;
            output.protection = try self.protectStoragePath(
                allocator,
                io,
                output.relative,
            );
            return;
        }
        return error.TransactionChanged;
    }

    fn sealStorageTree(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !usize {
        var directory = try self.storage.openDir(
            io,
            path,
            .{ .iterate = true, .follow_symlinks = false },
        );
        defer directory.close(io);
        try sealSnapshotDirectory(io, directory);
        return self.protectStoragePath(allocator, io, path);
    }

    fn sealStorageFile(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !usize {
        var file = try self.storage.openFile(io, path, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
        });
        var file_open = true;
        defer if (file_open) file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.TransactionChanged;
        try file.setPermissions(
            io,
            .fromMode(
                stat.permissions.toMode() &
                    ~@as(std.posix.mode_t, 0o222),
            ),
        );
        try file.sync(io);
        file.close(io);
        file_open = false;
        return self.protectStoragePath(allocator, io, path);
    }

    fn verifyChildAnchors(self: *const Transaction, io: Io) !void {
        try self.verifyAttached(io);
        for (self.child_anchors.items) |anchor| {
            const stat = try anchor.handle.stat(io);
            if (!anchor.identity.matches(stat) or
                !try entryHasIdentity(
                    self.storage,
                    io,
                    anchor.storage_path,
                    anchor.identity,
                ))
            {
                return error.TransactionChanged;
            }
            if (anchor.source_identity) |identity| {
                if (!identity.entry.matches(stat) or
                    identity.size != stat.size or
                    identity.mtime.nanoseconds != stat.mtime.nanoseconds)
                {
                    return error.TransactionChanged;
                }
            }
        }
        try self.verifyAttached(io);
    }

    fn verifyChildHandleIdentities(
        self: *const Transaction,
        io: Io,
    ) !void {
        for (self.child_anchors.items) |anchor| {
            const stat = try anchor.handle.stat(io);
            if (!anchor.identity.matches(stat)) {
                return error.TransactionChanged;
            }
            if (anchor.source_identity) |identity| {
                if (!identity.entry.matches(stat) or
                    identity.size != stat.size or
                    identity.mtime.nanoseconds != stat.mtime.nanoseconds)
                {
                    return error.TransactionChanged;
                }
            }
        }
    }

    fn prepareChild(self: *Transaction, io: Io) !void {
        try self.verifyIntegrity(self.allocator, io);
        try self.verifyChildAnchors(io);
        var inherited_count: usize = 0;
        errdefer {
            while (inherited_count > 0) {
                inherited_count -= 1;
                setHandleInherited(
                    self.child_anchors.items[inherited_count].handle.raw(),
                    false,
                ) catch {};
            }
        }
        for (self.child_anchors.items) |anchor| {
            try setHandleInherited(anchor.handle.raw(), true);
            inherited_count += 1;
        }
    }

    fn finishChild(self: *Transaction, io: Io) !void {
        var first_error: ?anyerror = null;
        for (self.child_anchors.items) |anchor| {
            setHandleInherited(anchor.handle.raw(), false) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        self.verifyChildAnchors(io) catch |err| {
            if (first_error == null) first_error = err;
        };
        self.verifyIntegrity(self.allocator, io) catch |err| {
            if (first_error == null) first_error = err;
        };
        if (first_error) |err| return err;
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
        self.publication_anchor.verifyMutableDirectory(io) catch
            return error.PublicationDirectoryChanged;
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

    fn directoryForLocation(
        self: *const Transaction,
        location: ProtectionLocation,
    ) Dir {
        return switch (location) {
            .storage => self.storage,
            .publication => self.publication,
        };
    }

    fn absoluteProtectedPath(
        self: *const Transaction,
        allocator: Allocator,
        location: ProtectionLocation,
        path: []const u8,
    ) ![]const u8 {
        const fallback = switch (location) {
            .storage => self.storage_path,
            .publication => self.publication_path,
        };
        const root = try stableHandlePath(
            allocator,
            self.directoryForLocation(location).handle,
            fallback,
        );
        return std.fs.path.join(allocator, &.{
            root,
            path,
        });
    }

    fn protectPath(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        location: ProtectionLocation,
        path: []const u8,
    ) !usize {
        for (self.protected.items, 0..) |protected, index| {
            if (!protected.active or protected.location != location or
                !std.mem.eql(u8, protected.path, path))
            {
                continue;
            }
            const current = try buildTreeManifest(
                allocator,
                io,
                self.directoryForLocation(location),
                path,
            );
            if (!protected.manifest.matches(current)) {
                return error.TransactionChanged;
            }
            return index;
        }
        const manifest = try buildTreeManifest(
            allocator,
            io,
            self.directoryForLocation(location),
            path,
        );
        const index = self.protected.items.len;
        self.protected.append(allocator, .{
            .location = location,
            .path = try allocator.dupe(u8, path),
            .manifest = manifest,
        }) catch @panic("out of memory");
        const absolute_root = try self.absoluteProtectedPath(
            allocator,
            location,
            path,
        );
        for (manifest.entries) |entry| {
            if (entry.kind == .sym_link) continue;
            const absolute = if (std.mem.eql(u8, entry.path, "."))
                absolute_root
            else
                try std.fs.path.join(
                    allocator,
                    &.{ absolute_root, entry.path },
                );
            try self.mutation_monitor.add(
                allocator,
                absolute,
                index,
                std.mem.eql(u8, entry.path, "."),
            );
        }
        try self.mutation_monitor.check(self.protected.items, null, null);
        const confirmed = try buildTreeManifest(
            allocator,
            io,
            self.directoryForLocation(location),
            path,
        );
        if (!manifest.matches(confirmed)) return error.TransactionChanged;
        try self.mutation_monitor.check(self.protected.items, null, null);
        return index;
    }

    fn protectStoragePath(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !usize {
        return self.protectPath(allocator, io, .storage, path);
    }

    fn protectPublicationPath(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        path: []const u8,
    ) !usize {
        return self.protectPath(allocator, io, .publication, path);
    }

    fn refreshProtectedStorageAdditions(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        protection: usize,
        additions: ?TreeManifest,
    ) !void {
        if (protection >= self.protected.items.len) {
            return error.TransactionChanged;
        }
        const protected = &self.protected.items[protection];
        if (!protected.active or protected.location != .storage) {
            return error.TransactionChanged;
        }
        try self.mutation_monitor.check(self.protected.items, null, protection);
        const previous = protected.manifest;
        const current = try buildTreeManifest(
            allocator,
            io,
            self.storage,
            protected.path,
        );
        if (!previous.matchesDebugMerge(additions, current)) {
            return error.TransactionChanged;
        }
        const absolute_root = try self.absoluteProtectedPath(
            allocator,
            .storage,
            protected.path,
        );
        for (current.entries) |entry| {
            if (entry.kind == .sym_link or
                manifestContainsPath(previous, entry.path))
            {
                continue;
            }
            const absolute = if (std.mem.eql(u8, entry.path, "."))
                absolute_root
            else
                try std.fs.path.join(
                    allocator,
                    &.{ absolute_root, entry.path },
                );
            try self.mutation_monitor.add(
                allocator,
                absolute,
                protection,
                false,
            );
        }
        protected.manifest = current;
        try self.mutation_monitor.check(self.protected.items, null, protection);
        const confirmed = try buildTreeManifest(
            allocator,
            io,
            self.storage,
            protected.path,
        );
        if (!current.matches(confirmed)) return error.TransactionChanged;
        protected.manifest = confirmed;
    }

    fn verifyProtectedManifests(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
    ) !void {
        for (self.protected.items) |*protected| {
            if (!protected.active) continue;
            if (protected.strict and
                (protected.namespace_changed or protected.attribute_changed))
            {
                return error.TransactionChanged;
            }
            const current = buildTreeManifest(
                allocator,
                io,
                self.directoryForLocation(protected.location),
                protected.path,
            ) catch return error.TransactionChanged;
            if (!protected.manifest.matches(current)) {
                if (builtin.os.tag != .linux or
                    !protected.manifest.matchesAfterObservedRootRename(
                        current,
                        protected.namespace_changed,
                    ))
                {
                    return error.TransactionChanged;
                }
                protected.manifest = current;
            }
            protected.namespace_changed = false;
            protected.attribute_changed = false;
        }
    }

    fn verifyIntegrity(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
    ) !void {
        try self.mutation_monitor.check(self.protected.items, null, null);
        try self.verifyProtectedManifests(allocator, io);
        try self.mutation_monitor.check(self.protected.items, null, null);
    }

    fn verifyRetainedIntegrity(self: *Transaction) !void {
        try self.mutation_monitor.check(self.protected.items, null, null);
    }

    fn moveProtected(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        protection: usize,
        new_location: ProtectionLocation,
        new_path: []const u8,
    ) !void {
        if (protection >= self.protected.items.len or
            !self.protected.items[protection].active)
        {
            return error.TransactionChanged;
        }
        try self.verifyIntegrity(allocator, io);
        const old_location = self.protected.items[protection].location;
        const old_path = self.protected.items[protection].path;
        const old_manifest = self.protected.items[protection].manifest;
        const owned_new_path = try allocator.dupe(u8, new_path);
        try self.directoryForLocation(old_location).renamePreserve(
            old_path,
            self.directoryForLocation(new_location),
            new_path,
            io,
        );
        self.protected.items[protection].location = new_location;
        self.protected.items[protection].path = owned_new_path;
        self.mutation_monitor.check(
            self.protected.items,
            protection,
            null,
        ) catch |move_error| return self.failProtectedMove(
            allocator,
            io,
            protection,
            old_location,
            old_path,
            old_manifest,
            move_error,
        );
        const moved_manifest = buildTreeManifest(
            allocator,
            io,
            self.directoryForLocation(new_location),
            new_path,
        ) catch |move_error| return self.failProtectedMove(
            allocator,
            io,
            protection,
            old_location,
            old_path,
            old_manifest,
            move_error,
        );
        if (!old_manifest.matchesAfterRootRename(moved_manifest)) {
            return self.failProtectedMove(
                allocator,
                io,
                protection,
                old_location,
                old_path,
                old_manifest,
                error.TransactionChanged,
            );
        }
        self.protected.items[protection].manifest = moved_manifest;
        self.protected.items[protection].namespace_changed = false;
        self.protected.items[protection].attribute_changed = false;
        self.verifyProtectedManifests(allocator, io) catch |move_error|
            return self.failProtectedMove(
                allocator,
                io,
                protection,
                old_location,
                old_path,
                old_manifest,
                move_error,
            );
        self.mutation_monitor.check(
            self.protected.items,
            null,
            null,
        ) catch |move_error| return self.failProtectedMove(
            allocator,
            io,
            protection,
            old_location,
            old_path,
            old_manifest,
            move_error,
        );
    }

    fn failProtectedMove(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        protection: usize,
        old_location: ProtectionLocation,
        old_path: []const u8,
        old_manifest: TreeManifest,
        move_error: anyerror,
    ) anyerror {
        self.restoreProtectedMove(
            allocator,
            io,
            protection,
            old_location,
            old_path,
            old_manifest,
        ) catch return error.RollbackIncomplete;
        return move_error;
    }

    fn restoreProtectedMove(
        self: *Transaction,
        allocator: Allocator,
        io: Io,
        protection: usize,
        old_location: ProtectionLocation,
        old_path: []const u8,
        old_manifest: TreeManifest,
    ) !void {
        const moved = self.protected.items[protection];
        try self.directoryForLocation(moved.location).renamePreserve(
            moved.path,
            self.directoryForLocation(old_location),
            old_path,
            io,
        );
        self.protected.items[protection].location = old_location;
        self.protected.items[protection].path = old_path;
        self.mutation_monitor.check(
            self.protected.items,
            protection,
            null,
        ) catch {};
        const restored = try buildTreeManifest(
            allocator,
            io,
            self.directoryForLocation(old_location),
            old_path,
        );
        if (!old_manifest.matchesAfterRootRename(restored)) {
            return error.RollbackIncomplete;
        }
        self.protected.items[protection].manifest = restored;
        self.protected.items[protection].namespace_changed = false;
        self.protected.items[protection].attribute_changed = false;
    }

    fn withdrawPublished(
        self: *Transaction,
        io: Io,
        protection: usize,
        destination: []const u8,
        staged: []const u8,
        identity: EntryIdentity,
    ) !void {
        if (protection >= self.protected.items.len) {
            return error.TransactionChanged;
        }
        const protected = &self.protected.items[protection];
        if (!protected.active or protected.location != .publication or
            !std.mem.eql(u8, protected.path, destination) or
            !try entryHasIdentity(
                self.publication,
                io,
                destination,
                identity,
            ))
        {
            return error.TransactionChanged;
        }
        try self.publication.renamePreserve(
            destination,
            self.storage,
            staged,
            io,
        );
        protected.location = .storage;
        protected.path = staged;
        protected.active = false;
        if (!try entryHasIdentity(self.storage, io, staged, identity)) {
            return error.TransactionChanged;
        }
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

    fn verifyOwnedSubtreeExact(
        self: *const Transaction,
        allocator: Allocator,
        io: Io,
        directory: Dir,
        relative: []const u8,
    ) !void {
        try self.verifyOwnedDirectory(
            allocator,
            io,
            directory,
            relative,
        );
        for (self.owned.items) |entry| {
            if (!std.mem.eql(u8, entry.path, relative) and
                !pathContains(relative, entry.path))
            {
                continue;
            }
            const stat = try self.storage.statFile(
                io,
                entry.path,
                .{ .follow_symlinks = false },
            );
            if (!entry.identity.matches(stat)) {
                return error.TransactionChanged;
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
    surface_target_wit: ?[]const u8,
    surface_target_world: ?[]const u8,
    platform_wit: []const u8,
    features: feature_surface.Features,
    bindings: ?[]const u8,
    dispatch_wit_digest: ?[]const u8,
    component_wit_digest: ?[]const u8,
    features_known: bool,
    zig: ?ZigSnapshot,
    build_tools: []const metadata.Tool,
    build_root_digest: ?[]const u8,
    cache_lock: ?File,
    aot: ?AotRuntime,
};

const EngineProvenance = struct {
    host_api: []const u8,
    features: feature_surface.Features,
    component_world: []const u8,
    surface_world: []const u8,
};

const FeatureManifest = struct {
    @"host-api": []const u8,
    @"component-world": []const u8,
    @"surface-world": []const u8,
    stdio: bool,
    random: bool,
    clocks: bool,
    http: bool,
    @"fetch-event": bool,
};

const WizerTool = struct {
    executable: Snapshot,
    wasmtime_subcommand: bool,
};

const Tools = struct {
    wizer: ?WizerTool,
    wabt: Snapshot,
    wasm_tools: Snapshot,
};

const FeatureSurfaceCommandContext = struct {
    diagnostic: *diagnostics.Context,
    transaction: *Transaction,
    transaction_storage: []const u8,
    environ: *const std.process.Environ.Map,
    snapshot_index: usize = 0,
};

fn runFeatureSurfaceCommand(
    context_ptr: *anyopaque,
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    verbose: bool,
    command_log: ?*std.ArrayList(u8),
) !void {
    const context: *FeatureSurfaceCommandContext = @ptrCast(@alignCast(context_ptr));
    context.diagnostic.begin(.adapt);
    runCommand(
        allocator,
        io,
        stage,
        argv,
        cwd,
        context.environ,
        null,
        verbose,
        command_log orelse @panic("missing feature-surface command log"),
        context.diagnostic,
        context.transaction_storage,
        context.transaction,
    ) catch |err| {
        try recordFeatureSurfaceWork(allocator, io, context.transaction);
        return err;
    };
    try recordFeatureSurfaceWork(allocator, io, context.transaction);
}

fn featureSurfaceStorageRelative(
    allocator: Allocator,
    transaction: *const Transaction,
    absolute: []const u8,
) ![]const u8 {
    const relative = try std.fs.path.relative(
        allocator,
        transaction.storage_path,
        null,
        transaction.storage_path,
        absolute,
    );
    if (std.fs.path.isAbsolute(relative) or
        std.mem.eql(u8, relative, "..") or
        std.mem.startsWith(u8, relative, "../"))
    {
        return error.TransactionChanged;
    }
    return relative;
}

fn retainFeatureSurfaceFile(
    context_ptr: *anyopaque,
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    absolute: []const u8,
) ![]const u8 {
    const context: *FeatureSurfaceCommandContext =
        @ptrCast(@alignCast(context_ptr));
    const relative = try featureSurfaceStorageRelative(
        allocator,
        context.transaction,
        absolute,
    );
    const destination_relative = try std.fmt.allocPrint(
        allocator,
        "feature-surface-input-{d}",
        .{context.snapshot_index},
    );
    context.snapshot_index += 1;
    const destination = try std.fs.path.join(
        allocator,
        &.{ context.transaction.storage_path, destination_relative },
    );
    const snapshot = snapshotFileAt(
        allocator,
        io,
        context.transaction.storage,
        relative,
        destination,
        context.transaction,
    ) catch |err| switch (err) {
        error.InputChanged => return error.TransactionChanged,
        else => return err,
    };
    context.transaction.protected.items[snapshot.protection].strict = true;
    try waitForCaptureTestBarrier(
        allocator,
        io,
        context.transaction.environ,
        stage,
    );
    try verifyFeatureSurfaceContext(context, allocator, io);
    return snapshot.path;
}

fn snapshotFeatureSurfaceTree(
    context_ptr: *anyopaque,
    allocator: Allocator,
    io: Io,
    stage: []const u8,
    absolute: []const u8,
) ![]const u8 {
    const context: *FeatureSurfaceCommandContext =
        @ptrCast(@alignCast(context_ptr));
    const transaction = context.transaction;
    const source_relative = try featureSurfaceStorageRelative(
        allocator,
        transaction,
        absolute,
    );
    try transaction.verifyIntegrity(allocator, io);
    var source = try transaction.storage.openDir(
        io,
        source_relative,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source.close(io);
    const source_stat = try source.stat(io);
    const source_identity = SourceIdentity.fromStat(source_stat);

    const destination_relative = try std.fmt.allocPrint(
        allocator,
        "feature-surface-input-{d}",
        .{context.snapshot_index},
    );
    context.snapshot_index += 1;
    try transaction.ensureStorageDirPath(
        allocator,
        io,
        destination_relative,
    );
    var destination = try transaction.storage.openDir(
        io,
        destination_relative,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer destination.close(io);
    var tree_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    _ = copyInputDirectory(
        allocator,
        io,
        source,
        destination,
        source_relative,
        "",
        destination_relative,
        "",
        &.{},
        &.{},
        .reject,
        &.{},
        null,
        &.{},
        transaction,
        &tree_hasher,
    ) catch |err| switch (err) {
        error.InputChanged => return error.TransactionChanged,
        else => return err,
    };
    if (!source_identity.matches(try source.stat(io))) {
        return error.TransactionChanged;
    }
    try sealSnapshotDirectory(io, destination);
    const protection = try transaction.protectStoragePath(
        allocator,
        io,
        destination_relative,
    );
    transaction.protected.items[protection].strict = true;
    const retained = try transaction.retainStorageDirectory(
        allocator,
        io,
        destination_relative,
    );
    try waitForCaptureTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
    );
    try verifyFeatureSurfaceContext(context, allocator, io);
    return retained;
}

fn verifyFeatureSurfaceContext(
    context: *FeatureSurfaceCommandContext,
    allocator: Allocator,
    io: Io,
) !void {
    try context.transaction.verifyIntegrity(allocator, io);
}

fn verifyFeatureSurfaceInputs(
    context_ptr: *anyopaque,
    allocator: Allocator,
    io: Io,
) !void {
    const context: *FeatureSurfaceCommandContext =
        @ptrCast(@alignCast(context_ptr));
    try verifyFeatureSurfaceContext(context, allocator, io);
}

fn setFeatureSurfaceDiagnosticDetail(
    context_ptr: *anyopaque,
    detail: []const u8,
) void {
    const context: *FeatureSurfaceCommandContext =
        @ptrCast(@alignCast(context_ptr));
    context.diagnostic.detail = detail;
}

fn recordFeatureSurfaceWork(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
) !void {
    var work = try transaction.storage.openDir(
        io,
        "feature-surface",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer work.close(io);
    try recordDebugBackupTree(
        allocator,
        io,
        transaction,
        work,
        "feature-surface",
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var diagnostic = diagnostics.Context{
        .allocator = allocator,
        .io = init.io,
        .format = cli.detectDiagnosticFormat(args),
    };
    reserveStandardDescriptors() catch |err| {
        diagnostic.report(err);
        std.process.exit(1);
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

fn reserveStandardDescriptors() !void {
    if (builtin.os.tag != .linux) return;
    for (0..3) |index| {
        const handle: std.posix.fd_t = @intCast(index);
        switch (std.posix.errno(std.posix.system.fcntl(
            handle,
            std.posix.F.GETFD,
            @as(usize, 0),
        ))) {
            .SUCCESS => continue,
            .BADF => {},
            else => return error.SystemResources,
        }
        const replacement = try std.posix.openat(
            std.posix.AT.FDCWD,
            "/dev/null",
            .{ .ACCMODE = .RDWR, .CLOEXEC = false },
            0,
        );
        if (replacement != handle) {
            _ = std.os.linux.close(replacement);
            return error.SystemResources;
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
    const configured_source = config.source orelse config.engine;
    const source_argument = if (configured_source) |path|
        try absolutePath(allocator, cwd, path)
    else
        try allocator.dupe(u8, cwd);
    const source_path = source_argument;
    try validateArgument(source_path);
    const initializer_path = if (config.initializer_script_path) |path|
        try absolutePath(allocator, cwd, path)
    else
        null;

    const output = if (config.output) |path|
        try absolutePath(allocator, cwd, path)
    else
        try defaultOutputPath(allocator, cwd, source_argument);
    try validateArgument(output);
    const output_parent = std.fs.path.dirname(output) orelse return error.InvalidPath;
    var publication_anchor = retainOrCreateAbsoluteDirectory(
        allocator,
        io,
        output_parent,
        environ,
        "output-parent",
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.PublicationDirectoryChanged,
    };
    var publication_transferred = false;
    defer if (!publication_transferred) publication_anchor.deinit(allocator, io);
    const publication_parent = publication_anchor.resolved_path;
    const publication_directory = switch (publication_anchor.entry) {
        .directory => |directory| directory,
        .file => return error.PublicationDirectoryChanged,
    };
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
    if ((configured_source != null and
        std.mem.eql(u8, source_path, resolved_output)) or
        (initializer_path != null and
            std.mem.eql(u8, initializer_path.?, resolved_output)))
    {
        return error.InputOutputCollision;
    }

    const metadata_output = if (config.metadata_out) |path| blk: {
        const destination = try absolutePath(allocator, cwd, path);
        const parent = std.fs.path.dirname(destination) orelse
            return error.InvalidMetadataDestination;
        var parent_anchor = retainOrCreateAbsoluteDirectory(
            allocator,
            io,
            parent,
            environ,
            "metadata-parent",
        ) catch return error.InvalidMetadataDestination;
        defer parent_anchor.deinit(allocator, io);
        try publication_anchor.verifyMutableDirectory(io);
        const parent_directory = switch (parent_anchor.entry) {
            .directory => |directory| directory,
            .file => return error.InvalidMetadataDestination,
        };
        const parent_stat = try parent_directory.stat(io);
        if (!publication_anchor.retained_identity.entry.matches(parent_stat) or
            !deviceIdentityMatches(
                publication_anchor.retained_device,
                try linuxDeviceForHandle(parent_directory.handle),
            ))
        {
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
            (configured_source != null and
                std.mem.eql(u8, resolved, source_path)) or
            (initializer_path != null and
                std.mem.eql(u8, resolved, initializer_path.?)))
        {
            return error.InvalidMetadataDestination;
        }
        break :blk resolved;
    } else null;

    const debug_dir = if (config.debug_bindings) blk: {
        const destination = if (config.debug_dir) |path|
            try absolutePath(allocator, cwd, path)
        else
            try std.fmt.allocPrint(allocator, "{s}.debug", .{output});
        const parent = std.fs.path.dirname(destination) orelse
            return error.DebugOutputCollision;
        var parent_anchor = retainOrCreateAbsoluteDirectory(
            allocator,
            io,
            parent,
            environ,
            "debug-parent",
        ) catch return error.DebugOutputCollision;
        defer parent_anchor.deinit(allocator, io);
        try publication_anchor.verifyMutableDirectory(io);
        const parent_directory = switch (parent_anchor.entry) {
            .directory => |directory| directory,
            .file => return error.DebugOutputCollision,
        };
        const parent_stat = try parent_directory.stat(io);
        if (!publication_anchor.retained_identity.entry.matches(parent_stat) or
            !deviceIdentityMatches(
                publication_anchor.retained_device,
                try linuxDeviceForHandle(parent_directory.handle),
            ))
        {
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
            (configured_source != null and
                pathContains(resolved, source_path)) or
            (initializer_path != null and
                pathContains(resolved, initializer_path.?)) or
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
    var effective_cache: ?EffectiveCache = if (config.cache_dir) |configured|
        try resolveEffectiveCache(
            allocator,
            io,
            cwd,
            configured,
            environ,
        )
    else
        null;
    defer if (effective_cache) |*cache| cache.deinit(allocator, io);
    var retained_build_root: ?RetainedInputPath = if (build_root) |path|
        retainAbsoluteInputDirectory(
            allocator,
            io,
            path,
            environ,
            "build-root",
        ) catch |err| switch (err) {
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => return err,
            error.InputChanged => return err,
            else => return error.InvalidBuildRoot,
        }
    else
        null;
    defer if (retained_build_root) |*root| root.deinit(allocator, io);
    if (retained_build_root) |*root| {
        const directory = switch (root.entry) {
            .directory => |value| value,
            .file => return error.InvalidBuildRoot,
        };
        try root.verify(io);
        if (!isBuildRootAt(io, directory)) return error.InvalidBuildRoot;
    }
    if (effective_cache == null and config.engine == null) {
        effective_cache = try resolveDefaultCacheAtBuildRoot(
            allocator,
            io,
            &retained_build_root.?,
        );
    }
    if (config.cache_dir == null) if (retained_build_root) |*root| {
        try root.refreshRetainedDirectoryBaseline(io);
        try root.verify(io);
    };
    var publication_destinations: [3][]const u8 = undefined;
    var publication_destination_count: usize = 0;
    publication_destinations[publication_destination_count] = output_name;
    publication_destination_count += 1;
    if (metadata_output) |path| {
        publication_destinations[publication_destination_count] =
            std.fs.path.basename(path);
        publication_destination_count += 1;
    }
    if (debug_dir) |path| {
        publication_destinations[publication_destination_count] =
            std.fs.path.basename(path);
        publication_destination_count += 1;
    }
    var publication_locks = try PublicationLocks.acquire(
        allocator,
        io,
        publication_directory,
        publication_destinations[0..publication_destination_count],
        environ,
    );
    defer publication_locks.deinit(io);

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const transaction_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.starling-componentize-{s}",
        .{ std.fs.path.basename(output), &random_hex },
    );
    diagnostic.begin(.inputs);
    try publication_anchor.verifyMutableDirectory(io);
    var transaction = try Transaction.create(
        allocator,
        io,
        publication_anchor,
        transaction_name,
        &random_hex,
        environ,
    );
    publication_transferred = true;
    const transaction_storage = transaction.storage_path;
    var transaction_safe_to_remove = true;
    defer transaction.deinit(
        allocator,
        io,
        transaction_safe_to_remove,
    );
    var synthetic_protection: ?usize = null;
    const retained_source_path = if (config.source != null)
        source_path
    else blk: {
        const synthetic = try std.fs.path.join(
            allocator,
            &.{ transaction_storage, "output-only-source.js" },
        );
        try Dir.cwd().writeFile(io, .{
            .sub_path = synthetic,
            .data = "",
        });
        try transaction.recordStorageAbsolute(allocator, io, synthetic);
        synthetic_protection = try transaction.sealStorageFile(
            allocator,
            io,
            "output-only-source.js",
        );
        break :blk synthetic;
    };
    var retained_source = retainAbsoluteInputFile(
        allocator,
        io,
        retained_source_path,
        environ,
        "source",
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.InputChanged,
    };
    defer retained_source.deinit(allocator, io);
    const source = retained_source.resolved_path;
    var retained_initializer: ?RetainedInputPath = if (initializer_path) |path|
        retainAbsoluteInputFile(
            allocator,
            io,
            path,
            environ,
            "initializer",
        ) catch |err| switch (err) {
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => return err,
            else => return error.InputChanged,
        }
    else
        null;
    defer if (retained_initializer) |*initializer_value| {
        initializer_value.deinit(allocator, io);
    };
    const initializer = if (retained_initializer) |*value|
        value.resolved_path
    else
        null;
    if (std.mem.eql(u8, source, resolved_output) or
        (initializer != null and std.mem.eql(u8, initializer.?, resolved_output)))
    {
        return error.InputOutputCollision;
    }
    if (metadata_output) |path| {
        if (std.mem.eql(u8, path, source) or
            (initializer != null and std.mem.eql(u8, path, initializer.?)))
        {
            return error.InvalidMetadataDestination;
        }
    }
    if (debug_dir) |path| {
        if (pathContains(path, source) or
            (initializer != null and pathContains(path, initializer.?)))
        {
            return error.DebugOutputCollision;
        }
    }
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
    try appendInputExclusion(
        allocator,
        io,
        &input_exclusions,
        resolved_output,
    );
    if (metadata_output) |path| {
        try appendInputExclusion(allocator, io, &input_exclusions, path);
    }
    if (debug_dir) |path| {
        for (debug_generated_names) |name| {
            try appendInputExclusion(
                allocator,
                io,
                &input_exclusions,
                try std.fs.path.join(allocator, &.{ path, name }),
            );
        }
    }
    try appendPublicationLockExclusions(
        allocator,
        io,
        &input_exclusions,
        publication_directory,
        publication_parent,
    );

    try waitForCaptureTestBarrier(
        allocator,
        io,
        environ,
        "source",
    );
    const input_snapshots = if (config.source != null)
        try snapshotInputs(
            allocator,
            io,
            &retained_source,
            if (retained_initializer) |*value| value else null,
            input_exclusions.items,
            &transaction,
        )
    else blk: {
        const child_path = try transaction.retainStorageFile(
            allocator,
            io,
            "output-only-source.js",
            false,
        );
        var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
            undefined;
        std.crypto.hash.sha2.Sha256.hash("", &digest_bytes, .{});
        const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
        const source_snapshot = InputSnapshot{
            .file = .{
                .path = child_path,
                .storage_path = retained_source_path,
                .digest = try allocator.dupe(u8, &digest_hex),
                .protection = synthetic_protection.?,
            },
            .logical_path = "",
            .host_dir = transaction.storage_path,
            .guest_dir = "/",
            .tree_entry = "output-only-source.js",
            .tree_digest = try allocator.dupe(u8, &digest_hex),
            .shares_source_tree = false,
        };
        break :blk InputSnapshots{
            .source = source_snapshot,
            .initializer = @as(?InputSnapshot, null),
        };
    };
    const source_snapshot = input_snapshots.source;
    const initializer_snapshot = input_snapshots.initializer;

    const tools = try resolveTools(
        allocator,
        io,
        environ,
        cwd,
        executable_dir,
        config,
        &transaction,
    );
    try waitForComponentizerTestHook(
        allocator,
        io,
        environ,
        "tools-resolved",
    );

    var preopen_snapshots: std.ArrayList(RetainedDirectory) = .empty;
    for (config.preopen_dirs, 0..) |preopen, index| {
        const preopen_abs = try absolutePath(allocator, cwd, preopen);
        preopen_snapshots.append(
            allocator,
            try snapshotRetainedDirectory(
                allocator,
                io,
                preopen_abs,
                try std.fmt.allocPrint(
                    allocator,
                    "preopens/{d}",
                    .{index},
                ),
                preopen_abs,
                "starling-componentizer-preopen-tree-v1",
                &.{},
                input_exclusions.items,
                .preserve_internal,
                "preopen",
                &transaction,
            ),
        ) catch @panic("out of memory");
    }

    var command_log: std.ArrayList(u8) = .empty;
    const runtime = if (config.engine) |engine_override|
        try externalRuntime(
            allocator,
            io,
            environ,
            cwd,
            config,
            engine_override,
            tools,
            &transaction,
            diagnostic,
            &command_log,
        )
    else
        try buildRuntime(
            allocator,
            io,
            environ,
            cwd,
            build_root.?,
            &retained_build_root.?,
            executable_dir,
            config,
            &effective_cache.?,
            diagnostic,
            &transaction,
        );
    defer if (runtime.aot) |aot| aot.retained_weval.close(io);
    defer if (runtime.cache_lock) |lock| {
        lock.unlock(io);
        lock.close(io);
    };

    const runtime_args_path = try std.fs.path.join(
        allocator,
        &.{ transaction_storage, "runtime-args.txt" },
    );
    const runtime_args = if (config.source != null)
        try renderRuntimeArgs(
            allocator,
            cwd,
            source_snapshot.logical_path,
            if (initializer_snapshot) |snapshot| snapshot.logical_path else null,
            config,
        )
    else
        try allocator.dupe(u8, "");
    try Dir.cwd().writeFile(io, .{
        .sub_path = runtime_args_path,
        .data = runtime_args,
    });
    try transaction.recordStorageAbsolute(allocator, io, runtime_args_path);
    _ = try transaction.sealStorageFile(
        allocator,
        io,
        "runtime-args.txt",
    );
    const runtime_args_child_path = try transaction.retainStorageFile(
        allocator,
        io,
        "runtime-args.txt",
        false,
    );

    var initialized = try createChildOutput(
        allocator,
        io,
        &transaction,
        "initialized.wasm",
    );
    var pipeline_env = std.process.Environ.Map.init(allocator);
    try copyEnvironment(&pipeline_env, environ);
    if (try sanitizedPipelinePath(allocator, io, environ, cwd, config)) |path| {
        try pipeline_env.put("PATH", path);
    }
    try pipeline_env.put("WASMTIME_BACKTRACE_DETAILS", "1");
    _ = pipeline_env.swapRemove("STARLINGMONKEY_CONFIG");
    _ = pipeline_env.swapRemove("RUST_MIN_STACK");
    if (runtime.aot != null) {
        try pipeline_env.put(
            "RUST_MIN_STACK",
            try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{
                    config.aot_min_stack_size orelse
                        aot_cache.default_min_stack_size,
                },
            ),
        );
    }
    if (config.source != null) {
        var wizer_args: std.ArrayList([]const u8) = .empty;
        if (runtime.aot) |aot| {
            wizer_args.appendSlice(allocator, &.{
                aot.weval.path,
                "weval",
                "-w",
                "--init-func",
                "wizer-initialize",
                "--cache-ro",
                aot.cache.path,
            }) catch @panic("out of memory");
            if (config.verbose) {
                wizer_args.appendSlice(allocator, &.{
                    "--verbose",
                    "--show-stats",
                }) catch @panic("out of memory");
            }
        } else if (tools.wizer.?.wasmtime_subcommand) {
            wizer_args.append(allocator, tools.wizer.?.executable.path) catch
                @panic("out of memory");
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
            wizer_args.append(allocator, tools.wizer.?.executable.path) catch
                @panic("out of memory");
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
        for (preopen_snapshots.items) |preopen| {
            try addMappedPreopen(
                allocator,
                &wizer_args,
                preopen.absolute,
                preopen.guest,
            );
        }
        wizer_args.appendSlice(
            allocator,
            if (runtime.aot != null)
                &.{ "-o", initialized.path, "-i", runtime.engine.path }
            else
                &.{ "-o", initialized.path, runtime.engine.path },
        ) catch @panic("out of memory");

        diagnostic.begin(.initialize);
        if (runtime.aot) |aot| {
            var retained_args: std.ArrayList([]const u8) = .empty;
            if (aot.weval_is_bash_script) {
                retained_args.appendSlice(
                    allocator,
                    &.{ aot.weval.path, aot.weval.path },
                ) catch @panic("out of memory");
                retained_args.appendSlice(allocator, wizer_args.items[1..]) catch
                    @panic("out of memory");
            }
            try runRetainedAotCommand(
                allocator,
                io,
                aot.retained_weval,
                if (aot.weval_is_bash_script)
                    retained_args.items
                else
                    wizer_args.items,
                cwd,
                &pipeline_env,
                runtime_args_child_path,
                config.verbose,
                &command_log,
                diagnostic,
                transaction_storage,
                &transaction,
            );
        } else {
            try runCommand(
                allocator,
                io,
                "wizer",
                wizer_args.items,
                cwd,
                &pipeline_env,
                runtime_args_child_path,
                config.verbose,
                &command_log,
                diagnostic,
                transaction_storage,
                &transaction,
            );
        }
    } else {
        if (runtime.aot) |aot| {
            var args: std.ArrayList([]const u8) = .empty;
            args.appendSlice(allocator, &.{
                aot.weval.path,
                "weval",
                "-w",
                "--init-func",
                "starling-aot-runtime-initialize",
                "--cache-ro",
                aot.cache.path,
                "-o",
                initialized.path,
                "-i",
                runtime.engine.path,
            }) catch @panic("out of memory");
            var retained_args: std.ArrayList([]const u8) = .empty;
            if (aot.weval_is_bash_script) {
                retained_args.appendSlice(
                    allocator,
                    &.{ aot.weval.path, aot.weval.path },
                ) catch @panic("out of memory");
                retained_args.appendSlice(allocator, args.items[1..]) catch
                    @panic("out of memory");
            }
            diagnostic.begin(.initialize);
            try runRetainedAotCommand(
                allocator,
                io,
                aot.retained_weval,
                if (aot.weval_is_bash_script)
                    retained_args.items
                else
                    args.items,
                cwd,
                &pipeline_env,
                null,
                config.verbose,
                &command_log,
                diagnostic,
                transaction_storage,
                &transaction,
            );
        } else {
            var input = try Dir.cwd().openFile(io, runtime.engine.path, .{
                .allow_directory = false,
            });
            defer input.close(io);
            var output_file = try transaction.storage.openFile(
                io,
                initialized.relative,
                .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                },
            );
            defer output_file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (true) {
                const count = try input.readPositional(
                    io,
                    &.{&buffer},
                    offset,
                );
                if (count == 0) break;
                try output_file.writePositionalAll(
                    io,
                    buffer[0..count],
                    offset,
                );
                offset += count;
            }
            try output_file.setLength(io, offset);
            try output_file.sync(io);
        }
    }
    try transaction.sealChildOutput(
        allocator,
        io,
        &initialized,
    );
    if (runtime.aot) |aot| {
        try aot_cache.validateWevalPackage(
            allocator,
            io,
            aot.weval.path,
            aot.validated,
        );
    }

    var stripped: ?ChildOutput = null;
    var embedded: ?ChildOutput = null;
    const wabt_used_for_embedding =
        runtime.component_wit != null and config.wit != null and runtime.zig == null;
    const candidate: ChildOutput = if (runtime.component_wit) |component_wit| blk: {
        const use_wabt = config.wit != null and runtime.zig == null;
        var stripped_output = try createChildOutput(
            allocator,
            io,
            &transaction,
            "stripped.wasm",
        );
        diagnostic.begin(.strip);
        try runCommand(
            allocator,
            io,
            if (use_wabt) "wabt module strip" else "wasm-tools strip",
            if (use_wabt) &.{
                tools.wabt.path,      "module",         "strip", "-o",
                stripped_output.path, initialized.path,
            } else &.{
                tools.wasm_tools.path, "strip",          "--all", "-o",
                stripped_output.path,  initialized.path,
            },
            cwd,
            &pipeline_env,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_storage,
            &transaction,
        );
        try transaction.sealChildOutput(
            allocator,
            io,
            &stripped_output,
        );
        stripped = stripped_output;
        var embedded_output = try createChildOutput(
            allocator,
            io,
            &transaction,
            "embedded.wasm",
        );
        diagnostic.begin(.embed);
        try runCommand(
            allocator,
            io,
            if (use_wabt)
                "wabt component embed"
            else
                "wasm-tools component embed",
            if (use_wabt) &.{
                tools.wabt.path,           "component", "embed",              "--world",
                runtime.component_world.?, "-o",        embedded_output.path, component_wit,
                stripped_output.path,
            } else &.{
                tools.wasm_tools.path, "component",               "embed", component_wit,
                "--world",             runtime.component_world.?, "-o",    embedded_output.path,
                stripped_output.path,
            },
            cwd,
            &pipeline_env,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_storage,
            &transaction,
        );
        try transaction.sealChildOutput(
            allocator,
            io,
            &embedded_output,
        );
        embedded = embedded_output;
        var candidate_output = try createChildOutput(
            allocator,
            io,
            &transaction,
            "candidate.wasm",
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
            if (use_wabt)
                "wabt component new"
            else
                "wasm-tools component new",
            if (use_wabt) &.{
                tools.wabt.path, "component",           "new",                "--adapt", adapter_arg,
                "-o",            candidate_output.path, embedded_output.path,
            } else &.{
                tools.wasm_tools.path, "component", "new",                 "--adapt",
                adapter_arg,           "-o",        candidate_output.path, embedded_output.path,
            },
            cwd,
            &pipeline_env,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_storage,
            &transaction,
        );
        try transaction.sealChildOutput(
            allocator,
            io,
            &candidate_output,
        );
        break :blk candidate_output;
    } else blk: {
        var candidate_output = try createChildOutput(
            allocator,
            io,
            &transaction,
            "candidate.wasm",
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
            "wasm-tools component new",
            &.{
                tools.wasm_tools.path,
                "component",
                "new",
                "--adapt",
                adapter_arg,
                "--output",
                candidate_output.path,
                initialized.path,
            },
            cwd,
            &pipeline_env,
            null,
            config.verbose,
            &command_log,
            diagnostic,
            transaction_storage,
            &transaction,
        );
        try transaction.sealChildOutput(
            allocator,
            io,
            &candidate_output,
        );
        break :blk candidate_output;
    };

    var surfaced = try createChildOutput(
        allocator,
        io,
        &transaction,
        "surfaced.wasm",
    );
    const surface_work_dir = try std.fs.path.join(
        allocator,
        &.{ transaction_storage, "feature-surface" },
    );
    try transaction.createStorageDir(
        allocator,
        io,
        "feature-surface",
        .fromMode(0o700),
    );
    var surface_command_context = FeatureSurfaceCommandContext{
        .diagnostic = diagnostic,
        .transaction = &transaction,
        .transaction_storage = transaction_storage,
        .environ = &pipeline_env,
    };
    const wabt_used_for_surface = try feature_surface.apply(allocator, io, .{
        .wabt = tools.wabt.path,
        .wasm_tools = tools.wasm_tools.path,
        .platform_wit = runtime.platform_wit,
        .component = candidate.path,
        .output = surfaced.path,
        .work_dir = surface_work_dir,
        .target_wit = runtime.surface_target_wit,
        .target_world = runtime.surface_target_world,
        .features = runtime.features,
        .runtime_config = if (config.source != null)
            .snapshotted
        else
            .external,
        .inspect_candidate = true,
        .cwd = cwd,
        .verbose = config.verbose,
        .command_log = &command_log,
        .command_runner = .{
            .context = &surface_command_context,
            .run = runFeatureSurfaceCommand,
        },
        .generated_inputs = .{
            .context = &surface_command_context,
            .retain_file = retainFeatureSurfaceFile,
            .snapshot_tree = snapshotFeatureSurfaceTree,
            .verify = verifyFeatureSurfaceInputs,
            .set_diagnostic_detail = setFeatureSurfaceDiagnosticDetail,
        },
    });
    var surface_work = try transaction.storage.openDir(
        io,
        "feature-surface",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer surface_work.close(io);
    try recordDebugBackupTree(
        allocator,
        io,
        &transaction,
        surface_work,
        "feature-surface",
    );
    _ = try transaction.sealStorageTree(
        allocator,
        io,
        "feature-surface",
    );
    try transaction.sealChildOutput(
        allocator,
        io,
        &surfaced,
    );

    var processed = try createChildOutput(
        allocator,
        io,
        &transaction,
        "component.wasm",
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
        processed.path,
        surfaced.path,
    }) catch @panic("out of memory");
    diagnostic.begin(.metadata);
    try runCommand(
        allocator,
        io,
        "wasm-tools metadata add",
        metadata_args.items,
        cwd,
        &pipeline_env,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        transaction_storage,
        &transaction,
    );
    try transaction.sealChildOutput(
        allocator,
        io,
        &processed,
    );

    diagnostic.begin(.validate);
    try runCommand(
        allocator,
        io,
        "wasm-tools validate",
        &.{
            tools.wasm_tools.path,
            "validate",
            "--features",
            "all",
            processed.path,
        },
        cwd,
        &pipeline_env,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        transaction_storage,
        &transaction,
    );
    try transaction.verifyChildAnchors(io);
    try transaction.verifyIntegrity(allocator, io);
    try requireFile(io, processed.path);

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
            source_snapshot,
            initializer_snapshot,
            runtime_args,
            runtime,
            tools,
            wabt_used_for_embedding or wabt_used_for_surface,
            preopen_snapshots.items,
            processed.path,
            imports,
        );
        metadata_json = try metadata.render(allocator, document);
    }

    var metadata_protection: ?usize = null;
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
        metadata_protection = try transaction.sealStorageFile(
            allocator,
            io,
            "metadata.json",
        );
        break :blk path;
    } else null;

    var debug_protection: ?usize = null;
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
            .{ .iterate = true, .follow_symlinks = false },
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
        try copyDebugFile(io, initialized.path, debug_dir_handle, "initialized.wasm");
        try transaction.recordStoragePath(allocator, io, "debug/initialized.wasm");
        if (stripped) |child_output| {
            try copyDebugFile(io, child_output.path, debug_dir_handle, "stripped.wasm");
            try transaction.recordStoragePath(allocator, io, "debug/stripped.wasm");
        }
        if (embedded) |child_output| {
            try copyDebugFile(io, child_output.path, debug_dir_handle, "embedded.wasm");
            try transaction.recordStoragePath(allocator, io, "debug/embedded.wasm");
        }
        try copyDebugFile(
            io,
            candidate.path,
            debug_dir_handle,
            "component-before-feature-surface.wasm",
        );
        try transaction.recordStoragePath(
            allocator,
            io,
            "debug/component-before-feature-surface.wasm",
        );
        try copyDebugFile(io, surfaced.path, debug_dir_handle, "surfaced.wasm");
        try transaction.recordStoragePath(allocator, io, "debug/surfaced.wasm");
        try copyDebugFile(io, processed.path, debug_dir_handle, "component.wasm");
        try transaction.recordStoragePath(allocator, io, "debug/component.wasm");
        const provider_wit = try std.fs.path.join(
            allocator,
            &.{ surface_work_dir, "feature-0-provider-wit", "component.wit" },
        );
        if (pathExists(io, provider_wit)) {
            try copyDebugFile(io, provider_wit, debug_dir_handle, "feature-provider.wit");
            try transaction.recordStoragePath(
                allocator,
                io,
                "debug/feature-provider.wit",
            );
        }
        const provider_component = try std.fs.path.join(
            allocator,
            &.{ surface_work_dir, "feature-provider-a.wasm" },
        );
        if (pathExists(io, provider_component)) {
            try copyDebugFile(io, provider_component, debug_dir_handle, "feature-provider.wasm");
            try transaction.recordStoragePath(
                allocator,
                io,
                "debug/feature-provider.wasm",
            );
        }
        if (runtime.bindings) |path| {
            try copyDebugFile(io, path, debug_dir_handle, "component-bindings.zig");
            try transaction.recordStoragePath(
                allocator,
                io,
                "debug/component-bindings.zig",
            );
        }
        if (runtime.aot) |aot| {
            try copyDebugFile(
                io,
                aot.manifest.path,
                debug_dir_handle,
                "aot-cache.manifest",
            );
            try transaction.recordStoragePath(
                allocator,
                io,
                "debug/aot-cache.manifest",
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
        try transaction.verifyOwnedSubtreeExact(
            allocator,
            io,
            debug_dir_handle,
            "debug",
        );
        try sealSnapshotDirectory(io, debug_dir_handle);
        try debug_dir_handle.setPermissions(io, .fromMode(0o700));
        debug_protection = try transaction.protectStoragePath(
            allocator,
            io,
            "debug",
        );
        break :blk directory;
    } else null;

    var candidate_file = try Dir.openFileAbsolute(io, processed.path, .{});
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
        processed.storage_path,
        processed.protection.?,
        output_name,
        metadata_staged,
        metadata_protection,
        if (metadata_output) |path| std.fs.path.basename(path) else null,
        debug_staged,
        debug_protection,
        if (debug_dir) |path| std.fs.path.basename(path) else null,
        &transaction_safe_to_remove,
        source,
        resolved_output,
        environ,
        diagnostic,
        &publication_locks,
    );
}

fn externalRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    config: *const cli.Config,
    engine_override: []const u8,
    tools: Tools,
    transaction: *Transaction,
    diagnostic: *diagnostics.Context,
    command_log: *std.ArrayList(u8),
) !Runtime {
    const transaction_dir = transaction.storage_path;
    if (config.disable_features.len != 0 or
        config.enable_features.len != 0 or
        config.use_debug_build)
    {
        return error.IncompatibleEngineOptions;
    }
    const engine_source = try absolutePath(allocator, cwd, engine_override);
    const captured_engine = try captureInputFile(
        allocator,
        io,
        engine_source,
        try std.fs.path.join(allocator, &.{ transaction_dir, "engine.wasm" }),
        transaction,
        "engine",
    );
    try waitForComponentizerTestHook(
        allocator,
        io,
        transaction.environ,
        "external-package-engine-captured",
    );
    const engine = captured_engine.snapshot;
    const engine_dir = std.fs.path.dirname(captured_engine.resolved_path) orelse
        return error.InvalidPath;
    const manifest_source = try std.fs.path.join(
        allocator,
        &.{ engine_dir, "features.json" },
    );
    const manifest = (captureInputFile(
        allocator,
        io,
        manifest_source,
        try std.fs.path.join(allocator, &.{ transaction_dir, "features.json" }),
        transaction,
        "engine provenance",
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine package requires sibling features.json",
            .{},
        );
        return err;
    }).snapshot;
    const provenance = try loadEngineProvenance(
        allocator,
        io,
        engine.path,
        manifest.path,
        diagnostic,
    );
    const adapter_source = try std.fs.path.join(
        allocator,
        &.{ engine_dir, "preview1-adapter.wasm" },
    );
    const adapter = (captureInputFile(
        allocator,
        io,
        adapter_source,
        try std.fs.path.join(allocator, &.{ transaction_dir, "preview2-adapter.wasm" }),
        transaction,
        "adapter",
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine package requires sibling preview1-adapter.wasm",
            .{},
        );
        return err;
    }).snapshot;
    if (config.preview2_adapter) |path| {
        const override = (try captureInputFile(
            allocator,
            io,
            try absolutePath(allocator, cwd, path),
            try std.fs.path.join(allocator, &.{ transaction_dir, "adapter-override.wasm" }),
            transaction,
            "adapter override",
        )).snapshot;
        if (!std.mem.eql(u8, adapter.digest, override.digest)) {
            setExternalPackageDetail(
                diagnostic,
                "--preview2-adapter does not match the external engine package adapter",
                .{},
            );
            return error.IncompatibleEngineOptions;
        }
    }
    const component_wit = stageWit(
        allocator,
        io,
        try std.fs.path.join(allocator, &.{ engine_dir, "component-wit" }),
        try std.fs.path.join(allocator, &.{ transaction_dir, "component-wit" }),
        transaction,
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine package requires sibling component-wit",
            .{},
        );
        return err;
    };
    const surface_target_wit = stageWit(
        allocator,
        io,
        try std.fs.path.join(allocator, &.{ engine_dir, "surface-wit" }),
        try std.fs.path.join(allocator, &.{ transaction_dir, "surface-wit" }),
        transaction,
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine package requires sibling surface-wit",
            .{},
        );
        return err;
    };
    const platform_wit_source = try std.fs.path.join(
        allocator,
        &.{ engine_dir, "feature-wit" },
    );
    const platform_wit = stageWit(
        allocator,
        io,
        platform_wit_source,
        try std.fs.path.join(allocator, &.{ transaction_dir, "feature-wit" }),
        transaction,
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine package requires sibling feature-wit",
            .{},
        );
        return err;
    };
    var selected_component_wit = component_wit;
    var selected_surface_target_wit = surface_target_wit;
    if (config.component_wit) |path| {
        const override = try stageWit(
            allocator,
            io,
            try absolutePath(allocator, cwd, path),
            try std.fs.path.join(allocator, &.{ transaction_dir, "component-wit-override" }),
            transaction,
        );
        if (!std.mem.eql(u8, component_wit.digest, override.digest)) {
            setExternalPackageDetail(
                diagnostic,
                "--component-wit does not match the external engine package component-wit",
                .{},
            );
            return error.IncompatibleEngineOptions;
        }
        selected_component_wit = override;
    }
    if (config.wit) |path| {
        const override = try stageWit(
            allocator,
            io,
            try absolutePath(allocator, cwd, path),
            try std.fs.path.join(allocator, &.{ transaction_dir, "wit-override" }),
            transaction,
        );
        if (!std.mem.eql(u8, surface_target_wit.digest, override.digest)) {
            setExternalPackageDetail(
                diagnostic,
                "--wit does not match the external engine package surface-wit",
                .{},
            );
            return error.IncompatibleEngineOptions;
        }
        selected_surface_target_wit = override;
    }
    if (config.component_world_name) |world| {
        if (!std.mem.eql(u8, world, provenance.component_world)) {
            setExternalPackageDetail(
                diagnostic,
                "--component-world-name does not match external engine provenance",
                .{},
            );
            return error.IncompatibleEngineOptions;
        }
    }
    if (config.world_name) |world| {
        if (!std.mem.eql(u8, world, provenance.surface_world)) {
            setExternalPackageDetail(
                diagnostic,
                "--world-name does not match external engine surface provenance",
                .{},
            );
            return error.IncompatibleEngineOptions;
        }
    }
    const wit_validation = [_]struct {
        label: []const u8,
        path: []const u8,
        world: []const u8,
    }{
        .{
            .label = "validate external component WIT",
            .path = selected_component_wit.absolute,
            .world = provenance.component_world,
        },
        .{
            .label = "validate external surface WIT",
            .path = selected_surface_target_wit.absolute,
            .world = provenance.surface_world,
        },
    };
    for (wit_validation) |validation| {
        runCommand(
            allocator,
            io,
            validation.label,
            &.{
                tools.wasm_tools.path,
                "component",
                "embed",
                "--all-features",
                "--world",
                validation.world,
                "--dummy",
                "--output",
                "/dev/null",
                validation.path,
            },
            cwd,
            null,
            null,
            config.verbose,
            command_log,
            diagnostic,
            transaction.storage_path,
            transaction,
        ) catch |err| switch (err) {
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.InputChanged,
            => return err,
            else => return error.InvalidEngineProvenance,
        };
    }
    runCommand(
        allocator,
        io,
        "validate external feature WIT",
        &.{
            tools.wasm_tools.path,
            "component",
            "wit",
            "--wasm",
            "--output",
            "/dev/null",
            platform_wit.absolute,
        },
        cwd,
        null,
        null,
        config.verbose,
        command_log,
        diagnostic,
        transaction.storage_path,
        transaction,
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.InputChanged,
        => return err,
        else => return error.InvalidEngineProvenance,
    };
    const aot = if (config.aot)
        try prepareAotRuntime(
            allocator,
            io,
            environ,
            cwd,
            config,
            engine,
            engine_dir,
            provenance.host_api,
            provenance.features,
            transaction,
        )
    else
        null;
    if (aot != null) {
        try waitForComponentizerTestHook(
            allocator,
            io,
            transaction.environ,
            "aot-inputs-captured",
        );
    }
    try waitForComponentizerTestHook(
        allocator,
        io,
        transaction.environ,
        "external-inputs-snapshotted",
    );
    try transaction.verifyRetainedIntegrity();
    return .{
        .engine = engine,
        .adapter = adapter,
        .component_wit = selected_component_wit.absolute,
        .component_world = provenance.component_world,
        .surface_target_wit = selected_surface_target_wit.absolute,
        .surface_target_world = provenance.surface_world,
        .platform_wit = platform_wit.absolute,
        .features = provenance.features,
        .bindings = null,
        .dispatch_wit_digest = selected_surface_target_wit.digest,
        .component_wit_digest = selected_component_wit.digest,
        .features_known = true,
        .zig = null,
        .build_tools = &.{},
        .build_root_digest = null,
        .cache_lock = null,
        .aot = aot,
    };
}

fn loadEngineProvenance(
    allocator: Allocator,
    io: Io,
    engine: []const u8,
    manifest_path: []const u8,
    diagnostic: *diagnostics.Context,
) !EngineProvenance {
    const module = try readAbsoluteFile(allocator, io, engine);
    const section = findEngineProvenanceSection(module) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine has invalid embedded feature/host provenance ({t})",
            .{err},
        );
        return error.InvalidEngineProvenance;
    } orelse {
        setExternalPackageDetail(
            diagnostic,
            "the external engine is missing embedded feature/host provenance",
            .{},
        );
        return error.MissingEngineProvenance;
    };
    const parsed = parseEngineProvenance(
        allocator,
        section.metadata,
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine has malformed embedded feature/host provenance ({t})",
            .{err},
        );
        return error.InvalidEngineProvenance;
    };

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(module[0..section.section_start]);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, parsed.sha256, &digest_hex)) {
        setExternalPackageDetail(
            diagnostic,
            "the external engine provenance digest does not match the engine bytes",
            .{},
        );
        return error.EngineProvenanceMismatch;
    }

    const manifest_text = readAbsoluteFile(
        allocator,
        io,
        manifest_path,
    ) catch {
        setExternalPackageDetail(
            diagnostic,
            "the external engine requires sibling features.json provenance",
            .{},
        );
        return error.MissingEngineProvenance;
    };
    const manifest = std.json.parseFromSliceLeaky(
        FeatureManifest,
        allocator,
        manifest_text,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        setExternalPackageDetail(
            diagnostic,
            "the external engine sibling features.json is invalid JSON ({t})",
            .{err},
        );
        return error.InvalidEngineProvenance;
    };
    const manifest_features = feature_surface.Features{
        .stdio = manifest.stdio,
        .random = manifest.random,
        .clocks = manifest.clocks,
        .http = manifest.http,
        .fetch_event = manifest.@"fetch-event",
    };
    if (!std.mem.eql(u8, parsed.host_api, manifest.@"host-api") or
        !std.mem.eql(
            u8,
            parsed.component_world,
            manifest.@"component-world",
        ) or
        !std.mem.eql(u8, parsed.surface_world, manifest.@"surface-world") or
        !featuresEqual(parsed.features, manifest_features))
    {
        setExternalPackageDetail(
            diagnostic,
            "the external engine embedded provenance does not match sibling features.json",
            .{},
        );
        return error.EngineProvenanceMismatch;
    }
    return .{
        .host_api = parsed.host_api,
        .features = parsed.features,
        .component_world = parsed.component_world,
        .surface_world = parsed.surface_world,
    };
}

fn setExternalPackageDetail(
    diagnostic: *diagnostics.Context,
    comptime format: []const u8,
    args: anytype,
) void {
    diagnostic.detail = std.fmt.allocPrint(
        diagnostic.allocator,
        format,
        args,
    ) catch "external engine package validation failed";
}

const EngineProvenanceSection = struct {
    section_start: usize,
    metadata: []const u8,
};

fn findEngineProvenanceSection(
    module: []const u8,
) !?EngineProvenanceSection {
    const wasm_magic = "\x00asm\x01\x00\x00\x00";
    if (module.len < wasm_magic.len or
        !std.mem.eql(u8, module[0..wasm_magic.len], wasm_magic))
    {
        return error.InvalidWasm;
    }

    var found: ?EngineProvenanceSection = null;
    var offset: usize = wasm_magic.len;
    while (offset < module.len) {
        const section_start = offset;
        const section_id = module[offset];
        offset += 1;
        const size = try readUleb(module, &offset);
        const section_end = std.math.add(usize, offset, size) catch
            return error.InvalidWasm;
        if (section_end > module.len) return error.InvalidWasm;
        if (section_id == 0) {
            var name_offset = offset;
            const name_len = try readUleb(module, &name_offset);
            const name_end = std.math.add(usize, name_offset, name_len) catch
                return error.InvalidWasm;
            if (name_end > section_end) return error.InvalidWasm;
            if (std.mem.eql(
                u8,
                module[name_offset..name_end],
                "starling:engine-provenance",
            )) {
                if (found != null or section_end != module.len) {
                    return error.InvalidProvenanceSection;
                }
                found = .{
                    .section_start = section_start,
                    .metadata = module[name_end..section_end],
                };
            }
        }
        offset = section_end;
    }
    return found;
}

const ParsedEngineProvenance = struct {
    sha256: []const u8,
    host_api: []const u8,
    features: feature_surface.Features,
    component_world: []const u8,
    surface_world: []const u8,
};

const JsonEngineProvenance = struct {
    schema: u32,
    sha256: []const u8,
    host_api: []const u8,
    features: struct {
        stdio: bool,
        random: bool,
        clocks: bool,
        http: bool,
        @"fetch-event": bool,
    },
    component_world: []const u8,
    surface_world: []const u8,
};

fn parseEngineProvenance(
    allocator: Allocator,
    provenance_metadata: []const u8,
) !ParsedEngineProvenance {
    const parsed = std.json.parseFromSliceLeaky(
        JsonEngineProvenance,
        allocator,
        provenance_metadata,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidMetadata;
    if (parsed.schema != 1 or parsed.sha256.len != 64)
        return error.InvalidMetadata;
    for (parsed.sha256) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.InvalidMetadata;
        }
    }
    if (!validMetadataValue(parsed.host_api) or
        !validMetadataValue(parsed.component_world) or
        !validMetadataValue(parsed.surface_world))
    {
        return error.InvalidMetadata;
    }
    return .{
        .sha256 = parsed.sha256,
        .host_api = parsed.host_api,
        .features = .{
            .stdio = parsed.features.stdio,
            .random = parsed.features.random,
            .clocks = parsed.features.clocks,
            .http = parsed.features.http,
            .fetch_event = parsed.features.@"fetch-event",
        },
        .component_world = parsed.component_world,
        .surface_world = parsed.surface_world,
    };
}

fn metadataField(line: []const u8, prefix: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, line, prefix) or line.len == prefix.len) {
        return error.InvalidMetadata;
    }
    return line[prefix.len..];
}

fn validMetadataValue(value: []const u8) bool {
    return value.len <= 256 and
        std.unicode.utf8ValidateSlice(value) and
        std.mem.indexOfAny(u8, value, "\x00\r\n=") == null;
}

fn featuresFromTuple(tuple: []const u8) !feature_surface.Features {
    if (tuple.len != 5) return error.InvalidMetadata;
    var values: [5]bool = undefined;
    for (tuple, 0..) |byte, index| {
        values[index] = switch (byte) {
            '0' => false,
            '1' => true,
            else => return error.InvalidMetadata,
        };
    }
    return .{
        .stdio = values[0],
        .random = values[1],
        .clocks = values[2],
        .http = values[3],
        .fetch_event = values[4],
    };
}

fn featuresEqual(
    lhs: feature_surface.Features,
    rhs: feature_surface.Features,
) bool {
    return lhs.stdio == rhs.stdio and
        lhs.random == rhs.random and
        lhs.clocks == rhs.clocks and
        lhs.http == rhs.http and
        lhs.fetch_event == rhs.fetch_event;
}

fn readUleb(bytes: []const u8, offset: *usize) !usize {
    var value: usize = 0;
    var shift: u6 = 0;
    for (0..5) |_| {
        if (offset.* >= bytes.len) return error.InvalidWasm;
        const byte = bytes[offset.*];
        offset.* += 1;
        value |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
    }
    return error.InvalidWasm;
}

fn buildRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    build_root: []const u8,
    retained_build_root: *RetainedInputPath,
    executable_dir: []const u8,
    config: *const cli.Config,
    cache: *const EffectiveCache,
    diagnostic: *diagnostics.Context,
    transaction: *Transaction,
) !Runtime {
    const transaction_dir = transaction.storage_path;
    try cache.verifyCanonical(io);

    const build_root_dir = switch (retained_build_root.entry) {
        .directory => |directory| directory,
        .file => return error.InvalidBuildRoot,
    };
    if (!isBuildRootAt(io, build_root_dir)) return error.InvalidBuildRoot;
    const build_selections = try runtimeBuildSelections(
        allocator,
        io,
        build_root_dir,
    );
    const build_exclusions = [_]InputExclusion{.{
        .path = cache.path,
        .identity = cache.identity,
    }};
    const build_snapshot = try snapshotRetainedDirectoryFromHandle(
        allocator,
        io,
        retained_build_root,
        "build-root",
        build_root,
        "starling-componentizer-runtime-build-root-v1",
        build_selections.paths,
        &build_exclusions,
        .dereference_files,
        transaction,
    );
    if (build_selections.manifest_digest) |expected_digest| {
        const retained_manifest = try std.fs.path.join(
            allocator,
            &.{ build_snapshot.absolute, runtime_build_manifest },
        );
        const actual_digest = try metadata.sha256File(
            allocator,
            io,
            retained_manifest,
        );
        if (!std.mem.eql(u8, expected_digest, actual_digest)) {
            return error.InputChanged;
        }
    }

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

    const zig_source = if (config.zig_bin) |path|
        path
    else if (environ.get("ZIG")) |path|
        path
    else
        build_options.zig_exe;
    const zig_resolved = try resolveConfiguredExecutable(
        allocator,
        io,
        environ,
        cwd,
        zig_source,
    );
    const zig_canonical = try Dir.realPathFileAbsoluteAlloc(
        io,
        zig_resolved,
        allocator,
    );
    const zig_install = try snapshotZigInstallation(
        allocator,
        io,
        zig_canonical,
        environ,
        build_root,
        build_snapshot.absolute,
        transaction,
    );
    const zig = zig_install.executable;
    const adapter_source: ?[]const u8 = if (config.preview2_adapter) |path|
        try absolutePath(allocator, cwd, path)
    else blk: {
        const sibling = try std.fs.path.join(
            allocator,
            &.{ executable_dir, "preview1-adapter.wasm" },
        );
        break :blk if (pathExists(io, sibling)) sibling else null;
    };
    const adapter_destination = try std.fs.path.join(
        allocator,
        &.{ transaction_dir, "runtime-adapter-input.wasm" },
    );
    const adapter_input = if (adapter_source) |path|
        (try captureInputFile(
            allocator,
            io,
            path,
            adapter_destination,
            transaction,
            "adapter",
        )).snapshot
    else
        try snapshotFileAt(
            allocator,
            io,
            transaction.storage,
            try std.fs.path.join(
                allocator,
                &.{
                    "build-root",
                    try selectedHostApiPath(allocator),
                    if (config.use_debug_build)
                        "preview1-adapter-debug/wasi_snapshot_preview1.wasm"
                    else
                        "preview1-adapter-release/wasi_snapshot_preview1.wasm",
                },
            ),
            adapter_destination,
            transaction,
        );

    const needs_bindings = (config.debug_bindings or config.metadata_out != null) and
        dispatch_wit != null;
    const key = try runtimeKey(
        allocator,
        config,
        if (dispatch_wit) |wit| wit.digest else null,
        if (component_wit) |wit| wit.digest else null,
        build_options.host_api_world,
        adapter_input.digest,
        needs_bindings,
        build_snapshot.digest,
        zig_install,
    );
    var locks = try ensureCacheDirectory(
        allocator,
        io,
        cache.directory,
        cache.path,
        "locks",
    );
    defer locks.close(io);
    const lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{key});
    const cache_lock = try acquireCacheLock(io, locks.directory, lock_name);
    const lock_file = cache_lock.file;
    errdefer lock_file.close(io);
    errdefer lock_file.unlock(io);

    var runtimes = try ensureCacheDirectory(
        allocator,
        io,
        cache.directory,
        cache.path,
        "runtimes",
    );
    defer runtimes.close(io);
    var prefix = try ensureCacheDirectory(
        allocator,
        io,
        runtimes.directory,
        runtimes.path,
        key,
    );
    defer prefix.close(io);
    var cache_bin = try ensureCacheDirectory(
        allocator,
        io,
        prefix.directory,
        prefix.path,
        "bin",
    );
    defer cache_bin.close(io);
    try verifyNoSymlinkTree(io, cache_bin.directory);

    var zig_global = try ensureCacheDirectory(
        allocator,
        io,
        cache.directory,
        cache.path,
        "zig-global-cache",
    );
    defer zig_global.close(io);
    var zig_local = try ensureCacheDirectory(
        allocator,
        io,
        cache.directory,
        cache.path,
        "zig-local-cache",
    );
    defer zig_local.close(io);

    try verifyCacheLayout(
        cache,
        &runtimes,
        &prefix,
        &cache_bin,
        &locks,
        cache_lock,
        &zig_global,
        &zig_local,
        io,
    );

    try transaction.createStorageDir(
        allocator,
        io,
        "runtime-prefix",
        .fromMode(0o700),
    );
    const runtime_bin_relative = if (config.aot)
        "runtime-prefix/.starling-aot-engine/current/bin"
    else
        "runtime-prefix/bin";
    if (!config.aot) {
        try transaction.createStorageDir(
            allocator,
            io,
            runtime_bin_relative,
            .fromMode(0o700),
        );
    }
    const prefix_child_path = try transaction.retainStorageDirectoryForDescendants(
        allocator,
        io,
        "runtime-prefix",
    );
    if (!config.aot) {
        _ = try transaction.retainStorageDirectory(
            allocator,
            io,
            runtime_bin_relative,
        );
    }
    var runtime_prefix = try transaction.storage.openDir(
        io,
        "runtime-prefix",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer runtime_prefix.close(io);
    const zig_global_child_path = try cacheDirectoryChildPath(
        allocator,
        zig_global,
    );
    const zig_local_child_path = try cacheDirectoryChildPath(
        allocator,
        zig_local,
    );

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(allocator, &.{
        zig.path,
        "build",
        "--prefix",
        prefix_child_path,
        if (config.use_debug_build) "-Doptimize=Debug" else "-Doptimize=ReleaseSmall",
        try std.fmt.allocPrint(
            allocator,
            "-Dpreview1-adapter={s}",
            .{adapter_input.path},
        ),
        try std.fmt.allocPrint(allocator, "-Dhost-api={s}", .{build_options.host_api}),
        try std.fmt.allocPrint(
            allocator,
            "-Dhost-api-world={s}",
            .{build_options.host_api_world},
        ),
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
    if (config.aot) {
        argv.append(allocator, "-Daot-engine=true") catch
            @panic("out of memory");
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
    if (needs_bindings) {
        argv.append(allocator, "-Dcomponentizer-debug-bindings=true") catch
            @panic("out of memory");
    }

    var build_env = std.process.Environ.Map.init(allocator);
    try copyEnvironment(&build_env, environ);
    try build_env.put("ZIG_GLOBAL_CACHE_DIR", zig_global_child_path);
    try build_env.put("ZIG_LOCAL_CACHE_DIR", zig_local_child_path);
    try build_env.put("ZIG_LIB_DIR", zig_install.lib_dir);
    var command_log: std.ArrayList(u8) = .empty;
    const child_directories = [_]Dir{
        zig_global.directory,
        zig_local.directory,
    };
    var inherited_count: usize = 0;
    defer {
        while (inherited_count > 0) {
            inherited_count -= 1;
            setDirectoryInherited(
                child_directories[inherited_count],
                false,
            ) catch {};
        }
    }
    for (child_directories) |directory| {
        try setDirectoryInherited(directory, true);
        inherited_count += 1;
    }
    try runtime_prefix.setPermissions(
        io,
        .fromMode(if (config.aot) 0o700 else 0o500),
    );
    diagnostic.begin(.runtime_build);
    try runCommandRedacted(
        allocator,
        io,
        "zig build runtime",
        argv.items,
        build_snapshot.absolute,
        &build_env,
        null,
        config.verbose,
        &command_log,
        diagnostic,
        &.{
            .{ .path = transaction_dir, .replacement = "<transaction>" },
            .{ .path = prefix_child_path, .replacement = prefix.path },
            .{ .path = zig_global_child_path, .replacement = zig_global.path },
            .{ .path = zig_local_child_path, .replacement = zig_local.path },
        },
        transaction,
    );
    while (inherited_count > 0) {
        inherited_count -= 1;
        try setDirectoryInherited(
            child_directories[inherited_count],
            false,
        );
    }
    try runtime_prefix.setPermissions(io, .fromMode(0o700));
    var runtime_bin = try transaction.storage.openDir(
        io,
        runtime_bin_relative,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer runtime_bin.close(io);
    try verifyNoSymlinkTree(io, runtime_bin);
    try recordDebugBackupTree(
        allocator,
        io,
        transaction,
        runtime_prefix,
        "runtime-prefix",
    );
    _ = try transaction.sealStorageTree(
        allocator,
        io,
        "runtime-prefix",
    );
    const features = resolveFeatures(config);
    if (config.aot) {
        try aot_cache.publishGenerationDirectory(
            allocator,
            io,
            try std.fs.path.join(allocator, &.{ prefix.path, "current" }),
            try std.fs.path.join(
                allocator,
                &.{
                    transaction.storage_path,
                    "runtime-prefix/.starling-aot-engine/current",
                },
            ),
            try expectedAotFeatureAbi(
                allocator,
                build_options.host_api,
                features,
            ),
            .{},
        );
    }
    try verifyCacheLayout(
        cache,
        &runtimes,
        &prefix,
        &cache_bin,
        &locks,
        cache_lock,
        &zig_global,
        &zig_local,
        io,
    );
    try verifyNoSymlinkTree(io, cache_bin.directory);

    const engine = try snapshotFileAt(
        allocator,
        io,
        runtime_bin,
        "starling-raw.wasm",
        try std.fs.path.join(allocator, &.{ transaction_dir, "engine.wasm" }),
        transaction,
    );
    if (try statEntry(runtime_bin, io, "preview1-adapter.wasm") == null) {
        return error.MissingBuildArtifact;
    }
    const generated_adapter = try snapshotFileAt(
        allocator,
        io,
        runtime_bin,
        "preview1-adapter.wasm",
        try std.fs.path.join(
            allocator,
            &.{ transaction_dir, "generated-preview1-adapter.wasm" },
        ),
        transaction,
    );
    if (!std.mem.eql(u8, generated_adapter.digest, adapter_input.digest)) {
        return error.InputChanged;
    }
    const adapter = adapter_input;
    const bindings = if (needs_bindings) blk: {
        break :blk (try snapshotFileAt(
            allocator,
            io,
            runtime_bin,
            "component-bindings.zig",
            try std.fs.path.join(allocator, &.{ transaction_dir, "component-bindings.zig" }),
            transaction,
        )).path;
    } else null;
    const build_tools = try readBuildToolManifest(
        allocator,
        io,
        runtime_bin,
        "runtime-build-tools.json",
        transaction,
    );
    try verifyCacheLayout(
        cache,
        &runtimes,
        &prefix,
        &cache_bin,
        &locks,
        cache_lock,
        &zig_global,
        &zig_local,
        io,
    );
    try verifyNoSymlinkTree(io, cache_bin.directory);

    const platform_wit = try stageRuntimeWit(
        allocator,
        io,
        runtime_bin,
        "feature-wit",
        try std.fs.path.join(allocator, &.{ transaction_dir, "runtime-feature-wit" }),
        transaction,
    );
    const runtime_component_wit = if (component_wit) |wit| wit else blk: {
        break :blk try stageRuntimeWit(
            allocator,
            io,
            runtime_bin,
            "component-wit",
            try std.fs.path.join(allocator, &.{ transaction_dir, "runtime-component-wit" }),
            transaction,
        );
    };
    const runtime_component_world = config.component_world_name orelse
        config.world_name orelse
        build_options.host_api_world;
    const surface_target_wit = if (dispatch_wit) |wit| wit else blk: {
        break :blk try stageRuntimeWit(
            allocator,
            io,
            runtime_bin,
            "surface-wit",
            try std.fs.path.join(allocator, &.{ transaction_dir, "runtime-surface-wit" }),
            transaction,
        );
    };
    const surface_target_world = config.world_name orelse "caller";
    const runtime_bin_path = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, runtime_bin_relative },
    );
    const aot = if (config.aot)
        try prepareAotRuntime(
            allocator,
            io,
            environ,
            cwd,
            config,
            engine,
            runtime_bin_path,
            build_options.host_api,
            features,
            transaction,
        )
    else
        null;
    return .{
        .engine = engine,
        .adapter = adapter,
        .component_wit = runtime_component_wit.absolute,
        .component_world = runtime_component_world,
        .surface_target_wit = surface_target_wit.absolute,
        .surface_target_world = surface_target_world,
        .platform_wit = platform_wit.absolute,
        .features = features,
        .bindings = bindings,
        .dispatch_wit_digest = surface_target_wit.digest,
        .component_wit_digest = runtime_component_wit.digest,
        .features_known = true,
        .zig = zig_install,
        .build_tools = build_tools,
        .build_root_digest = build_snapshot.digest,
        .cache_lock = lock_file,
        .aot = aot,
    };
}

const AotWevalSource = struct {
    selected: []const u8,
    package_root: []const u8,
};

fn resolveAotBundleSources(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    override: ?[]const u8,
    default_dir: []const u8,
) !struct { cache: []const u8, manifest: []const u8 } {
    const root = if (override) |path|
        try absolutePath(allocator, cwd, path)
    else
        default_dir;
    const stat = Dir.cwd().statFile(
        io,
        root,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat != null and stat.?.kind == .file) {
        return .{
            .cache = root,
            .manifest = try std.fmt.allocPrint(
                allocator,
                "{s}.manifest",
                .{root},
            ),
        };
    }
    return .{
        .cache = try std.fs.path.join(
            allocator,
            &.{ root, aot_cache.cache_basename },
        ),
        .manifest = try std.fs.path.join(
            allocator,
            &.{ root, aot_cache.manifest_basename },
        ),
    };
}

fn describeAotWevalSource(
    allocator: Allocator,
    io: Io,
    selected_path: []const u8,
) !AotWevalSource {
    if (std.mem.eql(u8, std.fs.path.basename(selected_path), "weval")) {
        if (std.fs.path.dirname(selected_path)) |parent| {
            if (std.mem.eql(u8, std.fs.path.basename(parent), "bin")) {
                if (std.fs.path.dirname(parent)) |prefix| {
                    const packaged = try std.fs.path.join(
                        allocator,
                        &.{ prefix, "weval-package", "weval" },
                    );
                    if (pathExists(io, packaged)) {
                        return describeAotWevalSource(
                            allocator,
                            io,
                            packaged,
                        );
                    }
                }
            }
        }
    }
    _ = try Dir.realPathFileAbsoluteAlloc(io, selected_path, allocator);
    const package_root = std.fs.path.dirname(selected_path) orelse
        return error.MissingAotCache;
    return .{
        .selected = selected_path,
        .package_root = package_root,
    };
}

fn resolveAotWevalSource(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    config: *const cli.Config,
    default_dir: []const u8,
) !AotWevalSource {
    if (config.weval_bin orelse environ.get("WEVAL_BIN")) |configured| {
        const executable = try resolveExecutable(
            allocator,
            io,
            environ,
            configured,
        );
        return describeAotWevalSource(allocator, io, executable);
    }
    const default_parent = std.fs.path.dirname(default_dir);
    const candidates = [_]?[]const u8{
        try std.fs.path.join(
            allocator,
            &.{ default_dir, "weval-package", "weval" },
        ),
        if (default_parent) |parent|
            try std.fs.path.join(
                allocator,
                &.{ parent, "weval-package", "weval" },
            )
        else
            null,
        try std.fs.path.join(allocator, &.{ default_dir, "weval" }),
    };
    for (candidates) |candidate_optional| {
        const candidate = candidate_optional orelse continue;
        if (pathExists(io, candidate)) {
            return describeAotWevalSource(allocator, io, candidate);
        }
    }
    return error.MissingAotCache;
}

fn expectedAotFeatureAbi(
    allocator: Allocator,
    host_api: []const u8,
    features: feature_surface.Features,
) ![]const u8 {
    return aot_cache.featureAbi(
        allocator,
        features.stdio,
        features.random,
        features.clocks,
        features.http,
        features.fetch_event,
        "ReleaseSmall",
        host_api,
        true,
    );
}

fn mapAotValidationError(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound,
        error.MissingCacheArtifact,
        => error.MissingAotCache,
        error.CorruptCache,
        error.InvalidCacheFormat,
        => error.CorruptAotCache,
        error.IncompleteCache,
        error.InvalidCacheSchema,
        error.InvalidManifest,
        error.SqliteUnavailable,
        error.SealPathAlias,
        => error.InvalidAotCache,
        error.StaleEngine,
        error.StaleFeatureAbi,
        error.StaleTool,
        => error.StaleAotCache,
        else => err,
    };
}

fn prepareAotRuntime(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    config: *const cli.Config,
    engine: Snapshot,
    default_dir: []const u8,
    host_api: []const u8,
    features: feature_surface.Features,
    transaction: *Transaction,
) !AotRuntime {
    const bundle = try resolveAotBundleSources(
        allocator,
        io,
        cwd,
        config.aot_cache_dir,
        default_dir,
    );
    const weval_source = try resolveAotWevalSource(
        allocator,
        io,
        environ,
        config,
        default_dir,
    );
    try transaction.ensureStorageDirPath(allocator, io, "aot-cache-inputs");
    const cache = captureInputFile(
        allocator,
        io,
        bundle.cache,
        try std.fs.path.join(
            allocator,
            &.{
                transaction.storage_path,
                "aot-cache-inputs",
                aot_cache.cache_basename,
            },
        ),
        transaction,
        "AOT cache",
    ) catch |err| return mapAotValidationError(err);
    const manifest = captureInputFile(
        allocator,
        io,
        bundle.manifest,
        try std.fs.path.join(
            allocator,
            &.{
                transaction.storage_path,
                "aot-cache-inputs",
                aot_cache.manifest_basename,
            },
        ),
        transaction,
        "AOT cache manifest",
    ) catch |err| return mapAotValidationError(err);
    const weval_tree = snapshotRetainedDirectory(
        allocator,
        io,
        weval_source.package_root,
        "aot-weval-package",
        weval_source.package_root,
        "starling-componentizer-aot-weval-package-v1",
        &.{},
        &.{},
        .preserve_internal,
        "weval",
        transaction,
    ) catch |err| return mapAotValidationError(err);
    const weval_path = try std.fs.path.join(
        allocator,
        &.{
            weval_tree.absolute,
            std.fs.path.basename(weval_source.selected),
        },
    );
    const weval = Snapshot{
        .path = weval_path,
        .storage_path = weval_path,
        .digest = try metadata.sha256File(allocator, io, weval_path),
        .protection = 0,
    };
    const weval_bytes = try readAbsoluteFile(allocator, io, weval.path);
    const shebang_end = std.mem.indexOfScalar(u8, weval_bytes, '\n');
    const weval_is_bash_script = if (shebang_end) |end|
        std.mem.eql(u8, weval_bytes[0..end], "#!/usr/bin/env bash") or
            std.mem.eql(u8, weval_bytes[0..end], "#!/bin/bash") or
            std.mem.eql(u8, weval_bytes[0..end], "#!/usr/bin/bash")
    else
        false;
    const retained_weval = if (weval_is_bash_script) blk: {
        try transaction.ensureStorageDirPath(
            allocator,
            io,
            "aot-weval-interpreter",
        );
        const bash_source = "/usr/bin/bash";
        const bash = try captureInputFile(
            allocator,
            io,
            bash_source,
            try std.fs.path.join(
                allocator,
                &.{ transaction.storage_path, "aot-weval-interpreter/bash" },
            ),
            transaction,
            "AOT Weval script interpreter",
        );
        break :blk try aot_pipeline.prepareRetainedSnapshotExecutable(
            allocator,
            io,
            bash.snapshot.storage_path,
            try std.fs.path.join(
                allocator,
                &.{ transaction.storage_path, "aot-weval-interpreter" },
            ),
            bash_source,
        );
    } else try aot_pipeline.prepareRetainedSnapshotExecutable(
        allocator,
        io,
        try std.fs.path.join(
            allocator,
            &.{
                transaction.storage_path,
                "aot-weval-package",
                std.fs.path.basename(weval_source.selected),
            },
        ),
        try std.fs.path.join(
            allocator,
            &.{ transaction.storage_path, "aot-weval-package" },
        ),
        weval_source.selected,
    );
    const expected_feature_abi = try expectedAotFeatureAbi(
        allocator,
        host_api,
        features,
    );
    const validated = aot_cache.validate(
        allocator,
        io,
        engine.path,
        weval.path,
        cache.snapshot.path,
        manifest.snapshot.path,
        expected_feature_abi,
    ) catch |err| return mapAotValidationError(err);
    return .{
        .weval = weval,
        .weval_tree_digest = weval_tree.digest,
        .retained_weval = retained_weval,
        .weval_is_bash_script = weval_is_bash_script,
        .cache = cache.snapshot,
        .manifest = manifest.snapshot,
        .validated = validated,
    };
}

fn snapshotZigInstallation(
    allocator: Allocator,
    io: Io,
    zig_path: []const u8,
    environ: *std.process.Environ.Map,
    resolution_cwd: []const u8,
    child_cwd: []const u8,
    transaction: *Transaction,
) !ZigSnapshot {
    const zig_absolute = try absolutePath(allocator, resolution_cwd, zig_path);
    try transaction.ensureStorageDirPath(allocator, io, "zig-install/bin");
    try transaction.ensureStorageDirPath(allocator, io, "zig-install/lib");
    const executable_path = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, "zig-install", "bin", "zig" },
    );
    const captured_zig = try captureInputFile(
        allocator,
        io,
        zig_absolute,
        executable_path,
        transaction,
        "zig",
    );
    const executable = captured_zig.snapshot;
    const zig_source = captured_zig.resolved_path;
    const lib_source = try discoverZigLibDir(
        allocator,
        io,
        zig_source,
        executable.path,
        environ,
        resolution_cwd,
        child_cwd,
        transaction,
    );
    const lib_snapshot = try snapshotRetainedDirectory(
        allocator,
        io,
        lib_source,
        "zig-install/lib",
        lib_source,
        "starling-componentizer-zig-lib-tree-v1",
        &.{},
        &.{},
        .preserve_internal,
        "zig-lib",
        transaction,
    );
    try requirePinnedZigVersion(
        allocator,
        io,
        executable.path,
        environ,
        child_cwd,
        transaction,
    );
    return .{
        .executable = executable,
        .lib_dir = lib_snapshot.absolute,
        .lib_digest = lib_snapshot.digest,
    };
}

fn requirePinnedZigVersion(
    allocator: Allocator,
    io: Io,
    zig: []const u8,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    transaction: *Transaction,
) !void {
    try transaction.prepareChild(io);
    var child_prepared = true;
    defer if (child_prepared) transaction.finishChild(io) catch {};
    try transaction.verifyRetainedIntegrity();
    try transaction.verifyChildHandleIdentities(io);
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ zig, "version" },
        .cwd = .{ .path = cwd },
        .environ_map = environ,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try transaction.verifyChildHandleIdentities(io);
    try transaction.verifyRetainedIntegrity();
    try transaction.finishChild(io);
    child_prepared = false;
    if (!termSucceeded(result.term) or
        !std.mem.eql(
            u8,
            std.mem.trim(u8, result.stdout, " \t\r\n"),
            required_zig_version,
        ))
    {
        return error.UnsupportedZigVersion;
    }
}

fn discoverZigLibDir(
    allocator: Allocator,
    io: Io,
    zig_source: []const u8,
    zig: []const u8,
    environ: *std.process.Environ.Map,
    resolution_cwd: []const u8,
    child_cwd: []const u8,
    transaction: *Transaction,
) ![]const u8 {
    const discovered = if (environ.get("ZIG_LIB_DIR")) |configured|
        try absolutePath(allocator, resolution_cwd, configured)
    else if (try inferZigLibDir(allocator, io, zig_source)) |inferred|
        inferred
    else blk: {
        try transaction.prepareChild(io);
        var child_prepared = true;
        defer if (child_prepared) transaction.finishChild(io) catch {};
        try waitForSpawnTestBarrier(
            allocator,
            io,
            transaction.environ,
            "zig env",
            .before,
        );
        try transaction.verifyRetainedIntegrity();
        try transaction.verifyChildHandleIdentities(io);
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ zig, "env" },
            .cwd = .{ .path = child_cwd },
            .environ_map = environ,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try transaction.verifyChildHandleIdentities(io);
        try transaction.verifyRetainedIntegrity();
        try waitForSpawnTestBarrier(
            allocator,
            io,
            transaction.environ,
            "zig env",
            .after,
        );
        try transaction.finishChild(io);
        child_prepared = false;
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
        break :blk try absolutePath(allocator, resolution_cwd, parsed);
    };
    return discovered;
}

fn inferZigLibDir(
    allocator: Allocator,
    io: Io,
    zig: []const u8,
) !?[]const u8 {
    const executable_dir = std.fs.path.dirname(zig) orelse return null;
    const install_root = std.fs.path.dirname(executable_dir);
    const candidates = [_]?[]const u8{
        try std.fs.path.join(allocator, &.{ executable_dir, "lib" }),
        if (install_root) |root|
            try std.fs.path.join(allocator, &.{ root, "lib", "zig" })
        else
            null,
        if (install_root) |root|
            try std.fs.path.join(allocator, &.{ root, "lib" })
        else
            null,
    };
    for (candidates) |candidate_optional| {
        const candidate = candidate_optional orelse continue;
        const stat = Dir.cwd().statFile(
            io,
            candidate,
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .directory) continue;
        return candidate;
    }
    return null;
}

fn snapshotDirectoryTree(
    allocator: Allocator,
    io: Io,
    retained_source: *RetainedInputPath,
    destination_path: []const u8,
    digest_domain: []const u8,
    included_paths: []const []const u8,
    excluded_paths: []const InputExclusion,
    symlink_policy: SnapshotSymlinkPolicy,
    transaction: *Transaction,
) ![]const u8 {
    const source_path = retained_source.resolved_path;
    const source = switch (retained_source.entry) {
        .directory => |directory| directory,
        .file => return error.InvalidPath,
    };
    try retained_source.verify(io);
    const source_stat = try source.stat(io);
    const source_identity = SourceIdentity.fromStat(source_stat);
    var destination = try Dir.openDirAbsolute(
        io,
        destination_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer destination.close(io);
    var dereferenced_targets: std.ArrayList(DereferencedTarget) = .empty;
    defer {
        for (dereferenced_targets.items) |*target| {
            target.deinit(allocator, io);
        }
        dereferenced_targets.deinit(allocator);
    }
    var target_monitor = try MutationMonitor.init();
    defer target_monitor.deinit(allocator);
    var target_protections: std.ArrayList(ProtectedTree) = .empty;
    defer target_protections.deinit(allocator);
    if (symlink_policy == .dereference_files) {
        try anchorDereferencedTargets(
            allocator,
            io,
            source,
            source_path,
            source_path,
            "",
            included_paths,
            excluded_paths,
            transaction,
            source_identity,
            &dereferenced_targets,
            &target_monitor,
            &target_protections,
        );
        if (dereferenced_targets.items.len != 0) {
            try waitForCaptureTestBarrier(
                allocator,
                io,
                transaction.environ,
                "build-root-targets",
            );
        }
    }
    const destination_relative = try std.fs.path.relative(
        allocator,
        transaction.storage_path,
        null,
        transaction.storage_path,
        destination_path,
    );
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(digest_domain);
    hasher.update(&.{0});
    _ = try copyInputDirectory(
        allocator,
        io,
        source,
        destination,
        source_path,
        "",
        destination_relative,
        "",
        included_paths,
        excluded_paths,
        symlink_policy,
        dereferenced_targets.items,
        &target_monitor,
        target_protections.items,
        transaction,
        &hasher,
    );
    if (!source_identity.matches(try source.stat(io))) return error.InputChanged;
    try retained_source.verify(io);
    try destination.setPermissions(io, source_stat.permissions);
    try sealSnapshotDirectory(io, destination);
    _ = try transaction.protectStoragePath(
        allocator,
        io,
        destination_relative,
    );
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn snapshotRetainedDirectory(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    storage_relative: []const u8,
    guest: []const u8,
    digest_domain: []const u8,
    included_paths: []const []const u8,
    excluded_paths: []const InputExclusion,
    symlink_policy: SnapshotSymlinkPolicy,
    stage: []const u8,
    transaction: *Transaction,
) !RetainedDirectory {
    var retained_source = retainAbsoluteInputDirectory(
        allocator,
        io,
        source_path,
        transaction.environ,
        stage,
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.InputChanged,
    };
    defer retained_source.deinit(allocator, io);
    return snapshotRetainedDirectoryFromHandle(
        allocator,
        io,
        &retained_source,
        storage_relative,
        guest,
        digest_domain,
        included_paths,
        excluded_paths,
        symlink_policy,
        transaction,
    );
}

fn snapshotRetainedDirectoryFromHandle(
    allocator: Allocator,
    io: Io,
    retained_source: *RetainedInputPath,
    storage_relative: []const u8,
    guest: []const u8,
    digest_domain: []const u8,
    included_paths: []const []const u8,
    excluded_paths: []const InputExclusion,
    symlink_policy: SnapshotSymlinkPolicy,
    transaction: *Transaction,
) !RetainedDirectory {
    try transaction.ensureStorageDirPath(allocator, io, storage_relative);
    const destination = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, storage_relative },
    );
    const digest = snapshotDirectoryTree(
        allocator,
        io,
        retained_source,
        destination,
        digest_domain,
        included_paths,
        excluded_paths,
        symlink_policy,
        transaction,
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.UnsupportedInputEntry,
        => return err,
        else => return error.InputChanged,
    };
    for (included_paths) |included| {
        const retained_path = try std.fs.path.join(
            allocator,
            &.{ storage_relative, included },
        );
        _ = transaction.storage.statFile(
            io,
            retained_path,
            .{ .follow_symlinks = false },
        ) catch return error.InvalidBuildRoot;
    }
    return .{
        .absolute = try transaction.retainStorageDirectory(
            allocator,
            io,
            storage_relative,
        ),
        .guest = try allocator.dupe(u8, guest),
        .digest = digest,
    };
}

fn runtimeBuildSelections(
    allocator: Allocator,
    io: Io,
    build_root: Dir,
) !BuildSelections {
    const source = build_root.readFileAlloc(
        io,
        runtime_build_manifest,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .paths = &.{},
            .manifest_digest = null,
        },
        else => return err,
    };
    var selections: std.ArrayList([]const u8) = .empty;
    selections.append(allocator, runtime_build_manifest) catch
        @panic("out of memory");
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try validatePathUtf8(line);
        if (std.fs.path.isAbsolute(line) or
            std.mem.indexOfScalar(u8, line, '\\') != null)
        {
            return error.InvalidBuildRoot;
        }
        var components = std.mem.splitScalar(u8, line, '/');
        while (components.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, ".."))
            {
                return error.InvalidBuildRoot;
            }
        }
        selections.append(allocator, try allocator.dupe(u8, line)) catch
            @panic("out of memory");
    }
    const host_api_path = try selectedHostApiPath(allocator);
    for (selections.items) |existing| {
        if (std.mem.eql(u8, existing, host_api_path)) break;
    } else {
        selections.append(allocator, host_api_path) catch
            @panic("out of memory");
    }
    return .{
        .paths = selections.toOwnedSlice(allocator) catch
            @panic("out of memory"),
        .manifest_digest = try metadata.sha256Bytes(allocator, source),
    };
}

fn selectedHostApiPath(allocator: Allocator) ![]const u8 {
    const selection = build_options.host_api;
    if (std.fs.path.isAbsolute(selection) or
        std.mem.indexOfScalar(u8, selection, '\\') != null)
    {
        return error.InvalidBuildRoot;
    }
    var components = std.mem.splitScalar(u8, selection, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return error.InvalidBuildRoot;
        }
    }
    if (std.mem.indexOfScalar(u8, selection, '/') != null) {
        return allocator.dupe(u8, selection);
    }
    return std.fs.path.join(allocator, &.{ "host-apis", selection });
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

fn captureTool(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    source: []const u8,
    storage_name: []const u8,
    capture_package: bool,
    transaction: *Transaction,
) !Snapshot {
    const resolved = try resolveConfiguredExecutable(
        allocator,
        io,
        environ,
        cwd,
        source,
    );
    if (!capture_package) {
        return (try captureInputFile(
            allocator,
            io,
            resolved,
            try std.fs.path.join(
                allocator,
                &.{ transaction.storage_path, storage_name },
            ),
            transaction,
            storage_name,
        )).snapshot;
    }

    const canonical = try Dir.realPathFileAbsoluteAlloc(
        io,
        resolved,
        allocator,
    );
    const parent = std.fs.path.dirname(canonical) orelse return error.InvalidPath;
    const basename = std.fs.path.basename(canonical);
    const storage_relative = try std.fmt.allocPrint(
        allocator,
        "{s}-package",
        .{storage_name},
    );
    const retained = try snapshotRetainedDirectory(
        allocator,
        io,
        parent,
        storage_relative,
        storage_relative,
        "starling-componentizer-tool-package-v1",
        &.{},
        &.{},
        .dereference_files,
        storage_name,
        transaction,
    );
    const path = try std.fs.path.join(
        allocator,
        &.{ retained.absolute, basename },
    );
    const storage_path = try std.fs.path.join(
        allocator,
        &.{ transaction.storage_path, storage_relative, basename },
    );
    var executable = try Dir.cwd().openFile(io, storage_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer executable.close(io);
    const digest_bytes = try hashOpenFile(io, executable);
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    return .{
        .path = path,
        .storage_path = storage_path,
        .digest = try allocator.dupe(u8, &digest_hex),
        .protection = transaction.protected.items.len - 1,
    };
}

fn sanitizedPipelinePath(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    config: *const cli.Config,
) !?[]const u8 {
    const original = environ.get("PATH") orelse return null;
    var excluded: std.ArrayList([]const u8) = .empty;
    const configured = [_]?[]const u8{
        config.wizer_bin,
        config.wasmtime_bin,
        config.wabt_bin,
        config.wasm_tools_bin,
        environ.get("WIZER_BIN"),
        environ.get("WASMTIME_BIN"),
        environ.get("WABT"),
        environ.get("WASM_TOOLS_BIN"),
    };
    for (configured) |source| {
        const value = source orelse continue;
        const resolved = resolveConfiguredExecutable(
            allocator,
            io,
            environ,
            cwd,
            value,
        ) catch continue;
        const parent = std.fs.path.dirname(resolved) orelse continue;
        var duplicate = false;
        for (excluded.items) |existing| {
            if (std.mem.eql(u8, existing, parent)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) excluded.append(
            allocator,
            try allocator.dupe(u8, parent),
        ) catch @panic("out of memory");
    }
    var result: std.ArrayList(u8) = .empty;
    var entries = std.mem.splitScalar(u8, original, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        var omit = false;
        for (excluded.items) |directory| {
            if (std.mem.eql(u8, entry, directory)) {
                omit = true;
                break;
            }
        }
        if (omit) continue;
        if (result.items.len != 0) {
            result.append(allocator, std.fs.path.delimiter) catch
                @panic("out of memory");
        }
        result.appendSlice(allocator, entry) catch @panic("out of memory");
    }
    return result.toOwnedSlice(allocator) catch @panic("out of memory");
}

fn resolveTools(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    executable_dir: []const u8,
    config: *const cli.Config,
    transaction: *Transaction,
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
        path
    else if (config.wasmtime_bin) |path|
        path
    else if (environ.get("WIZER_BIN")) |path|
        path
    else if (environ.get("WASMTIME_BIN")) |path|
        path
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
        path
    else if (environ.get("WASM_TOOLS_BIN")) |path|
        path
    else
        try siblingOrName(
            allocator,
            io,
            executable_dir,
            "wasm-tools",
            "wasm-tools",
        );
    const wabt_source = if (config.wabt_bin) |path|
        path
    else if (environ.get("WABT")) |path|
        path
    else
        try siblingOrName(allocator, io, executable_dir, "wabt", "wabt");
    const wizer: ?WizerTool = if (config.aot or config.source == null) null else WizerTool{
        .executable = try captureTool(
            allocator,
            io,
            environ,
            cwd,
            wizer_executable,
            "wizer",
            false,
            transaction,
        ),
        .wasmtime_subcommand = wizer_is_wasmtime,
    };
    const wasm_tools = try captureTool(
        allocator,
        io,
        environ,
        cwd,
        wasm_tools_source,
        "wasm-tools",
        false,
        transaction,
    );
    const wabt = try captureTool(
        allocator,
        io,
        environ,
        cwd,
        wabt_source,
        "wabt",
        config.wabt_bin != null or environ.get("WABT") != null,
        transaction,
    );
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
    _ = io;
    return absolutePath(allocator, cwd, path);
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

fn isBuildRootAt(io: Io, candidate: Dir) bool {
    const required = [_][]const u8{
        "build.zig",
        "build.zig.zon",
        "runtime/js.cpp",
        "tools/componentizer/main.zig",
    };
    for (required) |path| {
        const stat = candidate.statFile(
            io,
            path,
            .{ .follow_symlinks = false },
        ) catch return false;
        if (stat.kind != .file) return false;
    }
    return true;
}

fn stageWit(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    stage_path: []const u8,
    transaction: *Transaction,
) !StagedWit {
    var retained_source = retainAbsoluteInputDirectory(
        allocator,
        io,
        source_path,
        transaction.environ,
        "wit",
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.InputChanged,
    };
    defer retained_source.deinit(allocator, io);
    const retained_directory = switch (retained_source.entry) {
        .directory => |directory| directory,
        .file => return error.UnsupportedWitEntry,
    };
    const source_manifest = try buildTreeManifest(
        allocator,
        io,
        retained_directory,
        ".",
    );
    const stage_relative = std.fs.path.basename(stage_path);
    const capture_relative = try std.fmt.allocPrint(
        allocator,
        "{s}-source",
        .{stage_relative},
    );
    try waitForCaptureTestBarrier(
        allocator,
        io,
        transaction.environ,
        "wit",
    );
    try retained_source.verify(io);
    _ = snapshotRetainedDirectoryFromHandle(
        allocator,
        io,
        &retained_source,
        capture_relative,
        source_path,
        "starling-componentizer-wit-source-tree-v1",
        &.{},
        &.{},
        .reject,
        transaction,
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        error.UnsupportedInputEntry => return error.UnsupportedWitEntry,
        else => return error.InputChanged,
    };
    const confirmed_manifest = try buildTreeManifest(
        allocator,
        io,
        retained_directory,
        ".",
    );
    if (!source_manifest.matches(confirmed_manifest)) {
        return error.InputChanged;
    }
    var source_dir = try transaction.storage.openDir(
        io,
        capture_relative,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source_dir.close(io);
    const staged = try stageWitDirectory(
        allocator,
        io,
        source_dir,
        stage_path,
        transaction,
    );
    try retained_source.verify(io);
    return staged;
}

fn stageWitDirectory(
    allocator: Allocator,
    io: Io,
    source_dir: Dir,
    stage_path: []const u8,
    transaction: *Transaction,
) !StagedWit {
    const stage_relative = std.fs.path.basename(stage_path);
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
    var staged_directory = try transaction.storage.openDir(
        io,
        stage_relative,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer staged_directory.close(io);
    try sealSnapshotDirectory(io, staged_directory);
    _ = try transaction.protectStoragePath(
        allocator,
        io,
        stage_relative,
    );
    return .{
        .absolute = try transaction.retainStorageDirectory(
            allocator,
            io,
            stage_relative,
        ),
        .digest = digest,
    };
}

fn stageRuntimeWit(
    allocator: Allocator,
    io: Io,
    runtime_bin: Dir,
    source_path: []const u8,
    stage_path: []const u8,
    transaction: *Transaction,
) !StagedWit {
    var source = try runtime_bin.openDir(
        io,
        source_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer source.close(io);
    return stageWitDirectory(
        allocator,
        io,
        source,
        stage_path,
        transaction,
    );
}

fn runtimeKey(
    allocator: Allocator,
    config: *const cli.Config,
    dispatch_digest: ?[]const u8,
    component_digest: ?[]const u8,
    host_api_world: []const u8,
    adapter_digest: []const u8,
    needs_bindings: bool,
    build_root_digest: []const u8,
    zig: ZigSnapshot,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "schema", "3");
    hashField(&hasher, "version", build_options.version);
    hashField(&hasher, "host-api", build_options.host_api);
    hashField(&hasher, "host-api-world", host_api_world);
    hashField(&hasher, "aot", if (config.aot) "true" else "false");
    hashField(&hasher, "optimize", if (config.use_debug_build) "Debug" else "ReleaseSmall");
    hashField(&hasher, "dispatch-wit", dispatch_digest orelse "");
    hashField(&hasher, "component-wit", component_digest orelse "");
    hashField(&hasher, "preview1-adapter", adapter_digest);
    hashField(
        &hasher,
        "componentizer-debug-bindings",
        if (needs_bindings) "true" else "false",
    );
    hashField(&hasher, "build-root", build_root_digest);
    hashField(&hasher, "zig", zig.executable.digest);
    hashField(&hasher, "zig-lib", zig.lib_digest);
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
    source: InputSnapshot,
    initializer: ?InputSnapshot,
    runtime_args: []const u8,
    runtime: Runtime,
    tools: Tools,
    wabt_invoked: bool,
    preopens: []const RetainedDirectory,
    component: []const u8,
    imports: metadata.Imports,
) !metadata.Document {
    var features: std.ArrayList(metadata.Feature) = .empty;
    var feature_fields: std.ArrayList([2][]const u8) = .empty;
    if (runtime.features_known) {
        const enabled_features = [_]bool{
            runtime.features.stdio,
            runtime.features.random,
            runtime.features.clocks,
            runtime.features.http,
            runtime.features.fetch_event,
        };
        for (cli.feature_names, enabled_features) |name, enabled| {
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
        .name = runtime.surface_target_world,
        .wit_sha256 = runtime.dispatch_wit_digest,
    };
    const component_world = metadata.World{
        .name = runtime.component_world,
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
    if (tools.wizer) |wizer| {
        try appendToolSnapshot(
            allocator,
            &tool_values,
            &tool_fields,
            if (wizer.wasmtime_subcommand) "wasmtime-wizer" else "wizer",
            wizer.executable,
        );
    }
    if (runtime.aot) |aot| {
        tool_values.append(allocator, .{
            .name = "weval",
            .sha256 = aot.weval.digest,
            .lib_tree_sha256 = aot.weval_tree_digest,
        }) catch @panic("out of memory");
        tool_fields.append(
            allocator,
            .{ "weval", aot.weval.digest },
        ) catch @panic("out of memory");
        tool_fields.append(
            allocator,
            .{ "weval-package", aot.weval_tree_digest },
        ) catch @panic("out of memory");
    }
    if (wabt_invoked) {
        try appendToolSnapshot(
            allocator,
            &tool_values,
            &tool_fields,
            "wabt",
            tools.wabt,
        );
    }
    try appendToolSnapshot(
        allocator,
        &tool_values,
        &tool_fields,
        "wasm-tools",
        tools.wasm_tools,
    );

    var preopen_values: std.ArrayList(metadata.DirectoryTree) = .empty;
    for (preopens) |preopen| {
        preopen_values.append(allocator, .{
            .sha256 = preopen.digest,
        }) catch @panic("out of memory");
    }

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
                .build_root_sha256 = runtime.build_root_digest,
                .preopen_trees = if (preopen_values.items.len == 0)
                    null
                else
                    preopen_values.toOwnedSlice(allocator) catch
                        @panic("out of memory"),
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

fn resolveConfiguredExecutable(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    cwd: []const u8,
    executable: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(executable) or
        std.mem.indexOfScalar(u8, executable, std.fs.path.sep) != null)
    {
        const path = try absolutePath(allocator, cwd, executable);
        if (!try isExecutableFile(io, path))
            return error.MissingBuildArtifact;
        return path;
    }
    return resolveExecutable(allocator, io, environ, executable);
}

fn resolveExecutable(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    executable: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(executable)) {
        if (!try isExecutableFile(io, executable))
            return error.MissingBuildArtifact;
        return allocator.dupe(u8, executable);
    }
    if (std.mem.indexOfScalar(u8, executable, std.fs.path.sep) != null) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        const path = try absolutePath(allocator, cwd, executable);
        if (!try isExecutableFile(io, path))
            return error.MissingBuildArtifact;
        return path;
    }
    const path_value = environ.get("PATH") orelse return error.MissingBuildArtifact;
    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, executable });
        if (try isExecutableFile(io, candidate)) return candidate;
    }
    return error.MissingBuildArtifact;
}

fn isExecutableFile(io: Io, path: []const u8) !bool {
    const stat = Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return false,
        else => return err,
    };
    if (stat.kind != .file) return false;
    return !File.Permissions.has_executable_bit or
        stat.permissions.toMode() & 0o111 != 0;
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
    source_directory: Dir,
    manifest_path: []const u8,
    transaction: *Transaction,
) ![]const metadata.Tool {
    const transaction_dir = transaction.storage_path;
    const manifest_snapshot = try snapshotFileAt(
        allocator,
        io,
        source_directory,
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
        "";
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
        const source_path = if (manifest_dir.len == 0)
            try allocator.dupe(u8, entry.path)
        else
            try std.fs.path.join(allocator, &.{ manifest_dir, entry.path });
        const snapshot = snapshotFileAt(
            allocator,
            io,
            source_directory,
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
        ) catch |err| switch (err) {
            error.InvalidPath => return error.InvalidToolManifest,
            else => return err,
        };
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
    retained_source: *RetainedInputPath,
    retained_initializer: ?*RetainedInputPath,
    excluded_paths: []const InputExclusion,
    transaction: *Transaction,
) !InputSnapshots {
    try retained_source.verify(io);
    if (retained_initializer) |value| try value.verify(io);
    const source = retained_source.resolved_path;
    const initializer = if (retained_initializer) |value|
        value.resolved_path
    else
        null;
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
    const source_tree_input = if (shared_root) |root|
        if (std.mem.eql(u8, root, source_parent))
            retained_source
        else
            retained_initializer.?
    else
        retained_source;
    const source_tree_directory = source_tree_input.parentDirectory(
        source_tree_input.parent,
    );
    const source_file = try snapshotInputTree(
        allocator,
        io,
        source_tree_directory,
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
    const source_child_host = try transaction.retainStorageDirectory(
        allocator,
        io,
        source_tree_name,
    );
    const source_snapshot = InputSnapshot{
        .file = source_file.file,
        .logical_path = source,
        .host_dir = source_child_host,
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
                retained_initializer.?.parentDirectory(
                    retained_initializer.?.parent,
                ),
                initializer_parent.?,
                host,
                entry,
                excluded_paths,
                transaction,
            )
        else
            null;
        const shared_file_path = if (shared_root != null)
            try transaction.retainStorageFile(
                allocator,
                io,
                try std.fs.path.join(
                    allocator,
                    &.{ source_tree_name, entry },
                ),
                false,
            )
        else
            null;
        break :blk .{
            .file = if (shared_root != null)
                Snapshot{
                    .path = shared_file_path.?,
                    .storage_path = try std.fs.path.join(
                        allocator,
                        &.{ source_host, entry },
                    ),
                    .digest = try metadata.sha256File(
                        allocator,
                        io,
                        try std.fs.path.join(
                            allocator,
                            &.{ source_child_host, entry },
                        ),
                    ),
                    .protection = source_snapshot.file.protection,
                }
            else
                distinct_tree.?.file,
            .logical_path = path,
            .host_dir = if (shared_root != null)
                source_child_host
            else
                try transaction.retainStorageDirectory(
                    allocator,
                    io,
                    "inputs/initializer",
                ),
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

    try retained_source.verify(io);
    if (retained_initializer) |value| try value.verify(io);
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

    fn matchesRetained(self: SourceIdentity, stat: File.Stat) bool {
        return self.entry.matches(stat) and
            self.size == stat.size and
            self.mtime.nanoseconds == stat.mtime.nanoseconds;
    }
};

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

const DeviceIdentity = struct {
    major: u32,
    minor: u32,
};

fn deviceIdentityMatches(expected: DeviceIdentity, actual: DeviceIdentity) bool {
    return expected.major == actual.major and expected.minor == actual.minor;
}

fn linuxDeviceForHandle(handle: std.posix.fd_t) !DeviceIdentity {
    if (builtin.os.tag != .linux) return .{ .major = 0, .minor = 0 };
    const linux = std.os.linux;
    while (true) {
        var statx = std.mem.zeroes(linux.Statx);
        switch (linux.errno(linux.statx(
            handle,
            "",
            linux.AT.EMPTY_PATH | linux.AT.NO_AUTOMOUNT,
            linux.STATX.BASIC_STATS,
            &statx,
        ))) {
            .SUCCESS => return .{
                .major = statx.dev_major,
                .minor = statx.dev_minor,
            },
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn linuxDeviceAt(
    directory: Dir,
    path: []const u8,
) !DeviceIdentity {
    if (builtin.os.tag != .linux) return .{ .major = 0, .minor = 0 };
    const linux = std.os.linux;
    const path_z = try std.posix.toPosixPath(path);
    while (true) {
        var statx = std.mem.zeroes(linux.Statx);
        switch (linux.errno(linux.statx(
            directory.handle,
            &path_z,
            linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW,
            linux.STATX.BASIC_STATS,
            &statx,
        ))) {
            .SUCCESS => return .{
                .major = statx.dev_major,
                .minor = statx.dev_minor,
            },
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT, .NOTDIR => return error.TransactionChanged,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn updateManifestDigest(
    hasher: *std.crypto.hash.sha2.Sha256,
    entry: ManifestEntry,
) void {
    var buffer: [256]u8 = undefined;
    hasher.update(entry.path);
    hasher.update(&.{0});
    hasher.update(@tagName(entry.kind));
    hasher.update(&.{0});
    const fields = std.fmt.bufPrint(
        &buffer,
        "{d}:{d}:{d}:{d}:{d}:{d}:{d}:{d}:{d}",
        .{
            entry.device_major,
            entry.device_minor,
            entry.inode,
            entry.nlink,
            entry.size,
            entry.mode,
            entry.mtime.nanoseconds,
            entry.ctime.nanoseconds,
            if (entry.link_target) |target| target.len else 0,
        },
    ) catch unreachable;
    hasher.update(fields);
    hasher.update(&.{0});
    if (entry.link_target) |target| hasher.update(target);
    hasher.update(&.{0});
    hasher.update(&entry.content_digest);
    hasher.update(&.{0xff});
}

fn digestManifestEntries(
    entries: []const ManifestEntry,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("starling-componentizer-exact-tree-manifest-v1\x00");
    for (entries) |entry| updateManifestDigest(&hasher, entry);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashOpenFile(
    io: Io,
    file: File,
) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) continue;
        hasher.update(buffer[0..count]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn appendManifestEntry(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    name: []const u8,
    relative: []const u8,
    expected: SourceIdentity,
    entries: *std.ArrayList(ManifestEntry),
) !void {
    const current = try parent.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    );
    if (!expected.matches(current)) return error.TransactionChanged;
    switch (expected.entry.kind) {
        .file => {
            var file = try parent.openFile(io, name, .{
                .mode = .read_only,
                .allow_directory = false,
                .follow_symlinks = false,
            });
            defer file.close(io);
            if (!expected.matches(try file.stat(io))) {
                return error.TransactionChanged;
            }
            const device = try linuxDeviceForHandle(file.handle);
            const digest = try hashOpenFile(io, file);
            if (!expected.matches(try file.stat(io)) or
                !expected.matches(try parent.statFile(
                    io,
                    name,
                    .{ .follow_symlinks = false },
                )))
            {
                return error.TransactionChanged;
            }
            entries.append(allocator, .{
                .path = try allocator.dupe(u8, relative),
                .kind = .file,
                .device_major = device.major,
                .device_minor = device.minor,
                .inode = current.inode,
                .nlink = current.nlink,
                .size = current.size,
                .mode = current.permissions.toMode(),
                .mtime = current.mtime,
                .ctime = current.ctime,
                .link_target = null,
                .content_digest = digest,
            }) catch @panic("out of memory");
        },
        .sym_link => {
            var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const target_length = try parent.readLink(
                io,
                name,
                &target_buffer,
            );
            const target = try allocator.dupe(
                u8,
                target_buffer[0..target_length],
            );
            if (!expected.matches(try parent.statFile(
                io,
                name,
                .{ .follow_symlinks = false },
            ))) return error.TransactionChanged;
            const device = try linuxDeviceAt(parent, name);
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(target);
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
                undefined;
            hasher.final(&digest);
            entries.append(allocator, .{
                .path = try allocator.dupe(u8, relative),
                .kind = .sym_link,
                .device_major = device.major,
                .device_minor = device.minor,
                .inode = current.inode,
                .nlink = current.nlink,
                .size = current.size,
                .mode = current.permissions.toMode(),
                .mtime = current.mtime,
                .ctime = current.ctime,
                .link_target = target,
                .content_digest = digest,
            }) catch @panic("out of memory");
        },
        .directory => {
            var directory = try parent.openDir(
                io,
                name,
                .{ .iterate = true, .follow_symlinks = false },
            );
            defer directory.close(io);
            if (!expected.matches(try directory.stat(io))) {
                return error.TransactionChanged;
            }
            const device = try linuxDeviceForHandle(directory.handle);
            const manifest_index = entries.items.len;
            entries.append(allocator, .{
                .path = try allocator.dupe(u8, relative),
                .kind = .directory,
                .device_major = device.major,
                .device_minor = device.minor,
                .inode = current.inode,
                .nlink = current.nlink,
                .size = current.size,
                .mode = current.permissions.toMode(),
                .mtime = current.mtime,
                .ctime = current.ctime,
                .link_target = null,
                .content_digest = @splat(0),
            }) catch @panic("out of memory");

            const Child = struct {
                name: []const u8,
                identity: SourceIdentity,
            };
            var children: std.ArrayList(Child) = .empty;
            defer children.deinit(allocator);
            var iterator = directory.iterate();
            while (try iterator.next(io)) |child| {
                try validatePathUtf8(child.name);
                const stat = try directory.statFile(
                    io,
                    child.name,
                    .{ .follow_symlinks = false },
                );
                if (stat.kind != .file and
                    stat.kind != .directory and
                    stat.kind != .sym_link)
                {
                    return error.TransactionChanged;
                }
                children.append(allocator, .{
                    .name = try allocator.dupe(u8, child.name),
                    .identity = SourceIdentity.fromStat(stat),
                }) catch @panic("out of memory");
            }
            std.mem.sort(Child, children.items, {}, struct {
                fn lessThan(_: void, left: Child, right: Child) bool {
                    return std.mem.lessThan(u8, left.name, right.name);
                }
            }.lessThan);
            const descendants_start = entries.items.len;
            for (children.items) |child| {
                try appendManifestEntry(
                    allocator,
                    io,
                    directory,
                    child.name,
                    if (std.mem.eql(u8, relative, "."))
                        try allocator.dupe(u8, child.name)
                    else
                        try std.fmt.allocPrint(
                            allocator,
                            "{s}/{s}",
                            .{ relative, child.name },
                        ),
                    child.identity,
                    entries,
                );
            }
            var seen: usize = 0;
            var final_iterator = directory.iterate();
            while (try final_iterator.next(io)) |child| {
                const stat = try directory.statFile(
                    io,
                    child.name,
                    .{ .follow_symlinks = false },
                );
                for (children.items) |initial| {
                    if (!std.mem.eql(u8, initial.name, child.name)) continue;
                    if (!initial.identity.matches(stat)) {
                        return error.TransactionChanged;
                    }
                    seen += 1;
                    break;
                } else return error.TransactionChanged;
            }
            if (seen != children.items.len or
                !expected.matches(try directory.stat(io)) or
                !expected.matches(try parent.statFile(
                    io,
                    name,
                    .{ .follow_symlinks = false },
                )))
            {
                return error.TransactionChanged;
            }
            entries.items[manifest_index].content_digest =
                digestManifestEntries(entries.items[descendants_start..]);
        },
        else => return error.TransactionChanged,
    }
}

fn buildTreeManifest(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    path: []const u8,
) !TreeManifest {
    const stat = try parent.statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    );
    var entries: std.ArrayList(ManifestEntry) = .empty;
    try appendManifestEntry(
        allocator,
        io,
        parent,
        path,
        ".",
        SourceIdentity.fromStat(stat),
        &entries,
    );
    const owned = entries.toOwnedSlice(allocator) catch
        @panic("out of memory");
    return .{
        .entries = owned,
        .digest = digestManifestEntries(owned),
    };
}

fn snapshotInputTree(
    allocator: Allocator,
    io: Io,
    source_dir: Dir,
    source_path: []const u8,
    destination_path: []const u8,
    entry_name: []const u8,
    excluded_paths: []const InputExclusion,
    transaction: *Transaction,
) !TreeSnapshot {
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
        &.{},
        excluded_paths,
        .preserve_internal,
        &.{},
        null,
        &.{},
        transaction,
        &tree_hasher,
    );
    if (!source_identity.matches(try source_dir.stat(io))) {
        return error.InputChanged;
    }
    try sealSnapshotDirectory(io, destination_dir);
    const protection = try transaction.protectStoragePath(
        allocator,
        io,
        destination_relative,
    );
    const file_relative = try std.fs.path.join(
        allocator,
        &.{ destination_relative, normalized_entry },
    );
    const child_file_path = try transaction.retainStorageFile(
        allocator,
        io,
        file_relative,
        false,
    );
    var tree_digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
        undefined;
    tree_hasher.final(&tree_digest_bytes);
    const tree_digest_hex = std.fmt.bytesToHex(tree_digest_bytes, .lower);
    return .{
        .file = .{
            .path = child_file_path,
            .storage_path = try std.fs.path.join(
                allocator,
                &.{ destination_path, entry_name },
            ),
            .digest = file_digest orelse return error.MissingBuildArtifact,
            .protection = protection,
        },
        .entry = normalized_entry,
        .digest = try allocator.dupe(u8, &tree_digest_hex),
    };
}

fn sealSnapshotDirectory(io: Io, directory: Dir) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var child = try directory.openDir(
                    io,
                    entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                sealSnapshotDirectory(io, child) catch |err| {
                    child.close(io);
                    return err;
                };
                child.close(io);
            },
            .file => {
                var file = try directory.openFile(io, entry.name, .{
                    .mode = .read_only,
                    .allow_directory = false,
                    .follow_symlinks = false,
                });
                const stat = file.stat(io) catch |err| {
                    file.close(io);
                    return err;
                };
                file.setPermissions(
                    io,
                    .fromMode(
                        stat.permissions.toMode() &
                            ~@as(std.posix.mode_t, 0o222),
                    ),
                ) catch |err| {
                    file.close(io);
                    return err;
                };
                file.close(io);
            },
            .sym_link => {},
            else => return error.UnsupportedInputEntry,
        }
    }
    const stat = try directory.stat(io);
    try directory.setPermissions(
        io,
        .fromMode(
            stat.permissions.toMode() &
                ~@as(std.posix.mode_t, 0o222),
        ),
    );
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

fn retainSymlinkNoFollow(
    io: Io,
    parent: Dir,
    name: []const u8,
    expected: SourceIdentity,
) !File {
    if (builtin.os.tag != .linux) return error.UnsupportedInputEntry;
    const handle = std.posix.openat(parent.handle, name, .{
        .PATH = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.SymLinkLoop,
        => return error.InputChanged,
        else => return err,
    };
    var link = File{
        .handle = handle,
        .flags = .{ .nonblocking = false },
    };
    errdefer link.close(io);
    if (!expected.matches(try link.stat(io))) return error.InputChanged;
    return link;
}

fn readBoundSymlink(
    io: Io,
    expected: SourceIdentity,
    retained: File,
    buffer: []u8,
) !usize {
    if (builtin.os.tag != .linux) return error.InputChanged;
    if (!expected.matchesRetained(try retained.stat(io))) {
        return error.InputChanged;
    }
    const linux = std.os.linux;
    while (true) {
        const result = linux.readlinkat(
            retained.handle,
            "",
            buffer.ptr,
            buffer.len,
        );
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (!expected.matchesRetained(try retained.stat(io))) {
                    return error.InputChanged;
                }
                if (result == buffer.len) return error.NameTooLong;
                return @intCast(result);
            },
            .INTR => continue,
            .NOENT, .NOTDIR, .INVAL => return error.InputChanged,
            .NAMETOOLONG => return error.NameTooLong,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn anchorDereferencedTarget(
    allocator: Allocator,
    io: Io,
    source_root_path: []const u8,
    source_parent_path: []const u8,
    source_parent: Dir,
    link_name: []const u8,
    link_path: []const u8,
    link_identity: SourceIdentity,
    root_identity: SourceIdentity,
    environ: *std.process.Environ.Map,
) !DereferencedTarget {
    const link_handle = try retainSymlinkNoFollow(
        io,
        source_parent,
        link_name,
        link_identity,
    );
    errdefer link_handle.close(io);
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try waitForSymlinkReadTestBarrier(
        allocator,
        io,
        environ,
        .first_before,
    );
    const link_len = try readBoundSymlink(
        io,
        link_identity,
        link_handle,
        &link_buffer,
    );
    try waitForSymlinkReadTestBarrier(
        allocator,
        io,
        environ,
        .first_after,
    );
    const link_target = link_buffer[0..link_len];
    const target_absolute = try std.fs.path.resolve(
        allocator,
        if (std.fs.path.isAbsolute(link_target))
            &.{link_target}
        else
            &.{ source_parent_path, link_target },
    );
    if (!pathContains(source_root_path, target_absolute) or
        std.mem.eql(u8, source_root_path, target_absolute))
    {
        return error.UnsupportedInputEntry;
    }
    const target_relative = target_absolute[source_root_path.len + 1 ..];
    try validateArgument(target_relative);

    var root = try Dir.openDirAbsolute(
        io,
        source_root_path,
        .{ .iterate = true, .follow_symlinks = false },
    );
    errdefer root.close(io);
    if (!root_identity.matches(try root.stat(io))) {
        return error.InputChanged;
    }
    var directories: std.ArrayList(AnchoredTargetDirectory) = .empty;
    errdefer {
        var index = directories.items.len;
        while (index > 0) {
            index -= 1;
            directories.items[index].directory.close(io);
        }
        directories.deinit(allocator);
    }
    if (std.fs.path.dirname(target_relative)) |parent_path| {
        var components = std.mem.splitScalar(
            u8,
            parent_path,
            std.fs.path.sep,
        );
        while (components.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, ".."))
            {
                return error.UnsupportedInputEntry;
            }
            const parent = if (directories.items.len == 0)
                root
            else
                directories.items[directories.items.len - 1].directory;
            const stat = try parent.statFile(
                io,
                component,
                .{ .follow_symlinks = false },
            );
            if (stat.kind != .directory) {
                return error.UnsupportedInputEntry;
            }
            const identity = SourceIdentity.fromStat(stat);
            const child = try parent.openDir(
                io,
                component,
                .{ .iterate = true, .follow_symlinks = false },
            );
            errdefer child.close(io);
            if (!identity.matches(try child.stat(io)) or
                !identity.matches(try parent.statFile(
                    io,
                    component,
                    .{ .follow_symlinks = false },
                )))
            {
                return error.InputChanged;
            }
            directories.append(allocator, .{
                .name = try allocator.dupe(u8, component),
                .identity = identity,
                .directory = child,
            }) catch @panic("out of memory");
        }
    }
    const basename = std.fs.path.basename(target_relative);
    const parent = if (directories.items.len == 0)
        root
    else
        directories.items[directories.items.len - 1].directory;
    const target_stat = try parent.statFile(
        io,
        basename,
        .{ .follow_symlinks = false },
    );
    if (target_stat.kind != .file) return error.UnsupportedInputEntry;
    const entry_identity = SourceIdentity.fromStat(target_stat);
    var file = try parent.openFile(io, basename, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    errdefer file.close(io);
    const file_identity = SourceIdentity.fromStat(try file.stat(io));
    if (!entry_identity.matches(try file.stat(io)) or
        !entry_identity.matches(try parent.statFile(
            io,
            basename,
            .{ .follow_symlinks = false },
        )))
    {
        return error.InputChanged;
    }
    return .{
        .link_path = try allocator.dupe(u8, link_path),
        .link_target = try allocator.dupe(u8, link_target),
        .link_identity = link_identity,
        .link_handle = link_handle,
        .root = root,
        .root_identity = root_identity,
        .directories = directories.toOwnedSlice(allocator) catch
            @panic("out of memory"),
        .basename = try allocator.dupe(u8, basename),
        .entry_identity = entry_identity,
        .file = file,
        .file_identity = file_identity,
        .guard_root = try allocator.dupe(u8, target_absolute),
        .guard_index = 0,
    };
}

fn anchorDereferencedTargets(
    allocator: Allocator,
    io: Io,
    source: Dir,
    source_root_path: []const u8,
    source_path: []const u8,
    relative: []const u8,
    included_paths: []const []const u8,
    excluded_paths: []const InputExclusion,
    transaction: *Transaction,
    root_identity: SourceIdentity,
    targets: *std.ArrayList(DereferencedTarget),
    target_monitor: *MutationMonitor,
    target_protections: *std.ArrayList(ProtectedTree),
) !void {
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
        if (transaction.isRootEntry(child_source_path, stat)) continue;
        const child_relative = if (relative.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ relative, entry.name },
            );
        if (!treePathSelected(child_relative, included_paths)) continue;
        var excluded = false;
        for (excluded_paths) |candidate| {
            if (candidate.matches(child_source_path, stat)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        const identity = SourceIdentity.fromStat(stat);
        switch (stat.kind) {
            .directory => {
                var child = try source.openDir(
                    io,
                    entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                defer child.close(io);
                if (!identity.matches(try child.stat(io))) {
                    return error.InputChanged;
                }
                try anchorDereferencedTargets(
                    allocator,
                    io,
                    child,
                    source_root_path,
                    child_source_path,
                    child_relative,
                    included_paths,
                    excluded_paths,
                    transaction,
                    root_identity,
                    targets,
                    target_monitor,
                    target_protections,
                );
                if (!identity.entry.matches(try child.stat(io)) or
                    !identity.entry.matches(try source.statFile(
                        io,
                        entry.name,
                        .{ .follow_symlinks = false },
                    )))
                {
                    return error.InputChanged;
                }
            },
            .sym_link => {
                var target = try anchorDereferencedTarget(
                    allocator,
                    io,
                    source_root_path,
                    source_path,
                    source,
                    entry.name,
                    child_relative,
                    identity,
                    root_identity,
                    transaction.environ,
                );
                errdefer target.deinit(allocator, io);
                const guard_index = target_protections.items.len;
                const manifest = try buildTreeManifest(
                    allocator,
                    io,
                    .cwd(),
                    target.guard_root,
                );
                target_protections.append(allocator, .{
                    .location = .storage,
                    .path = target.guard_root,
                    .manifest = manifest,
                }) catch @panic("out of memory");
                try target_monitor.add(
                    allocator,
                    target.guard_root,
                    guard_index,
                    true,
                );
                try target_monitor.check(
                    target_protections.items,
                    null,
                    null,
                );
                const confirmed = try buildTreeManifest(
                    allocator,
                    io,
                    .cwd(),
                    target.guard_root,
                );
                if (!manifest.matches(confirmed)) return error.InputChanged;
                try target_monitor.check(
                    target_protections.items,
                    null,
                    null,
                );
                target.guard_index = guard_index;
                targets.append(allocator, target) catch @panic("out of memory");
            },
            .file => {},
            else => return error.UnsupportedInputEntry,
        }
    }
}

fn findDereferencedTarget(
    targets: []DereferencedTarget,
    link_path: []const u8,
) ?*DereferencedTarget {
    for (targets) |*target| {
        if (std.mem.eql(u8, target.link_path, link_path)) return target;
    }
    return null;
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
    included_paths: []const []const u8,
    excluded_paths: []const InputExclusion,
    symlink_policy: SnapshotSymlinkPolicy,
    dereferenced_targets: []DereferencedTarget,
    target_monitor: ?*MutationMonitor,
    target_protections: []ProtectedTree,
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
        const selected_path = if (relative.len == 0)
            entry.name
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ relative, entry.name },
            );
        if (!treePathSelected(selected_path, included_paths)) continue;
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
                const child_digest = try copyInputDirectory(
                    allocator,
                    io,
                    source_child,
                    destination_child,
                    child_source_path,
                    child_relative,
                    owned_path,
                    digest_entry,
                    included_paths,
                    excluded_paths,
                    symlink_policy,
                    dereferenced_targets,
                    target_monitor,
                    target_protections,
                    transaction,
                    tree_hasher,
                );
                if (child_digest) |digest| {
                    if (selected_digest != null) {
                        return error.TransactionChanged;
                    }
                    selected_digest = digest;
                }
                if (!entry.identity.entry.matches(try source_child.stat(io))) {
                    return error.InputChanged;
                }
                try destination_child.setPermissions(
                    io,
                    (try source_child.stat(io)).permissions,
                );
            },
            .sym_link => {
                if (symlink_policy == .reject) {
                    return error.UnsupportedInputEntry;
                }
                if (symlink_policy == .dereference_files) {
                    const target = findDereferencedTarget(
                        dereferenced_targets,
                        child_relative,
                    ) orelse return error.InputChanged;
                    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    try waitForSymlinkReadTestBarrier(
                        allocator,
                        io,
                        transaction.environ,
                        .second_before,
                    );
                    const link_len = try readBoundSymlink(
                        io,
                        entry.identity,
                        target.link_handle,
                        &link_buffer,
                    );
                    try waitForSymlinkReadTestBarrier(
                        allocator,
                        io,
                        transaction.environ,
                        .second_after,
                    );
                    if (!entry.identity.matches(try source.statFile(
                        io,
                        entry.name,
                        .{ .follow_symlinks = false },
                    )) or
                        !target.link_identity.matches(try source.statFile(
                            io,
                            entry.name,
                            .{ .follow_symlinks = false },
                        )) or
                        !std.mem.eql(
                            u8,
                            target.link_target,
                            link_buffer[0..link_len],
                        ))
                    {
                        return error.InputChanged;
                    }
                    try target.verify(
                        allocator,
                        io,
                        target_monitor orelse return error.InputChanged,
                        target_protections,
                    );
                    hashTreeEntryHeader(
                        tree_hasher,
                        'f',
                        child_relative,
                        target.file_identity.size,
                    );
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
                    var buffer: [64 * 1024]u8 = undefined;
                    while (true) {
                        const count = target.file.readStreaming(
                            io,
                            &.{&buffer},
                        ) catch |err| switch (err) {
                            error.EndOfStream => break,
                            else => return err,
                        };
                        if (count == 0) continue;
                        tree_hasher.update(buffer[0..count]);
                        try destination_file.writeStreamingAll(
                            io,
                            buffer[0..count],
                        );
                    }
                    tree_hasher.update(&.{0xff});
                    try target.verify(
                        allocator,
                        io,
                        target_monitor orelse return error.InputChanged,
                        target_protections,
                    );
                    if (!entry.identity.matches(try source.statFile(
                        io,
                        entry.name,
                        .{ .follow_symlinks = false },
                    ))) {
                        return error.InputChanged;
                    }
                    try destination_file.setPermissions(
                        io,
                        (try target.file.stat(io)).permissions,
                    );
                    try destination_file.sync(io);
                    continue;
                }
                const retained_link = try retainSymlinkNoFollow(
                    io,
                    source,
                    entry.name,
                    entry.identity,
                );
                defer retained_link.close(io);
                var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_len = try readBoundSymlink(
                    io,
                    entry.identity,
                    retained_link,
                    &link_buffer,
                );
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
        const selected_path = if (relative.len == 0)
            entry.name
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ relative, entry.name },
            );
        if (!treePathSelected(selected_path, included_paths)) continue;
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

fn treePathSelected(
    path: []const u8,
    included_paths: []const []const u8,
) bool {
    if (included_paths.len == 0) return true;
    for (included_paths) |selected| {
        if (std.mem.eql(u8, path, selected) or
            isRelativeDescendant(path, selected) or
            isRelativeDescendant(selected, path))
        {
            return true;
        }
    }
    return false;
}

fn isRelativeDescendant(path: []const u8, parent: []const u8) bool {
    return path.len > parent.len and
        std.mem.startsWith(u8, path, parent) and
        path[parent.len] == '/';
}

fn retainAbsoluteInputFile(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    environ: *std.process.Environ.Map,
    stage: []const u8,
) !RetainedInputPath {
    return retainAbsoluteInputPath(
        allocator,
        io,
        path,
        environ,
        stage,
        .file,
        false,
    );
}

fn retainAbsoluteInputDirectory(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    environ: *std.process.Environ.Map,
    stage: []const u8,
) !RetainedInputPath {
    return retainAbsoluteInputPath(
        allocator,
        io,
        path,
        environ,
        stage,
        .directory,
        false,
    );
}

fn retainOrCreateAbsoluteDirectory(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    environ: *std.process.Environ.Map,
    stage: []const u8,
) !RetainedInputPath {
    return retainAbsoluteInputPath(
        allocator,
        io,
        path,
        environ,
        stage,
        .directory,
        true,
    );
}

fn retainAbsoluteInputPath(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    environ: *std.process.Environ.Map,
    stage: []const u8,
    expected_kind: RetainedInputKind,
    create_missing_directories: bool,
) !RetainedInputPath {
    if (std.fs.path.sep != '/' or
        !std.fs.path.isAbsolute(path) or
        std.mem.eql(u8, path, "/"))
    {
        return error.UnsupportedInputEntry;
    }
    var root = try Dir.openDirAbsolute(
        io,
        "/",
        .{ .iterate = true, .follow_symlinks = false },
    );
    errdefer root.close(io);
    var root_identity = SourceIdentity.fromStat(try root.stat(io));
    const root_device = try linuxDeviceForHandle(root.handle);
    var nodes: std.ArrayList(RetainedInputPathNode) = .empty;
    errdefer {
        var index = nodes.items.len;
        while (index > 0) {
            index -= 1;
            const node = nodes.items[index];
            if (node.directory) |directory| directory.close(io);
            if (node.symlink) |link| link.close(io);
            if (node.link_target) |target| allocator.free(target);
            allocator.free(node.name);
        }
        nodes.deinit(allocator);
    }
    var current_path = try allocator.dupe(u8, path);
    var symlink_count: usize = 0;
    resolve: while (true) {
        var components: std.ArrayList([]const u8) = .empty;
        defer components.deinit(allocator);
        var split = std.mem.splitScalar(u8, current_path[1..], '/');
        while (split.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, ".."))
            {
                return error.UnsupportedInputEntry;
            }
            components.append(allocator, component) catch
                @panic("out of memory");
        }
        if (components.items.len == 0) return error.UnsupportedInputEntry;

        var parent = root;
        var parent_node: ?usize = null;
        var parent_absolute: []const u8 = "/";
        for (components.items, 0..) |component, component_index| {
            const stat = parent.statFile(
                io,
                component,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    if (!create_missing_directories or
                        expected_kind != .directory)
                    {
                        return err;
                    }
                    return createRetainedDirectoryTail(
                        allocator,
                        io,
                        root,
                        &root_identity,
                        root_device,
                        &nodes,
                        parent_node,
                        parent,
                        components.items[component_index..],
                        current_path,
                    );
                },
                else => return err,
            };
            const identity = SourceIdentity.fromStat(stat);
            const device = try linuxDeviceAt(parent, component);

            if (stat.kind == .sym_link) {
                if (symlink_count == 40) return error.UnsupportedInputEntry;
                symlink_count += 1;
                const link = try retainSymlinkNoFollow(
                    io,
                    parent,
                    component,
                    identity,
                );
                errdefer link.close(io);
                try waitForInputSymlinkTestBarrier(
                    allocator,
                    io,
                    environ,
                    stage,
                    .before_read,
                );
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const link_length = try readBoundSymlink(
                    io,
                    identity,
                    link,
                    &buffer,
                );
                try waitForInputSymlinkTestBarrier(
                    allocator,
                    io,
                    environ,
                    stage,
                    .after_read,
                );
                if (!identity.matches(try parent.statFile(
                    io,
                    component,
                    .{ .follow_symlinks = false },
                )) or
                    !deviceIdentityMatches(
                        device,
                        try linuxDeviceAt(parent, component),
                    ))
                {
                    return error.InputChanged;
                }
                const link_target = try allocator.dupe(
                    u8,
                    buffer[0..link_length],
                );
                nodes.append(allocator, .{
                    .parent = parent_node,
                    .name = try allocator.dupe(u8, component),
                    .identity = identity,
                    .device = device,
                    .symlink = link,
                    .link_target = link_target,
                }) catch @panic("out of memory");
                const target_absolute = try std.fs.path.resolve(
                    allocator,
                    if (std.fs.path.isAbsolute(link_target))
                        &.{link_target}
                    else
                        &.{ parent_absolute, link_target },
                );
                if (component_index + 1 == components.items.len) {
                    current_path = target_absolute;
                } else {
                    const remaining = try std.fs.path.join(
                        allocator,
                        components.items[component_index + 1 ..],
                    );
                    current_path = try std.fs.path.resolve(
                        allocator,
                        &.{ target_absolute, remaining },
                    );
                }
                continue :resolve;
            }

            if (component_index + 1 == components.items.len) {
                if ((expected_kind == .file and stat.kind != .file) or
                    (expected_kind == .directory and stat.kind != .directory))
                {
                    return error.UnsupportedInputEntry;
                }
                try waitForAdapterRetainTestBarrier(
                    allocator,
                    io,
                    environ,
                    component,
                    .before_open,
                );
                const retained: RetainedInputHandle = switch (expected_kind) {
                    .file => .{ .file = try parent.openFile(io, component, .{
                        .mode = .read_only,
                        .allow_directory = false,
                        .follow_symlinks = false,
                    }) },
                    .directory => .{ .directory = try parent.openDir(
                        io,
                        component,
                        .{ .iterate = true, .follow_symlinks = false },
                    ) },
                };
                errdefer switch (retained) {
                    .file => |file| file.close(io),
                    .directory => |directory| directory.close(io),
                };
                try waitForAdapterRetainTestBarrier(
                    allocator,
                    io,
                    environ,
                    component,
                    .after_open,
                );
                const retained_stat = switch (retained) {
                    .file => |file| try file.stat(io),
                    .directory => |directory| try directory.stat(io),
                };
                const retained_identity = SourceIdentity.fromStat(retained_stat);
                const retained_device = switch (retained) {
                    .file => |file| try linuxDeviceForHandle(file.handle),
                    .directory => |directory| try linuxDeviceForHandle(directory.handle),
                };
                const namespace_stat = try parent.statFile(
                    io,
                    component,
                    .{ .follow_symlinks = false },
                );
                const retained_matches = if (create_missing_directories and
                    expected_kind == .directory)
                    identity.entry.matches(retained_stat)
                else
                    identity.matches(retained_stat);
                const namespace_matches = if (create_missing_directories and
                    expected_kind == .directory)
                    retained_identity.entry.matches(namespace_stat)
                else
                    retained_identity.matches(namespace_stat);
                if (!retained_matches or
                    !namespace_matches or
                    !deviceIdentityMatches(device, retained_device) or
                    !deviceIdentityMatches(
                        device,
                        try linuxDeviceAt(parent, component),
                    ))
                {
                    return error.InputChanged;
                }
                return .{
                    .root = root,
                    .root_identity = root_identity,
                    .root_device = root_device,
                    .nodes = nodes.toOwnedSlice(allocator) catch
                        @panic("out of memory"),
                    .parent = parent_node,
                    .basename = try allocator.dupe(u8, component),
                    .entry_identity = identity,
                    .entry_device = device,
                    .entry = retained,
                    .retained_identity = retained_identity,
                    .retained_device = retained_device,
                    .resolved_path = try allocator.dupe(u8, current_path),
                };
            }

            if (stat.kind != .directory) {
                return error.UnsupportedInputEntry;
            }
            try waitForAdapterRetainTestBarrier(
                allocator,
                io,
                environ,
                component,
                .before_open,
            );
            const child = try parent.openDir(
                io,
                component,
                .{ .iterate = true, .follow_symlinks = false },
            );
            errdefer child.close(io);
            try waitForAdapterRetainTestBarrier(
                allocator,
                io,
                environ,
                component,
                .after_open,
            );
            const child_stat = try child.stat(io);
            const namespace_stat = try parent.statFile(
                io,
                component,
                .{ .follow_symlinks = false },
            );
            const child_matches = if (create_missing_directories)
                identity.entry.matches(child_stat)
            else
                identity.matches(child_stat);
            const namespace_matches = if (create_missing_directories)
                identity.entry.matches(namespace_stat)
            else
                identity.matches(namespace_stat);
            if (!child_matches or
                !namespace_matches or
                !deviceIdentityMatches(
                    device,
                    try linuxDeviceForHandle(child.handle),
                ) or
                !deviceIdentityMatches(
                    device,
                    try linuxDeviceAt(parent, component),
                ))
            {
                return error.InputChanged;
            }
            nodes.append(allocator, .{
                .parent = parent_node,
                .name = try allocator.dupe(u8, component),
                .identity = identity,
                .device = device,
                .directory = child,
            }) catch @panic("out of memory");
            parent_node = nodes.items.len - 1;
            parent = child;
            parent_absolute = try std.fs.path.join(
                allocator,
                &.{ parent_absolute, component },
            );
        }
        unreachable;
    }
}

fn refreshRetainedCreatedParent(
    io: Io,
    root: Dir,
    root_identity: *SourceIdentity,
    root_device: DeviceIdentity,
    nodes: *std.ArrayList(RetainedInputPathNode),
    parent_node: ?usize,
) !void {
    if (parent_node) |index| {
        const node = &nodes.items[index];
        const directory = node.directory orelse return error.InputChanged;
        const namespace_parent = if (node.parent) |parent_index|
            nodes.items[parent_index].directory.?
        else
            root;
        const namespace_stat = try namespace_parent.statFile(
            io,
            node.name,
            .{ .follow_symlinks = false },
        );
        const retained_stat = try directory.stat(io);
        if (!node.identity.entry.matches(namespace_stat) or
            !node.identity.entry.matches(retained_stat) or
            !deviceIdentityMatches(
                node.device,
                try linuxDeviceAt(namespace_parent, node.name),
            ) or
            !deviceIdentityMatches(
                node.device,
                try linuxDeviceForHandle(directory.handle),
            ))
        {
            return error.InputChanged;
        }
        node.identity = SourceIdentity.fromStat(retained_stat);
        node.device = try linuxDeviceForHandle(directory.handle);
        return;
    }
    const stat = try root.stat(io);
    if (!root_identity.entry.matches(stat) or
        !deviceIdentityMatches(
            root_device,
            try linuxDeviceForHandle(root.handle),
        ))
    {
        return error.InputChanged;
    }
    root_identity.* = SourceIdentity.fromStat(stat);
}

fn createRetainedDirectoryTail(
    allocator: Allocator,
    io: Io,
    root: Dir,
    root_identity: *SourceIdentity,
    root_device: DeviceIdentity,
    nodes: *std.ArrayList(RetainedInputPathNode),
    initial_parent_node: ?usize,
    initial_parent: Dir,
    components: []const []const u8,
    resolved_path: []const u8,
) !RetainedInputPath {
    var parent_node = initial_parent_node;
    var parent = initial_parent;
    for (components, 0..) |component, index| {
        parent.createDir(io, component, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => return error.InputChanged,
            else => return err,
        };
        try refreshRetainedCreatedParent(
            io,
            root,
            root_identity,
            root_device,
            nodes,
            parent_node,
        );
        const stat = try parent.statFile(
            io,
            component,
            .{ .follow_symlinks = false },
        );
        if (stat.kind != .directory) return error.InputChanged;
        const identity = SourceIdentity.fromStat(stat);
        const device = try linuxDeviceAt(parent, component);
        const child = try parent.openDir(
            io,
            component,
            .{ .iterate = true, .follow_symlinks = false },
        );
        errdefer child.close(io);
        const retained_stat = try child.stat(io);
        if (!identity.entry.matches(retained_stat) or
            !identity.entry.matches(try parent.statFile(
                io,
                component,
                .{ .follow_symlinks = false },
            )) or
            !deviceIdentityMatches(
                device,
                try linuxDeviceForHandle(child.handle),
            ) or
            !deviceIdentityMatches(
                device,
                try linuxDeviceAt(parent, component),
            ))
        {
            return error.InputChanged;
        }
        if (index + 1 == components.len) {
            return .{
                .root = root,
                .root_identity = root_identity.*,
                .root_device = root_device,
                .nodes = nodes.toOwnedSlice(allocator) catch
                    @panic("out of memory"),
                .parent = parent_node,
                .basename = try allocator.dupe(u8, component),
                .entry_identity = identity,
                .entry_device = device,
                .entry = .{ .directory = child },
                .retained_identity = SourceIdentity.fromStat(retained_stat),
                .retained_device = try linuxDeviceForHandle(child.handle),
                .resolved_path = try allocator.dupe(u8, resolved_path),
            };
        }
        nodes.append(allocator, .{
            .parent = parent_node,
            .name = try allocator.dupe(u8, component),
            .identity = identity,
            .device = device,
            .directory = child,
        }) catch @panic("out of memory");
        parent_node = nodes.items.len - 1;
        parent = child;
    }
    unreachable;
}

fn captureInputFile(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    destination_path: []const u8,
    transaction: *Transaction,
    stage: []const u8,
) !CapturedInputFile {
    var retained = retainAbsoluteInputFile(
        allocator,
        io,
        source_path,
        transaction.environ,
        stage,
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.InputChanged,
    };
    defer retained.deinit(allocator, io);
    try waitForCaptureTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
    );
    const snapshot = snapshotRetainedInputFile(
        allocator,
        io,
        &retained,
        destination_path,
        transaction,
        stage,
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.InputChanged,
    };
    return .{
        .snapshot = snapshot,
        .resolved_path = try allocator.dupe(u8, retained.resolved_path),
    };
}

fn openFileNoFollowPath(
    io: Io,
    directory: Dir,
    path: []const u8,
    mode: Dir.OpenFileOptions.Mode,
) !File {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) {
        return error.InvalidPath;
    }
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, ".") or
        std.mem.eql(u8, basename, ".."))
    {
        return error.InvalidPath;
    }
    var parent_handle: ?Dir = null;
    defer if (parent_handle) |parent| parent.close(io);
    if (std.fs.path.dirname(path)) |parent_path| {
        var components = std.mem.splitScalar(
            u8,
            parent_path,
            std.fs.path.sep,
        );
        while (components.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, ".."))
            {
                return error.InvalidPath;
            }
            const parent = parent_handle orelse directory;
            const child = try parent.openDir(
                io,
                component,
                .{ .iterate = true, .follow_symlinks = false },
            );
            if (parent_handle) |old| old.close(io);
            parent_handle = child;
        }
    }
    return (parent_handle orelse directory).openFile(io, basename, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
    });
}

fn snapshotFileAt(
    allocator: Allocator,
    io: Io,
    source_directory: Dir,
    source_path: []const u8,
    destination_path: []const u8,
    transaction: *Transaction,
) !Snapshot {
    try transaction.verifyIntegrity(allocator, io);
    var source = try openFileNoFollowPath(
        io,
        source_directory,
        source_path,
        .read_only,
    );
    defer source.close(io);
    const source_stat = try source.stat(io);
    if (source_stat.kind != .file) return error.MissingBuildArtifact;
    const source_identity = SourceIdentity.fromStat(source_stat);

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
    var destination_open = true;
    defer if (destination_open) destination.close(io);

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
    if (!source_identity.matches(try source.stat(io))) {
        return error.InputChanged;
    }
    var source_check = try openFileNoFollowPath(
        io,
        source_directory,
        source_path,
        .read_only,
    );
    defer source_check.close(io);
    if (!source_identity.matches(try source_check.stat(io))) {
        return error.InputChanged;
    }
    try destination.setPermissions(
        io,
        .fromMode(
            source_stat.permissions.toMode() &
                ~@as(std.posix.mode_t, 0o222),
        ),
    );
    try destination.sync(io);
    destination.close(io);
    destination_open = false;
    const storage_relative = try std.fs.path.relative(
        allocator,
        transaction.storage_path,
        null,
        transaction.storage_path,
        destination_path,
    );
    const child_path = try transaction.retainStorageFile(
        allocator,
        io,
        storage_relative,
        false,
    );
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest_bytes);
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    const protection = try transaction.protectStoragePath(
        allocator,
        io,
        storage_relative,
    );
    const manifest = transaction.protected.items[protection].manifest;
    if (manifest.entries.len != 1 or
        !std.mem.eql(
            u8,
            &manifest.entries[0].content_digest,
            &digest_bytes,
        ))
    {
        return error.TransactionChanged;
    }
    try transaction.verifyIntegrity(allocator, io);
    return .{
        .path = child_path,
        .storage_path = destination_path,
        .digest = try allocator.dupe(u8, &digest_hex),
        .protection = protection,
    };
}

fn snapshotRetainedInputFile(
    allocator: Allocator,
    io: Io,
    source: *RetainedInputPath,
    destination_path: []const u8,
    transaction: *Transaction,
    stage: []const u8,
) !Snapshot {
    try transaction.verifyIntegrity(allocator, io);
    const source_file = switch (source.entry) {
        .file => |file| file,
        .directory => return error.InvalidPath,
    };
    const source_stat = try source_file.stat(io);

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
    var destination_open = true;
    defer if (destination_open) destination.close(io);

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
        hasher.update(buffer[0..count]);
        try destination.writeStreamingAll(io, buffer[0..count]);
    }
    try waitForInputSnapshotTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
    );
    try source.verify(io);
    try destination.setPermissions(
        io,
        .fromMode(
            source_stat.permissions.toMode() &
                ~@as(std.posix.mode_t, 0o222),
        ),
    );
    try destination.sync(io);
    destination.close(io);
    destination_open = false;
    const storage_relative = try std.fs.path.relative(
        allocator,
        transaction.storage_path,
        null,
        transaction.storage_path,
        destination_path,
    );
    const child_path = try transaction.retainStorageFile(
        allocator,
        io,
        storage_relative,
        false,
    );
    var digest_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest_bytes);
    const digest_hex = std.fmt.bytesToHex(digest_bytes, .lower);
    const protection = try transaction.protectStoragePath(
        allocator,
        io,
        storage_relative,
    );
    const manifest = transaction.protected.items[protection].manifest;
    if (manifest.entries.len != 1 or
        !std.mem.eql(
            u8,
            &manifest.entries[0].content_digest,
            &digest_bytes,
        ))
    {
        return error.TransactionChanged;
    }
    try transaction.verifyIntegrity(allocator, io);
    return .{
        .path = child_path,
        .storage_path = destination_path,
        .digest = try allocator.dupe(u8, &digest_hex),
        .protection = protection,
    };
}

fn createChildOutput(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    relative: []const u8,
) !ChildOutput {
    var file = try transaction.storage.createFile(io, relative, .{
        .read = true,
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    try file.sync(io);
    try transaction.recordStoragePath(allocator, io, relative);
    return .{
        .path = try transaction.retainStorageFile(
            allocator,
            io,
            relative,
            true,
        ),
        .storage_path = try std.fs.path.join(
            allocator,
            &.{ transaction.storage_path, relative },
        ),
        .relative = try allocator.dupe(u8, relative),
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

fn appendInputExclusion(
    allocator: Allocator,
    io: Io,
    exclusions: *std.ArrayList(InputExclusion),
    path: []const u8,
) !void {
    const stat = Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    exclusions.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .identity = if (stat) |entry|
            EntryIdentity.fromStat(entry)
        else
            null,
    }) catch @panic("out of memory");
}

fn appendPublicationLockExclusions(
    allocator: Allocator,
    io: Io,
    exclusions: *std.ArrayList(InputExclusion),
    publication: Dir,
    publication_parent: []const u8,
) !void {
    var iterator = publication.iterate();
    while (try iterator.next(io)) |entry| {
        if (!isPublicationLockName(entry.name)) continue;
        const stat = try publication.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        if (stat.kind != .file) continue;
        exclusions.append(allocator, .{
            .path = try std.fs.path.join(
                allocator,
                &.{ publication_parent, entry.name },
            ),
            .identity = EntryIdentity.fromStat(stat),
        }) catch @panic("out of memory");
    }
}

fn isPublicationLockName(name: []const u8) bool {
    const prefix = ".starling-componentize-lock-";
    if (!std.mem.startsWith(u8, name, prefix) or
        name.len != prefix.len + std.crypto.hash.sha2.Sha256.digest_length * 2)
    {
        return false;
    }
    for (name[prefix.len..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
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

const PublicationLock = struct {
    name: []const u8,
    identity: EntryIdentity,
    file: File,
};

const PublicationLocks = struct {
    entries: []PublicationLock,

    fn acquire(
        allocator: Allocator,
        io: Io,
        publication: Dir,
        destinations: []const []const u8,
        environ: *std.process.Environ.Map,
    ) !PublicationLocks {
        var names: std.ArrayList([]const u8) = .empty;
        for (destinations) |destination| {
            const name = try publicationLockName(allocator, destination);
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, name)) break;
            } else {
                names.append(allocator, name) catch @panic("out of memory");
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.lessThan);

        var acquired: std.ArrayList(PublicationLock) = .empty;
        errdefer {
            var index = acquired.items.len;
            while (index > 0) {
                index -= 1;
                acquired.items[index].file.unlock(io);
                acquired.items[index].file.close(io);
            }
        }
        try waitForPublicationLockTestHook(
            allocator,
            io,
            environ,
            .before,
        );
        for (names.items) |name| {
            if (acquired.items.len == 0) {
                try signalPublicationLockAttempt(
                    allocator,
                    io,
                    environ,
                );
            }
            acquired.append(
                allocator,
                try acquirePublicationLock(io, publication, name),
            ) catch @panic("out of memory");
        }
        try signalPublicationLockAcquired(
            allocator,
            io,
            environ,
        );
        try waitForPublicationLockTestHook(
            allocator,
            io,
            environ,
            .after,
        );
        return .{
            .entries = acquired.toOwnedSlice(allocator) catch
                @panic("out of memory"),
        };
    }

    fn deinit(self: *PublicationLocks, io: Io) void {
        var index = self.entries.len;
        while (index > 0) {
            index -= 1;
            self.entries[index].file.unlock(io);
            self.entries[index].file.close(io);
        }
    }

    fn verify(
        self: *const PublicationLocks,
        publication: Dir,
        io: Io,
    ) !void {
        for (self.entries) |entry| {
            if (!entry.identity.matches(try entry.file.stat(io)) or
                !try entryHasIdentity(
                    publication,
                    io,
                    entry.name,
                    entry.identity,
                ))
            {
                return error.TransactionChanged;
            }
        }
    }
};

const PublicationLockHook = enum { before, after };

fn publicationLockTestBase(
    environ: *std.process.Environ.Map,
    hook: PublicationLockHook,
) ?[]const u8 {
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_LOCK_BARRIER",
    ) orelse return null;
    const mode = environ.get(
        "STARLING_COMPONENTIZER_TEST_LOCK_BARRIER_MODE",
    ) orelse "before";
    const selected: PublicationLockHook = if (std.mem.eql(u8, mode, "after"))
        .after
    else
        .before;
    return if (selected == hook) base else null;
}

fn waitForPublicationLockTestHook(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    hook: PublicationLockHook,
) !void {
    const base = publicationLockTestBase(environ, hook) orelse return;
    try validateArgument(base);
    const ready_suffix = if (hook == .before) ".before" else ".acquired";
    const release_suffix = if (hook == .before) ".enter" else ".release";
    const ready = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ base, ready_suffix },
    );
    const release = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ base, release_suffix },
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn signalPublicationLockAttempt(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) !void {
    const base = publicationLockTestBase(environ, .before) orelse return;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}.attempting",
        .{base},
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "attempting\n",
    });
}

fn signalPublicationLockAcquired(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) !void {
    const base = publicationLockTestBase(environ, .before) orelse return;
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}.acquired",
        .{base},
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "acquired\n",
    });
}

fn publicationLockName(
    allocator: Allocator,
    destination: []const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("starling-componentizer-publication-lock-v1\x00");
    hasher.update(destination);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(
        allocator,
        ".starling-componentize-lock-{s}",
        .{&hex},
    );
}

fn acquirePublicationLock(
    io: Io,
    publication: Dir,
    name: []const u8,
) !PublicationLock {
    while (true) {
        var file = publication.openFile(io, name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .exclusive,
        }) catch |open_error| switch (open_error) {
            error.FileNotFound => publication.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .lock = .exclusive,
                .permissions = .fromMode(0o600),
            }) catch |create_error| switch (create_error) {
                error.PathAlreadyExists => continue,
                else => return create_error,
            },
            else => return open_error,
        };
        errdefer {
            file.unlock(io);
            file.close(io);
        }
        try setFileInherited(file, false);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.TransactionChanged;
        const identity = EntryIdentity.fromStat(stat);
        if (!try entryHasIdentity(publication, io, name, identity)) {
            return error.TransactionChanged;
        }
        return .{
            .name = name,
            .identity = identity,
            .file = file,
        };
    }
}

fn publishArtifacts(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component_staged: []const u8,
    component_protection: usize,
    component_output: []const u8,
    metadata_staged: ?[]const u8,
    metadata_protection: ?usize,
    metadata_output: ?[]const u8,
    debug_staged: ?[]const u8,
    debug_protection: ?usize,
    debug_output: ?[]const u8,
    transaction_safe_to_remove: *bool,
    source: []const u8,
    resolved_output: []const u8,
    environ: *std.process.Environ.Map,
    diagnostic: *diagnostics.Context,
    publication_locks: *const PublicationLocks,
) !void {
    _ = component_staged;
    var component = ArtifactState{
        .destination = component_output,
        .staged = "component.wasm",
        .staged_protection = component_protection,
        .backup_name = "previous-component",
    };
    var metadata_state: ?ArtifactState = if (metadata_staged != null) .{
        .destination = metadata_output.?,
        .staged = "metadata.json",
        .staged_protection = metadata_protection.?,
        .backup_name = "previous-metadata",
    } else null;
    var debug_state = DebugPublication{
        .destination = debug_output,
        .staged = if (debug_staged != null) "debug" else null,
        .staged_protection = debug_protection,
        .staged_manifest = if (debug_protection) |protection|
            transaction.protected.items[protection].manifest
        else
            null,
    };
    try transaction.verifyIntegrity(allocator, io);
    try transaction.verifyCanonicalPublication(io);
    try publication_locks.verify(transaction.publication, io);

    publishArtifactsAttempt(
        allocator,
        io,
        transaction,
        &component,
        &metadata_state,
        &debug_state,
        transaction_safe_to_remove,
        environ,
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

    waitForCommitTestBarrier(allocator, io, environ) catch |barrier_error| {
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
        return barrier_error;
    };
    verifyRecoveryAnchors(
        allocator,
        io,
        transaction,
        component,
        metadata_state,
        debug_state,
        environ,
    ) catch |verification_error| {
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
        return verification_error;
    };
    verifyPublishedBundle(
        allocator,
        transaction,
        publication_locks,
        component,
        metadata_state,
        debug_state,
        io,
        environ,
    ) catch |verification_error| {
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
        return verification_error;
    };
    releasePublishedRegularFiles(
        io,
        transaction,
        component,
        metadata_state,
    ) catch |release_error| {
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
        return release_error;
    };

    const PublicationState = enum { rollback_armed, committed };
    var publication_state: PublicationState = .rollback_armed;
    publication_state = .committed;
    std.debug.assert(publication_state == .committed);

    transaction_safe_to_remove.* = false;
    diagnostic.reportSuccess(source, resolved_output);
    cleanupCommittedBackups(
        allocator,
        io,
        transaction,
        component,
        metadata_state,
        debug_state,
        environ,
    ) catch return;
    transaction_safe_to_remove.* = true;
}

fn releasePublishedRegularFiles(
    io: Io,
    transaction: *Transaction,
    component: ArtifactState,
    metadata_state: ?ArtifactState,
) !void {
    try setPublishedFilePermissions(
        io,
        transaction,
        component.destination,
        component.published.?,
    );
    if (metadata_state) |state| {
        try setPublishedFilePermissions(
            io,
            transaction,
            state.destination,
            state.published.?,
        );
    }
    transaction.protected.items[component.staged_protection].active = false;
    if (metadata_state) |state| {
        transaction.protected.items[state.staged_protection].active = false;
    }
}

fn setPublishedFilePermissions(
    io: Io,
    transaction: *Transaction,
    path: []const u8,
    identity: EntryIdentity,
) !void {
    var file = try transaction.publication.openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    if (!identity.matches(try file.stat(io)) or
        !try entryHasIdentity(
            transaction.publication,
            io,
            path,
            identity,
        ))
    {
        return error.TransactionChanged;
    }
    try file.setPermissions(io, .fromMode(0o644));
    if (!identity.matches(try file.stat(io)) or
        !try entryHasIdentity(
            transaction.publication,
            io,
            path,
            identity,
        ))
    {
        return error.TransactionChanged;
    }
}

fn cleanupCommittedBackups(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component: ArtifactState,
    metadata_state: ?ArtifactState,
    debug_state: DebugPublication,
    environ: *std.process.Environ.Map,
) !void {
    if (component.backup) |identity| {
        try injectPublicationFault(environ, "cleanup-component-before");
        try removeExactEntry(
            io,
            transaction.storage,
            component.backup_name,
            identity,
        );
        try injectPublicationFault(environ, "cleanup-component-after");
    }
    if (metadata_state) |state| {
        if (state.backup) |identity| {
            try injectPublicationFault(environ, "cleanup-metadata-before");
            try removeExactEntry(
                io,
                transaction.storage,
                state.backup_name,
                identity,
            );
            try injectPublicationFault(environ, "cleanup-metadata-after");
        }
    }
    if (debug_state.backup) |backup| {
        try injectPublicationFault(environ, "cleanup-debug-before");
        try finalizeDebugBackup(
            allocator,
            io,
            transaction,
            backup,
        );
        try injectPublicationFault(environ, "cleanup-debug-after");
    }
}

fn verifyPublishedBundle(
    allocator: Allocator,
    transaction: *Transaction,
    publication_locks: *const PublicationLocks,
    component: ArtifactState,
    metadata_state: ?ArtifactState,
    debug_state: DebugPublication,
    io: Io,
    environ: *std.process.Environ.Map,
) !void {
    try transaction.verifyIntegrity(allocator, io);
    try injectPublicationFault(environ, "final-publication-before");
    try transaction.verifyCanonicalPublication(io);
    try injectPublicationFault(environ, "final-publication-parent-before");
    try publication_locks.verify(transaction.publication, io);
    try injectPublicationFault(environ, "final-lock-before");
    const component_identity = component.published orelse
        return error.TransactionChanged;
    if (!try entryHasIdentity(
        transaction.publication,
        io,
        component.destination,
        component_identity,
    )) return error.TransactionChanged;
    try injectPublicationFault(environ, "final-component");
    if (metadata_state) |state| {
        const identity = state.published orelse
            return error.TransactionChanged;
        if (!try entryHasIdentity(
            transaction.publication,
            io,
            state.destination,
            identity,
        )) return error.TransactionChanged;
        try injectPublicationFault(environ, "final-metadata");
    }
    if (debug_state.staged != null) {
        const identity = debug_state.published orelse
            return error.TransactionChanged;
        if (!try entryHasIdentity(
            transaction.publication,
            io,
            debug_state.destination.?,
            identity,
        )) return error.TransactionChanged;
        const manifest = try buildTreeManifest(
            allocator,
            io,
            transaction.publication,
            debug_state.destination.?,
        );
        if (!debug_state.staged_manifest.?.matchesAfterRootRename(manifest)) {
            return error.TransactionChanged;
        }
        try injectPublicationFault(environ, "final-debug");
    }
    try publication_locks.verify(transaction.publication, io);
    try injectPublicationFault(environ, "final-lock-after");
    try transaction.verifyCanonicalPublication(io);
    try transaction.verifyIntegrity(allocator, io);
    try injectPublicationFault(environ, "final-publication-after");
    try injectPublicationFault(environ, "final-before-commit");
}

fn verifyRecoveryAnchors(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component: ArtifactState,
    metadata_state: ?ArtifactState,
    debug_state: DebugPublication,
    environ: *std.process.Environ.Map,
) !void {
    try transaction.verifyIntegrity(allocator, io);
    try transaction.verifyAttached(io);
    try injectPublicationFault(environ, "final-recovery-attached");
    if (component.backup) |identity| {
        if (!try entryHasIdentity(
            transaction.storage,
            io,
            component.backup_name,
            identity,
        )) return error.TransactionChanged;
    }
    try injectPublicationFault(environ, "final-recovery-component");
    if (metadata_state) |state| {
        if (state.backup) |identity| {
            if (!try entryHasIdentity(
                transaction.storage,
                io,
                state.backup_name,
                identity,
            )) return error.TransactionChanged;
        }
    }
    try injectPublicationFault(environ, "final-recovery-metadata");
    if (debug_state.backup) |backup| {
        var directory = try transaction.storage.openDir(
            io,
            "previous-debug",
            .{ .iterate = true, .follow_symlinks = false },
        );
        defer directory.close(io);
        if (!backup.identity.matches(try directory.stat(io))) {
            return error.TransactionChanged;
        }
        const manifest = try buildTreeManifest(
            allocator,
            io,
            transaction.storage,
            "previous-debug",
        );
        if (!backup.manifest.matchesAfterRootRename(manifest)) {
            return error.TransactionChanged;
        }
        try transaction.verifyOwnedSubtreeExact(
            allocator,
            io,
            directory,
            "previous-debug",
        );
    }
    try injectPublicationFault(environ, "final-recovery-debug");
    try transaction.verifyAttached(io);
    try transaction.verifyIntegrity(allocator, io);
    try injectPublicationFault(environ, "final-recovery-after");
}

fn injectPublicationFault(
    environ: *std.process.Environ.Map,
    point: []const u8,
) !void {
    const selected = environ.get(
        "STARLING_COMPONENTIZER_TEST_PUBLICATION_FAULT",
    ) orelse return;
    if (std.mem.eql(u8, selected, point)) return error.CommandFailed;
}

fn waitForCommitTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) !void {
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_COMMIT_BARRIER",
    ) orelse return;
    try validateArgument(base);
    const ready = try std.fmt.allocPrint(allocator, "{s}.ready", .{base});
    const release = try std.fmt.allocPrint(allocator, "{s}.release", .{base});
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

const SpawnBarrierPoint = enum { before, after };
const AdapterRetainBarrierPoint = enum { before_open, after_open };
const InputSymlinkBarrierPoint = enum { before_read, after_read };

fn waitForInputSymlinkTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stage: []const u8,
    point: InputSymlinkBarrierPoint,
) !void {
    const selected = environ.get(
        "STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_STAGE",
    ) orelse return;
    if (!std.mem.eql(u8, selected, stage)) return;
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_BARRIER",
    ) orelse return;
    try validateArgument(base);
    const suffix = @tagName(point);
    const ready = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.ready",
        .{ base, suffix },
    );
    const release = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.release",
        .{ base, suffix },
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForAdapterRetainTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    component: []const u8,
    point: AdapterRetainBarrierPoint,
) !void {
    const selected = environ.get(
        "STARLING_COMPONENTIZER_TEST_ADAPTER_RETAIN_COMPONENT",
    ) orelse return;
    if (!std.mem.eql(u8, selected, component)) return;
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_ADAPTER_RETAIN_BARRIER",
    ) orelse return;
    try validateArgument(base);
    const suffix = @tagName(point);
    const ready = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.ready",
        .{ base, suffix },
    );
    const release = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.release",
        .{ base, suffix },
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForAdapterSnapshotTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) !void {
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_ADAPTER_SNAPSHOT_BARRIER",
    ) orelse return;
    try validateArgument(base);
    const ready = try std.fmt.allocPrint(allocator, "{s}.ready", .{base});
    const release = try std.fmt.allocPrint(allocator, "{s}.release", .{base});
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForInputSnapshotTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stage: []const u8,
) !void {
    if (std.mem.eql(u8, stage, "adapter")) {
        try waitForAdapterSnapshotTestBarrier(
            allocator,
            io,
            environ,
        );
    }
    const selected = environ.get(
        "STARLING_COMPONENTIZER_TEST_INPUT_SNAPSHOT_STAGE",
    ) orelse return;
    if (!std.mem.eql(u8, selected, stage)) return;
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_INPUT_SNAPSHOT_BARRIER",
    ) orelse return;
    try validateArgument(base);
    const ready = try std.fmt.allocPrint(allocator, "{s}.ready", .{base});
    const release = try std.fmt.allocPrint(allocator, "{s}.release", .{base});
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForSymlinkReadTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    point: SymlinkReadBarrierPoint,
) !void {
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_SYMLINK_READ_BARRIER",
    ) orelse return;
    try validateArgument(base);
    const suffix = @tagName(point);
    const ready = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.ready",
        .{ base, suffix },
    );
    const release = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.release",
        .{ base, suffix },
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForCaptureTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stage: []const u8,
) !void {
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER",
    ) orelse return;
    if (environ.get("STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE")) |selected| {
        if (!std.mem.eql(u8, selected, stage)) return;
    }
    try validateArgument(base);
    const ready = try std.fmt.allocPrint(
        allocator,
        "{s}.ready",
        .{base},
    );
    const release = try std.fmt.allocPrint(
        allocator,
        "{s}.release",
        .{base},
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForComponentizerTestHook(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stage: []const u8,
) !void {
    const directory = environ.get(
        "STARLING_COMPONENTIZER_TEST_HOOK_DIR",
    ) orelse return;
    const selected = environ.get(
        "STARLING_COMPONENTIZER_TEST_WAIT_AT",
    ) orelse return;
    if (!std.mem.eql(u8, selected, stage)) return;
    const ready = try std.fs.path.join(
        allocator,
        &.{ directory, try std.fmt.allocPrint(allocator, "{s}.ready", .{stage}) },
    );
    const release = try std.fs.path.join(
        allocator,
        &.{ directory, try std.fmt.allocPrint(allocator, "{s}.continue", .{stage}) },
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn waitForSpawnTestBarrier(
    allocator: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    stage: []const u8,
    point: SpawnBarrierPoint,
) !void {
    const base = environ.get(
        "STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER",
    ) orelse return;
    if (environ.get("STARLING_COMPONENTIZER_TEST_SPAWN_STAGE")) |selected| {
        if (!std.mem.eql(u8, selected, stage)) return;
    }
    try validateArgument(base);
    const ready_suffix = if (point == .before) ".ready" else ".complete";
    const release_suffix = if (point == .before) ".release" else ".verify";
    const ready = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ base, ready_suffix },
    );
    const release = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ base, release_suffix },
    );
    try Dir.cwd().writeFile(io, .{
        .sub_path = ready,
        .data = "ready\n",
    });
    var attempts: usize = 0;
    while (attempts < 30_000) : (attempts += 1) {
        if (pathExists(io, release)) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.CommandFailed;
}

fn publishArtifactsAttempt(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    component: *ArtifactState,
    metadata_state: *?ArtifactState,
    debug_state: *DebugPublication,
    transaction_safe_to_remove: *bool,
    environ: *std.process.Environ.Map,
) !void {
    try transaction.verifyAttached(io);
    component.backup = try backupRegularDestination(
        allocator,
        io,
        transaction,
        component.destination,
        component.backup_name,
        error.InvalidPath,
        transaction_safe_to_remove,
        environ,
        "backup-component-after-rename",
        "backup-component-after-stat",
        "backup-component-after-identity",
        "backup-component-after-record",
    );
    if (metadata_state.*) |*state| {
        state.backup = try backupRegularDestination(
            allocator,
            io,
            transaction,
            state.destination,
            state.backup_name,
            error.InvalidMetadataDestination,
            transaction_safe_to_remove,
            environ,
            "backup-metadata-after-rename",
            "backup-metadata-after-stat",
            "backup-metadata-after-identity",
            "backup-metadata-after-record",
        );
    }
    if (debug_state.staged != null) {
        debug_state.backup = try prepareDebugDestination(
            allocator,
            io,
            transaction,
            debug_state.destination.?,
            transaction_safe_to_remove,
            environ,
        );
        try transaction.refreshProtectedStorageAdditions(
            allocator,
            io,
            debug_state.staged_protection.?,
            if (debug_state.backup) |backup| backup.manifest else null,
        );
        debug_state.staged_manifest = transaction.protected.items[
            debug_state.staged_protection.?
        ].manifest;
    }

    component.published = try publishEntry(
        allocator,
        io,
        transaction,
        component.staged,
        component.destination,
        component.staged_protection,
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
            allocator,
            io,
            transaction,
            state.staged,
            state.destination,
            state.staged_protection,
        );
    }
    if (debug_state.staged) |staged| {
        debug_state.published = try publishEntry(
            allocator,
            io,
            transaction,
            staged,
            debug_state.destination.?,
            debug_state.staged_protection.?,
        );
    }
}

const debug_generated_names = [_][]const u8{
    "runtime-args.txt",
    "initialized.wasm",
    "stripped.wasm",
    "embedded.wasm",
    "component-before-feature-surface.wasm",
    "surfaced.wasm",
    "component.wasm",
    "feature-provider.wit",
    "feature-provider.wasm",
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

const DebugBackup = struct {
    identity: EntryIdentity,
    protection: usize,
    manifest: TreeManifest,
};

const DebugPublication = struct {
    destination: ?[]const u8,
    staged: ?[]const u8,
    staged_protection: ?usize,
    staged_manifest: ?TreeManifest,
    backup: ?DebugBackup = null,
    published: ?EntryIdentity = null,
};

const ArtifactState = struct {
    destination: []const u8,
    staged: []const u8,
    staged_protection: usize,
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
    transaction_safe_to_remove: *bool,
    environ: *std.process.Environ.Map,
    after_rename_fault: []const u8,
    after_stat_fault: []const u8,
    after_identity_fault: []const u8,
    after_record_fault: []const u8,
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
    return finishRegularBackup(
        allocator,
        io,
        transaction,
        backup,
        identity,
        environ,
        after_rename_fault,
        after_stat_fault,
        after_identity_fault,
        after_record_fault,
    ) catch |err| {
        restoreBackup(
            io,
            transaction,
            destination,
            backup,
            identity,
        ) catch {
            transaction_safe_to_remove.* = false;
            return error.RollbackIncomplete;
        };
        return err;
    };
}

fn finishRegularBackup(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    backup: []const u8,
    identity: EntryIdentity,
    environ: *std.process.Environ.Map,
    after_rename_fault: []const u8,
    after_stat_fault: []const u8,
    after_identity_fault: []const u8,
    after_record_fault: []const u8,
) !?EntryIdentity {
    try injectPublicationFault(environ, after_rename_fault);
    const moved = try transaction.storage.statFile(
        io,
        backup,
        .{ .follow_symlinks = false },
    );
    try injectPublicationFault(environ, after_stat_fault);
    if (!identity.matches(moved)) {
        return error.TransactionChanged;
    }
    try injectPublicationFault(environ, after_identity_fault);
    try transaction.recordStoragePath(allocator, io, backup);
    try injectPublicationFault(environ, after_record_fault);
    return identity;
}

fn prepareDebugDestination(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    transaction_safe_to_remove: *bool,
    environ: *std.process.Environ.Map,
) !?DebugBackup {
    const initial = try statEntry(
        transaction.publication,
        io,
        destination,
    ) orelse return null;
    if (initial.kind != .directory) return error.DebugOutputCollision;
    const backup_identity = EntryIdentity.fromStat(initial);
    const protection = try transaction.protectPublicationPath(
        allocator,
        io,
        destination,
    );
    const manifest = transaction.protected.items[protection].manifest;
    try transaction.moveProtected(
        allocator,
        io,
        protection,
        .storage,
        "previous-debug",
    );
    return finishPrepareDebugDestination(
        allocator,
        io,
        transaction,
        destination,
        backup_identity,
        protection,
        manifest,
        environ,
    ) catch |err| {
        restoreDebugBackup(
            allocator,
            io,
            transaction,
            destination,
            .{
                .identity = backup_identity,
                .protection = protection,
                .manifest = manifest,
            },
        ) catch {
            transaction_safe_to_remove.* = false;
            return error.RollbackIncomplete;
        };
        return err;
    };
}

fn finishPrepareDebugDestination(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    backup_identity: EntryIdentity,
    protection: usize,
    manifest: TreeManifest,
    environ: *std.process.Environ.Map,
) !?DebugBackup {
    _ = destination;
    try injectPublicationFault(environ, "backup-debug-after-rename");
    const moved_backup = try transaction.storage.statFile(
        io,
        "previous-debug",
        .{ .follow_symlinks = false },
    );
    try injectPublicationFault(environ, "backup-debug-after-stat");
    if (!backup_identity.matches(moved_backup)) {
        return error.TransactionChanged;
    }
    try injectPublicationFault(environ, "backup-debug-after-identity");
    try transaction.recordStoragePath(allocator, io, "previous-debug");
    try injectPublicationFault(environ, "backup-debug-after-record");

    var backup_dir = try transaction.storage.openDir(
        io,
        "previous-debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer backup_dir.close(io);
    try injectPublicationFault(environ, "backup-debug-after-open-backup");
    var staged_dir = try transaction.storage.openDir(
        io,
        "debug",
        .{ .iterate = true, .follow_symlinks = false },
    );
    defer staged_dir.close(io);
    try injectPublicationFault(environ, "backup-debug-after-open-staged");
    const DebugEntry = struct {
        name: []const u8,
        identity: EntryIdentity,
        generated: bool,
    };
    var entries: std.ArrayList(DebugEntry) = .empty;
    var iterator = backup_dir.iterate();
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
        entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .identity = EntryIdentity.fromStat(stat),
            .generated = generated,
        }) catch @panic("out of memory");
    }
    try injectPublicationFault(environ, "backup-debug-after-scan");
    try verifyDirectoryEntries(io, backup_dir, entries.items);
    try injectPublicationFault(environ, "backup-debug-after-verify");
    try recordDebugBackupTree(
        allocator,
        io,
        transaction,
        backup_dir,
        "previous-debug",
    );
    try injectPublicationFault(environ, "backup-debug-after-record-tree");

    for (entries.items) |entry| {
        if (entry.generated) continue;
        try copyDebugBackupEntry(
            allocator,
            io,
            transaction,
            backup_dir,
            staged_dir,
            entry.name,
            entry.name,
            entry.identity,
        );
    }
    try injectPublicationFault(environ, "backup-debug-after-copy");
    try verifyDirectoryEntries(io, backup_dir, entries.items);
    try injectPublicationFault(environ, "backup-debug-after-final-verify");
    return .{
        .identity = backup_identity,
        .protection = protection,
        .manifest = manifest,
    };
}

fn recordDebugBackupTree(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    directory: Dir,
    relative: []const u8,
) !void {
    const Entry = struct {
        name: []const u8,
        identity: EntryIdentity,
    };
    var entries: std.ArrayList(Entry) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = try directory.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .identity = EntryIdentity.fromStat(stat),
        }) catch @panic("out of memory");
    }
    try verifyDirectoryEntries(io, directory, entries.items);
    for (entries.items) |entry| {
        const path = try std.fs.path.join(
            allocator,
            &.{ relative, entry.name },
        );
        try transaction.recordStoragePath(allocator, io, path);
        if (entry.identity.kind == .directory) {
            var child = try directory.openDir(
                io,
                entry.name,
                .{ .iterate = true, .follow_symlinks = false },
            );
            defer child.close(io);
            if (!entry.identity.matches(try child.stat(io))) {
                return error.TransactionChanged;
            }
            try recordDebugBackupTree(
                allocator,
                io,
                transaction,
                child,
                path,
            );
        }
    }
    try verifyDirectoryEntries(io, directory, entries.items);
}

fn copyDebugBackupEntry(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    source: Dir,
    destination: Dir,
    name: []const u8,
    relative: []const u8,
    expected: EntryIdentity,
) !void {
    const source_stat = try source.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    );
    if (!expected.matches(source_stat)) return error.TransactionChanged;
    const owned_path = try std.fs.path.join(
        allocator,
        &.{ "debug", relative },
    );
    switch (expected.kind) {
        .file => {
            var source_file = try source.openFile(io, name, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
            defer source_file.close(io);
            if (!expected.matches(try source_file.stat(io))) {
                return error.TransactionChanged;
            }
            var destination_file = try destination.createFile(
                io,
                name,
                .{ .exclusive = true },
            );
            defer destination_file.close(io);
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
                try destination_file.writeStreamingAll(io, buffer[0..count]);
            }
            try destination_file.setPermissions(io, source_stat.permissions);
            try destination_file.sync(io);
            try transaction.recordStoragePath(allocator, io, owned_path);
        },
        .sym_link => {
            var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const target_len = try source.readLink(io, name, &target_buffer);
            if (!expected.matches(try source.statFile(
                io,
                name,
                .{ .follow_symlinks = false },
            ))) return error.TransactionChanged;
            try destination.symLink(
                io,
                target_buffer[0..target_len],
                name,
                .{},
            );
            try transaction.recordStoragePath(allocator, io, owned_path);
        },
        .directory => {
            try destination.createDir(io, name, .fromMode(0o700));
            try transaction.recordStoragePath(allocator, io, owned_path);
            var source_child = try source.openDir(
                io,
                name,
                .{ .iterate = true, .follow_symlinks = false },
            );
            defer source_child.close(io);
            if (!expected.matches(try source_child.stat(io))) {
                return error.TransactionChanged;
            }
            var destination_child = try destination.openDir(
                io,
                name,
                .{ .iterate = true, .follow_symlinks = false },
            );
            defer destination_child.close(io);
            const Child = struct {
                name: []const u8,
                identity: EntryIdentity,
            };
            var children: std.ArrayList(Child) = .empty;
            var iterator = source_child.iterate();
            while (try iterator.next(io)) |entry| {
                const stat = try source_child.statFile(
                    io,
                    entry.name,
                    .{ .follow_symlinks = false },
                );
                children.append(allocator, .{
                    .name = try allocator.dupe(u8, entry.name),
                    .identity = EntryIdentity.fromStat(stat),
                }) catch @panic("out of memory");
            }
            try verifyDirectoryEntries(io, source_child, children.items);
            for (children.items) |entry| {
                try copyDebugBackupEntry(
                    allocator,
                    io,
                    transaction,
                    source_child,
                    destination_child,
                    entry.name,
                    try std.fs.path.join(
                        allocator,
                        &.{ relative, entry.name },
                    ),
                    entry.identity,
                );
            }
            try verifyDirectoryEntries(io, source_child, children.items);
            try destination_child.setPermissions(io, source_stat.permissions);
        },
        else => return error.DebugOutputCollision,
    }
    if (!expected.matches(try source.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    ))) return error.TransactionChanged;
}

fn publishEntry(
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    staged: []const u8,
    destination: []const u8,
    protection: usize,
) !EntryIdentity {
    const stat = try transaction.storage.statFile(
        io,
        staged,
        .{ .follow_symlinks = false },
    );
    const identity = transaction.ownedIdentity(staged) orelse
        return error.TransactionChanged;
    if (!identity.matches(stat)) return error.TransactionChanged;
    try transaction.moveProtected(
        allocator,
        io,
        protection,
        .publication,
        destination,
    );
    const published = try transaction.publication.statFile(
        io,
        destination,
        .{ .follow_symlinks = false },
    );
    if (!identity.matches(published)) {
        transaction.moveProtected(
            allocator,
            io,
            protection,
            .storage,
            staged,
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
            allocator,
            io,
            transaction,
            debug_state.destination.?,
            debug_state.staged.?,
            identity,
            debug_state.staged_protection.?,
        ) catch |err| if (first_error == null) {
            first_error = err;
        };
    }
    if (metadata_state) |state| {
        if (state.published) |identity| {
            returnPublishedEntry(
                allocator,
                io,
                transaction,
                state.destination,
                state.staged,
                identity,
                state.staged_protection,
            ) catch |err| if (first_error == null) {
                first_error = err;
            };
        }
    }
    if (component.published) |identity| {
        returnPublishedEntry(
            allocator,
            io,
            transaction,
            component.destination,
            component.staged,
            identity,
            component.staged_protection,
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
    allocator: Allocator,
    io: Io,
    transaction: *Transaction,
    destination: []const u8,
    staged: []const u8,
    identity: EntryIdentity,
    protection: usize,
) !void {
    _ = allocator;
    try transaction.withdrawPublished(
        io,
        protection,
        destination,
        staged,
        identity,
    );
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
    if (try statEntry(transaction.publication, io, destination) != null) {
        return error.TransactionChanged;
    }
    const current = try buildTreeManifest(
        allocator,
        io,
        transaction.storage,
        "previous-debug",
    );
    if (!backup.manifest.matchesAfterRootRename(current)) {
        return error.TransactionChanged;
    }
    if (backup.protection >= transaction.protected.items.len) {
        return error.TransactionChanged;
    }
    const protected = &transaction.protected.items[backup.protection];
    if (!protected.active or protected.location != .storage or
        !std.mem.eql(u8, protected.path, "previous-debug"))
    {
        return error.TransactionChanged;
    }
    try transaction.storage.renamePreserve(
        "previous-debug",
        transaction.publication,
        destination,
        io,
    );
    protected.location = .publication;
    protected.path = destination;
    if (!try entryHasIdentity(
        transaction.publication,
        io,
        destination,
        backup.identity,
    )) return error.TransactionChanged;
    const restored = try buildTreeManifest(
        allocator,
        io,
        transaction.publication,
        destination,
    );
    if (!backup.manifest.matchesAfterRootRename(restored)) {
        return error.TransactionChanged;
    }
    protected.manifest = restored;
}

fn finalizeDebugBackup(
    allocator: Allocator,
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
    const current = try buildTreeManifest(
        allocator,
        io,
        transaction.storage,
        "previous-debug",
    );
    if (!backup.manifest.matchesAfterRootRename(current)) {
        return error.TransactionChanged;
    }
    transaction.protected.items[backup.protection].active = false;
    try backup_dir.setPermissions(io, .fromMode(0o700));
    try transaction.verifyOwnedSubtreeExact(
        allocator,
        io,
        backup_dir,
        "previous-debug",
    );
    try transaction.removeOwnedDirectory(
        allocator,
        io,
        backup_dir,
        "previous-debug",
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

const Redaction = struct {
    path: []const u8,
    replacement: []const u8,
};

fn applyRedactions(
    allocator: Allocator,
    input: []const u8,
    redactions: []const Redaction,
) ![]const u8 {
    var stable = try allocator.dupe(u8, input);
    for (redactions) |redaction| {
        stable = try std.mem.replaceOwned(
            u8,
            allocator,
            stable,
            redaction.path,
            redaction.replacement,
        );
    }
    const marker = "/proc/self/fd/";
    if (std.mem.indexOf(u8, stable, marker) == null) return stable;
    var output: std.ArrayList(u8) = .empty;
    var remaining = stable;
    while (std.mem.indexOf(u8, remaining, marker)) |offset| {
        output.appendSlice(allocator, remaining[0..offset]) catch
            @panic("out of memory");
        var end = offset + marker.len;
        while (end < remaining.len and std.ascii.isDigit(remaining[end])) {
            end += 1;
        }
        if (end == offset + marker.len) {
            output.appendSlice(allocator, marker) catch @panic("out of memory");
            remaining = remaining[offset + marker.len ..];
            continue;
        }
        output.appendSlice(allocator, "<transaction>") catch
            @panic("out of memory");
        remaining = remaining[end..];
    }
    output.appendSlice(allocator, remaining) catch @panic("out of memory");
    return output.toOwnedSlice(allocator) catch @panic("out of memory");
}

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
        redactions: []const Redaction,
    ) ![]const u8 {
        const stable = try applyRedactions(
            allocator,
            self.bytes.items,
            redactions,
        );
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

fn runRetainedAotCommand(
    allocator: Allocator,
    io: Io,
    retained: aot_pipeline.RetainedSnapshotExecutable,
    argv: []const []const u8,
    cwd: []const u8,
    environ: *const std.process.Environ.Map,
    stdin_path: ?[]const u8,
    verbose: bool,
    command_log: *std.ArrayList(u8),
    diagnostic: *diagnostics.Context,
    transaction_storage: []const u8,
    transaction: *Transaction,
) !void {
    const stage = "weval AOT";
    const redactions = &.{Redaction{
        .path = transaction_storage,
        .replacement = "<transaction>",
    }};
    command_log.appendSlice(allocator, stage) catch @panic("out of memory");
    command_log.append(allocator, '\n') catch @panic("out of memory");
    for (argv) |arg| {
        const stable_arg = try applyRedactions(allocator, arg, redactions);
        command_log.appendSlice(allocator, "  ") catch @panic("out of memory");
        command_log.appendSlice(allocator, stable_arg) catch @panic("out of memory");
        command_log.append(allocator, '\n') catch @panic("out of memory");
    }
    if (verbose and diagnostic.format == .human) {
        try File.stderr().writeStreamingAll(io, "[weval AOT]\n");
        for (argv) |arg| {
            const stable_arg = try applyRedactions(allocator, arg, redactions);
            try File.stderr().writeStreamingAll(
                io,
                try std.fmt.allocPrint(allocator, "  {s}\n", .{stable_arg}),
            );
        }
    }

    var stdout_output = try createChildOutput(
        allocator,
        io,
        transaction,
        "weval-stdout.log",
    );
    var stderr_output = try createChildOutput(
        allocator,
        io,
        transaction,
        "weval-stderr.log",
    );
    var stdout_file = try Dir.openFileAbsolute(io, stdout_output.path, .{
        .mode = .read_write,
        .allow_directory = false,
    });
    var stdout_open = true;
    defer if (stdout_open) stdout_file.close(io);
    var stderr_file = try Dir.openFileAbsolute(io, stderr_output.path, .{
        .mode = .read_write,
        .allow_directory = false,
    });
    var stderr_open = true;
    defer if (stderr_open) stderr_file.close(io);

    try transaction.prepareChild(io);
    var child_prepared = true;
    defer if (child_prepared) transaction.finishChild(io) catch {};
    try retained.verify(io);
    try transaction.verifyRetainedIntegrity();
    try transaction.verifyChildHandleIdentities(io);
    try waitForComponentizerTestHook(
        allocator,
        io,
        transaction.environ,
        "retained-environment-captured-weval",
    );
    try waitForSpawnTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
        .before,
    );
    const term = try retained.run(
        allocator,
        io,
        argv,
        cwd,
        environ,
        stdin_path,
        stdout_file,
        stderr_file,
    );
    try transaction.verifyChildHandleIdentities(io);
    try transaction.verifyRetainedIntegrity();
    try waitForSpawnTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
        .after,
    );
    try transaction.finishChild(io);
    child_prepared = false;
    stdout_file.close(io);
    stdout_open = false;
    stderr_file.close(io);
    stderr_open = false;
    try transaction.sealChildOutput(allocator, io, &stdout_output);
    try transaction.sealChildOutput(allocator, io, &stderr_output);
    const stdout = try readAbsoluteFile(allocator, io, stdout_output.path);
    const stderr = try readAbsoluteFile(allocator, io, stderr_output.path);
    if (diagnostic.format == .human) {
        if (stdout.len != 0) try File.stdout().writeStreamingAll(io, stdout);
        if (term.success() and stderr.len != 0)
            try File.stderr().writeStreamingAll(io, stderr);
    }
    if (!term.success()) {
        diagnostic.commandFailed(stage, term, stderr, null);
        return error.CommandFailed;
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
    transaction: *Transaction,
) !void {
    if (redact_path) |path| {
        return runCommandRedacted(
            allocator,
            io,
            stage,
            argv,
            cwd,
            environ,
            stdin_path,
            verbose,
            command_log,
            diagnostic,
            &.{.{ .path = path, .replacement = "<transaction>" }},
            transaction,
        );
    }
    return runCommandRedacted(
        allocator,
        io,
        stage,
        argv,
        cwd,
        environ,
        stdin_path,
        verbose,
        command_log,
        diagnostic,
        &.{},
        transaction,
    );
}

fn runCommandRedacted(
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
    redactions: []const Redaction,
    transaction: *Transaction,
) !void {
    command_log.appendSlice(allocator, stage) catch @panic("out of memory");
    command_log.append(allocator, '\n') catch @panic("out of memory");
    for (argv) |arg| {
        const stable_arg = try applyRedactions(allocator, arg, redactions);
        command_log.appendSlice(allocator, "  ") catch @panic("out of memory");
        command_log.appendSlice(allocator, stable_arg) catch @panic("out of memory");
        command_log.append(allocator, '\n') catch @panic("out of memory");
    }
    if (verbose and diagnostic.format == .human) {
        const header = try std.fmt.allocPrint(allocator, "[{s}]\n", .{stage});
        try File.stderr().writeStreamingAll(io, header);
        for (argv) |arg| {
            const stable_arg = try applyRedactions(
                allocator,
                arg,
                redactions,
            );
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
    try transaction.prepareChild(io);
    var child_prepared = true;
    defer if (child_prepared) transaction.finishChild(io) catch {};
    try waitForSpawnTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
        .before,
    );
    try transaction.verifyRetainedIntegrity();
    try transaction.verifyChildHandleIdentities(io);
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
        if (diagnostic.format == .human and redactions.len == 0) {
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
    try transaction.verifyChildHandleIdentities(io);
    try transaction.verifyRetainedIntegrity();
    try waitForSpawnTestBarrier(
        allocator,
        io,
        transaction.environ,
        stage,
        .after,
    );
    try transaction.finishChild(io);
    child_prepared = false;
    if (diagnostic.format == .human and redactions.len != 0) {
        const stdout = try stdout_capture.render(
            allocator,
            "stdout",
            redactions,
        );
        if (stdout.len != 0) {
            try File.stdout().writeStreamingAll(io, stdout);
        }
        if (termSucceeded(term)) {
            const stderr = try stderr_capture.render(
                allocator,
                "stderr",
                redactions,
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
            redactions,
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

fn resolveFeatures(config: *const cli.Config) feature_surface.Features {
    var features = feature_surface.Features{};
    for (config.disable_features) |name| setFeature(&features, name, false);
    for (config.enable_features) |name| setFeature(&features, name, true);
    return features;
}

fn setFeature(features: *feature_surface.Features, name: []const u8, enabled: bool) void {
    if (std.mem.eql(u8, name, "stdio")) {
        features.stdio = enabled;
    } else if (std.mem.eql(u8, name, "random")) {
        features.random = enabled;
    } else if (std.mem.eql(u8, name, "clocks")) {
        features.clocks = enabled;
    } else if (std.mem.eql(u8, name, "http")) {
        features.http = enabled;
    } else if (std.mem.eql(u8, name, "fetch-event")) {
        features.fetch_event = enabled;
    } else {
        unreachable;
    }
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
    if (config.source) |source| try validateArgument(source);
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

fn readAbsoluteFile(
    allocator: Allocator,
    io: Io,
    path: []const u8,
) ![]const u8 {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    var dir = try Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    return dir.readFileAlloc(
        io,
        std.fs.path.basename(path),
        allocator,
        .unlimited,
    );
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

fn copyDebugFile(
    io: Io,
    source: []const u8,
    debug_dir: Dir,
    basename: []const u8,
) !void {
    try Dir.cwd().copyFile(source, debug_dir, basename, io, .{});
}

fn resolveDefaultCacheAtBuildRoot(
    allocator: Allocator,
    io: Io,
    retained_root: *RetainedInputPath,
) !EffectiveCache {
    const root = switch (retained_root.entry) {
        .directory => |directory| directory,
        .file => return error.InvalidBuildRoot,
    };
    var zig_cache = try ensureCacheDirectory(
        allocator,
        io,
        root,
        retained_root.resolved_path,
        ".zig-cache",
    );
    defer zig_cache.directory.close(io);
    const cache = try ensureCacheDirectory(
        allocator,
        io,
        zig_cache.directory,
        zig_cache.path,
        "starling-componentizer",
    );
    return .{
        .path = cache.path,
        .identity = cache.identity,
        .directory = cache.directory,
        .anchor = null,
    };
}

fn resolveEffectiveCache(
    allocator: Allocator,
    io: Io,
    cwd: []const u8,
    configured: []const u8,
    environ: *std.process.Environ.Map,
) !EffectiveCache {
    const requested = try absolutePath(allocator, cwd, configured);
    var anchor = retainOrCreateAbsoluteDirectory(
        allocator,
        io,
        requested,
        environ,
        "cache",
    ) catch |err| switch (err) {
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return err,
        else => return error.CacheDirectoryChanged,
    };
    errdefer anchor.deinit(allocator, io);
    try anchor.verifyMutableDirectory(io);
    const directory = switch (anchor.entry) {
        .directory => |value| value,
        .file => return error.CacheDirectoryChanged,
    };
    const stat = try directory.stat(io);
    if (stat.kind != .directory) return error.CacheDirectoryChanged;
    const identity = EntryIdentity.fromStat(stat);
    return .{
        .path = anchor.resolved_path,
        .identity = identity,
        .directory = directory,
        .anchor = anchor,
    };
}

fn ensureCacheDirectory(
    allocator: Allocator,
    io: Io,
    parent: Dir,
    parent_path: []const u8,
    name: []const u8,
) !CacheDirectory {
    const initial = parent.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (initial == null) {
        parent.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const entry = try parent.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    );
    if (entry.kind != .directory) return error.CacheDirectoryChanged;
    var directory = try parent.openDir(
        io,
        name,
        .{ .iterate = true, .follow_symlinks = false },
    );
    errdefer directory.close(io);
    const identity = EntryIdentity.fromStat(try directory.stat(io));
    if (!identity.matches(entry) or
        !try entryHasIdentity(parent, io, name, identity))
    {
        return error.CacheDirectoryChanged;
    }
    return .{
        .name = try allocator.dupe(u8, name),
        .path = try std.fs.path.join(allocator, &.{ parent_path, name }),
        .identity = identity,
        .directory = directory,
    };
}

fn acquireCacheLock(
    io: Io,
    locks: Dir,
    name: []const u8,
) !CacheLock {
    while (true) {
        var file = locks.openFile(io, name, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .lock = .exclusive,
        }) catch |open_error| switch (open_error) {
            error.FileNotFound => locks.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .lock = .exclusive,
                .permissions = .fromMode(0o600),
            }) catch |create_error| switch (create_error) {
                error.PathAlreadyExists => continue,
                else => return create_error,
            },
            else => return open_error,
        };
        errdefer {
            file.unlock(io);
            file.close(io);
        }
        try setFileInherited(file, false);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.CacheDirectoryChanged;
        const identity = EntryIdentity.fromStat(stat);
        if (!try entryHasIdentity(locks, io, name, identity)) {
            return error.CacheDirectoryChanged;
        }
        return .{
            .name = name,
            .identity = identity,
            .file = file,
        };
    }
}

fn verifyCacheLayout(
    cache: *const EffectiveCache,
    runtimes: *const CacheDirectory,
    prefix: *const CacheDirectory,
    bin: *const CacheDirectory,
    locks: *const CacheDirectory,
    cache_lock: CacheLock,
    zig_global: *const CacheDirectory,
    zig_local: *const CacheDirectory,
    io: Io,
) !void {
    try cache.verifyCanonical(io);
    try runtimes.verify(cache.directory, io);
    try prefix.verify(runtimes.directory, io);
    try bin.verify(prefix.directory, io);
    try locks.verify(cache.directory, io);
    if (!cache_lock.identity.matches(try cache_lock.file.stat(io)) or
        !try entryHasIdentity(
            locks.directory,
            io,
            cache_lock.name,
            cache_lock.identity,
        ))
    {
        return error.CacheDirectoryChanged;
    }
    try zig_global.verify(cache.directory, io);
    try zig_local.verify(cache.directory, io);
    try cache.verifyCanonical(io);
}

fn verifyNoSymlinkTree(io: Io, directory: Dir) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = try directory.statFile(
            io,
            entry.name,
            .{ .follow_symlinks = false },
        );
        switch (stat.kind) {
            .file => {
                var file = try directory.openFile(io, entry.name, .{
                    .mode = .read_only,
                    .allow_directory = false,
                    .follow_symlinks = false,
                });
                const opened_stat = file.stat(io) catch |err| {
                    file.close(io);
                    return err;
                };
                file.close(io);
                if (!EntryIdentity.fromStat(stat).matches(opened_stat)) {
                    return error.CacheDirectoryChanged;
                }
            },
            .directory => {
                var child = try directory.openDir(
                    io,
                    entry.name,
                    .{ .iterate = true, .follow_symlinks = false },
                );
                const opened_stat = child.stat(io) catch |err| {
                    child.close(io);
                    return err;
                };
                if (!EntryIdentity.fromStat(stat).matches(opened_stat)) {
                    child.close(io);
                    return error.CacheDirectoryChanged;
                }
                verifyNoSymlinkTree(io, child) catch |err| {
                    child.close(io);
                    return err;
                };
                child.close(io);
            },
            else => return error.CacheDirectoryChanged,
        }
    }
}

fn cacheDirectoryChildPath(
    allocator: Allocator,
    directory: CacheDirectory,
) ![]const u8 {
    return stableHandlePath(allocator, directory.directory.handle, directory.path);
}

fn stableHandlePath(
    allocator: Allocator,
    handle: std.posix.fd_t,
    fallback: []const u8,
) ![]const u8 {
    _ = fallback;
    const prefix = switch (builtin.os.tag) {
        .linux => "/proc/self/fd",
        .macos, .freebsd, .netbsd, .openbsd, .dragonfly => "/dev/fd",
        else => return error.UnsupportedOperatingSystem,
    };
    return std.fmt.allocPrint(allocator, "{s}/{d}", .{ prefix, handle });
}

fn stableDescendantHandlePath(
    allocator: Allocator,
    handle: std.posix.fd_t,
    fallback: []const u8,
) ![]const u8 {
    if (builtin.os.tag != .linux)
        return stableHandlePath(allocator, handle, fallback);
    return std.fmt.allocPrint(
        allocator,
        "/proc/{d}/fd/{d}",
        .{ std.os.linux.getpid(), handle },
    );
}

fn setDirectoryInherited(directory: Dir, inherited: bool) !void {
    return setHandleInherited(directory.handle, inherited);
}

fn setFileInherited(file: File, inherited: bool) !void {
    return setHandleInherited(file.handle, inherited);
}

fn setHandleInherited(handle: std.posix.fd_t, inherited: bool) !void {
    const flags: usize = if (inherited) 0 else std.posix.FD_CLOEXEC;
    while (true) switch (std.posix.errno(std.posix.system.fcntl(
        handle,
        std.posix.F.SETFD,
        flags,
    ))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return std.posix.unexpectedErrno(err),
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
            std.heap.page_allocator,
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
            std.heap.page_allocator,
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
    const snapshot = Snapshot{
        .path = "zig",
        .storage_path = "zig",
        .digest = "zig-digest",
        .protection = 0,
    };
    const zig = ZigSnapshot{
        .executable = snapshot,
        .lib_dir = "lib",
        .lib_digest = "lib-digest",
    };
    const first = try runtimeKey(
        std.testing.allocator,
        &config,
        "a",
        "b",
        "bindings",
        "adapter",
        false,
        "root",
        zig,
    );
    defer std.testing.allocator.free(first);
    config.source = "second.js";
    const second = try runtimeKey(
        std.testing.allocator,
        &config,
        "a",
        "b",
        "bindings",
        "adapter",
        false,
        "root",
        zig,
    );
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
        &.{},
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

test "monitor distinguishes namespace changes from integrity failures" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    try std.testing.expect(isNamespaceOnlyMutation(linux.IN.MOVE_SELF));
    try std.testing.expect(isNamespaceOnlyMutation(
        linux.IN.CREATE | linux.IN.ISDIR,
    ));
    try std.testing.expect(!isNamespaceOnlyMutation(linux.IN.ATTRIB));
    try std.testing.expect(!isNamespaceOnlyMutation(linux.IN.MODIFY));
    try std.testing.expect(!isNamespaceOnlyMutation(linux.IN.Q_OVERFLOW));
}

test "root ctime relaxation requires an observed rename" {
    var expected_entry = std.mem.zeroes(ManifestEntry);
    expected_entry.path = ".";
    expected_entry.kind = .directory;
    var changed_entry = expected_entry;
    changed_entry.ctime.nanoseconds = 1;
    const expected = TreeManifest{
        .entries = &.{expected_entry},
        .digest = @splat(0),
    };
    const changed = TreeManifest{
        .entries = &.{changed_entry},
        .digest = @splat(0),
    };

    try std.testing.expect(!expected.matches(changed));
    try std.testing.expect(expected.matchesAfterRootRename(changed));
    try std.testing.expect(!expected.matchesAfterObservedRootRename(
        changed,
        false,
    ));
    try std.testing.expect(expected.matchesAfterObservedRootRename(
        changed,
        true,
    ));
}

test "runtime build selections include only selected closures" {
    const selected = [_][]const u8{
        "build.zig",
        "runtime",
        "deps/lib/archive.a",
    };
    try std.testing.expect(treePathSelected("build.zig", &selected));
    try std.testing.expect(treePathSelected("runtime/js.cpp", &selected));
    try std.testing.expect(treePathSelected("deps", &selected));
    try std.testing.expect(treePathSelected("deps/lib", &selected));
    try std.testing.expect(treePathSelected(
        "deps/lib/archive.a",
        &selected,
    ));
    try std.testing.expect(!treePathSelected("deps/source", &selected));
    try std.testing.expect(!treePathSelected(".zig-cache", &selected));
}

test "runtime cache key includes the authoritative host API world" {
    var config = cli.Config{ .source = "source.js" };
    const snapshot = Snapshot{
        .path = "zig",
        .storage_path = "zig",
        .digest = "zig-digest",
        .protection = 0,
    };
    const zig = ZigSnapshot{
        .executable = snapshot,
        .lib_dir = "lib",
        .lib_digest = "lib-digest",
    };
    const bindings = try runtimeKey(
        std.testing.allocator,
        &config,
        null,
        null,
        "bindings",
        "adapter",
        false,
        "root",
        zig,
    );
    defer std.testing.allocator.free(bindings);
    const custom = try runtimeKey(
        std.testing.allocator,
        &config,
        null,
        null,
        "custom-bindings",
        "adapter",
        false,
        "root",
        zig,
    );
    defer std.testing.allocator.free(custom);
    try std.testing.expect(!std.mem.eql(u8, bindings, custom));
}

test "engine provenance requires a complete feature and topology tuple" {
    const parsed = try parseEngineProvenance(
        std.testing.allocator,
        "{\"schema\":1," ++
            "\"sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"," ++
            "\"host_api\":\"wasi-0.2.3\"," ++
            "\"features\":{\"stdio\":false,\"random\":true,\"clocks\":false,\"http\":false,\"fetch-event\":true}," ++
            "\"component_world\":\"custom-bindings\",\"surface_world\":\"caller\"}",
    );
    try std.testing.expectEqualStrings("wasi-0.2.3", parsed.host_api);
    try std.testing.expect(!parsed.features.stdio);
    try std.testing.expect(parsed.features.random);
    try std.testing.expect(parsed.features.fetch_event);
    try std.testing.expectEqualStrings(
        "custom-bindings",
        parsed.component_world,
    );
    try std.testing.expectError(
        error.InvalidMetadata,
        parseEngineProvenance(
            std.testing.allocator,
            "{\"schema\":1,\"sha256\":\"short\"}",
        ),
    );
    try std.testing.expectError(
        error.InvalidMetadata,
        parseEngineProvenance(
            std.testing.allocator,
            "schema=1\n" ++
                "sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n" ++
                "host-api=wasi-0.2.3\nfeatures=01001\n" ++
                "component-world=custom-bindings\nsurface-world=caller\n",
        ),
    );
    try std.testing.expectError(
        error.InvalidMetadata,
        parseEngineProvenance(
            std.testing.allocator,
            "{\"schema\":1," ++
                "\"sha256\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"," ++
                "\"host_api\":\"wasi-0.2.3\"," ++
                "\"features\":{\"stdio\":false,\"random\":true,\"clocks\":false,\"http\":false}," ++
                "\"component_world\":\"custom-bindings\",\"surface_world\":\"caller\"}",
        ),
    );
}
