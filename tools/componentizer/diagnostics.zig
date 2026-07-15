const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.Io.File;

pub const Format = enum {
    human,
    json,
};

pub const Phase = enum {
    arguments,
    inputs,
    runtime_build,
    initialize,
    strip,
    embed,
    adapt,
    metadata,
    validate,
    debug,
    publish,
};

pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    format: Format,
    phase: Phase = .inputs,
    detail: ?[]const u8 = null,
    message: ?[]const u8 = null,
    command: ?[]const u8 = null,
    exit_code: ?u8 = null,
    signal: ?u32 = null,

    pub fn begin(self: *Context, phase: Phase) void {
        self.phase = phase;
        self.detail = null;
        self.message = null;
        self.command = null;
        self.exit_code = null;
        self.signal = null;
    }

    pub fn commandFailed(
        self: *Context,
        stage: []const u8,
        term: std.process.Child.Term,
        stderr: []const u8,
        redact_path: ?[]const u8,
    ) void {
        self.command = stage;
        self.message = std.fmt.allocPrint(
            self.allocator,
            "{s} did not complete successfully",
            .{stage},
        ) catch "a componentization command did not complete successfully";
        switch (term) {
            .exited => |code| self.exit_code = code,
            .signal, .stopped => |signal| self.signal = @intFromEnum(signal),
            .unknown => {},
        }

        const trimmed = std.mem.trim(u8, stderr, " \t\r\n");
        const limited = sanitizeStderr(self.allocator, trimmed, 16 * 1024);
        const safe_stderr = if (redact_path) |path|
            std.mem.replaceOwned(
                u8,
                self.allocator,
                limited,
                path,
                "<transaction>",
            ) catch limited
        else
            limited;
        const termination = terminationText(self.allocator, term);
        self.detail = if (safe_stderr.len == 0)
            termination
        else
            std.fmt.allocPrint(
                self.allocator,
                "{s}\n{s}",
                .{ termination, safe_stderr },
            ) catch safe_stderr;
    }

    pub fn report(self: *Context, err: anyerror) void {
        if (err == error.InvalidUtf8Path) self.phase = .inputs;
        const code = phaseCode(self.phase);
        const message = self.message orelse errorMessage(err, self.phase);
        const hint = errorHint(err) orelse phaseHint(self.phase);
        switch (self.format) {
            .human => self.reportHuman(code, message, @errorName(err), hint),
            .json => self.reportJson(
                "error",
                code,
                @tagName(self.phase),
                message,
                @errorName(err),
                self.detail,
                hint,
                null,
                null,
                null,
                null,
                null,
            ),
        }
    }

    pub fn reportParse(self: *Context, err: anyerror, message: []const u8) void {
        self.phase = .arguments;
        switch (self.format) {
            .human => self.reportHuman(
                "SMC0001",
                message,
                @errorName(err),
                "run with --help to inspect the supported command-line surface",
            ),
            .json => self.reportJson(
                "error",
                "SMC0001",
                "arguments",
                message,
                @errorName(err),
                null,
                "run with --help to inspect the supported command-line surface",
                null,
                null,
                null,
                null,
                null,
            ),
        }
    }

    pub fn reportSuccess(
        self: *Context,
        source: []const u8,
        output: []const u8,
    ) void {
        switch (self.format) {
            .human => {
                const line = std.fmt.allocPrint(
                    self.allocator,
                    "Componentized {s} into {s}\n",
                    .{ source, output },
                ) catch return;
                File.stderr().writeStreamingAll(self.io, line) catch {};
            },
            .json => self.reportJson(
                "info",
                "SMC0000",
                "publish",
                "componentization completed",
                null,
                null,
                null,
                source,
                output,
                null,
                null,
                null,
            ),
        }
    }

    fn reportHuman(
        self: *Context,
        code: []const u8,
        message: []const u8,
        cause: []const u8,
        hint: []const u8,
    ) void {
        const rendered = if (self.detail) |detail|
            std.fmt.allocPrint(
                self.allocator,
                "error[{s}] {s}: {s} ({s})\n  {s}\n  hint: {s}\n",
                .{ code, @tagName(self.phase), message, cause, detail, hint },
            ) catch return
        else
            std.fmt.allocPrint(
                self.allocator,
                "error[{s}] {s}: {s} ({s})\n  hint: {s}\n",
                .{ code, @tagName(self.phase), message, cause, hint },
            ) catch return;
        File.stderr().writeStreamingAll(self.io, rendered) catch {};
    }

    fn reportJson(
        self: *Context,
        severity: []const u8,
        code: []const u8,
        phase: []const u8,
        message: []const u8,
        cause: ?[]const u8,
        detail: ?[]const u8,
        hint: ?[]const u8,
        source: ?[]const u8,
        output_path: ?[]const u8,
        command: ?[]const u8,
        exit_code: ?u8,
        signal: ?u32,
    ) void {
        const diagnostic = .{
            .schema = "starling-componentize-diagnostic/v1",
            .severity = self.jsonString(severity),
            .code = self.jsonString(code),
            .phase = self.jsonString(phase),
            .message = self.jsonString(message),
            .cause = if (cause) |value| self.jsonString(value) else null,
            .detail = if (detail) |value| self.jsonString(value) else null,
            .hint = if (hint) |value| self.jsonString(value) else null,
            .source = if (source) |value| self.jsonString(value) else null,
            .output = if (output_path) |value| self.jsonString(value) else null,
            .command = if (command orelse self.command) |value|
                self.jsonString(value)
            else
                null,
            .exit_code = exit_code orelse self.exit_code,
            .signal = signal orelse self.signal,
        };
        var rendered: std.Io.Writer.Allocating = .init(self.allocator);
        defer rendered.deinit();
        std.json.Stringify.value(diagnostic, .{}, &rendered.writer) catch return;
        rendered.writer.writeByte('\n') catch return;
        File.stderr().writeStreamingAll(self.io, rendered.written()) catch {};
    }

    fn jsonString(self: *Context, value: []const u8) []const u8 {
        if (std.unicode.utf8ValidateSlice(value)) return value;
        return sanitizeStderr(self.allocator, value, std.math.maxInt(usize));
    }
};

