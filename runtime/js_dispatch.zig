const std = @import("std");

const DispatchResult = extern struct {
    ptr: ?[*]u8,
    len: usize,
};

extern fn starling_js_dispatch(
    export_name_ptr: [*]const u8,
    export_name_len: usize,
    args_json_ptr: [*]const u8,
    args_json_len: usize,
    result: *DispatchResult,
) u32;

extern fn free(ptr: ?*anyopaque) void;

var result_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

// ---------------------------------------------------------------------------
// Typed native dispatch bridge (see runtime/js_dispatch.h for the C++ side
// and the shared design rationale: JSON round-trips `u64`/`s64` through a
// `f64` double during `JSON.parse`/`JSON.stringify` and silently loses
// precision above 2**53; this path instead builds/reads a small tagged value
// tree directly against SpiderMonkey's `BigInt`/object APIs, so it is used
// automatically -- and *only* -- for the exports whose argument or result
// type graph actually contains an `i64`/`u64` (see `needsNative` below).
// Every other export keeps going through `callJson` unchanged, so this is a
// strictly additive, bounded extension of the existing dispatch, not a
// replacement of it.

const NativeTag = enum(u32) {
    bool_ = 0,
    i64_ = 1,
    u64_ = 2,
    f64_ = 3,
    string_ = 4,
    option_none = 5,
    option_some = 6,
    record = 7,
};

// Mirrors `struct StarlingJsValue` in js_dispatch.h field-for-field. Both
// sides live in the same wasm module, so this is exchanged by pointer, not
// serialized.
const NativeValue = extern struct {
    tag: NativeTag,
    bool_val: u8 = 0,
    i64_val: i64 = 0,
    u64_val: u64 = 0,
    f64_val: f64 = 0,
    str_ptr: ?[*]const u8 = null,
    str_len: usize = 0,
    option_ptr: ?*const NativeValue = null, // tag == .option_some
    fields_ptr: ?[*]const NativeField = null, // tag == .record
    fields_len: usize = 0, // tag == .record
};

// Mirrors `struct StarlingJsField` in js_dispatch.h. `value` is a pointer
// (not embedded by value) to match the C++ side, which needs it that way to
// keep `StarlingJsValue`/`StarlingJsField` mutually referencing without a
// forward-declaration ordering problem.
const NativeField = extern struct {
    name_ptr: ?[*]const u8 = null,
    name_len: usize = 0,
    value: ?*const NativeValue = null,
};

extern fn starling_js_dispatch_native(
    export_name_ptr: [*]const u8,
    export_name_len: usize,
    args_ptr: [*]const NativeValue,
    args_len: usize,
    out_result: *NativeValue,
    out_arena: *?*anyopaque,
) u32;

extern fn starling_js_dispatch_native_free(arena: ?*anyopaque) void;

