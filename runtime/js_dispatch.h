#ifndef STARLINGMONKEY_JS_DISPATCH_H
#define STARLINGMONKEY_JS_DISPATCH_H

#include <stddef.h>
#include <stdint.h>

// world-shell-integration: in the monolithic build these functions are kept
// alive because runtime/js_dispatch.zig's `extern fn` declarations are real
// call sites, so wasm-ld's default DCE never has to consider removing them.
// A world-independent "engine" PIC dylib (see build.zig's
// -Dengine-dylib-experiment) has no such caller inside the module itself --
// the caller lives in a separately-built "shell" dylib, resolved only at
// `wasm-tools component link` time -- so, from the engine dylib's own DCE
// pass, these exports are otherwise indistinguishable from dead code and get
// garbage-collected despite already having default (non-hidden) visibility.
// `used` forces retention regardless of any in-module reachability.
#define STARLING_ENGINE_EXPORT __attribute__((used, visibility("default")))

struct StarlingJSDispatchResult {
  uint8_t *ptr;
  size_t len;
};

extern "C" STARLING_ENGINE_EXPORT uint32_t starling_js_dispatch(const uint8_t *export_name_ptr,
                                         size_t export_name_len,
                                         const uint8_t *args_json_ptr,
                                         size_t args_json_len,
                                         StarlingJSDispatchResult *result);

