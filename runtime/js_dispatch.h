#ifndef STARLINGMONKEY_JS_DISPATCH_H
#define STARLINGMONKEY_JS_DISPATCH_H

#include <stddef.h>
#include <stdint.h>

#include "resource_registry.h"

namespace api {
class Engine;
}

namespace starling {
bool drain_resource_drops(api::Engine *engine);
bool shutdown_resources(api::Engine *engine);
}

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
// directions; only who calls encode vs. decode swaps. Resource values carry
// their canonical i32 handle plus canonical provider/name identity and
// ownership mode. Runtime-local type IDs and generation/borrow tokens are
// added by the instance-long registry; persistent state never lives in this
// call-scoped tree.
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
  // A WIT function with no result. Encodes (encode_to_js) to JavaScript
  // `undefined` -- *never* `false` (a stray `STARLING_JS_BOOL`) or `null`
  // (`STARLING_JS_OPTION_NONE`, which is option-`none`'s tag, not void's).
  // This is encode-direction only (the reverse `--js-imports` bridge, where
  // a host import with no result must hand JavaScript back exactly
  // `undefined`): `decode_from_js` never *produces* this tag -- a real JS
  // `undefined`/`null` returned from an *export* still decodes to
  // `STARLING_JS_OPTION_NONE` as before (see `decode_from_js` below), since
  // that direction has no target type to know it's looking at a `void`
  // rather than an absent optional. Keep this in sync with `NativeTag` in
  // runtime/js_dispatch.zig (`.undefined_`), which must carry the identical
  // numeric value. Deliberately `10`, not `9`: `STARLING_JS_BYTES` (above)
  // claimed `9` first when the synchronous value-parity and WIT-imports
  // bridges were integrated, and every existing tag's original numeric
  // value is preserved rather than renumbered to make room.
  STARLING_JS_UNDEFINED = 10,
  STARLING_JS_RESOURCE = 11,
};

enum StarlingJsResourceOwnership : uint8_t {
  STARLING_JS_RESOURCE_OWN = 0,
  STARLING_JS_RESOURCE_BORROW = 1,
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
  // tag == RESOURCE. The canonical WIT interface/resource identity accompanies
  // every value entering the bridge. The C++ registry interns that exact pair
  // to `resource_type_id`; a hash-derived ID is never trusted as identity.
  const uint8_t *resource_provider_ptr;
  size_t resource_provider_len;
  const uint8_t *resource_name_ptr;
  size_t resource_name_len;
  uint32_t resource_type_id;
  int32_t resource_handle;
  StarlingJsResourceOwnership resource_ownership;
  uint64_t resource_generation;
  uint64_t resource_borrow_epoch;
};

// Validates a resource token produced by `decode_from_js`. Borrowed tokens are
// checked against the active dispatch epoch. Owned transfers are staged until
// the complete aggregate has decoded successfully, then committed atomically.
extern "C" STARLING_ENGINE_EXPORT uint32_t starling_js_resource_validate(
    uint32_t type_id, int32_t handle, uint64_t generation,
    StarlingJsResourceOwnership ownership, uint64_t borrow_epoch);
extern "C" STARLING_ENGINE_EXPORT uint32_t
starling_js_resource_transfer_many(const starling::ResourceToken *tokens, size_t len);

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
// Calls the named export with `args`. A bare dispatch name resolves a root
// module function; `<package>/<interface>[@version]#<function>` resolves the
// function inside the module's same-named interface namespace object.
// Interface-qualified names never fall back to flat module functions.
// Arguments are encoded to JS values (records ->
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
// A direct `STARLING_JS_OPTION_NONE` encodes to JavaScript `undefined`.
// The Zig side represents an `option<option<T>>` with a regular
// `STARLING_JS_RECORD` `{tag:"none"|"some", val?}` tree before it reaches
// this generic encoder, so neither this tag nor `STARLING_JS_UNDEFINED`
// needs a lossy overloaded meaning.
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
// A *Promise* returned by a `result_is_wit_result` export gets the exact
// same err-via-throw treatment, not just a plain synchronous exception at
// the `JS::Call` boundary above: `resolve_promise_like` pumps the event loop
// for it exactly as for any other export, and if it settles Rejected, the
// rejection reason is decoded into `*out_result` and this function returns
// 2 here too -- a rejected Promise and a synchronous throw are
// indistinguishable at this boundary, and re-verified directly against the
// pinned ComponentizeJS 0.21.0 reference (not assumed): both simply become
// the `err` payload, and both trap if decoding that payload as `E` fails
// (wrong JS kind for `E`; `E == void` never even inspects the payload, so
// *any* rejection reason of *any* shape becomes a bare `Err()` there -- see
// js_dispatch.zig's `callNative`). A deadlock/no-progress or reentrancy
// diagnostic from that pump is, however, *never* reinterpreted as `err`
// regardless of `result_is_wit_result` -- surfaced the same way as for a
// non-result export (dumped to stderr, hard dispatch failure, status 1) --
// since those are StarlingMonkey-internal dispatch failures with no
// ComponentizeJS equivalent to defer to, confirmed by the same empirical
// check (see tests/compat/fixtures/promises-result and manifest.json's
// "promise-result-rejection-matches-throw" known_deviation for the
// differential evidence, gathered through the real Wasmtime 42 CLI, this
// was checked against).
//
// Returns 0 on success, 1 if the export was missing, wasn't callable,
// returned a Promise that deadlocked/hit reentrancy, or raised/rejected with
// a JS exception/reason that isn't the `result_is_wit_result` err case
// above, or 2 for that err case (see above; returned whether the exception
// was synchronous or arrived via a rejected Promise, as long as
// `result_is_wit_result` is true).
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
extern "C" STARLING_ENGINE_EXPORT uint32_t starling_js_dispatch_native_free(void *arena);