// Recursively checks whether `T`'s type graph (struct fields, optional
// children) contains an exact `i64`/`u64` anywhere -- the only types JSON
// cannot carry losslessly. Used at comptime to decide, per export, whether
// `call` should route through the native bridge or the JSON one; this is the
// "bounded fallback" that keeps every JSON-representable export working
// exactly as before.
fn typeNeedsNative(comptime T: type) bool {
    if (T == i64 or T == u64) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| typeNeedsNative(o.child),
        .@"struct" => |s| comptime blk: {
            for (s.field_types) |field_type| {
                if (typeNeedsNative(field_type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn needsNative(comptime Result: type, comptime Args: type) bool {
    return typeNeedsNative(Result) or typeNeedsNative(Args);
}

// Builds a `NativeValue` tree for one Zig argument value. Nested allocations
// (record field arrays, boxed option payloads) come from `allocator`, which
// the caller (`callNative`) backs with a short-lived arena freed after the
// dispatch call returns; string payloads are referenced directly (no copy)
// since the source value already outlives the call.
fn encodeNative(comptime T: type, value: T, allocator: std.mem.Allocator) NativeValue {
    return switch (@typeInfo(T)) {
        .bool => .{ .tag = .bool_, .bool_val = @intFromBool(value) },
        .int => blk: {
            if (T == i64) break :blk .{ .tag = .i64_, .i64_val = value };
            if (T == u64) break :blk .{ .tag = .u64_, .u64_val = value };
            // Other integer widths (i32/u32/...) fit exactly in an f64, but
            // also stash the exact bits in `i64_val` since `decodeNative`
            // reads that field back via `@intCast` for these -- consistent
            // with the C++ decode side, which likewise populates every
            // integer-ish field with the same bit pattern for a JS `Number`.
            break :blk .{ .tag = .f64_, .f64_val = @floatFromInt(value), .i64_val = @intCast(value) };
        },
        .float => .{ .tag = .f64_, .f64_val = @floatCast(value) },
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) {
                break :blk .{ .tag = .string_, .str_ptr = value.ptr, .str_len = value.len };
            }
            @compileError("native dispatch: unsupported argument type " ++ @typeName(T));
        },
        .optional => |o| blk: {
            if (value) |present| {
                const boxed = allocator.create(NativeValue) catch @panic("OOM");
                boxed.* = encodeNative(o.child, present, allocator);
                break :blk .{ .tag = .option_some, .option_ptr = boxed };
            }
            break :blk .{ .tag = .option_none };
        },
        .@"struct" => |s| blk: {
            const fields = allocator.alloc(NativeField, s.field_names.len) catch @panic("OOM");
            inline for (s.field_names, s.field_types, 0..) |name, field_type, i| {
                const boxed = allocator.create(NativeValue) catch @panic("OOM");
                boxed.* = encodeNative(field_type, @field(value, name), allocator);
                fields[i] = .{ .name_ptr = name.ptr, .name_len = name.len, .value = boxed };
            }
            break :blk .{ .tag = .record, .fields_ptr = fields.ptr, .fields_len = fields.len };
        },
        else => @compileError("native dispatch: unsupported argument type " ++ @typeName(T)),
    };
}

fn findNativeField(value: *const NativeValue, comptime name: []const u8) ?*const NativeValue {
    if (value.tag != .record) return null;
    const fields = value.fields_ptr orelse return null;
    for (fields[0..value.fields_len]) |field| {
        const field_name = (field.name_ptr orelse continue)[0..field.name_len];
        if (std.mem.eql(u8, field_name, name)) return field.value;
    }
    return null;
}

// Decodes a generic `NativeValue` tree (reflecting the JS return value's
// actual runtime shape, built by `decode_from_js` in js_dispatch.cpp) onto
// the concrete, comptime-known `T`. This is the native-bridge analogue of
// `std.json.parseFromSliceLeaky` in `callJson` below.
fn decodeNative(comptime T: type, value: *const NativeValue) T {
    return switch (@typeInfo(T)) {
        .bool => value.bool_val != 0,
        .int => blk: {
            if (T == i64) break :blk value.i64_val;
            if (T == u64) break :blk value.u64_val;
            break :blk @intCast(value.i64_val);
        },
        .float => @floatCast(value.f64_val),
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) {
                const ptr = value.str_ptr orelse @panic("native dispatch: expected a string result");
                break :blk ptr[0..value.str_len];
            }
            @compileError("native dispatch: unsupported result type " ++ @typeName(T));
        },
        .optional => |o| blk: {
            if (value.tag == .option_none) break :blk null;
            const inner = value.option_ptr orelse
                @panic("native dispatch: option marked present but missing a value");
            break :blk decodeNative(o.child, inner);
        },
        .@"struct" => |s| blk: {
            var result: T = undefined;
            inline for (s.field_names, s.field_types) |name, field_type| {
                const field_value = findNativeField(value, name) orelse
                    @panic("native dispatch: missing record field '" ++ name ++ "'");
                @field(result, name) = decodeNative(field_type, field_value);
            }
            break :blk result;
        },
        else => @compileError("native dispatch: unsupported result type " ++ @typeName(T)),
    };
}

fn callNative(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arg_info = @typeInfo(@TypeOf(args)).@"struct";
    var argv: [arg_info.field_names.len]NativeValue = undefined;
    inline for (arg_info.field_names, arg_info.field_types, 0..) |name, field_type, i| {
        argv[i] = encodeNative(field_type, @field(args, name), allocator);
    }

    var out_result: NativeValue = .{ .tag = .bool_ };
    var out_arena: ?*anyopaque = null;
    const status = starling_js_dispatch_native(
        export_name.ptr,
        export_name.len,
        &argv,
        argv.len,
        &out_result,
        &out_arena,
    );
    defer starling_js_dispatch_native_free(out_arena);
    if (status != 0) {
        @panic("JavaScript export dispatch failed");
    }
    if (Result == void) return;
    return decodeNative(Result, &out_result);
}

pub fn call(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    if (comptime needsNative(Result, @TypeOf(args))) {
        return callNative(export_name, Result, args);
    }
    return callJson(export_name, Result, args);
}

fn callJson(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    var args_json: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer args_json.deinit();
    std.json.Stringify.value(args, .{}, &args_json.writer) catch
        @panic("failed to serialize JavaScript arguments");

    var dispatch_result: DispatchResult = .{ .ptr = null, .len = 0 };
    if (starling_js_dispatch(
        export_name.ptr,
        export_name.len,
        args_json.written().ptr,
        args_json.written().len,
        &dispatch_result,
    ) != 0) {
        @panic("JavaScript export dispatch failed");
    }

    if (Result == void) {
        free(if (dispatch_result.ptr) |ptr| @ptrCast(ptr) else null);
        return;
    }

    const result_ptr = dispatch_result.ptr orelse
        @panic("JavaScript export dispatch returned no result");
    defer free(@ptrCast(result_ptr));
    _ = result_arena.reset(.retain_capacity);
    return std.json.parseFromSliceLeaky(
        Result,
        result_arena.allocator(),
        result_ptr[0..dispatch_result.len],
        .{},
    ) catch @panic("failed to decode the JavaScript return value");
}

test "serializes lifted arguments as a JSON array" {
    const Point = struct { x: i32, label: []const u8 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.json.Stringify.value(.{ @as(u32, 7), Point{ .x = -2, .label = "a" } }, .{}, &output.writer);
    try std.testing.expectEqualStrings("[7,{\"x\":-2,\"label\":\"a\"}]", output.written());
}

test "decodes structured JavaScript results" {
    const Result = struct { greeting: []const u8, values: []const u32, extra: ?bool };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try std.json.parseFromSliceLeaky(
        Result,
        arena.allocator(),
        "{\"greeting\":\"hello\",\"values\":[1,2],\"extra\":null}",
        .{},
    );
    try std.testing.expectEqualStrings("hello", result.greeting);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, result.values);
    try std.testing.expectEqual(null, result.extra);
}

test "needsNative routes plain types to JSON and u64/s64 to the native bridge" {
    const Plain = struct { x: i32, y: i32 };
    try std.testing.expect(!needsNative(Plain, @TypeOf(.{ @as(i32, 1), @as(i32, 2) })));
    try std.testing.expect(needsNative(void, @TypeOf(.{@as(u64, 1)})));
    try std.testing.expect(needsNative(i64, @TypeOf(.{})));

    // A u64 nested two levels deep (inside a record inside the args tuple)
    // must still be detected, since that's exactly the `big-point` shape
    // used by the end-to-end test fixture.
    const BigPoint = struct { p: Plain, id: u64 };
    try std.testing.expect(needsNative(BigPoint, @TypeOf(.{})));
    try std.testing.expect(needsNative(void, @TypeOf(.{BigPoint{ .p = .{ .x = 0, .y = 0 }, .id = 0 }})));
}

test "encodes and decodes exact u64 values beyond 2^53" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const big: u64 = std.math.maxInt(u64);
    const encoded = encodeNative(u64, big, arena.allocator());
    try std.testing.expectEqual(NativeTag.u64_, encoded.tag);
    try std.testing.expectEqual(big, encoded.u64_val);
    try std.testing.expectEqual(big, decodeNative(u64, &encoded));

    // 2^53 + 1: the smallest integer a round trip through `f64`/JSON would
    // corrupt (JSON.parse/JSON.stringify go through IEEE-754 doubles, whose
    // mantissa can't represent this value exactly).
    const beyond_f64: u64 = (1 << 53) + 1;
    const encoded_beyond = encodeNative(u64, beyond_f64, arena.allocator());
    try std.testing.expectEqual(beyond_f64, decodeNative(u64, &encoded_beyond));
}