fn sanitizeStderr(
    allocator: Allocator,
    input: []const u8,
    limit: usize,
) []const u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < input.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[index]) catch {
            if (output.items.len + 3 > limit) break;
            output.appendSlice(allocator, "\xef\xbf\xbd") catch break;
            index += 1;
            continue;
        };
        const end = index + sequence_len;
        if (end > input.len or !std.unicode.utf8ValidateSlice(input[index..end])) {
            if (output.items.len + 3 > limit) break;
            output.appendSlice(allocator, "\xef\xbf\xbd") catch break;
            index += 1;
            continue;
        }
        if (output.items.len + sequence_len > limit) break;
        output.appendSlice(allocator, input[index..end]) catch break;
        index = end;
    }
    return output.toOwnedSlice(allocator) catch "";
}

fn terminationText(
    allocator: Allocator,
    term: std.process.Child.Term,
) []const u8 {
    return switch (term) {
        .exited => |code| std.fmt.allocPrint(
            allocator,
            "process exited with code {d}",
            .{code},
        ) catch "process exited",
        .signal => |signal| std.fmt.allocPrint(
            allocator,
            "process terminated with signal {t}",
            .{signal},
        ) catch "process terminated by a signal",
        .stopped => |signal| std.fmt.allocPrint(
            allocator,
            "process stopped with signal {t}",
            .{signal},
        ) catch "process stopped by a signal",
        .unknown => "process terminated unexpectedly",
    };
}

fn phaseCode(phase: Phase) []const u8 {
    return switch (phase) {
        .arguments => "SMC0001",
        .inputs => "SMC1001",
        .runtime_build => "SMC2001",
        .initialize => "SMC3001",
        .strip => "SMC4001",
        .embed => "SMC4101",
        .adapt => "SMC4201",
        .metadata => "SMC4301",
        .validate => "SMC5001",
        .debug => "SMC6001",
        .publish => "SMC7001",
    };
}

fn errorMessage(err: anyerror, phase: Phase) []const u8 {
    return switch (err) {
        error.InputOutputCollision => "the component output resolves to an input file",
        error.InvalidMetadataDestination => "the metadata destination collides with another artifact or is not beside the component",
        error.DebugOutputCollision => "the debug destination collides with an artifact or cannot be replaced safely",
        error.IncompatibleEngineOptions => "--engine cannot be combined with feature selection or --use-debug-build",
        error.MetadataUnavailable => "public imports metadata requires generated bindings from a native runtime build",
        error.InvalidBindingsManifest => "the generated bindings contain an invalid JavaScript imports manifest",
        error.InvalidUtf8Metadata => "generated public metadata contains a non-UTF-8 string",
        error.InvalidUtf8Path => "a filesystem path is not valid UTF-8",
        error.RollbackIncomplete => "publication rollback was incomplete; transaction storage was retained",
        error.EmptyRuntimeArgument => "--runtime-arg cannot represent an empty argument",
        error.UnrepresentableRuntimeArgument => "a runtime argument cannot be represented by StarlingMonkey's configuration parser",
        error.MissingWitFiles => "the selected WIT layout contains no .wit files",
        error.UnsupportedWitEntry => "the selected WIT layout contains a non-file, non-directory entry",
        error.MissingBuildArtifact => "a required runtime or tool artifact is missing",
        error.PublicationDirectoryChanged => "the canonical publication directory changed before commit",
        else => phaseMessage(phase),
    };
}