// Generated by WABT in `--dispatch` mode: one line per synchronous
// JavaScript-backed WIT export. Named-interface entries are
// "I\t<interface-id>#<function>\n"; root entries are "R\t<function>\n".
// The returned static buffer must not be freed. Builds without generated
// dispatch bindings use the weak empty fallback in js_dispatch.cpp.
extern "C" STARLING_ENGINE_EXPORT const uint8_t *starling_js_exports_manifest(size_t *out_len);

// Validates every generated export manifest entry against the evaluated
// JavaScript module namespace without invoking it. Leaves any diagnostic as a
// pending JS exception so the componentization initializer can abort with the
// existing engine error reporting.
bool starling_validate_required_exports();

// ---------------------------------------------------------------------------
// Reverse bridge: host-provided WIT interface or root-function imports called *from*
// JavaScript. These three symbols are emitted by the WABT `wasip3-bindgen`
// generator's `--js-imports` mode (see component_bindgen.zig's
// `emitJsImportBridge`) whenever the world imports at least one interface
// function whose full parameter/result type graph is representable by the
// same tagged-value vocabulary as the export bridge above (bool/integers/
// f32/f64/string/option<T>/list<T>/record, recursively). `js_dispatch.cpp`
// provides weak default fallbacks (see the `.cpp` file) so a build with no
// eligible imports -- or without `--dispatch`/`--js-imports` at all -- still
// links, with an empty manifest and a dispatch function that always reports
// "not found"; this keeps default behavior byte-for-byte unchanged for
// components with no custom imports.
//
// `wit_imports::install` (js_dispatch.cpp) parses the manifest, groups entries
// by JavaScript module id, and registers each builtin ES module via
// `Engine::define_builtin_module`. Interface imports expose named functions;
// a world-level function `foo` exposes `default` from module `foo`, matching
// ComponentizeJS 0.21. Arguments are built from JS values via the same
// `decode_from_js` used for export results, and results use the same
// `encode_to_js` used for export arguments.

// Returns a pointer to a TSV byte string, one line per JS-bridged import:
// "<module-id>\t<js-export-name>\t<dispatch-key>\t<arity>\n". Interface
// entries use `<iface-id>, <WIT function>, <iface-id>#<WIT function>`;
// root entries use `<WIT function>, default, $root#<WIT function>`. `*out_len`
// is set to its length. The static returned buffer must not be freed.
extern "C" STARLING_ENGINE_EXPORT const uint8_t *starling_js_imports_manifest(size_t *out_len);

// Looks up the manifest line's dispatch key (`<iface>#<function>` or
// `$root#<function>`) and, if found, decodes `argv` (built by
// the caller via `decode_from_js`) into the callee's concrete WIT parameter
// types, invokes the generated typed import wrapper, and encodes its result
// into `*out_result`/`*out_arena` (to later be read with `encode_to_js` and
// released via `starling_js_import_result_free`). Returns 0 on success, 1 if
// `name` does not match any bridged import (a build-time-impossible case in
// practice, since the caller only ever dispatches keys taken from the
// manifest -- guarded defensively anyway). A real Wasmtime host trap raised
// from within the underlying canonical-ABI import call unwinds the entire
// instance and never returns here at all, which is the correct/expected
// component-model behavior for host trap propagation.
extern "C" STARLING_ENGINE_EXPORT uint32_t starling_js_import_dispatch(const uint8_t *name_ptr,
                                                size_t name_len,
                                                const StarlingJsValue *argv_ptr,
                                                size_t argv_len,
                                                StarlingJsValue *out_result,
                                                void **out_arena);

// Frees an arena returned via `starling_js_import_dispatch`'s `*out_arena`.
// `arena` may be null.
extern "C" STARLING_ENGINE_EXPORT void starling_js_import_result_free(void *arena);

#endif
