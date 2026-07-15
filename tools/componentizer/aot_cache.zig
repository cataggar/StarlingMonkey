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
    CorruptCache,
    IncompleteCache,
    InvalidCacheFormat,
    InvalidCacheSchema,
    InvalidManifest,
    MissingCacheArtifact,
    SqliteUnavailable,
    StaleEngine,
    StaleFeatureAbi,
    StaleTool,
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
    try validateValue(feature_abi);
    const engine_sha = try hashFileHex(allocator, io, engine_path);
    try verifyCacheDatabase(allocator, cache_path, engine_sha);
    const sealed_cache_path = canonical_cache_path orelse cache_path;
    try canonicalizeCacheDatabase(
        allocator,
        io,
        cache_path,
        sealed_cache_path,
        engine_sha,
    );
    const weval_sha = try hashFileHex(allocator, io, weval_path);
    const cache_sha = try hashFileHex(allocator, io, sealed_cache_path);
    const primer_sha = try hashFileHex(allocator, io, primer_path);
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
    try Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = contents });
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
const sqlite_open_exclusive = 0x00000010;
const sqlite_integer = 1;
const sqlite_blob = 4;
const sqlite_row = 100;
const sqlite_done = 101;
const canonical_sqlite_version = [4]u8{ 0x00, 0x2e, 0x72, 0xa0 };

fn canonicalizeCacheDatabase(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    output_path: []const u8,
    engine_sha: []const u8,
) !void {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const temporary_path = try std.fmt.allocPrint(
        allocator,
        "{s}.canonical-{s}",
        .{ output_path, &random_hex },
    );
    defer Dir.deleteFileAbsolute(io, temporary_path) catch {};

    try writeCanonicalCache(allocator, source_path, temporary_path);
    try normalizeCanonicalHeader(io, temporary_path);
    try verifyCacheDatabase(allocator, temporary_path, engine_sha);

    var canonical = try Dir.openFileAbsolute(io, temporary_path, .{});
    defer canonical.close(io);
    try canonical.sync(io);
    try Dir.renameAbsolute(temporary_path, output_path, io);
}

fn writeCanonicalCache(
    allocator: Allocator,
    source_path: []const u8,
    output_path: []const u8,
) !void {
    var sqlite = try Sqlite.load();
    defer sqlite.deinit();

    const source_path_z = allocator.dupeSentinel(u8, source_path, 0) catch
        return error.InvalidCacheFormat;
    var optional_source: ?*SqliteDb = null;
    if (sqlite.open_v2(
        source_path_z,
        &optional_source,
        sqlite_open_readonly,
        null,
    ) != sqlite_ok) {
        if (optional_source) |db| _ = sqlite.close(db);
        return error.InvalidCacheFormat;
    }
    const source = optional_source orelse return error.InvalidCacheFormat;
    defer _ = sqlite.close(source);

    const output_path_z = allocator.dupeSentinel(u8, output_path, 0) catch
        return error.InvalidCacheFormat;
    var optional_output: ?*SqliteDb = null;
    if (sqlite.open_v2(
        output_path_z,
        &optional_output,
        sqlite_open_readwrite | sqlite_open_create | sqlite_open_exclusive,
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
}

fn normalizeCanonicalHeader(io: Io, path: []const u8) !void {
    var file = try Dir.openFileAbsolute(io, path, .{
        .mode = .read_write,
        .allow_directory = false,
    });
    defer file.close(io);
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
