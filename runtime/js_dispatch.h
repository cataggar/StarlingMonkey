#ifndef STARLINGMONKEY_JS_DISPATCH_H
#define STARLINGMONKEY_JS_DISPATCH_H

#include <stddef.h>
#include <stdint.h>

struct StarlingJSDispatchResult {
  uint8_t *ptr;
  size_t len;
};

extern "C" uint32_t starling_js_dispatch(const uint8_t *export_name_ptr,
                                         size_t export_name_len,
                                         const uint8_t *args_json_ptr,
                                         size_t args_json_len,
                                         StarlingJSDispatchResult *result);

// ---------------------------------------------------------------------------
// Typed native dispatch bridge.
//
// A JSON-free path for values that JSON cannot carry exactly (`u64`/`s64`
// beyond 2**53) or that we don't want to pay string-serialize/parse for
// (nested aggregates). It coexists with `starling_js_dispatch` above: the
// Zig-generated export shells call whichever bridge `runtime/js_dispatch.zig`
// selects for the given argument/result type graph (see `needsNative` there),
// so existing JSON-representable exports keep working unchanged.
//
// `StarlingJsValue` is a small self-describing value tree shared by value
// (not by wire format) between the Zig guest code and this C++ translation
// unit -- both are linked into the same wasm module, so pointers are valid
// directly across the "boundary" without any host copy. Zig builds the
// argument trees in its own arena (freed when `js_dispatch.zig`'s `call`
// returns); this file builds the *result* tree in a small bump arena whose
// opaque handle is threaded back through `out_arena` and released by the
// caller via `starling_js_dispatch_native_free`.
//
// Reversing for host imports: a JS `import` implementation would receive
// argv already decoded to a `StarlingJsValue` tree (mirroring the export
// result-encode direction below) and would return its result the way export
// *arguments* are encoded here -- the same tree/tag vocabulary and the same
// `encode_to_js`/`decode_from_js` pair in js_dispatch.cpp cover both
// directions; only who calls encode vs. decode swaps. Resources would extend
// `StarlingJsTag` with a `STARLING_JS_RESOURCE` tag carrying an opaque i32
// handle plus a resource-table id, converted to/from a `FinalizationRegistry`
// wrapped JS object -- no change to the tree shape or the Zig-side recursive
// encode/decode is needed, only one more tag arm on each side.
enum StarlingJsTag : uint32_t {
  STARLING_JS_BOOL = 0,
  // Both integer tags are just a hint to the *encoder* (which BigInt
  // constructor to call); the decoder always populates both `i64_val` and
  // `u64_val` with the same 64-bit pattern (see js_dispatch.cpp), so the Zig
  // side picks whichever field matches its comptime-known target signedness.
  STARLING_JS_I64 = 1,
  STARLING_JS_U64 = 2,
  STARLING_JS_F64 = 3,
  STARLING_JS_STRING = 4,
  STARLING_JS_OPTION_NONE = 5,
  STARLING_JS_OPTION_SOME = 6,
  STARLING_JS_RECORD = 7,
  STARLING_JS_LIST = 8,
};

struct StarlingJsValue;

struct StarlingJsField {
  const uint8_t *name_ptr;
  size_t name_len;
  StarlingJsValue *value;
};

struct StarlingJsValue {
  StarlingJsTag tag;
  uint8_t bool_val;
  int64_t i64_val;
  uint64_t u64_val;
  double f64_val;
  const uint8_t *str_ptr;
  size_t str_len;
  const StarlingJsValue *option_ptr;   // tag == OPTION_SOME
  const StarlingJsField *fields_ptr;   // tag == RECORD
  size_t fields_len;                   // tag == RECORD
  const StarlingJsValue *list_ptr;     // tag == LIST, `list_len` contiguous items
  size_t list_len;                     // tag == LIST
  // tag == U64 (BigInt) only. `ToBigInt64`/`ToBigUint64` merely reinterpret
  // the BigInt's low 64 bits, so a legitimate unsigned value >= 2**63 has an
  // `i64_val` that *looks* negative in two's complement even though the
  // BigInt itself is non-negative -- `i64_val < 0` is therefore NOT a valid
  // sign test. These three flags instead reflect the BigInt's true
  // mathematical sign/magnitude (via `JS::BigIntIsNegative`/`BigIntIsInt64`/
  // `BigIntIsUint64`), so the Zig side can validate the full exact s64/u64
  // domains (and reject out-of-both-ranges BigInts) without guessing from
  // the wrapped bit pattern.
  uint8_t bigint_is_negative;
  uint8_t bigint_fits_i64;
  uint8_t bigint_fits_u64;
};

