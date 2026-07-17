const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const PublicImport = [2][]const u8;

pub const Binding = struct {
    kind: []const u8,
    specifier: []const u8,
    name: []const u8,
    dispatch_key: ?[]const u8 = null,
    arity: ?usize = null,
    resource: ?[]const u8 = null,
};

pub const Imports = struct {
    complete: bool,
    public: []const PublicImport,
    bindings: []const Binding,
};

pub const World = struct {
    name: ?[]const u8,
    wit_sha256: ?[]const u8,
};

pub const Feature = struct {
    name: []const u8,
    enabled: bool,
};

pub const Tool = struct {
    name: []const u8,
    sha256: []const u8,
    lib_tree_sha256: ?[]const u8 = null,
};

pub const SourceTree = struct {
    entry: []const u8,
    sha256: []const u8,
};

pub const InitializerTree = struct {
    entry: []const u8,
    sha256: []const u8,
    shares_source_tree: bool,
};

pub const DirectoryTree = struct {
    sha256: []const u8,
};

pub const Inputs = struct {
    source_sha256: []const u8,
    initializer_sha256: ?[]const u8,
    source_tree: SourceTree,
    initializer_tree: ?InitializerTree,
    runtime_arguments_sha256: []const u8,
    engine_sha256: []const u8,
    preview2_adapter_sha256: []const u8,
    build_root_sha256: ?[]const u8 = null,
    preopen_trees: ?[]const DirectoryTree = null,
};

pub const Provenance = struct {
    dispatch_world: World,
    component_world: World,
    worlds_sha256: []const u8,
    features: ?[]const Feature,
    features_sha256: ?[]const u8,
    tools: []const Tool,
    tools_sha256: []const u8,
    inputs: Inputs,
};

pub const Document = struct {
    schema: []const u8 = "starling-componentize-metadata/v2",
    processed_by: ProcessedBy,
    component_sha256: []const u8,
    imports_complete: bool,
    imports: []const PublicImport,
    bindings: []const Binding,
    provenance: Provenance,
};

pub const ProcessedBy = struct {
    name: []const u8 = "starling-componentize",
    version: []const u8,
};

pub fn parseBindings(
    allocator: Allocator,
    source: []const u8,
) !Imports {
    const marker = "pub const js_import_manifest: []const u8 =";
    const marker_start = std.mem.indexOf(u8, source, marker) orelse
        return .{ .complete = true, .public = &.{}, .bindings = &.{} };
    const manifest_source = source[marker_start + marker.len ..];
    const marker_end = std.mem.indexOf(u8, manifest_source, "    \"\";") orelse
        return error.InvalidBindingsManifest;

    var public: std.ArrayList(PublicImport) = .empty;
    var bindings: std.ArrayList(Binding) = .empty;
    var lines = std.mem.splitScalar(u8, manifest_source[0..marker_end], '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 2 or line[0] != '"') continue;
        const quote_end = std.mem.lastIndexOfScalar(u8, line, '"') orelse
            return error.InvalidBindingsManifest;
        if (quote_end == 0) return error.InvalidBindingsManifest;
        const decoded = try decodeZigString(allocator, line[1..quote_end]);
        const record = std.mem.trimEnd(u8, decoded, "\n");
        if (record.len == 0) continue;

        var fields_buffer: [6][]const u8 = undefined;
        var field_count: usize = 0;
        var fields = std.mem.splitScalar(u8, record, '\t');
        while (fields.next()) |field| {
            if (field_count == fields_buffer.len) return error.InvalidBindingsManifest;
            fields_buffer[field_count] = field;
            field_count += 1;
        }

        if (field_count == 4 and std.mem.eql(u8, fields_buffer[0], "R")) {
            try appendPublicUnique(
                allocator,
                &public,
                .{ fields_buffer[1], fields_buffer[3] },
            );
            bindings.append(allocator, .{
                .kind = "resource",
                .specifier = fields_buffer[1],
                .name = fields_buffer[3],
                .resource = fields_buffer[2],
            }) catch @panic("out of memory");
        } else if (field_count == 6 and fields_buffer[0].len == 1) {
            const kind = switch (fields_buffer[0][0]) {
                'C' => "constructor",
                'M' => "method",
                'S' => "static",
                else => return error.InvalidBindingsManifest,
            };
            bindings.append(allocator, .{
                .kind = kind,
                .specifier = fields_buffer[1],
                .name = fields_buffer[3],
                .dispatch_key = fields_buffer[4],
                .arity = try std.fmt.parseInt(usize, fields_buffer[5], 10),
                .resource = fields_buffer[2],
            }) catch @panic("out of memory");
        } else if (field_count == 4) {
            try appendPublicUnique(
                allocator,
                &public,
                .{ fields_buffer[0], fields_buffer[1] },
            );
            bindings.append(allocator, .{
                .kind = "function",
                .specifier = fields_buffer[0],
                .name = fields_buffer[1],
                .dispatch_key = fields_buffer[2],
                .arity = try std.fmt.parseInt(usize, fields_buffer[3], 10),
            }) catch @panic("out of memory");
        } else {
            return error.InvalidBindingsManifest;
        }
    }

    return .{
        .complete = true,
        .public = public.toOwnedSlice(allocator) catch @panic("out of memory"),
        .bindings = bindings.toOwnedSlice(allocator) catch @panic("out of memory"),
    };
}