// Frees a `StarlingJSDispatchResult.ptr` buffer allocated by
// `starling_js_dispatch` above (see js_dispatch.cpp: it is backed by plain
// `std::malloc`). Callers -- including a separately-linked "shell" PIC
// dylib in the world-shell split build -- must go through this exported
// wrapper rather than calling libc's `free` directly: a thin shell has no
// reason to statically link its own copy of wasi-libc (doing so duplicates
// weak internal libc symbols across the engine and shell modules, which
// `wasm-tools component link` rejects as duplicate exports when merging
// the two side modules), and even if it did, its allocator instance would
// be a distinct one from whatever allocated this buffer in the engine.
extern "C" STARLING_ENGINE_EXPORT void starling_dispatch_result_free(void *ptr);

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
  // A WIT `list<u8>` (the `wit_types.ByteList` wrapper -- see the "string vs
  // list<u8>" note below): encodes to/from a genuine JS `Uint8Array`, never
  // a plain Array, matching ComponentizeJS 0.21.0's observed behavior.
  // `str_ptr`/`str_len` carry the raw bytes, reusing the same fields
  // `STARLING_JS_STRING` uses (this tag only changes how encode_to_js builds
  // the JS value and how decode_from_js recognizes one on the way back).
  STARLING_JS_BYTES = 9,
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
  // tag == U64 (BigInt) only. `i64_val`/`u64_val` are always populated via
  // `JS::ToBigInt64`/`JS::ToBigUint64` (the same modulo-2**64
  // reinterpretation the real ComponentizeJS/Wasmtime canonical-ABI JS
  // embedding performs when lowering a JS export's own BigInt return value),
  // so they are valid and authoritative for *every* BigInt, in range or not
  // -- an out-of-domain (too large, or negative-for-u64) BigInt result wraps
  // like real ComponentizeJS does, it is never rejected on that basis alone
  // (empirically re-verified against the pinned 0.21.0 reference itself; see
  // tests/compat/fixtures/integers-64bit's "sum-list-basic" case, which
  // deliberately sums past u64::MAX and expects the identical wrapped
  // result on both pipelines). These three flags are therefore only
  // diagnostic metadata now (not consulted by the current Zig-side decode
  // to reject anything): `bigint_is_negative` reflects the BigInt's true
  // mathematical sign (via `JS::BigIntIsNegative`, immune to two's
  // complement wraparound, unlike `i64_val < 0`), and `bigint_fits_i64`/
  // `bigint_fits_u64` (via `JS::BigIntFits`) report whether the BigInt's
  // true mathematical value happened to fit without truncation.
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
// Formerly-known limitation, now resolved: WIT `string` and `list<u8>` both
// lower, under the *default* wit-to-Zig bindgen (`zigType` in
// component_bindgen.zig), to the identical Zig type `[]const u8`, and
// likewise `char` and `u32` both lower to a bare `u32`. The pinned
// `--dispatch`-mode bindgen (js-dispatch shell generation only -- every other
// WIT world the generator serves, e.g. wasi:http, is unaffected) now emits
// nominal wrapper types `wit_types.ByteList`/`wit_types.Char` instead, whose
// Zig type identity `encodeNative`/`decodeNative` (js_dispatch.zig) checks
// for directly. `STARLING_JS_BYTES` (above) and single-codepoint
// `STARLING_JS_STRING` values are how those two wrappers cross this
// boundary; see js_dispatch.zig for the comptime dispatch on `T`.
//
// Calls the named export with `args`, encoding each to a JS value (records ->
// plain objects by field name, i64/u64 -> exact BigInt, lists -> JS Arrays,
// `wit_types.ByteList` -> a genuine `Uint8Array`, `wit_types.Char` -> a
// single-codepoint string, variant/result -> `{tag, val}` objects, flags ->
// a plain object with every flag name present as a boolean). If the call
// returns a Promise (or a thenable), this pumps the engine's event loop --
// microtask/job queue plus any queued timer/host-task callbacks -- until it
// settles, then uses the fulfilled value as if it had been returned
// directly (see `resolve_promise_like` in js_dispatch.cpp). On success
// writes the JS return value into `*out_result` (valid until freed) and an
// opaque arena handle into `*out_arena`; the caller must eventually pass that
// handle to `starling_js_dispatch_native_free`, even for `void` results (pass
// a scratch `out_result` in that case; the arena may still hold
// string/record bookkeeping).
//
// `result_is_wit_result` must be true iff the export's own return type is
// directly a WIT `result<T, E>` (i.e. `Result` in js_dispatch.zig's
// `callNative` is exactly `wit_types.Result(T, E)`, not merely containing one
// nested inside a record/list/option). ComponentizeJS's JS-visible calling
// convention special-cases exactly this position: the JS implementation
// returns the `ok` payload directly (no `{tag, val}` wrapper) and signals
// `err` by *throwing* the err payload (or throwing anything at all, if `E`
// is `void`) rather than returning a tagged object. When
// `result_is_wit_result` is true and the call throws a plain JS exception
// (not a missing/uncallable export, not a returned Promise), this function
// decodes the *thrown value* into `*out_result` and returns 2 instead of
// treating the exception as a hard dispatch failure; `callNative` then
// builds the `.err` case from it. Any other synchronous exception (or any
// exception at all when `result_is_wit_result` is false) is treated as
// before: it is left pending for the caller to dump/surface as a trap.
//
// A *Promise* returned by a `result_is_wit_result` export is deliberately
// **not** given the same err-via-throw treatment: only a plain synchronous
// exception at the `JS::Call` boundary above takes the status-2 path.
// `resolve_promise_like` still pumps the event loop for it exactly as for
// any other export, and a rejection (or a deadlock/reentrancy diagnostic
// from that pump) is surfaced the same way as for a non-result export --
// dumped to stderr and reported as a hard dispatch failure (status 1), not
// silently reinterpreted as `err` -- because this matches actual pinned
// ComponentizeJS 0.21.0/Wasmtime 42 behavior for a `result<T, E>` export
// whose implementation is `async`/returns a rejected Promise, verified
// empirically rather than assumed (see
// tests/compat/fixtures/promises-result and manifest.json's
// "promise-result-rejection" known_deviation for the differential evidence
// this was checked against). Only a real JS-visible Promise rejection is
// covered by that verification; an event-loop deadlock/no-progress or
// reentrancy diagnostic is never turned into `err` regardless of
// `result_is_wit_result`, since those are StarlingMonkey-internal dispatch
// failures with no ComponentizeJS equivalent to defer to.
//
// Returns 0 on success, 1 if the export was missing, wasn't callable,
// returned a Promise that rejected/deadlocked/hit reentrancy, or raised a
// JS exception that isn't the `result_is_wit_result` err-via-throw case
// above, or 2 for that err-via-throw case (see above; only ever returned
// when `result_is_wit_result` is true and the exception was synchronous,
// never for a rejected Promise).
extern "C" STARLING_ENGINE_EXPORT uint32_t starling_js_dispatch_native(const uint8_t *export_name_ptr,
                                                size_t export_name_len,
                                                const StarlingJsValue *args_ptr,
                                                size_t args_len,
                                                uint8_t result_is_wit_result,
                                                StarlingJsValue *out_result,
                                                void **out_arena);

// Frees a result arena returned by `starling_js_dispatch_native`. `arena` may
// be null. Callers must not read through any pointer into a previously
// returned `StarlingJsValue` tree after calling this.
extern "C" STARLING_ENGINE_EXPORT void starling_js_dispatch_native_free(void *arena);

#endif