test "encodes and decodes exact s64 values beyond -2^53" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const min: i64 = std.math.minInt(i64);
    const encoded = encodeNative(i64, min, arena.allocator());
    try std.testing.expectEqual(NativeTag.i64_, encoded.tag);
    try std.testing.expectEqual(min, encoded.i64_val);
    try std.testing.expectEqual(min, decodeNative(i64, &encoded));

    const beyond_f64: i64 = -((1 << 53) + 1);
    const encoded_beyond = encodeNative(i64, beyond_f64, arena.allocator());
    try std.testing.expectEqual(beyond_f64, decodeNative(i64, &encoded_beyond));
}

test "round-trips a nested aggregate carrying a u64 without JSON" {
    const Point = struct { x: i32, y: i32 };
    const BigPoint = struct { p: Point, id: u64 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = BigPoint{ .p = .{ .x = 3, .y = 4 }, .id = (1 << 53) + 7 };
    const encoded = encodeNative(BigPoint, value, arena.allocator());
    try std.testing.expectEqual(NativeTag.record, encoded.tag);

    const decoded = decodeNative(BigPoint, &encoded);
    try std.testing.expectEqual(value.p.x, decoded.p.x);
    try std.testing.expectEqual(value.p.y, decoded.p.y);
    try std.testing.expectEqual(value.id, decoded.id);
}

test "round-trips an optional u64 through option_some/option_none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const present: ?u64 = (1 << 53) + 42;
    const encoded_some = encodeNative(?u64, present, arena.allocator());
    try std.testing.expectEqual(NativeTag.option_some, encoded_some.tag);
    try std.testing.expectEqual(present, decodeNative(?u64, &encoded_some));

    const absent: ?u64 = null;
    const encoded_none = encodeNative(?u64, absent, arena.allocator());
    try std.testing.expectEqual(NativeTag.option_none, encoded_none.tag);
    try std.testing.expectEqual(absent, decodeNative(?u64, &encoded_none));
}