fn errorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InputOutputCollision => "choose an output that does not resolve to the source or initializer",
        error.InvalidMetadataDestination => "choose a regular metadata file in the component output directory",
        error.DebugOutputCollision => "use a real directory beside the component and keep generated names free of directories",
        error.IncompatibleEngineOptions => "build a matching runtime natively or remove the build-changing options",
        error.MetadataUnavailable => "omit --engine so the CLI can retain and inspect generated bindings",
        error.InvalidBindingsManifest => "rebuild with the repository-pinned binding generator",
        error.InvalidUtf8Metadata => "use UTF-8 names for all public metadata fields",
        error.InvalidUtf8Path => "rename the path using valid UTF-8 bytes and retry",
        error.RollbackIncomplete => "inspect the retained transaction beside the output and resolve raced destinations manually",
        error.EmptyRuntimeArgument, error.UnrepresentableRuntimeArgument => "use --runtime-arg only for values accepted by the runtime string parser",
        error.MissingWitFiles, error.UnsupportedWitEntry => "provide a regular WIT directory containing only directories and .wit files",
        error.MissingBuildArtifact => "verify tool overrides and native runtime build outputs",
        error.PublicationDirectoryChanged => "the original publication was restored; retry only after the canonical output directory is stable",
        else => null,
    };
}

fn phaseMessage(phase: Phase) []const u8 {
    return switch (phase) {
        .arguments => "invalid command-line arguments",
        .inputs => "input preflight failed",
        .runtime_build => "the WIT-specific StarlingMonkey runtime could not be prepared",
        .initialize => "JavaScript initialization or export preflight failed",
        .strip => "the initialized core module could not be stripped",
        .embed => "the selected component world could not be embedded",
        .adapt => "the core module could not be adapted into a component",
        .metadata => "component metadata could not be generated",
        .validate => "the completed component did not validate",
        .debug => "requested debug artifacts could not be prepared safely",
        .publish => "completed artifacts could not be published atomically",
    };
}

fn phaseHint(phase: Phase) []const u8 {
    return switch (phase) {
        .arguments => "run with --help to inspect the supported command-line surface",
        .inputs => "check source, WIT, tool, and destination paths",
        .runtime_build => "re-run with --verbose and verify the selected WIT world and Zig build inputs",
        .initialize => "inspect the JavaScript module's top-level evaluation and required WIT exports",
        .strip => "verify that the selected WABT build accepts the initialized core module",
        .embed => "verify --component-wit and --component-world-name describe the complete component closure",
        .adapt => "verify the preview1 adapter matches the reactor and component tool",
        .metadata => "verify wasm-tools supports metadata add and that generated import bindings are available",
        .validate => "inspect the preceding component construction stages and selected adapter",
        .debug => "use a real debug directory that does not contain an input or output",
        .publish => "check destination permissions and keep component, metadata, and debug outputs collision-free",
    };
}

test "phase diagnostic codes are stable and distinct" {
    try std.testing.expectEqualStrings("SMC0001", phaseCode(.arguments));
    try std.testing.expectEqualStrings("SMC3001", phaseCode(.initialize));
    try std.testing.expectEqualStrings("SMC4301", phaseCode(.metadata));
    try std.testing.expectEqualStrings("SMC7001", phaseCode(.publish));
}

test "known failures retain actionable messages" {
    try std.testing.expectEqualStrings(
        "public imports metadata requires generated bindings from a native runtime build",
        errorMessage(error.MetadataUnavailable, .metadata),
    );
    try std.testing.expect(errorHint(error.DebugOutputCollision) != null);
}

test "stderr sanitization replaces invalid bytes and truncates at codepoint boundaries" {
    const invalid = sanitizeStderr(
        std.testing.allocator,
        "ok\xff\xe2\x82broken",
        1024,
    );
    defer std.testing.allocator.free(invalid);
    try std.testing.expect(std.unicode.utf8ValidateSlice(invalid));
    try std.testing.expectEqualStrings("ok���broken", invalid);

    const truncated = sanitizeStderr(
        std.testing.allocator,
        "1234€",
        6,
    );
    defer std.testing.allocator.free(truncated);
    try std.testing.expectEqualStrings("1234", truncated);
}
