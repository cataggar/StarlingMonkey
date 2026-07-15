const std = @import("std");
const builtin = @import("builtin");
const wit_types = @import("wit_types");

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

pub const NativeTag = enum(u32) {
    bool_ = 0,
    i64_ = 1,
    u64_ = 2,
    f64_ = 3,
    string_ = 4,
    option_none = 5,
    option_some = 6,
    record = 7,
    list_ = 8,
    // WIT `list<u8>` (`wit_types.ByteList`): a genuine JS `Uint8Array`, never
    // a plain Array (matches ComponentizeJS 0.21.0). Reuses `str_ptr`/
    // `str_len` (see js_dispatch.h).
    bytes = 9,
    // A WIT function with no result, encoding to JavaScript `undefined` --
    // never `false` (`.bool_`) or `null` (`.option_none`, which is
    // option-`none`'s tag, not void's). Encode-direction only: see the
    // matching `STARLING_JS_UNDEFINED` doc comment in js_dispatch.h for why
    // `decodeNative` deliberately has no corresponding "this means the
    // result was void" special case (real JS `undefined`/`null` returned
    // from an *export* still decodes through `.option_none` as before).
    // Keep the numeric value in sync with `STARLING_JS_UNDEFINED` there --
    // deliberately `10`, not `9`: `.bytes` (above) already claimed `9`.
    undefined_ = 10,
    resource = 11,
};

pub const ResourceOwnership = enum(u8) {
    own = 0,
    borrow = 1,
};

pub const ResourceToken = extern struct {
    type_id: u32,
    handle: i32,
    generation: u64,
    ownership: ResourceOwnership,
    borrow_epoch: u64,
};

// Mirrors `struct StarlingJsValue` in js_dispatch.h field-for-field. Both
// sides live in the same wasm module, so this is exchanged by pointer, not
// serialized.
pub const NativeValue = extern struct {
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
    resource_provider_ptr: ?[*]const u8 = null,
    resource_provider_len: usize = 0,
    resource_name_ptr: ?[*]const u8 = null,
    resource_name_len: usize = 0,
    resource_type_id: u32 = 0,
    resource_handle: i32 = 0,
    resource_ownership: ResourceOwnership = .borrow,
    resource_generation: u64 = 0,
    resource_borrow_epoch: u64 = 0,
};

pub fn encodeResource(
    descriptor: wit_types.ResourceDescriptor,
    handle: i32,
    ownership: ResourceOwnership,
) NativeValue {
    return .{
        .tag = .resource,
        .resource_provider_ptr = descriptor.provider.ptr,
        .resource_provider_len = descriptor.provider.len,
        .resource_name_ptr = descriptor.name.ptr,
        .resource_name_len = descriptor.name.len,
        .resource_handle = handle,
        .resource_ownership = ownership,
    };
}

extern fn starling_js_resource_validate(
    type_id: u32,
    handle: i32,
    generation: u64,
    ownership: ResourceOwnership,
    borrow_epoch: u64,
) u32;

extern fn starling_js_resource_transfer_many(tokens: [*]const ResourceToken, len: usize) u32;

pub fn decodeResource(
    value: *const NativeValue,
    descriptor: wit_types.ResourceDescriptor,
    ownership: ResourceOwnership,
) i32 {
    if (value.tag != .resource or value.resource_ownership != ownership) {
        @panic("native dispatch: resource identity or ownership mismatch");
    }
    const provider_ptr = value.resource_provider_ptr orelse
        @panic("native dispatch: resource provider is missing");
    const name_ptr = value.resource_name_ptr orelse
        @panic("native dispatch: resource name is missing");
    if (!std.mem.eql(u8, provider_ptr[0..value.resource_provider_len], descriptor.provider) or
        !std.mem.eql(u8, name_ptr[0..value.resource_name_len], descriptor.name))
    {
        @panic("native dispatch: resource identity or ownership mismatch");
    }
    if (!builtin.is_test) {
        if (value.resource_type_id == 0 or value.resource_generation == 0) {
            @panic("native dispatch: resource registry token is missing");
        }
        const status = starling_js_resource_validate(
            value.resource_type_id,
            value.resource_handle,
            value.resource_generation,
            value.resource_ownership,
            value.resource_borrow_epoch,
        );
        if (status != 0) {
            @panic("native dispatch: stale, moved, dropped, or expired resource");
        }
    }
    return value.resource_handle;
}

// Mirrors `struct StarlingJsField` in js_dispatch.h. `value` is a pointer
// (not embedded by value) to match the C++ side, which needs it that way to
// keep `StarlingJsValue`/`StarlingJsField` mutually referencing without a
// forward-declaration ordering problem.
pub const NativeField = extern struct {
    name_ptr: ?[*]const u8 = null,
    name_len: usize = 0,
    value: ?*const NativeValue = null,
};

extern fn starling_js_dispatch_native(
    export_name_ptr: [*]const u8,
    export_name_len: usize,
    args_ptr: [*]const NativeValue,
    args_len: usize,
    result_is_wit_result: u8,
    out_result: *NativeValue,
    out_arena: *?*anyopaque,
) u32;

extern fn starling_js_dispatch_native_free(arena: ?*anyopaque) u32;

// ---------------------------------------------------------------------------
// Naming-convention helpers.
//
// The WABT bindgen's `snake()` helper (component_bindgen.zig) turns every WIT
// kebab-case identifier into a Zig field/tag name by replacing `-` with `_`
// (WIT identifiers never contain `_`, so this is exactly reversible).
// ComponentizeJS 0.21.0's JS-visible naming conventions were determined
// empirically against the pinned reference (0.21.0,
// 12c2b4a25033f65047f8ec5c5fb9e3013bfc4950) through the same Wasmtime 42
// differential host used by tests/compat, not guessed:
//   * record fields and flags labels become JS camelCase *property names*
//     (e.g. WIT `first-value` / Zig `first_value` -> JS `firstValue`).
//   * enum case labels and variant/result case tags stay their *original
//     kebab-case spelling*, carried as plain string *values* (not
//     identifiers), e.g. WIT `north-east` -> the JS string `"north-east"`
//     (not camelCased -- string content isn't an identifier).
//   * a kebab-case WIT function name is looked up as a camelCase JS export
//     identifier (see `kebab_to_camel_case` in js_dispatch.cpp).

fn CamelCase(comptime snake: []const u8) []const u8 {
    return comptime blk: {
        var buf: [snake.len]u8 = undefined;
        var len: usize = 0;
        var upper_next = false;
        for (snake) |c| {
            if (c == '_') {
                upper_next = true;
                continue;
            }
            buf[len] = if (upper_next) std.ascii.toUpper(c) else c;
            upper_next = false;
            len += 1;
        }
        const final = buf[0..len].*;
        break :blk &final;
    };
}

fn KebabCase(comptime snake: []const u8) []const u8 {
    return comptime blk: {
        var buf: [snake.len]u8 = snake[0..snake.len].*;
        for (&buf) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const final = buf;
        break :blk &final;
    };
}

// Converts a runtime (JS-sourced) kebab-case string back to the Zig
// snake_case spelling used by `@tagName`/`std.meta.stringToEnum`, into
// `buf`. Returns `null` if `s` doesn't fit `buf` -- which, for any string
// that could possibly match a real (bounded-length, comptime-known) case
// name, means it can't match and the caller should trap.
fn kebabToSnakeBuf(buf: []u8, s: []const u8) ?[]u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return buf[0..s.len];
}

// A WIT `result<T, E>` (`wit_types.Result(T, E)`) is, at the Zig level,
// indistinguishable from an ordinary two-case `variant` also named `ok`/
// `err` -- both are `union(enum) { ok: T, err: E }`. This structural check
// is what `callNative` uses to decide whether the export's own top-level
// return type gets ComponentizeJS's "return means Ok, throw means Err"
// calling convention (see js_dispatch.h); any *nested* `result<T, E>` (e.g.
// inside a record/list/option) is unaffected and keeps decoding via the
// ordinary `{tag, val}` object shape below.
fn isWitResultType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => |u| u.field_names.len == 2 and
            std.mem.eql(u8, u.field_names[0], "ok") and
            std.mem.eql(u8, u.field_names[1], "err"),
        else => false,
    };
}

