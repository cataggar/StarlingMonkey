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
};

// Calls the named export with `args`, encoding each to a JS value (records ->
// plain objects by field name, i64/u64 -> exact BigInt). On success writes
// the JS return value into `*out_result` (valid until freed) and an opaque
// arena handle into `*out_arena`; the caller must eventually pass that handle
// to `starling_js_dispatch_native_free`, even for `void` results (pass a
// scratch `out_result` in that case; the arena may still hold string/record
// bookkeeping). Returns 0 on success, non-zero if the export was missing,
// wasn't callable, returned a Promise, or raised a JS exception (the pending
// exception is left for the caller to surface as a trap).
extern "C" uint32_t starling_js_dispatch_native(const uint8_t *export_name_ptr,
                                                size_t export_name_len,
                                                const StarlingJsValue *args_ptr,
                                                size_t args_len,
                                                StarlingJsValue *out_result,
                                                void **out_arena);

// Frees a result arena returned by `starling_js_dispatch_native`. `arena` may
// be null.
extern "C" void starling_js_dispatch_native_free(void *arena);

#endif
