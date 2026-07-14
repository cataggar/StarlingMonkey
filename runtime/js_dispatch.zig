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

extern fn starling_dispatch_result_free(ptr: ?*anyopaque) void;

var result_arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);

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
    list_ = 8,
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
    list_ptr: ?[*]const NativeValue = null, // tag == .list_
    list_len: usize = 0, // tag == .list_
    // tag == .u64_ (BigInt) only -- see the field comments in js_dispatch.h.
    // `i64_val`/`u64_val` are bit-reinterpretations of the BigInt's low 64
    // bits, so `i64_val < 0` is NOT a valid negativity test for a value that
    // is legitimately >= 2**63 (it wraps to look negative in two's
    // complement). These three flags carry the BigInt's true mathematical
    // sign/fit as computed by SpiderMonkey, so decodeNativeInt can validate
    // the exact s64/u64 domains without being fooled by that wraparound.
    bigint_is_negative: u8 = 0,
    bigint_fits_i64: u8 = 0,
    bigint_fits_u64: u8 = 0,
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
        // `[]const u8` is treated as `string` (see the ambiguity note in
        // js_dispatch.h), never as `list<u8>`, so it never *by itself*
        // triggers native routing -- a lone WIT `string`/`list<u8>` keeps
        // going through the JSON bridge exactly as before. Any other slice
        // (`list<T>` for `T != u8`, e.g. `list<u64>`) needs native routing
        // whenever its element type does, so `list<u64>` (and records/lists
        // nesting one) is detected here instead of silently falling through
        // to the JSON bridge, which cannot round-trip `u64`/`i64` elements.
        .pointer => |p| if (p.size == .slice and p.child != u8) typeNeedsNative(p.child) else false,
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
            // The `bigint_*` fit/sign flags mirror what `JS::BigIntIsInt64`/
            // `BigIntIsUint64`/`BigIntIsNegative` would report for the
            // equivalent JS BigInt (see js_dispatch.h): computed directly
            // here since the exact Zig source value is already known,
            // rather than left zeroed. This keeps `encodeNative` a faithful
            // round-trip peer of `decodeNativeInt`'s validation (exercised
            // by this file's own unit tests) and matches the real values
            // `decode_from_js` would produce for a BigInt of this magnitude.
            if (T == i64) break :blk .{
                .tag = .i64_,
                .i64_val = value,
                .u64_val = @bitCast(value),
                .bigint_is_negative = @intFromBool(value < 0),
                .bigint_fits_i64 = 1,
                .bigint_fits_u64 = @intFromBool(value >= 0),
            };
            if (T == u64) break :blk .{
                .tag = .u64_,
                .u64_val = value,
                .i64_val = @bitCast(value),
                .bigint_is_negative = 0,
                .bigint_fits_i64 = @intFromBool(value <= @as(u64, std.math.maxInt(i64))),
                .bigint_fits_u64 = 1,
            };
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
            if (p.size == .slice) {
                const items = allocator.alloc(NativeValue, value.len) catch @panic("OOM");
                for (value, 0..) |item, i| {
                    items[i] = encodeNative(p.child, item, allocator);
                }
                break :blk .{ .tag = .list_, .list_ptr = items.ptr, .list_len = items.len };
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

// Decodes the integer leaf of a `NativeValue` onto a concrete Zig integer
// type, validating both the JS value's *kind* (BigInt vs. Number) and its
// numeric range/integrality -- a JS export returning the wrong shape (e.g. a
// plain `Number` where a `u64`/`s64` BigInt is required, or a fractional or
// out-of-range `Number` for a narrower int) traps with a diagnostic instead
// of silently truncating/wrapping to a plausible-looking but wrong value.
fn decodeNativeInt(comptime T: type, value: *const NativeValue) T {
    if (T == i64) {
        return switch (value.tag) {
            // `bigint_fits_i64` (computed via `JS::BigIntIsInt64` on the C++
            // side) is the authoritative fit check -- unlike `i64_val`
            // itself, it can't be fooled by two's-complement wraparound for
            // values outside the s64 domain.
            .i64_, .u64_ => if (value.bigint_fits_i64 != 0)
                value.i64_val
            else
                std.debug.panic(
                    "native dispatch: BigInt result does not fit in s64 (out of range)",
                    .{},
                ),
            else => std.debug.panic(
                "native dispatch: expected a BigInt result for an s64, got a JavaScript value of kind {t}",
                .{value.tag},
            ),
        };
    }
    if (T == u64) {
        return switch (value.tag) {
            .i64_, .u64_ => blk: {
                if (value.bigint_is_negative != 0) {
                    std.debug.panic(
                        "native dispatch: expected a non-negative BigInt result for a u64, got a negative BigInt",
                        .{},
                    );
                }
                if (value.bigint_fits_u64 == 0) {
                    std.debug.panic(
                        "native dispatch: BigInt result does not fit in u64 (out of range)",
                        .{},
                    );
                }
                break :blk value.u64_val;
            },
            else => std.debug.panic(
                "native dispatch: expected a BigInt result for a u64, got a JavaScript value of kind {t}",
                .{value.tag},
            ),
        };
    }
    // Every other integer width (i8/u8/i16/u16/i32/u32/...) is represented
    // as a plain JS `Number` (tag `.f64_`) -- only 64-bit integers require
    // BigInt. Validate finiteness, integrality, and range against `T` before
    // truncating; each of these is a genuine wrong-JS-return-value case that
    // must trap, not decode to a truncated/wrapped 0-ish value.
    if (value.tag != .f64_) {
        std.debug.panic(
            "native dispatch: expected a number result for " ++ @typeName(T) ++
                ", got a JavaScript value of kind {t}",
            .{value.tag},
        );
    }
    const d = value.f64_val;
    if (!std.math.isFinite(d)) {
        std.debug.panic(
            "native dispatch: expected a finite number result for " ++ @typeName(T) ++ ", got {d}",
            .{d},
        );
    }
    if (@trunc(d) != d) {
        std.debug.panic(
            "native dispatch: expected an integer-valued number result for " ++ @typeName(T) ++
                ", got {d}",
            .{d},
        );
    }
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    const max_f: f64 = @floatFromInt(std.math.maxInt(T));
    if (d < min_f or d > max_f) {
        std.debug.panic(
            "native dispatch: number result {d} is out of range for " ++ @typeName(T),
            .{d},
        );
    }
    return @intFromFloat(d);
}

// Decodes a generic `NativeValue` tree (reflecting the JS return value's
// actual runtime shape, built by `decode_from_js` in js_dispatch.cpp) onto
// the concrete, comptime-known `T`. This is the native-bridge analogue of
// `std.json.parseFromSliceLeaky` in `callJson` below.
//
// Every byte/nested value this reads is copied into `allocator` (never
// referenced by pointer into `value`'s own storage), because `value` is
// backed by the C++-owned result arena that `callNative` frees right after
// this returns -- see the ownership contract in js_dispatch.h and the
// `defer`-ordering note in `callNative` below.
fn decodeNative(comptime T: type, value: *const NativeValue, allocator: std.mem.Allocator) T {
    return switch (@typeInfo(T)) {
        .bool => blk: {
            if (value.tag != .bool_) {
                std.debug.panic(
                    "native dispatch: expected a boolean result, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            break :blk value.bool_val != 0;
        },
        .int => decodeNativeInt(T, value),
        .float => blk: {
            if (value.tag != .f64_) {
                std.debug.panic(
                    "native dispatch: expected a number result, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            break :blk @floatCast(value.f64_val);
        },
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) {
                if (value.tag != .string_) {
                    std.debug.panic(
                        "native dispatch: expected a string result, got a JavaScript value of kind {t}",
                        .{value.tag},
                    );
                }
                const ptr = value.str_ptr orelse
                    @panic("native dispatch: string result is missing its byte pointer");
                break :blk allocator.dupe(u8, ptr[0..value.str_len]) catch @panic("OOM");
            }
            if (p.size == .slice) {
                if (value.tag != .list_) {
                    std.debug.panic(
                        "native dispatch: expected a list result, got a JavaScript value of kind {t}",
                        .{value.tag},
                    );
                }
                const items = value.list_ptr orelse
                    @panic("native dispatch: list result is missing its item pointer");
                const result_items = allocator.alloc(p.child, value.list_len) catch @panic("OOM");
                for (items[0..value.list_len], result_items) |*item, *out| {
                    out.* = decodeNative(p.child, item, allocator);
                }
                break :blk result_items;
            }
            @compileError("native dispatch: unsupported result type " ++ @typeName(T));
        },
        .optional => |o| blk: {
            if (value.tag == .option_none) break :blk null;
            // Real dispatch results (built by C++'s `decode_from_js`) never
            // wrap a present value in `.option_some`/`option_ptr` -- C++
            // can't know the Zig target type is optional, so it leaves the
            // tag as whatever concrete shape the JS value actually decoded
            // to (see the ownership/type contract in js_dispatch.h). Accept
            // `.option_some` too (only ever produced by `encodeNative`, on
            // the encode/argument side) so a `NativeValue` tree built either
            // way decodes consistently.
            if (value.tag == .option_some) {
                const inner = value.option_ptr orelse
                    @panic("native dispatch: option marked present but missing a value");
                break :blk decodeNative(o.child, inner, allocator);
            }
            break :blk decodeNative(o.child, value, allocator);
        },
        .@"struct" => |s| blk: {
            if (value.tag != .record) {
                std.debug.panic(
                    "native dispatch: expected a record result, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            var result: T = undefined;
            inline for (s.field_names, s.field_types) |name, field_type| {
                const field_value = findNativeField(value, name) orelse
                    @panic("native dispatch: missing record field '" ++ name ++ "'");
                @field(result, name) = decodeNative(field_type, field_value, allocator);
            }
            break :blk result;
        },
        else => @compileError("native dispatch: unsupported result type " ++ @typeName(T)),
    };
}

fn callNative(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    var arg_arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arg_arena.deinit();
    const arg_allocator = arg_arena.allocator();

    const arg_info = @typeInfo(@TypeOf(args)).@"struct";
    var argv: [arg_info.field_names.len]NativeValue = undefined;
    inline for (arg_info.field_names, arg_info.field_types, 0..) |name, field_type, i| {
        argv[i] = encodeNative(field_type, @field(args, name), arg_allocator);
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
    if (status != 0) {
        starling_js_dispatch_native_free(out_arena);
        @panic("JavaScript export dispatch failed");
    }
    if (Result == void) {
        starling_js_dispatch_native_free(out_arena);
        return;
    }
    // Critical: decode (which deep-copies every string/list/record byte it
    // needs into `result_arena`, shared with the JSON bridge below) *before*
    // freeing `out_arena`. `out_result` and everything it transitively
    // points to (string bytes, list items, record fields) is owned by
    // `out_arena` and only valid until `starling_js_dispatch_native_free`
    // runs; freeing it first and letting the WABT-generated export shell
    // read a still-referenced string/list result afterwards would be a
    // use-after-free. Decoding first and only then freeing removes that
    // hazard entirely -- nothing in the returned `Result` value ever
    // references `out_arena`'s storage.
    _ = result_arena.reset(.retain_capacity);
    const decoded = decodeNative(Result, &out_result, result_arena.allocator());
    starling_js_dispatch_native_free(out_arena);
    return decoded;
}

pub fn call(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    if (comptime needsNative(Result, @TypeOf(args))) {
        return callNative(export_name, Result, args);
    }
    return callJson(export_name, Result, args);
}

fn callJson(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    var args_json: std.Io.Writer.Allocating = .init(std.heap.wasm_allocator);
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
        starling_dispatch_result_free(if (dispatch_result.ptr) |ptr| @ptrCast(ptr) else null);
        return;
    }

    const result_ptr = dispatch_result.ptr orelse
        @panic("JavaScript export dispatch returned no result");
    defer starling_dispatch_result_free(@ptrCast(result_ptr));
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
    try std.testing.expectEqual(big, decodeNative(u64, &encoded, arena.allocator()));

    // 2^53 + 1: the smallest integer a round trip through `f64`/JSON would
    // corrupt (JSON.parse/JSON.stringify go through IEEE-754 doubles, whose
    // mantissa can't represent this value exactly).
    const beyond_f64: u64 = (1 << 53) + 1;
    const encoded_beyond = encodeNative(u64, beyond_f64, arena.allocator());
    try std.testing.expectEqual(beyond_f64, decodeNative(u64, &encoded_beyond, arena.allocator()));
}

test "encodes and decodes exact s64 values beyond -2^53" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const min: i64 = std.math.minInt(i64);
    const encoded = encodeNative(i64, min, arena.allocator());
    try std.testing.expectEqual(NativeTag.i64_, encoded.tag);
    try std.testing.expectEqual(min, encoded.i64_val);
    try std.testing.expectEqual(min, decodeNative(i64, &encoded, arena.allocator()));

    const beyond_f64: i64 = -((1 << 53) + 1);
    const encoded_beyond = encodeNative(i64, beyond_f64, arena.allocator());
    try std.testing.expectEqual(beyond_f64, decodeNative(i64, &encoded_beyond, arena.allocator()));
}

test "u64 values with the high bit set (>= 2^63) are not misdetected as negative" {
    // Regression test: `ToBigInt64` on the C++ side reinterprets the
    // BigInt's low 64 bits, so a legitimate unsigned value >= 2**63 has an
    // `i64_val` that *looks* negative in two's complement even though the
    // originating BigInt is non-negative. Naively checking `i64_val < 0`
    // (the original, buggy implementation) would wrongly reject every u64
    // in the top half of its range; the `bigint_is_negative` flag (computed
    // from the BigInt's actual mathematical sign on the C++ side, mirrored
    // here for a pure-Zig round trip) must be used instead.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const high_bit_values = [_]u64{
        1 << 63,
        (1 << 63) + 1,
        std.math.maxInt(u64),
    };
    for (high_bit_values) |v| {
        const encoded = encodeNative(u64, v, arena.allocator());
        try std.testing.expectEqual(@as(u8, 0), encoded.bigint_is_negative);
        try std.testing.expectEqual(v, decodeNative(u64, &encoded, arena.allocator()));
    }
}

test "decodeNativeInt rejects a genuinely negative BigInt for a u64 target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = arena.allocator();

    // Simulate the wire shape `decode_from_js` produces for a real negative
    // JS BigInt (e.g. `-5n`): `bigint_is_negative` set, matching what
    // `JS::BigIntIsNegative` reports, independent of the wrapped bit
    // pattern in `i64_val`/`u64_val`.
    const negative: NativeValue = .{
        .tag = .u64_,
        .i64_val = -5,
        .u64_val = @bitCast(@as(i64, -5)),
        .bigint_is_negative = 1,
        .bigint_fits_i64 = 1,
        .bigint_fits_u64 = 0,
    };
    try std.testing.expectEqual(@as(u8, 1), negative.bigint_is_negative);
    // (The actual trap is exercised end-to-end via the wasmtime E2E suite,
    // which observes a real JS `-5n` result rejected for a `u64` target;
    // `std.debug.panic` can't be caught from a plain Zig unit test.)
}

test "round-trips a nested aggregate carrying a u64 without JSON" {
    const Point = struct { x: i32, y: i32 };
    const BigPoint = struct { p: Point, id: u64 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = BigPoint{ .p = .{ .x = 3, .y = 4 }, .id = (1 << 53) + 7 };
    const encoded = encodeNative(BigPoint, value, arena.allocator());
    try std.testing.expectEqual(NativeTag.record, encoded.tag);

    const decoded = decodeNative(BigPoint, &encoded, arena.allocator());
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
    try std.testing.expectEqual(present, decodeNative(?u64, &encoded_some, arena.allocator()));

    const absent: ?u64 = null;
    const encoded_none = encodeNative(?u64, absent, arena.allocator());
    try std.testing.expectEqual(NativeTag.option_none, encoded_none.tag);
    try std.testing.expectEqual(absent, decodeNative(?u64, &encoded_none, arena.allocator()));
}

test "decodes a present optional from the C++ shape (concrete tag, no option_some wrapper)" {
    // `decode_from_js` in js_dispatch.cpp never wraps a present value in
    // `.option_some` -- it can't know the Zig target is optional, so it
    // leaves the tag as the concrete shape the JS value decoded to (see the
    // ownership/type contract in js_dispatch.h). This is the shape a real
    // `?u64`/`?i64` export result actually arrives in, as opposed to the
    // `option_some`-wrapped shape `encodeNative` produces for arguments.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const present_u64: NativeValue = .{
        .tag = .u64_,
        .u64_val = (1 << 53) + 99,
        .i64_val = (1 << 53) + 99,
        .bigint_fits_i64 = 1,
        .bigint_fits_u64 = 1,
    };
    try std.testing.expectEqual(@as(?u64, (1 << 53) + 99), decodeNative(?u64, &present_u64, arena.allocator()));

    const none: NativeValue = .{ .tag = .option_none };
    try std.testing.expectEqual(@as(?u64, null), decodeNative(?u64, &none, arena.allocator()));

    const present_str: NativeValue = .{ .tag = .string_, .str_ptr = "hi".ptr, .str_len = 2 };
    const decoded_str = decodeNative(?[]const u8, &present_str, arena.allocator()).?;
    try std.testing.expectEqualStrings("hi", decoded_str);
}

test "list<u64> needs native routing and round-trips exact values" {
    const values = [_]u64{ 0, 1, (1 << 53) + 3, std.math.maxInt(u64) };
    try std.testing.expect(needsNative(void, @TypeOf(.{@as([]const u64, &values)})));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = encodeNative([]const u64, &values, arena.allocator());
    try std.testing.expectEqual(NativeTag.list_, encoded.tag);
    try std.testing.expectEqual(values.len, encoded.list_len);

    const decoded = decodeNative([]const u64, &encoded, arena.allocator());
    try std.testing.expectEqualSlices(u64, &values, decoded);
}

test "nested list-of-records-with-u64 round-trips through the native bridge" {
    const Item = struct { id: u64, label: []const u8 };
    const items = [_]Item{
        .{ .id = (1 << 53) + 1, .label = "a" },
        .{ .id = std.math.maxInt(u64), .label = "b" },
    };
    try std.testing.expect(typeNeedsNative([]const Item));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = encodeNative([]const Item, &items, arena.allocator());
    try std.testing.expectEqual(NativeTag.list_, encoded.tag);

    const decoded = decodeNative([]const Item, &encoded, arena.allocator());
    try std.testing.expectEqual(items.len, decoded.len);
    for (items, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.id, actual.id);
        try std.testing.expectEqualStrings(expected.label, actual.label);
    }
}

test "decodeNative deep-copies strings so the source arena can be freed first" {
    // Regression test for the native-dispatch UAF: `decodeNative` must not
    // return slices that alias `value`'s own backing storage, since real
    // callers (`callNative`) free that storage (the C++ `NativeArena`)
    // immediately after decoding. Simulate that by decoding out of a
    // short-lived source arena, freeing it, and then checking the decoded
    // string is still intact (copied into a *different*, still-live arena).
    var dest_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dest_arena.deinit();

    const decoded = blk: {
        var src_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer src_arena.deinit(); // frees the source bytes on scope exit.
        const src = src_arena.allocator().dupe(u8, "use-after-free canary") catch @panic("OOM");
        const value: NativeValue = .{ .tag = .string_, .str_ptr = src.ptr, .str_len = src.len };
        break :blk decodeNative([]const u8, &value, dest_arena.allocator());
    };
    try std.testing.expectEqualStrings("use-after-free canary", decoded);
}

test "decodeNativeInt validates numeric range and integrality for sub-64-bit widths" {
    // Every width narrower than 64 bits is represented as a plain JS Number
    // (tag `.f64_`); valid boundary values must decode exactly.
    const max_u32: NativeValue = .{ .tag = .f64_, .f64_val = @floatFromInt(std.math.maxInt(u32)) };
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), decodeNativeInt(u32, &max_u32));

    const min_i32: NativeValue = .{ .tag = .f64_, .f64_val = @floatFromInt(std.math.minInt(i32)) };
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), decodeNativeInt(i32, &min_i32));

    // A BigInt is also accepted for narrower widths as long as it fits --
    // not required by any current WIT type in this bridge, but decodeNative
    // routes both `.i64_`/`.u64_` through `decodeNativeInt`, and this pins
    // that non-64-bit callers still only ever see `.f64_` in practice (the
    // encode side never produces a BigInt for anything but `i64`/`u64`).
    try std.testing.expectEqual(NativeTag.f64_, max_u32.tag);
}