// Reversal-direction counterpart: `--js-imports`-generated dispatch code
// (see component_bindgen.zig's `emitJsImportBridge`) builds its own result
// `NativeValue` tree in a heap-allocated `ArenaAllocator` per call (the
// import direction has no C++-owned `NativeArena` to free -- the tree is
// entirely Zig-side, going *into* JS instead of coming *out of* it), and
// frees it through this same public name so both directions share one
// symbol the C++ host glue can call generically.
pub fn freeNativeArena(arena: ?*anyopaque) void {
    if (arena) |ptr| {
        const a: *std.heap.ArenaAllocator = @ptrCast(@alignCast(ptr));
        a.deinit();
        std.heap.wasm_allocator.destroy(a);
    }
}

// Recursively checks whether `T`'s type graph (struct fields, optional
// children) contains an exact `i64`/`u64` anywhere -- the only types JSON
// cannot carry losslessly -- or any of the shapes JSON can't represent in
// ComponentizeJS's exact JS shape at all (`char`/`list<u8>`'s nominal
// wrapper types, `enum`, `flags` (a packed struct, which JSON would instead
// serialize field-for-field including the padding field), or `variant`/
// `result` (a tagged union, which `std.json` serializes as a single-key
// `{"active_field": value}` object rather than ComponentizeJS's `{tag,
// val}`)). Used at comptime to decide, per export, whether `call` should
// route through the native bridge or the JSON one; this is the "bounded
// fallback" that keeps every JSON-representable export working exactly as
// before.
fn typeNeedsNative(comptime T: type) bool {
    if (T == i64 or T == u64) return true;
    if (T == wit_types.Char or T == wit_types.ByteList) return true;
    if (wit_types.resourceInfo(T) != null) return true;
    return switch (@typeInfo(T)) {
        // JSON cannot preserve JavaScript `undefined`, nor can it express
        // the tagged object needed for option<option<T>>. Route every
        // option-containing signature through the native bridge instead of
        // introducing a JSON sentinel that would conflate canonical states.
        .optional => true,
        .@"enum", .@"union" => true,
        .@"struct" => |s| comptime blk: {
            // A `flags` type: a packed struct backing integer. Always needs
            // native routing (JSON would otherwise leak the `_padding` field
            // and not camelCase the label names).
            if (s.layout == .@"packed") break :blk true;
            // A `tuple<...>` (`wit_types.Tuple`, a real Zig tuple struct):
            // `std.json` happens to already round-trip this correctly as a
            // JSON array, but it's routed through native unconditionally
            // anyway for a single consistent code path across every new
            // value shape (no existing fixture depends on tuple-via-JSON).
            if (s.is_tuple) break :blk true;
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
    if (typeNeedsNative(Result)) return true;
    // `Args` here is the compiler-synthesized anonymous tuple struct built
    // from `callNative`'s `args: anytype` parameter pack, not a genuine WIT
    // `tuple<...>` value -- both are `is_tuple == true` structurally, so
    // `typeNeedsNative` can't be called on `Args` itself (its "a WIT tuple
    // always needs native" rule would then force every export through the
    // native bridge, regardless of whether any of its arguments actually
    // need it). Check each argument's own type instead.
    const info = @typeInfo(Args).@"struct";
    inline for (info.field_types) |field_type| {
        if (typeNeedsNative(field_type)) return true;
    }
    return false;
}

// Builds a `NativeValue` tree for one Zig argument value. Nested allocations
// (record field arrays, boxed option payloads) come from `allocator`, which
// the caller (`callNative`) backs with a short-lived arena freed after the
// dispatch call returns; string payloads are referenced directly (no copy)
// since the source value already outlives the call.
// `pub`: the WABT `--js-imports` bindgen's generated reverse canonical-ABI
// import wrapper (a separate Zig file compiled into the same module; see
// component_bindgen.zig's `emitJsImportBridge`) calls this directly to
// encode an import call's *result* on the way back into the host, reusing
// the exact same tag vocabulary/encoding rules as the export-argument
// direction below.
pub fn encodeNative(comptime T: type, value: T, allocator: std.mem.Allocator) NativeValue {
    // `wit_types.Char`/`wit_types.ByteList` are plain single-field structs
    // (see wit_types.zig), so they'd otherwise fall into the generic
    // `.@"struct"` record arm below and encode as `{"codepoint": N}` /
    // `{"bytes": [...]}` -- checked by type identity first to instead
    // produce the exact JS shapes ComponentizeJS uses (a one-codepoint
    // string, a `Uint8Array`).
    if (T == wit_types.Char) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(value.codepoint), &buf) catch
            @panic("native dispatch: char argument is not a valid Unicode scalar value");
        const bytes = allocator.dupe(u8, buf[0..n]) catch @panic("OOM");
        return .{ .tag = .string_, .str_ptr = bytes.ptr, .str_len = bytes.len };
    }
    if (T == wit_types.ByteList) {
        return .{ .tag = .bytes, .str_ptr = value.bytes.ptr, .str_len = value.bytes.len };
    }
    if (comptime wit_types.resourceInfo(T)) |info| {
        const ownership: ResourceOwnership = switch (info.ownership) {
            .own => .own,
            .borrow => .borrow,
        };
        return encodeResource(info.descriptor, value.handle, ownership);
    }
    return switch (@typeInfo(T)) {
        .void => .{ .tag = .undefined_ },
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
            // ComponentizeJS keeps option<option<T>>'s three canonical
            // states distinct with a tagged object. A direct option<T>
            // remains unboxed: none is `undefined`, some is its value.
            // This construction must happen before the generic C++ encoder
            // sees the tree, because only this comptime-known type has the
            // nesting context needed to select the JS representation.
            if (@typeInfo(o.child) == .optional) {
                const tag_name: []const u8 = if (value == null) "none" else "some";
                const tag_boxed = allocator.create(NativeValue) catch @panic("OOM");
                tag_boxed.* = .{ .tag = .string_, .str_ptr = tag_name.ptr, .str_len = tag_name.len };
                const fields = allocator.alloc(NativeField, if (value == null) 1 else 2) catch @panic("OOM");
                fields[0] = .{ .name_ptr = "tag".ptr, .name_len = "tag".len, .value = tag_boxed };
                if (value) |present| {
                    const val_boxed = allocator.create(NativeValue) catch @panic("OOM");
                    val_boxed.* = encodeNative(o.child, present, allocator);
                    fields[1] = .{ .name_ptr = "val".ptr, .name_len = "val".len, .value = val_boxed };
                }
                break :blk .{ .tag = .record, .fields_ptr = fields.ptr, .fields_len = fields.len };
            }
            if (value) |present| {
                const boxed = allocator.create(NativeValue) catch @panic("OOM");
                boxed.* = encodeNative(o.child, present, allocator);
                break :blk .{ .tag = .option_some, .option_ptr = boxed };
            }
            break :blk .{ .tag = .option_none };
        },
        // A WIT `enum`: a bare tag, JS-visible as its original kebab-case
        // spelling (a plain string *value*, not an identifier -- unlike
        // record fields/flags labels, so no camelCasing here; see the
        // naming-convention note above `CamelCase`/`KebabCase`).
        .@"enum" => |e| blk: {
            const kebab_names = comptime names: {
                var names: [e.field_names.len][]const u8 = undefined;
                for (e.field_names, 0..) |name, i| names[i] = KebabCase(name);
                const final = names;
                break :names &final;
            };
            const name = kebab_names[@intFromEnum(value)];
            break :blk .{ .tag = .string_, .str_ptr = name.ptr, .str_len = name.len };
        },
        // A WIT `variant`/`result` (`wit_types.Result(T, E)` included --
        // ComponentizeJS's return-position throw-sugar is an export-level
        // *calling convention*, not a different argument shape: as an
        // argument, `result<T, E>` is JS-visible as the same `{tag, val}`
        // object every other variant/result uses, confirmed empirically
        // against the pinned reference). `val` is omitted entirely for a
        // void-payload case, matching the observed shape exactly (not
        // present-with-`null`/`undefined`).
        //
        // `active`'s ordinal (`@intFromEnum`, not its runtime `@tagName`) is
        // what selects the kebab-case name and payload field at runtime --
        // `KebabCase`/`@field` need a *comptime-known* field name, and a
        // union's actual active case is only known at runtime, so this
        // (like the `enum` arm above) precomputes a name table indexed by
        // ordinal at comptime instead of trying to feed a runtime tag name
        // through a comptime-parameter helper.
        .@"union" => |u| blk: {
            const active = std.meta.activeTag(value);
            const kebab_names = comptime names: {
                var names: [u.field_names.len][]const u8 = undefined;
                for (u.field_names, 0..) |name, i| names[i] = KebabCase(name);
                const final = names;
                break :names &final;
            };
            const tag_name = kebab_names[@intFromEnum(active)];
            const tag_bytes = allocator.dupe(u8, tag_name) catch @panic("OOM");
            const tag_boxed = allocator.create(NativeValue) catch @panic("OOM");
            tag_boxed.* = .{ .tag = .string_, .str_ptr = tag_bytes.ptr, .str_len = tag_bytes.len };
            const tag_field_name: []const u8 = "tag";
            const val_field_name: []const u8 = "val";

            var val_boxed: ?*NativeValue = null;
            inline for (u.field_names, u.field_types, 0..) |name, field_type, i| {
                if (field_type != void and @intFromEnum(active) == i) {
                    const boxed = allocator.create(NativeValue) catch @panic("OOM");
                    boxed.* = encodeNative(field_type, @field(value, name), allocator);
                    val_boxed = boxed;
                }
            }

            const field_count: usize = if (val_boxed != null) 2 else 1;
            const fields = allocator.alloc(NativeField, field_count) catch @panic("OOM");
            fields[0] = .{ .name_ptr = tag_field_name.ptr, .name_len = tag_field_name.len, .value = tag_boxed };
            if (val_boxed) |vb| {
                fields[1] = .{ .name_ptr = val_field_name.ptr, .name_len = val_field_name.len, .value = vb };
            }
            break :blk .{ .tag = .record, .fields_ptr = fields.ptr, .fields_len = fields.len };
        },
        .@"struct" => |s| blk: {
            // A WIT `flags`: a packed struct of `bool` labels plus, unless
            // the label count exactly fills the backing integer, a trailing
            // non-bool `_padding` field (see component_bindgen.zig's
            // `.flags` emission) that must never be treated as a label.
            // ComponentizeJS represents flags as a plain JS object with
            // *every* label present as a `true`/`false` camelCase property
            // (confirmed empirically -- not just the "set" ones).
            if (s.layout == .@"packed") {
                var field_count: usize = 0;
                inline for (s.field_types) |field_type| {
                    if (field_type == bool) field_count += 1;
                }
                const fields = allocator.alloc(NativeField, field_count) catch @panic("OOM");
                var i: usize = 0;
                inline for (s.field_names, s.field_types) |name, field_type| {
                    if (field_type == bool) {
                        const camel = CamelCase(name);
                        const boxed = allocator.create(NativeValue) catch @panic("OOM");
                        boxed.* = .{ .tag = .bool_, .bool_val = @intFromBool(@field(value, name)) };
                        fields[i] = .{ .name_ptr = camel.ptr, .name_len = camel.len, .value = boxed };
                        i += 1;
                    }
                }
                break :blk .{ .tag = .record, .fields_ptr = fields.ptr, .fields_len = fields.len };
            }
            // A WIT `tuple<...>` (`wit_types.Tuple(...)`, a real Zig tuple
            // struct): JS-visible as a plain positional Array, not a
            // `{"0": ..., "1": ...}` object.
            if (s.is_tuple) {
                const items = allocator.alloc(NativeValue, s.field_names.len) catch @panic("OOM");
                inline for (s.field_names, s.field_types, 0..) |name, field_type, i| {
                    items[i] = encodeNative(field_type, @field(value, name), allocator);
                }
                break :blk .{ .tag = .list_, .list_ptr = items.ptr, .list_len = items.len };
            }
            // A plain WIT `record`: field names are camelCased for the JS
            // property key (matches ComponentizeJS for multi-word field
            // names; a no-op for the already-single-word names every
            // existing fixture uses).
            const fields = allocator.alloc(NativeField, s.field_names.len) catch @panic("OOM");
            inline for (s.field_names, s.field_types, 0..) |name, field_type, i| {
                const camel = CamelCase(name);
                const boxed = allocator.create(NativeValue) catch @panic("OOM");
                boxed.* = encodeNative(field_type, @field(value, name), allocator);
                fields[i] = .{ .name_ptr = camel.ptr, .name_len = camel.len, .value = boxed };
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
// type, validating the JS value's *kind* (BigInt vs. Number) but -- for a
// value of the correct kind -- *wrapping* an out-of-range/negative/
// fractional/non-finite result modulo 2**bitSizeOf(T), exactly like the
// real ComponentizeJS/Wasmtime canonical-ABI JS embedding's own
// `ToInt32`/`ToUint32`-family (narrower widths) and `ToBigInt64`/
// `ToBigUint64` (64-bit) abstract operations do when lowering a JS export's
// return value -- neither of which throws/traps on magnitude alone. This
// was re-verified directly against the pinned ComponentizeJS 0.21.0
// reference (not assumed from the spec): e.g. a JS export returning
// `-1` for a `u32` result lowers to `4294967295`, `300` for a `u8` result
// lowers to `44` (`300 mod 256`), and `values.reduce(.... 0n)` summing a
// `list<u64>` past `u64::MAX` lowers the wrapped low-64-bits result, not a
// trap (see tests/compat/fixtures/integers-64bit's "sum-list-basic" case).
// A *wrong-kind* result (e.g. a plain `Number` where a `u64`/`s64` BigInt is
// required, or vice versa, or any non-numeric JS value) is a different,
// genuine implementation bug and still traps -- that direction has no
// coercion to fall back on (mirroring `ToBigInt`'s own `TypeError` on a
// `Number` argument).
fn decodeNativeInt(comptime T: type, value: *const NativeValue) T {
    if (T == i64) {
        return switch (value.tag) {
            // `i64_val` is always the exact `ToBigInt64`-style modulo-2**64
            // reinterpretation (see js_dispatch.cpp/.h), valid for every
            // BigInt regardless of whether it fits the s64 domain -- no
            // further range check is needed or correct here.
            .i64_, .u64_ => value.i64_val,
            else => std.debug.panic(
                "native dispatch: expected a BigInt result for an s64, got a JavaScript value of kind {t}",
                .{value.tag},
            ),
        };
    }
    if (T == u64) {
        return switch (value.tag) {
            // Likewise `u64_val` is always the exact `ToBigUint64`-style
            // modulo-2**64 reinterpretation, valid (and already
            // non-negative) for every BigInt.
            .i64_, .u64_ => value.u64_val,
            else => std.debug.panic(
                "native dispatch: expected a BigInt result for a u64, got a JavaScript value of kind {t}",
                .{value.tag},
            ),
        };
    }
    // Every other integer width (i8/u8/i16/u16/i32/u32/...) is represented
    // as a plain JS `Number` (tag `.f64_`) -- only 64-bit integers require
    // BigInt. A wrong *kind* (BigInt, string, bool, object, ...) still traps;
    // a `Number` of the right kind is wrapped, not rejected, matching
    // ECMAScript `ToInt32`/`ToUint32`/`ToInt8`/... semantics: NaN/+-Infinity
    // become 0, the value truncates toward zero, and the result reduces
    // modulo 2**bitSizeOf(T) (two's complement for a signed `T`).
    if (value.tag != .f64_) {
        std.debug.panic(
            "native dispatch: expected a number result for " ++ @typeName(T) ++
                ", got a JavaScript value of kind {t}",
            .{value.tag},
        );
    }
    return wrapFloatToInt(T, value.f64_val);
}

// Implements the ECMAScript `ToInt32`/`ToUint32`-family abstract operation,
// generalized to any integer width `T` up to 32 bits (the only widths that
// reach here -- 64-bit ints are BigInt and handled separately above).
fn wrapFloatToInt(comptime T: type, d: f64) T {
    const bits = @bitSizeOf(T);
    comptime std.debug.assert(bits < 64); // 64-bit widths are BigInt, handled above.
    if (!std.math.isFinite(d)) return 0; // NaN/+-Infinity -> +0, per spec.
    const modulus_pow: u64 = @as(u64, 1) << bits;
    const modulus_f: f64 = @floatFromInt(modulus_pow);
    // `@mod` on floats is floored (result takes the divisor's sign), giving
    // the spec's non-negative "modulo" directly once the fractional part is
    // truncated toward zero first (matching, e.g., a `u8` export returning
    // `3.5` lowering to `3`, not `3.5 mod 256`).
    const wrapped_f = @mod(@trunc(d), modulus_f); // in [0, modulus_f)
    // Safe: `wrapped_f` is in [0, 2**bits) with bits <= 32, well within u64.
    const wrapped_u64: u64 = @intFromFloat(wrapped_f);
    if (@typeInfo(T).int.signedness == .unsigned) {
        return @intCast(wrapped_u64);
    }
    const half: u64 = modulus_pow / 2;
    const signed: i64 = if (wrapped_u64 >= half)
        @as(i64, @intCast(wrapped_u64)) - @as(i64, @intCast(modulus_pow))
    else
        @intCast(wrapped_u64);
    return @intCast(signed);
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
// `pub`: the WABT `--js-imports` bindgen's generated reverse canonical-ABI
// import wrapper calls this directly to decode an import call's *arguments*
// on the way in from the host (mirroring `encodeNative`'s note above),
// reusing the exact same tag vocabulary/decoding rules as the export-result
// direction below.
pub fn decodeNative(comptime T: type, value: *const NativeValue, allocator: std.mem.Allocator) T {
    // See the matching note in `encodeNative`: `wit_types.Char`/
    // `wit_types.ByteList` must be special-cased by type identity before the
    // generic `.@"struct"` arm, or they'd expect a `{"codepoint": ...}` /
    // `{"bytes": ...}` record instead of the actual JS shapes ComponentizeJS
    // produces (a one-codepoint string, a `Uint8Array`).
    if (T == wit_types.Char) {
        if (value.tag != .string_) {
            std.debug.panic(
                "native dispatch: expected a one-character string result for char, got a JavaScript value of kind {t}",
                .{value.tag},
            );
        }
        const ptr = value.str_ptr orelse
            @panic("native dispatch: char result is missing its byte pointer");
        const bytes = ptr[0..value.str_len];
        const len = std.unicode.utf8ByteSequenceLength(if (bytes.len > 0) bytes[0] else 0) catch
            std.debug.panic(
                "native dispatch: char result is not exactly one Unicode scalar value, got {d} bytes",
                .{bytes.len},
            );
        if (len != bytes.len) {
            std.debug.panic(
                "native dispatch: char result is not exactly one Unicode scalar value, got {d} bytes",
                .{bytes.len},
            );
        }
        const codepoint = std.unicode.utf8Decode(bytes) catch
            @panic("native dispatch: char result is not valid UTF-8");
        return .{ .codepoint = codepoint };
    }
    if (T == wit_types.ByteList) {
        if (value.tag == .bytes) {
            const ptr = value.str_ptr orelse
                @panic("native dispatch: list<u8> result is missing its byte pointer");
            return .{ .bytes = allocator.dupe(u8, ptr[0..value.str_len]) catch @panic("OOM") };
        }
        // ComponentizeJS's own `list<u8>` lowering leniently accepts a
        // plain JS Array of small integers, not just a `Uint8Array`
        // (confirmed empirically), so this bridge does too.
        if (value.tag == .list_) {
            const items = value.list_ptr orelse
                @panic("native dispatch: list<u8> result is missing its item pointer");
            const bytes = allocator.alloc(u8, value.list_len) catch @panic("OOM");
            for (items[0..value.list_len], bytes) |*item, *out| {
                out.* = decodeNativeInt(u8, item);
            }
            return .{ .bytes = bytes };
        }
        std.debug.panic(
            "native dispatch: expected a Uint8Array or Array result for list<u8>, got a JavaScript value of kind {t}",
            .{value.tag},
        );
    }
    if (comptime wit_types.resourceInfo(T)) |info| {
        const ownership: ResourceOwnership = switch (info.ownership) {
            .own => .own,
            .borrow => .borrow,
        };
        return .{ .handle = decodeResource(value, info.descriptor, ownership) };
    }
    return switch (@typeInfo(T)) {
        // Only reachable if some future caller passes `void` through here
        // directly (today's call sites -- `callNative`/`callJson` -- both
        // special-case `Result == void` *before* ever calling `decodeNative`,
        // to avoid touching `out_arena` unnecessarily). Kept for symmetry
        // with `encodeNative`'s `.void` arm and so this function has a real
        // typed contract for every WIT result shape, not just the ones
        // exercised by the current two call sites. A real JS export
        // returning `undefined`/`null` decodes (via `decode_from_js` in
        // js_dispatch.cpp) to `.option_none`, never `.undefined_` -- that
        // tag is produced only by `encodeNative` on the reverse
        // (`--js-imports`) path -- so both are accepted here.
        .void => blk: {
            if (value.tag != .option_none and value.tag != .undefined_) {
                std.debug.panic(
                    "native dispatch: expected a void (undefined) result, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            break :blk {};
        },
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
            // Nested options have the same `{tag:"none"|"some", val?}`
            // shape as variants. Decode it only when the concrete target is
            // option<option<T>>; an ordinary record with those field names
            // must remain an ordinary record at every other type position.
            if (@typeInfo(o.child) == .optional) {
                if (value.tag != .record) {
                    std.debug.panic(
                        "native dispatch: expected a {{tag, val}} object result for option<option<T>>, got a JavaScript value of kind {t}",
                        .{value.tag},
                    );
                }
                const tag_value = findNativeField(value, "tag") orelse
                    @panic("native dispatch: nested option result is missing its 'tag' field");
                if (tag_value.tag != .string_) {
                    std.debug.panic(
                        "native dispatch: nested option 'tag' must be a string, got a JavaScript value of kind {t}",
                        .{tag_value.tag},
                    );
                }
                const tag_ptr = tag_value.str_ptr orelse
                    @panic("native dispatch: nested option 'tag' is missing its byte pointer");
                const tag = tag_ptr[0..tag_value.str_len];
                if (std.mem.eql(u8, tag, "none")) break :blk null;
                if (!std.mem.eql(u8, tag, "some")) {
                    std.debug.panic("native dispatch: invalid nested option tag '{s}'", .{tag});
                }
                const val_value = findNativeField(value, "val") orelse
                    @panic("native dispatch: nested option 'some' result is missing its 'val' field");
                break :blk decodeNative(o.child, val_value, allocator);
            }
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
        // A WIT `enum`: the JS side is a plain string of the case's
        // original kebab-case spelling (see the naming-convention note
        // above `CamelCase`/`KebabCase`). An unrecognized string is an
        // invalid discriminant and must trap, not silently decode to
        // whatever `@enumFromInt(0)` happens to be.
        .@"enum" => blk: {
            if (value.tag != .string_) {
                std.debug.panic(
                    "native dispatch: expected a string result for an enum, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            const ptr = value.str_ptr orelse
                @panic("native dispatch: enum result is missing its byte pointer");
            const kebab = ptr[0..value.str_len];
            var snake_buf: [128]u8 = undefined;
            const snake = kebabToSnakeBuf(&snake_buf, kebab) orelse
                std.debug.panic("native dispatch: invalid enum case '{s}'", .{kebab});
            break :blk std.meta.stringToEnum(T, snake) orelse
                std.debug.panic("native dispatch: invalid enum case '{s}'", .{kebab});
        },
        // A WIT `variant`/`result`: the JS side is a `{tag, val}` object
        // (see the naming-convention note above `CamelCase`/`KebabCase`;
        // this is the *nested*-position shape -- an export's own top-level
        // `result<T, E>` return value instead uses the throw-means-err
        // convention special-cased in `callNative`, never reaching this
        // arm for that position). An unmatched `tag` string is an invalid
        // discriminant and must trap.
        .@"union" => |u| blk: {
            if (value.tag != .record) {
                std.debug.panic(
                    "native dispatch: expected a {{tag, val}} object result for a variant/result, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            const tag_value = findNativeField(value, "tag") orelse
                @panic("native dispatch: variant/result result is missing its 'tag' field");
            if (tag_value.tag != .string_) {
                std.debug.panic(
                    "native dispatch: variant/result 'tag' must be a string, got a JavaScript value of kind {t}",
                    .{tag_value.tag},
                );
            }
            const tag_ptr = tag_value.str_ptr orelse
                @panic("native dispatch: variant/result 'tag' is missing its byte pointer");
            const kebab = tag_ptr[0..tag_value.str_len];
            var snake_buf: [128]u8 = undefined;
            const snake = kebabToSnakeBuf(&snake_buf, kebab) orelse
                std.debug.panic("native dispatch: invalid variant/result discriminant '{s}'", .{kebab});

            var result: ?T = null;
            inline for (u.field_names, u.field_types) |name, field_type| {
                if (result == null and std.mem.eql(u8, snake, name)) {
                    if (field_type == void) {
                        result = @unionInit(T, name, {});
                    } else {
                        const val_value = findNativeField(value, "val") orelse
                            @panic("native dispatch: variant/result result is missing its 'val' field");
                        result = @unionInit(T, name, decodeNative(field_type, val_value, allocator));
                    }
                }
            }
            break :blk result orelse
                std.debug.panic("native dispatch: invalid variant/result discriminant '{s}'", .{kebab});
        },
        .@"struct" => |s| blk: {
            // A WIT `flags`: JS-visible as a plain object with every label
            // present as a camelCase boolean property (see `encodeNative`).
            // A missing or non-boolean expected property is a genuine
            // wrong-shape result and must trap.
            if (s.layout == .@"packed") {
                if (value.tag != .record) {
                    std.debug.panic(
                        "native dispatch: expected an object result for flags, got a JavaScript value of kind {t}",
                        .{value.tag},
                    );
                }
                // Field default values aren't guaranteed (the generated
                // `_padding` field has one, but the `bool` label fields
                // don't -- see component_bindgen.zig's `.flags` emission),
                // so every field must be explicitly assigned, including the
                // padding bits (always zeroed; it carries no JS-visible
                // meaning).
                var result: T = undefined;
                inline for (s.field_names, s.field_types) |name, field_type| {
                    if (field_type != bool) {
                        @field(result, name) = 0;
                    }
                }
                inline for (s.field_names, s.field_types) |name, field_type| {
                    if (field_type == bool) {
                        const camel = comptime CamelCase(name);
                        const field_value = findNativeField(value, camel) orelse
                            @panic("native dispatch: missing flags property '" ++ camel ++ "'");
                        if (field_value.tag != .bool_) {
                            std.debug.panic(
                                "native dispatch: flags property '" ++ camel ++
                                    "' must be a boolean, got a JavaScript value of kind {t}",
                                .{field_value.tag},
                            );
                        }
                        @field(result, name) = field_value.bool_val != 0;
                    }
                }
                break :blk result;
            }
            // A WIT `tuple<...>`: JS-visible as a plain positional Array.
            if (s.is_tuple) {
                if (value.tag != .list_) {
                    std.debug.panic(
                        "native dispatch: expected an array result for a tuple, got a JavaScript value of kind {t}",
                        .{value.tag},
                    );
                }
                if (value.list_len != s.field_names.len) {
                    std.debug.panic(
                        "native dispatch: tuple result has {d} elements, expected {d}",
                        .{ value.list_len, s.field_names.len },
                    );
                }
                const items = value.list_ptr orelse
                    @panic("native dispatch: tuple result is missing its item pointer");
                var result: T = undefined;
                inline for (s.field_names, s.field_types, 0..) |name, field_type, i| {
                    @field(result, name) = decodeNative(field_type, &items[i], allocator);
                }
                break :blk result;
            }
            if (value.tag != .record) {
                std.debug.panic(
                    "native dispatch: expected a record result, got a JavaScript value of kind {t}",
                    .{value.tag},
                );
            }
            var result: T = undefined;
            inline for (s.field_names, s.field_types) |name, field_type| {
                const camel = comptime CamelCase(name);
                const field_value = findNativeField(value, camel) orelse
                    @panic("native dispatch: missing record field '" ++ camel ++ "'");
                @field(result, name) = decodeNative(field_type, field_value, allocator);
            }
            break :blk result;
        },
        else => @compileError("native dispatch: unsupported result type " ++ @typeName(T)),
    };
}

fn collectOwnedResources(
    comptime T: type,
    decoded: T,
    value: *const NativeValue,
    resources: *std.ArrayListUnmanaged(ResourceToken),
    allocator: std.mem.Allocator,
) void {
    if (comptime wit_types.resourceInfo(T)) |info| {
        if (info.ownership == .own) {
            resources.append(allocator, .{
                .type_id = value.resource_type_id,
                .handle = value.resource_handle,
                .generation = value.resource_generation,
                .ownership = .own,
                .borrow_epoch = 0,
            }) catch @panic("OOM");
        }
        return;
    }
    if (T == wit_types.Char or T == wit_types.ByteList) return;

    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice or p.child == u8) return;
            const items = value.list_ptr orelse
                @panic("native dispatch: decoded list is missing its item pointer");
            for (decoded, items[0..value.list_len]) |item, *native_item| {
                collectOwnedResources(p.child, item, native_item, resources, allocator);
            }
        },
        .optional => |o| {
            const present = decoded orelse return;
            const inner = if (value.tag == .option_some)
                value.option_ptr orelse
                    @panic("native dispatch: decoded option is missing its value")
            else if (@typeInfo(o.child) == .optional and value.tag == .record)
                findNativeField(value, "val") orelse
                    @panic("native dispatch: decoded nested option is missing its value")
            else
                value;
            collectOwnedResources(o.child, present, inner, resources, allocator);
        },
        .@"union" => |u| {
            const active = std.meta.activeTag(decoded);
            inline for (u.field_names, u.field_types, 0..) |name, field_type, i| {
                if (field_type != void and @intFromEnum(active) == i) {
                    const inner = findNativeField(value, "val") orelse
                        @panic("native dispatch: decoded variant is missing its value");
                    collectOwnedResources(
                        field_type,
                        @field(decoded, name),
                        inner,
                        resources,
                        allocator,
                    );
                }
            }
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return;
            if (s.is_tuple) {
                const items = value.list_ptr orelse
                    @panic("native dispatch: decoded tuple is missing its item pointer");
                inline for (s.field_names, s.field_types, 0..) |name, field_type, i| {
                    collectOwnedResources(
                        field_type,
                        @field(decoded, name),
                        &items[i],
                        resources,
                        allocator,
                    );
                }
                return;
            }
            inline for (s.field_names, s.field_types) |name, field_type| {
                const camel = comptime CamelCase(name);
                const field_value = findNativeField(value, camel) orelse
                    @panic("native dispatch: decoded record is missing field '" ++ camel ++ "'");
                collectOwnedResources(
                    field_type,
                    @field(decoded, name),
                    field_value,
                    resources,
                    allocator,
                );
            }
        },
        else => {},
    }
}

/// Commit every owned resource in a successfully decoded value as one
/// transaction. Validation happens while decoding; this separate phase keeps
/// malformed later fields from consuming earlier owned handles.
pub fn commitNativeResources(
    comptime T: type,
    decoded: T,
    value: *const NativeValue,
    allocator: std.mem.Allocator,
) bool {
    var resources: std.ArrayListUnmanaged(ResourceToken) = .empty;
    defer resources.deinit(allocator);
    collectOwnedResources(T, decoded, value, &resources, allocator);
    if (resources.items.len == 0 or builtin.is_test) return true;
    return starling_js_resource_transfer_many(resources.items.ptr, resources.items.len) == 0;
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

    // See js_dispatch.h: an export whose own return type is directly
    // `result<T, E>` gets ComponentizeJS's "return means Ok, throw means
    // Err" calling convention instead of the ordinary `{tag, val}` object
    // shape -- `isWitResultType` is the exact structural check for that
    // position (never for a *nested* result, e.g. inside a record/list).
    const is_wit_result = comptime isWitResultType(Result);

    var out_result: NativeValue = .{ .tag = .bool_ };
    var out_arena: ?*anyopaque = null;
    const status = starling_js_dispatch_native(
        export_name.ptr,
        export_name.len,
        &argv,
        argv.len,
        @intFromBool(is_wit_result),
        &out_result,
        &out_arena,
    );
    // Status 2 (thrown-value-as-err) is only ever returned when
    // `is_wit_result` is true (see js_dispatch.h); any other non-zero status
    // is a genuine dispatch failure.
    if (status != 0 and !(is_wit_result and status == 2)) {
        _ = starling_js_dispatch_native_free(out_arena);
        @panic("JavaScript export dispatch failed");
    }
    if (Result == void) {
        if (starling_js_dispatch_native_free(out_arena) != 0) {
            @panic("JavaScript resource drop failed");
        }
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
    const decoded: Result = blk: {
        if (is_wit_result) {
            // `out_result` holds the bare Ok/Err payload (no `{tag, val}`
            // wrapper) in this position -- decode it directly as
            // `OkType`/`ErrType` and build the union case ourselves, rather
            // than routing through the generic `.@"union"` arm of
            // `decodeNative` (which expects the nested-position `{tag,
            // val}` shape and would misinterpret this one).
            const union_info = @typeInfo(Result).@"union";
            const OkType = union_info.field_types[0];
            const ErrType = union_info.field_types[1];
            if (status == 2) {
                break :blk if (ErrType == void)
                    Result{ .err = {} }
                else
                    Result{ .err = decodeNative(ErrType, &out_result, result_arena.allocator()) };
            }
            break :blk if (OkType == void)
                Result{ .ok = {} }
            else
                Result{ .ok = decodeNative(OkType, &out_result, result_arena.allocator()) };
        }
        break :blk decodeNative(Result, &out_result, result_arena.allocator());
    };
    if (is_wit_result) {
        const union_info = @typeInfo(Result).@"union";
        const OkType = union_info.field_types[0];
        const ErrType = union_info.field_types[1];
        if (status == 2) {
            if (ErrType != void) {
                if (!commitNativeResources(
                    ErrType,
                    decoded.err,
                    &out_result,
                    result_arena.allocator(),
                )) {
                    _ = starling_js_dispatch_native_free(out_arena);
                    @panic("native dispatch: resource transfer transaction failed");
                }
            }
        } else if (OkType != void) {
            if (!commitNativeResources(
                OkType,
                decoded.ok,
                &out_result,
                result_arena.allocator(),
            )) {
                _ = starling_js_dispatch_native_free(out_arena);
                @panic("native dispatch: resource transfer transaction failed");
            }
        }
    } else {
        if (!commitNativeResources(
            Result,
            decoded,
            &out_result,
            result_arena.allocator(),
        )) {
            _ = starling_js_dispatch_native_free(out_arena);
            @panic("native dispatch: resource transfer transaction failed");
        }
    }
    if (starling_js_dispatch_native_free(out_arena) != 0) {
        @panic("JavaScript resource drop failed");
    }
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

test "needsNative routes plain types to JSON and option-containing signatures to the native bridge" {
    const Plain = struct { x: i32, y: i32 };
    try std.testing.expect(!needsNative(Plain, @TypeOf(.{ @as(i32, 1), @as(i32, 2) })));
    try std.testing.expect(needsNative(?u32, @TypeOf(.{})));
    try std.testing.expect(needsNative(void, @TypeOf(.{@as(?u32, null)})));
    try std.testing.expect(needsNative(void, @TypeOf(.{@as(u64, 1)})));
    try std.testing.expect(needsNative(i64, @TypeOf(.{})));

    // A u64 nested two levels deep (inside a record inside the args tuple)
    // must still be detected, since that's exactly the `big-point` shape
    // used by the end-to-end test fixture.
    const BigPoint = struct { p: Plain, id: u64 };
    try std.testing.expect(needsNative(BigPoint, @TypeOf(.{})));
    try std.testing.expect(needsNative(void, @TypeOf(.{BigPoint{ .p = .{ .x = 0, .y = 0 }, .id = 0 }})));
}

test "resource metadata preserves provider, name, handle, and ownership" {
    const First = struct {
        handle: i32,
        pub const __wit_resource = wit_types.ResourceDescriptor{
            .provider = "test:resources/first@1.0.0",
            .name = "item",
        };
        pub const __wit_resource_ownership: wit_types.ResourceOwnership = .own;
    };
    const OtherProvider = struct {
        handle: i32,
        pub const __wit_resource = wit_types.ResourceDescriptor{
            .provider = "test:resources/second@1.0.0",
            .name = "item",
        };
        pub const __wit_resource_ownership: wit_types.ResourceOwnership = .own;
    };
    const OtherType = struct {
        handle: i32,
        pub const __wit_resource = wit_types.ResourceDescriptor{
            .provider = "test:resources/first@1.0.0",
            .name = "other",
        };
        pub const __wit_resource_ownership: wit_types.ResourceOwnership = .own;
    };
    const Borrowed = wit_types.Borrow(First);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first = encodeNative(First, .{ .handle = 1 }, arena.allocator());
    const same_handle_other_provider =
        encodeNative(OtherProvider, .{ .handle = 1 }, arena.allocator());
    const same_handle_other_type = encodeNative(OtherType, .{ .handle = 1 }, arena.allocator());
    const borrowed = encodeNative(Borrowed, .{ .handle = 1 }, arena.allocator());

    try std.testing.expect(typeNeedsNative(First));
    try std.testing.expect(typeNeedsNative(Borrowed));
    try std.testing.expectEqual(NativeTag.resource, first.tag);
    try std.testing.expectEqual(@as(i32, 1), decodeNative(First, &first, arena.allocator()).handle);
    try std.testing.expectEqualStrings(
        First.__wit_resource.provider,
        first.resource_provider_ptr.?[0..first.resource_provider_len],
    );
    try std.testing.expectEqualStrings(
        First.__wit_resource.name,
        first.resource_name_ptr.?[0..first.resource_name_len],
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        first.resource_provider_ptr.?[0..first.resource_provider_len],
        same_handle_other_provider.resource_provider_ptr.?[0..same_handle_other_provider.resource_provider_len],
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        first.resource_name_ptr.?[0..first.resource_name_len],
        same_handle_other_type.resource_name_ptr.?[0..same_handle_other_type.resource_name_len],
    ));
    try std.testing.expect(first.resource_ownership != borrowed.resource_ownership);

    var owned_native = first;
    owned_native.resource_type_id = 5;
    owned_native.resource_generation = 9;
    var borrowed_native = borrowed;
    borrowed_native.resource_type_id = 5;
    borrowed_native.resource_generation = 9;
    borrowed_native.resource_borrow_epoch = 2;
    const fields = [_]NativeField{
        .{ .name_ptr = "owned".ptr, .name_len = "owned".len, .value = &owned_native },
        .{ .name_ptr = "borrowed".ptr, .name_len = "borrowed".len, .value = &borrowed_native },
    };
    const native_bundle = NativeValue{
        .tag = .record,
        .fields_ptr = &fields,
        .fields_len = fields.len,
    };
    const Bundle = struct { owned: First, borrowed: Borrowed };
    var transfers: std.ArrayListUnmanaged(ResourceToken) = .empty;
    defer transfers.deinit(arena.allocator());
    collectOwnedResources(
        Bundle,
        .{ .owned = .{ .handle = 1 }, .borrowed = .{ .handle = 1 } },
        &native_bundle,
        &transfers,
        arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 1), transfers.items.len);
    try std.testing.expectEqual(@as(u32, 5), transfers.items[0].type_id);
    try std.testing.expectEqual(@as(u64, 9), transfers.items[0].generation);
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

test "decodeNativeInt wraps a negative BigInt for a u64 target, matching ToBigUint64" {
    // Simulate the wire shape `decode_from_js` produces for a real negative
    // JS BigInt (e.g. `-5n`): `i64_val`/`u64_val` are always the exact
    // `ToBigInt64`/`ToBigUint64`-style modulo-2**64 reinterpretation (see
    // js_dispatch.cpp), so a negative BigInt decodes to a u64 target as the
    // wrapped two's-complement value, not a trap -- re-verified against the
    // pinned ComponentizeJS 0.21.0 reference itself (a JS export returning
    // `-5n` for a `u64` result lowers to `18446744073709551611`, i.e.
    // `2**64 - 5`, it does not throw). `bigint_is_negative`/
    // `bigint_fits_u64` remain available as diagnostic metadata only.
    const negative: NativeValue = .{
        .tag = .u64_,
        .i64_val = -5,
        .u64_val = @bitCast(@as(i64, -5)),
        .bigint_is_negative = 1,
        .bigint_fits_i64 = 1,
        .bigint_fits_u64 = 0,
    };
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(u64) - 4),
        decodeNativeInt(u64, &negative),
    );
}

test "decodeNativeInt wraps an out-of-domain BigInt for an s64 target, matching ToBigInt64" {
    // `2**64` (one past u64::MAX) as a BigInt result for an s64 target:
    // modulo 2**64 is exactly 0, matching the pinned reference (a JS export
    // returning `18446744073709551616n` for an `s64` result lowers to `0`,
    // not a trap).
    const huge: NativeValue = .{
        .tag = .u64_,
        .i64_val = 0,
        .u64_val = 0,
        .bigint_is_negative = 0,
        .bigint_fits_i64 = 0,
        .bigint_fits_u64 = 0,
    };
    try std.testing.expectEqual(@as(i64, 0), decodeNativeInt(i64, &huge));
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

test "nested options preserve none, some-none, and some-some" {
    const Nested = ??u32;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outer_none: Nested = null;
    const encoded_none = encodeNative(Nested, outer_none, arena.allocator());
    try std.testing.expectEqual(NativeTag.record, encoded_none.tag);
    try std.testing.expectEqual(@as(usize, 1), encoded_none.fields_len);
    const none_tag = findNativeField(&encoded_none, "tag") orelse return error.MissingField;
    try std.testing.expectEqualStrings("none", none_tag.str_ptr.?[0..none_tag.str_len]);
    try std.testing.expectEqual(outer_none, decodeNative(Nested, &encoded_none, arena.allocator()));

    const outer_some_none: Nested = @as(?u32, null);
    const encoded_some_none = encodeNative(Nested, outer_some_none, arena.allocator());
    const some_tag = findNativeField(&encoded_some_none, "tag") orelse return error.MissingField;
    try std.testing.expectEqualStrings("some", some_tag.str_ptr.?[0..some_tag.str_len]);
    const some_none_val = findNativeField(&encoded_some_none, "val") orelse return error.MissingField;
    try std.testing.expectEqual(NativeTag.option_none, some_none_val.tag);
    try std.testing.expectEqual(outer_some_none, decodeNative(Nested, &encoded_some_none, arena.allocator()));

    const outer_some_some: Nested = @as(?u32, 42);
    const encoded_some_some = encodeNative(Nested, outer_some_some, arena.allocator());
    const some_some_val = findNativeField(&encoded_some_some, "val") orelse return error.MissingField;
    try std.testing.expectEqual(NativeTag.option_some, some_some_val.tag);
    try std.testing.expectEqual(NativeTag.f64_, some_some_val.option_ptr.?.tag);
    try std.testing.expectEqual(outer_some_some, decodeNative(Nested, &encoded_some_some, arena.allocator()));

    // JavaScript null and undefined both decode to this tag. At a nested
    // target they lower to the outer none state, never some-none.
    const js_null_or_undefined: NativeValue = .{ .tag = .option_none };
    try std.testing.expectEqual(outer_none, decodeNative(Nested, &js_null_or_undefined, arena.allocator()));
}

test "encodes void as its own dedicated tag, never bool_/option_none" {
    // The reverse (`--js-imports`) bridge's generated dispatch trampoline
    // calls `encodeNative(void, {}, alloc)` for a WIT import with no
    // result; `encode_to_js` (js_dispatch.cpp) then converts `.undefined_`
    // to a real JavaScript `undefined`. Before this fix the generator
    // hard-coded `.tag = .bool_` (JS `false`); `.option_none` (JS `null`)
    // would be equally wrong, since that tag means WIT `option::none`, not
    // "no result at all".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const encoded = encodeNative(void, {}, arena.allocator());
    try std.testing.expectEqual(NativeTag.undefined_, encoded.tag);
    try std.testing.expect(encoded.tag != .bool_);
    try std.testing.expect(encoded.tag != .option_none);
    try std.testing.expect(NativeTag.option_none != NativeTag.undefined_);
}

test "decodeNative(void, ...) accepts either the undefined tag or a real export's option_none shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const from_import_bridge: NativeValue = .{ .tag = .undefined_ };
    decodeNative(void, &from_import_bridge, arena.allocator());

    // A real void *export* result decodes (via decode_from_js) to
    // `.option_none` (JS undefined/null with no target-type context) --
    // `decodeNative(void, ...)` must accept that shape too.
    const from_export_result: NativeValue = .{ .tag = .option_none };
    decodeNative(void, &from_export_result, arena.allocator());
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

test "decodeNativeInt decodes valid sub-64-bit widths exactly at their boundaries" {
    // Every width narrower than 64 bits is represented as a plain JS Number
    // (tag `.f64_`); valid boundary values must decode exactly.
    const max_u32: NativeValue = .{ .tag = .f64_, .f64_val = @floatFromInt(std.math.maxInt(u32)) };
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), decodeNativeInt(u32, &max_u32));

    const min_i32: NativeValue = .{ .tag = .f64_, .f64_val = @floatFromInt(std.math.minInt(i32)) };
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), decodeNativeInt(i32, &min_i32));
}

test "decodeNativeInt wraps out-of-range/negative/fractional/non-finite sub-64-bit Numbers, matching ToInt32/ToUint32" {
    // Re-verified directly against the pinned ComponentizeJS 0.21.0
    // reference (tests/compat/reference), not assumed from the ECMAScript
    // spec alone: a JS export returning any of these values for the given
    // WIT integer type lowers to exactly these wrapped results, never a
    // trap.
    const cases = .{
        // (type, input, expected)
        .{ u8, 300.0, @as(u8, 44) }, // 300 mod 256
        .{ u8, -5.0, @as(u8, 251) }, // 256 - 5
        .{ u8, 3.5, @as(u8, 3) }, // truncates toward zero before wrapping
        .{ i8, 200.0, @as(i8, -56) }, // 200 - 256
        .{ u32, -1.0, @as(u32, std.math.maxInt(u32)) },
        .{ u32, 4294967296.0, @as(u32, 0) }, // 2**32 mod 2**32
        .{ i32, std.math.inf(f64), @as(i32, 0) }, // +Infinity -> +0
        .{ i32, -std.math.inf(f64), @as(i32, 0) }, // -Infinity -> +0
        .{ i32, std.math.nan(f64), @as(i32, 0) }, // NaN -> +0
    };
    inline for (cases) |c| {
        const T = c[0];
        const value: NativeValue = .{ .tag = .f64_, .f64_val = c[1] };
        try std.testing.expectEqual(c[2], decodeNativeInt(T, &value));
    }
}

test "wit_types.Char round-trips as a single-codepoint JS string" {
    try std.testing.expect(typeNeedsNative(wit_types.Char));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A multi-byte scalar value (U+00E9, 'e' with acute accent) exercises
    // the UTF-8 encode/decode path, not just plain ASCII.
    const value: wit_types.Char = .{ .codepoint = 0xE9 };
    const encoded = encodeNative(wit_types.Char, value, arena.allocator());
    try std.testing.expectEqual(NativeTag.string_, encoded.tag);
    const bytes = encoded.str_ptr.?[0..encoded.str_len];
    try std.testing.expectEqualStrings("\u{E9}", bytes);

    const decoded = decodeNative(wit_types.Char, &encoded, arena.allocator());
    try std.testing.expectEqual(@as(u32, 0xE9), decoded.codepoint);
}

test "wit_types.ByteList round-trips as a Uint8Array and accepts a lenient JS Array" {
    try std.testing.expect(typeNeedsNative(wit_types.ByteList));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value: wit_types.ByteList = .{ .bytes = &.{ 0, 1, 2, 255 } };
    const encoded = encodeNative(wit_types.ByteList, value, arena.allocator());
    // Must be a genuine Uint8Array tag (`.bytes`), not the generic list tag
    // used for every other `list<T>` -- ComponentizeJS distinguishes these.
    try std.testing.expectEqual(NativeTag.bytes, encoded.tag);
    const decoded = decodeNative(wit_types.ByteList, &encoded, arena.allocator());
    try std.testing.expectEqualSlices(u8, value.bytes, decoded.bytes);

    // ComponentizeJS's own `list<u8>` lowering leniently accepts a plain
    // Array of small integers too (confirmed empirically); decodeNative must
    // accept that shape as well, since a JS export is free to `return
    // [0, 1, 2, 255]` instead of constructing a real `Uint8Array`.
    var items = [_]NativeValue{
        .{ .tag = .f64_, .f64_val = 0 },
        .{ .tag = .f64_, .f64_val = 1 },
        .{ .tag = .f64_, .f64_val = 2 },
        .{ .tag = .f64_, .f64_val = 255 },
    };
    const list_shaped: NativeValue = .{ .tag = .list_, .list_ptr = &items, .list_len = items.len };
    const decoded_list = decodeNative(wit_types.ByteList, &list_shaped, arena.allocator());
    try std.testing.expectEqualSlices(u8, value.bytes, decoded_list.bytes);
}

test "a WIT enum round-trips as a plain kebab-case JS string" {
    const Direction = enum { north_east, south_west };
    try std.testing.expect(typeNeedsNative(Direction));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const encoded = encodeNative(Direction, .north_east, arena.allocator());
    try std.testing.expectEqual(NativeTag.string_, encoded.tag);
    // Case labels stay in their original kebab-case spelling as a string
    // *value* (not camelCased -- confirmed against the pinned
    // ComponentizeJS reference; string content isn't an identifier).
    try std.testing.expectEqualStrings("north-east", encoded.str_ptr.?[0..encoded.str_len]);

    const decoded = decodeNative(Direction, &encoded, arena.allocator());
    try std.testing.expectEqual(Direction.north_east, decoded);
}

test "a WIT flags type round-trips as a plain object with every label present" {
    const Perms = packed struct(u8) { can_read: bool, can_write: bool, _padding: u6 = 0 };
    try std.testing.expect(typeNeedsNative(Perms));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value: Perms = .{ .can_read = true, .can_write = false };
    const encoded = encodeNative(Perms, value, arena.allocator());
    try std.testing.expectEqual(NativeTag.record, encoded.tag);
    // Only the two `bool` labels are present -- the `_padding` field must
    // never leak into the JS-visible shape.
    try std.testing.expectEqual(@as(usize, 2), encoded.fields_len);
    const can_read = findNativeField(&encoded, "canRead") orelse return error.MissingField;
    try std.testing.expectEqual(@as(u8, 1), can_read.bool_val);
    const can_write = findNativeField(&encoded, "canWrite") orelse return error.MissingField;
    try std.testing.expectEqual(@as(u8, 0), can_write.bool_val);

    const decoded = decodeNative(Perms, &encoded, arena.allocator());
    try std.testing.expectEqual(value.can_read, decoded.can_read);
    try std.testing.expectEqual(value.can_write, decoded.can_write);
}

test "a WIT tuple round-trips as a plain positional JS array" {
    const T = wit_types.Tuple(.{ u32, []const u8 });
    try std.testing.expect(typeNeedsNative(T));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value: T = .{ 42, "hi" };
    const encoded = encodeNative(T, value, arena.allocator());
    try std.testing.expectEqual(NativeTag.list_, encoded.tag);
    try std.testing.expectEqual(@as(usize, 2), encoded.list_len);

    const decoded = decodeNative(T, &encoded, arena.allocator());
    try std.testing.expectEqual(value[0], decoded[0]);
    try std.testing.expectEqualStrings(value[1], decoded[1]);
}

test "a WIT variant round-trips as a {tag, val} object, val omitted for a void case" {
    const Shape = union(enum) { circle: u32, point: void };
    try std.testing.expect(typeNeedsNative(Shape));
    try std.testing.expect(!isWitResultType(Shape));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const with_payload: Shape = .{ .circle = 5 };
    const encoded_payload = encodeNative(Shape, with_payload, arena.allocator());
    try std.testing.expectEqual(NativeTag.record, encoded_payload.tag);
    try std.testing.expectEqual(@as(usize, 2), encoded_payload.fields_len);
    const tag_field = findNativeField(&encoded_payload, "tag") orelse return error.MissingField;
    try std.testing.expectEqualStrings("circle", tag_field.str_ptr.?[0..tag_field.str_len]);
    const val_field = findNativeField(&encoded_payload, "val") orelse return error.MissingField;
    try std.testing.expectEqual(@as(f64, 5), val_field.f64_val);

    const decoded_payload = decodeNative(Shape, &encoded_payload, arena.allocator());
    try std.testing.expectEqual(@as(u32, 5), decoded_payload.circle);

    const void_case: Shape = .point;
    const encoded_void = encodeNative(Shape, void_case, arena.allocator());
    // A void-payload case omits `val` entirely (not present-with-null),
    // matching the shape ComponentizeJS actually produces.
    try std.testing.expectEqual(@as(usize, 1), encoded_void.fields_len);
    try std.testing.expect(findNativeField(&encoded_void, "val") == null);

    const decoded_void = decodeNative(Shape, &encoded_void, arena.allocator());
    try std.testing.expectEqual(Shape.point, decoded_void);
}

test "isWitResultType only matches the exact ok/err two-case union shape" {
    try std.testing.expect(isWitResultType(wit_types.Result(u32, []const u8)));
    try std.testing.expect(isWitResultType(wit_types.Result(void, void)));
    try std.testing.expect(!isWitResultType(union(enum) { circle: u32, point: void }));
    try std.testing.expect(!isWitResultType(struct { ok: u32, err: []const u8 }));
}