pub fn render(allocator: Allocator, document: Document) ![]const u8 {
    try validateDocumentUtf8(document);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(document, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    return allocator.dupe(u8, output.written());
}

pub fn renderImports(allocator: Allocator, imports: Imports) ![]const u8 {
    try validateImportsUtf8(imports);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(.{
        .schema = "starling-componentize-imports/v1",
        .complete = imports.complete,
        .imports = imports.public,
        .bindings = imports.bindings,
    }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    return allocator.dupe(u8, output.written());
}

fn validateDocumentUtf8(document: Document) !void {
    try validateString(document.schema);
    try validateString(document.processed_by.name);
    try validateString(document.processed_by.version);
    try validateString(document.component_sha256);
    try validateImportsUtf8(.{
        .complete = document.imports_complete,
        .public = document.imports,
        .bindings = document.bindings,
    });
    try validateWorldUtf8(document.provenance.dispatch_world);
    try validateWorldUtf8(document.provenance.component_world);
    try validateString(document.provenance.worlds_sha256);
    if (document.provenance.features) |features| {
        for (features) |feature| try validateString(feature.name);
    }
    if (document.provenance.features_sha256) |digest| try validateString(digest);
    for (document.provenance.tools) |tool| {
        try validateString(tool.name);
        try validateString(tool.sha256);
        if (tool.lib_tree_sha256) |digest| try validateString(digest);
    }
    try validateString(document.provenance.tools_sha256);
    const inputs = document.provenance.inputs;
    try validateString(inputs.source_sha256);
    if (inputs.initializer_sha256) |digest| try validateString(digest);
    try validateString(inputs.source_tree.entry);
    try validateString(inputs.source_tree.sha256);
    if (inputs.initializer_tree) |tree| {
        try validateString(tree.entry);
        try validateString(tree.sha256);
    }
    try validateString(inputs.runtime_arguments_sha256);
    try validateString(inputs.engine_sha256);
    try validateString(inputs.preview2_adapter_sha256);
    if (inputs.build_root_sha256) |digest| try validateString(digest);
    if (inputs.preopen_trees) |trees| {
        for (trees) |tree| {
            try validateString(tree.sha256);
        }
    }
}

fn validateImportsUtf8(imports: Imports) !void {
    for (imports.public) |entry| {
        try validateString(entry[0]);
        try validateString(entry[1]);
    }
    for (imports.bindings) |binding| {
        try validateString(binding.kind);
        try validateString(binding.specifier);
        try validateString(binding.name);
        if (binding.dispatch_key) |value| try validateString(value);
        if (binding.resource) |value| try validateString(value);
    }
}

fn validateWorldUtf8(world: World) !void {
    if (world.name) |name| try validateString(name);
    if (world.wit_sha256) |digest| try validateString(digest);
}

fn validateString(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8Metadata;
}

pub fn sha256Bytes(allocator: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

pub fn sha256File(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    var file = try Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (read == 0) continue;
        hasher.update(buffer[0..read]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

pub fn hashFields(
    allocator: Allocator,
    fields: []const [2][]const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (fields) |field| {
        hasher.update(field[0]);
        hasher.update(&.{0});
        hasher.update(field[1]);
        hasher.update(&.{0xff});
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn appendPublicUnique(
    allocator: Allocator,
    imports: *std.ArrayList(PublicImport),
    value: PublicImport,
) !void {
    for (imports.items) |existing| {
        if (std.mem.eql(u8, existing[0], value[0]) and
            std.mem.eql(u8, existing[1], value[1]))
        {
            return;
        }
    }
    imports.append(allocator, value) catch @panic("out of memory");
}

fn decodeZigString(allocator: Allocator, encoded: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] != '\\') {
            output.append(allocator, encoded[i]) catch @panic("out of memory");
            continue;
        }
        i += 1;
        if (i >= encoded.len) return error.InvalidBindingsManifest;
        const decoded: u8 = switch (encoded[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            else => return error.InvalidBindingsManifest,
        };
        output.append(allocator, decoded) catch @panic("out of memory");
    }
    return output.toOwnedSlice(allocator);
}

test "parses public and detailed import binding metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\pub const js_import_manifest: []const u8 =
        \\    "R\ttest:host/api@1.0.0\tcounter\tCounter\n" ++
        \\    "M\ttest:host/api@1.0.0\tcounter\tincrement\ttest:host/api@1.0.0#[method]counter.increment\t1\n" ++
        \\    "test:host/api@1.0.0\tadd\ttest:host/api@1.0.0#add\t2\n" ++
        \\    "root-fn\tdefault\t$root#root-fn\t0\n" ++
        \\    "";
    ;
    const parsed = try parseBindings(arena.allocator(), source);
    try std.testing.expect(parsed.complete);
    try std.testing.expectEqual(@as(usize, 3), parsed.public.len);
    try std.testing.expectEqualStrings("Counter", parsed.public[0][1]);
    try std.testing.expectEqualStrings("method", parsed.bindings[1].kind);
    try std.testing.expectEqual(@as(usize, 1), parsed.bindings[1].arity.?);
    try std.testing.expectEqualStrings("default", parsed.public[2][1]);
}

test "missing import manifest means no JavaScript guest imports" {
    const parsed = try parseBindings(std.testing.allocator, "pub const answer = 42;");
    try std.testing.expect(parsed.complete);
    try std.testing.expectEqual(@as(usize, 0), parsed.public.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.bindings.len);
}

test "public JSON rejects non-UTF-8 strings instead of emitting byte arrays" {
    try std.testing.expectError(
        error.InvalidUtf8Metadata,
        renderImports(std.testing.allocator, .{
            .complete = true,
            .public = &.{
                .{ "valid", "invalid\xff" },
            },
            .bindings = &.{},
        }),
    );

    const document = Document{
        .processed_by = .{ .version = "test" },
        .component_sha256 = "00",
        .imports_complete = true,
        .imports = &.{},
        .bindings = &.{},
        .provenance = .{
            .dispatch_world = .{ .name = null, .wit_sha256 = null },
            .component_world = .{ .name = null, .wit_sha256 = null },
            .worlds_sha256 = "00",
            .features = null,
            .features_sha256 = null,
            .tools = &.{},
            .tools_sha256 = "00",
            .inputs = .{
                .source_sha256 = "00",
                .initializer_sha256 = null,
                .source_tree = .{
                    .entry = "invalid\xff",
                    .sha256 = "00",
                },
                .initializer_tree = null,
                .runtime_arguments_sha256 = "00",
                .engine_sha256 = "00",
                .preview2_adapter_sha256 = "00",
            },
        },
    };
    try std.testing.expectError(
        error.InvalidUtf8Metadata,
        render(std.testing.allocator, document),
    );
}