// ---------------------------------------------------------------------------
// Ownership/type contract (read this before touching either side of the
// bridge):
//
// * Argument direction (Zig -> JS, `encode_to_js`): the Zig caller
//   (`encodeNative` in js_dispatch.zig) knows every argument's concrete WIT
//   type at comptime, so it builds a fully-tagged tree, including using
//   `STARLING_JS_OPTION_SOME`/`option_ptr` to box a *present* optional value.
//   That tree lives in the Zig caller's own short-lived arena and is only
//   read (never retained) by `encode_to_js`/`starling_js_dispatch_native`;
//   it stays valid for the duration of that one call.
//
// * Result direction (JS -> Zig, `decode_from_js`): this side has no target
//   type to consult -- it walks the *actual runtime shape* of the returned
//   JS::Value and reflects it generically, the same way `JS_Stringify` does
//   for the JSON bridge. In particular:
//     - `null`/`undefined` always decode to `STARLING_JS_OPTION_NONE`.
//     - Every other JS value decodes to its own concrete tag (`BOOL`/
//       `U64`/`F64`/`STRING`/`LIST`/`RECORD`) *directly* -- `decode_from_js`
//       never wraps a present value in `STARLING_JS_OPTION_SOME`, because it
//       cannot know whether the caller's target type is optional. Zig's
//       `decodeNative` accounts for this: decoding a `?T` accepts either an
//       `OPTION_NONE` node (-> null) or *any other* node decoded directly as
//       `T` (-> present), and only unwraps `option_ptr` for the (encode-only)
//       `OPTION_SOME` shape.
//     - JS Arrays are detected before the generic own-enumerable-keys object
//       walk and always produce `STARLING_JS_LIST`, so integer element
//       "keys" are never silently dropped as if the array were a
//       property-keyed record.
//   All of this tree's storage (boxed values, field/list arrays, decoded
//   string bytes) is owned by the `NativeArena` referenced by `*out_arena`,
//   valid only until `starling_js_dispatch_native_free` runs. The Zig-side
//   `callNative` MUST finish copying every byte/nested value it needs
//   (`decodeNative` deep-copies into a Zig-owned allocator) *before* it frees
//   that arena -- freeing it first and only afterwards reading through
//   dangling `str_ptr`/`list_ptr`/`fields_ptr` pointers is a use-after-free.
//
// Known limitation: WIT `string` and `list<u8>` both lower, in the current
// wit-to-Zig bindgen (`zigType` in component_bindgen.zig), to the identical
// Zig type `[]const u8`. Neither `encode_to_js`/`decode_from_js` here nor
// `encodeNative`/`decodeNative` in js_dispatch.zig have any way to recover
// which WIT type a given `[]const u8` value actually came from, so both
// sides treat `[]const u8` as a UTF-8 `string` (matching the far more common
// case, and consistent with the JSON bridge's existing `[]const u8` <->
// JSON-string handling). A WIT `list<u8>` result/argument that reaches the
// native bridge (i.e. co-occurs with an `i64`/`u64` elsewhere in the same
// call) is therefore misrepresented as a string rather than an array of
// byte values. Resolving this precisely requires the bindgen generator to
// emit a distinguishing wrapper type for `list<u8>`; that is out of scope
// here (it would ripple into every other WIT world the generator serves,
// e.g. wasi:http bodies) and is called out as a follow-up rather than
// silently "fixed" by guesswork.
//
// Calls the named export with `args`, encoding each to a JS value (records ->
// plain objects by field name, i64/u64 -> exact BigInt, lists -> JS Arrays).
// On success writes the JS return value into `*out_result` (valid until
// freed) and an opaque arena handle into `*out_arena`; the caller must
// eventually pass that handle to `starling_js_dispatch_native_free`, even for
// `void` results (pass a scratch `out_result` in that case; the arena may
// still hold string/record bookkeeping). Returns 0 on success, non-zero if
// the export was missing, wasn't callable, returned a Promise, or raised a
// JS exception (the pending exception is left for the caller to surface as a
// trap).
extern "C" uint32_t starling_js_dispatch_native(const uint8_t *export_name_ptr,
                                                size_t export_name_len,
                                                const StarlingJsValue *args_ptr,
                                                size_t args_len,
                                                StarlingJsValue *out_result,
                                                void **out_arena);

// Frees a result arena returned by `starling_js_dispatch_native`. `arena` may
// be null. Callers must not read through any pointer into a previously
// returned `StarlingJsValue` tree after calling this.
extern "C" void starling_js_dispatch_native_free(void *arena);

#endif
