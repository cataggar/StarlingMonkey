#include "js_dispatch.h"

#include "builtin.h"
#include "extension-api.h"
#include "decode.h"
#include "encode.h"
#include "event_loop.h"

#include "js/Array.h"
#include "js/BigInt.h"
#include "js/CallAndConstruct.h"
#include "js/CharacterEncoding.h"
#include "js/GCAPI.h"
#include "js/JSON.h"
#include "js/Promise.h"
#include "js/PropertyAndElement.h"
#include "js/experimental/TypedData.h"

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <print>
#include <string>
#include <string_view>
#include <vector>

namespace {

struct JsonBuffer {
  JSContext *cx;
  std::string bytes;
};

bool write_json(const char16_t *chars, uint32_t len, void *data) {
  auto *output = static_cast<JsonBuffer *>(data);
  JS::RootedString string(output->cx, JS_NewUCStringCopyN(output->cx, chars, len));
  if (!string) {
    return false;
  }

  JS::UniqueChars utf8(JS_EncodeStringToUTF8(output->cx, string));
  if (!utf8) {
    return false;
  }
  output->bytes.append(utf8.get());
  return true;
}

uint32_t dispatch_error(JSContext *cx, const char *context) {
  if (JS_IsExceptionPending(cx)) {
    api::Engine::dump_pending_exception(context);
  }
  return 1;
}

// ComponentizeJS/jco's generated glue looks up export functions by camelCase
// identifier (a kebab-case WIT name like "echo-color" becomes "echoColor"),
// not by the literal kebab-case string. `resolve_export_function` below
// tries the literal name first (preserving this bridge's original,
// already-tested convention -- a module can still expose a non-identifier
// name via `export { impl as "big-add" }`), and only falls back to the
// camelCase spelling if the literal property doesn't exist, so JS written
// against either convention resolves correctly.
std::string kebab_to_camel_case(std::string_view kebab) {
  std::string out;
  out.reserve(kebab.size());
  bool upper_next = false;
  for (char c : kebab) {
    if (c == '-') {
      upper_next = true;
      continue;
    }
    out.push_back(upper_next ? static_cast<char>(std::toupper(static_cast<unsigned char>(c))) : c);
    upper_next = false;
  }
  return out;
}

// Shared by both the JSON and the typed-native bridge: looks up
// `<top-level module>[function_name]` (the bare WIT function name, taken
// verbatim from after the last '#' of the qualified export name -- e.g.
// "starling:js/api#big-add" -> "big-add"; a module can expose that literal
// (non-identifier) name via `export { impl as "big-add" }`, or, matching
// ComponentizeJS, a camelCase identifier export like `export function
// bigAdd(...)`). Assumes `cx` is valid and its realm has already been
// entered by the caller.
bool resolve_export_function(JSContext *cx, JS::MutableHandleValue out_function,
                             const uint8_t *export_name_ptr, size_t export_name_len,
                             const char **error_context, std::string *out_function_name) {
  JS::RootedValue module_namespace(cx, api::Engine::script_value());
  if (!module_namespace.isObject()) {
    JS_ReportErrorASCII(cx, "the top-level JavaScript module has no namespace");
    *error_context = "resolving the JavaScript module namespace";
    return false;
  }

  std::string_view export_name(reinterpret_cast<const char *>(export_name_ptr), export_name_len);
  size_t separator = export_name.rfind('#');
  std::string function_name(
      separator == std::string_view::npos ? export_name : export_name.substr(separator + 1));

  JS::RootedObject namespace_object(cx, &module_namespace.toObject());
  std::string lookup_name = function_name;
  std::string camel_name = kebab_to_camel_case(function_name);
  if (camel_name != function_name) {
    bool has_literal = false;
    if (!JS_HasProperty(cx, namespace_object, function_name.c_str(), &has_literal)) {
      *error_context = "resolving a JavaScript module export";
      return false;
    }
    if (!has_literal) {
      lookup_name = camel_name;
    }
  }

  if (!JS_GetProperty(cx, namespace_object, lookup_name.c_str(), out_function)) {
    *error_context = "resolving a JavaScript module export";
    return false;
  }
  if (!out_function.isObject() || !JS::IsCallable(&out_function.toObject())) {
    JS_ReportErrorUTF8(cx, "JavaScript module export '%s' is not a function",
                       lookup_name.c_str());
    *error_context = "resolving a JavaScript module export";
    return false;
  }
  *out_function_name = std::move(function_name);
  return true;
}

// ---------------------------------------------------------------------------
// Promise/thenable driving (`promise-sync` roadmap phase): shared by both the
// JSON and the typed-native bridge. A synchronous WIT export's JavaScript
// implementation is allowed to return a Promise (or a thenable, per the same
// duck test `await`/`Promise.resolve` use: an object with a callable `then`);
// this pumps the engine's existing microtask/job queue and queued async task
// list (see event_loop.{h,cpp}) until it settles, then hands the fulfilled
// value back to the caller for the normal typed/JSON conversion below.
//
// Left unchanged for anything that *isn't* Promise-or-thenable-shaped
// (primitives, plain records/lists, etc.): the `!value.isObject()` fast path
// costs nothing extra, matching the pre-existing synchronous validation, and
// even for a plain object return value the only extra cost is one property
// lookup for the (non-callable, non-existent on ordinary records) `then`
// property.
//
// `result_is_wit_result` must be true iff the export's own return type is
// directly a WIT `result<T, E>` (see js_dispatch.h/starling_js_dispatch_native
// for the synchronous-throw half of this same convention). Re-verified
// directly against the pinned ComponentizeJS 0.21.0 reference (not assumed):
// a rejected Promise is indistinguishable there from a synchronous throw at
// this boundary -- both simply become the `err` payload, decoded/validated
// exactly like any other value of type `E`, and both trap if that decode
// fails (wrong JS kind for `E`), not just for a mismatched throw. `E == void`
// never even inspects the payload (see js_dispatch.zig's `callNative`), so
// *any* rejection reason -- of *any* shape -- becomes a bare `Err()` there.
// See manifest.json known_deviations "promise-result-rejection-matches-throw"
// for the differential evidence (tests/compat/fixtures/promises-result) this
// was checked against, gathered through the real Wasmtime 42 CLI.
//
// Returns true with `value` updated in place to either the fulfilled result,
// or (only when `result_is_wit_result` and the Promise rejected)
// `*out_is_err_rejection` set and `value` set to the raw rejection reason for
// the caller to decode as the `Err(E)` payload, exactly like a synchronous
// throw. Returns false if the Promise rejected while `result_is_wit_result`
// is false, deadlocked (no further microtask/task progress possible while
// still pending -- a deterministic diagnostic, never a hang, and never
// reinterpreted as `Err` regardless of `result_is_wit_result`: an event-loop
// no-progress/reentrancy failure has no ComponentizeJS equivalent to defer
// to), or the event loop was already being pumped by an outer/reentrant
// call; in every false case, a description has already been dumped to
// stderr, so the caller should simply propagate failure (return 1) without
// any further reporting.
bool resolve_promise_like(JSContext *cx, const char *function_name, bool result_is_wit_result,
                          JS::MutableHandleValue value, bool *out_is_err_rejection) {
  *out_is_err_rejection = false;
  if (!value.isObject()) {
    return true;
  }

  JS::RootedObject obj(cx, &value.toObject());
  JS::RootedObject promise(cx);
  if (JS::IsPromiseObject(obj)) {
    promise = obj;
  } else {
    JS::RootedValue then_val(cx);
    if (!JS_GetProperty(cx, obj, "then", &then_val)) {
      api::Engine::dump_pending_exception(
          "probing a JavaScript export's return value for a Promise/thenable shape");
      return false;
    }
    if (!then_val.isObject() || !JS::IsCallable(&then_val.toObject())) {
      return true; // Not thenable: `value` is the final result, unchanged.
    }
    // Normalize via the engine's own spec-compliant Promise resolution
    // machinery (`JS::ResolvePromise` performs the same duck-typed
    // "thenable" chaining `await`/`Promise.resolve` use), rather than
    // hand-rolling a `then` call: this correctly handles nested thenables,
    // a `then` that itself throws, etc. without reimplementing any of it.
    JS::RootedObject wrapper(cx, JS::NewPromiseObject(cx, nullptr));
    if (!wrapper || !JS::ResolvePromise(cx, wrapper, value)) {
      api::Engine::dump_pending_exception(
          "normalizing a thenable JavaScript return value into a Promise");
      return false;
    }
    promise = wrapper;
  }

  api::Engine *engine = api::Engine::get(cx);
  if (JS::GetPromiseState(promise) == JS::PromiseState::Pending) {
    switch (core::EventLoop::pump_until_promise_settled(engine, promise)) {
    case core::PromisePumpResult::Settled:
      break;
    case core::PromisePumpResult::JSException:
      api::Engine::dump_pending_exception(
          "running a JavaScript export's Promise to completion");
      return false;
    case core::PromisePumpResult::NoProgress:
      std::println(stderr,
                   "Error: synchronous component export '{}' returned a Promise that "
                   "never settled -- the JavaScript job queue and async task queue "
                   "both ran empty while it was still pending (deadlock)",
                   function_name);
      return false;
    case core::PromisePumpResult::AlreadyRunning:
      std::println(stderr,
                   "Error: synchronous component export '{}' returned a Promise, but "
                   "the event loop is already being pumped by another call "
                   "(reentrant dispatch is not supported)",
                   function_name);
      return false;
    }
  }

  JS::PromiseState state = JS::GetPromiseState(promise);
  if (state == JS::PromiseState::Rejected) {
    JS::RootedValue reason(cx, JS::GetPromiseResult(promise));
    if (result_is_wit_result) {
      // Mirrors starling_js_dispatch_native's synchronous err-via-throw
      // path exactly: the rejection reason becomes the raw `Err(E)` payload
      // for the caller to decode, not a hard failure. `reason` is handed
      // back as-is (not re-validated here) -- the caller's decode step is
      // exactly the same one a synchronous throw already goes through, so
      // a wrong-kind `reason` traps there, identically either way.
      value.set(reason);
      *out_is_err_rejection = true;
      return true;
    }
    engine->dump_promise_rejection(reason, promise, stderr);
    return false;
  }

  value.set(JS::GetPromiseResult(promise));
  return true;
}

} // namespace

extern "C" uint32_t starling_js_dispatch(const uint8_t *export_name_ptr,
                                         size_t export_name_len,
                                         const uint8_t *args_json_ptr,
                                         size_t args_json_len,
                                         StarlingJSDispatchResult *result) {
  result->ptr = nullptr;
  result->len = 0;

  JSContext *cx = api::Engine::cx();
  if (!cx) {
    return 1;
  }
  JSAutoRealm realm(cx, api::Engine::global());

  JS::RootedValue function(cx);
  const char *error_context = "resolving a JavaScript module export";
  std::string function_name;
  if (!resolve_export_function(cx, &function, export_name_ptr, export_name_len,
                               &error_context, &function_name)) {
    return dispatch_error(cx, error_context);
  }

  JS::RootedString args_json(
      cx, core::decode(cx, std::string_view(reinterpret_cast<const char *>(args_json_ptr),
                                            args_json_len)));
  if (!args_json) {
    return dispatch_error(cx, "decoding JavaScript arguments");
  }

  JS::RootedValue parsed_args(cx);
  if (!JS_ParseJSON(cx, args_json, &parsed_args)) {
    return dispatch_error(cx, "parsing JavaScript arguments");
  }

  bool is_array = false;
  if (!JS::IsArrayObject(cx, parsed_args, &is_array)) {
    return dispatch_error(cx, "checking JavaScript arguments");
  }
  if (!is_array) {
    JS_ReportErrorASCII(cx, "JavaScript dispatch arguments must be a JSON array");
    return dispatch_error(cx, "checking JavaScript arguments");
  }

  JS::RootedObject args_array(cx, &parsed_args.toObject());
  uint32_t argc = 0;
  if (!JS::GetArrayLength(cx, args_array, &argc)) {
    return dispatch_error(cx, "reading JavaScript arguments");
  }

  JS::RootedValueVector argv(cx);
  if (!argv.reserve(argc)) {
    JS_ReportOutOfMemory(cx);
    return dispatch_error(cx, "allocating JavaScript arguments");
  }
  for (uint32_t i = 0; i < argc; ++i) {
    JS::RootedValue arg(cx);
    if (!JS_GetElement(cx, args_array, i, &arg) || !argv.append(arg)) {
      return dispatch_error(cx, "reading JavaScript arguments");
    }
  }

  JS::RootedValue return_value(cx);
  if (!JS::Call(cx, JS::UndefinedHandleValue, function, argv, &return_value)) {
    return dispatch_error(cx, "calling a JavaScript module export");
  }
  // The JSON bridge never carries a top-level WIT `result<T, E>` export (see
  // js_dispatch.zig's typeNeedsNative: any `result`/variant unconditionally
  // routes through the native bridge below instead), so a rejected Promise
  // here is always a hard failure -- `result_is_wit_result` is always false.
  bool unused_is_err_rejection = false;
  if (!resolve_promise_like(cx, function_name.c_str(), false, &return_value,
                            &unused_is_err_rejection)) {
    return 1;
  }

  JsonBuffer json{cx, {}};
  if (!JS_Stringify(cx, &return_value, nullptr, JS::NullHandleValue, write_json, &json)) {
    return dispatch_error(cx, "serializing a JavaScript return value");
  }

  auto *bytes =
      static_cast<uint8_t *>(std::malloc(json.bytes.empty() ? 1 : json.bytes.size()));
  if (!bytes) {
    JS_ReportOutOfMemory(cx);
    return dispatch_error(cx, "allocating a JavaScript return value");
  }
  if (!json.bytes.empty()) {
    std::memcpy(bytes, json.bytes.data(), json.bytes.size());
  }
  result->ptr = bytes;
  result->len = json.bytes.size();
  return 0;
}

extern "C" void starling_dispatch_result_free(void *ptr) { std::free(ptr); }

// ---------------------------------------------------------------------------
// Typed native dispatch bridge (see js_dispatch.h for the wire vocabulary and
// the import/resource-reversal notes).

namespace {

// Owns every allocation made while building a *result* tree so the whole
// thing can be released in one call. Argument trees (the other direction)
// are owned by the Zig caller's own arena instead -- this side never mutates
// or frees them, only reads.
struct NativeArena {
  std::vector<std::unique_ptr<StarlingJsValue>> boxed_values;
  std::vector<std::unique_ptr<StarlingJsField[]>> field_arrays;
  std::vector<std::unique_ptr<uint8_t[]>> byte_buffers;
  std::vector<std::unique_ptr<StarlingJsValue[]>> list_arrays;

  const StarlingJsValue *box(StarlingJsValue v) {
    boxed_values.push_back(std::make_unique<StarlingJsValue>(v));
    return boxed_values.back().get();
  }
  StarlingJsField *fields(size_t n) {
    field_arrays.push_back(std::make_unique<StarlingJsField[]>(n));
    return field_arrays.back().get();
  }
  const uint8_t *copy_bytes(const char *data, size_t len) {
    auto buf = std::make_unique<uint8_t[]>(len);
    if (len > 0) {
      std::memcpy(buf.get(), data, len);
    }
    byte_buffers.push_back(std::move(buf));
    return byte_buffers.back().get();
  }
  // A contiguous array of `n` list-item nodes (tag == LIST); unlike record
  // fields these are unnamed, so no `StarlingJsField` wrapper is needed.
  StarlingJsValue *list_items(size_t n) {
    list_arrays.push_back(std::make_unique<StarlingJsValue[]>(n));
    return list_arrays.back().get();
  }
};

// Encodes one `StarlingJsValue` leaf/subtree to a rooted JS value. Each
// recursive call roots its own intermediates in its own C++ stack frame
// (`JS::Rooted*` locals), so nothing an ancestor frame already produced and
// is holding live (its own `JS::Rooted*`/`MutableHandleValue` out-param) can
// be collected out from under it -- the usual SpiderMonkey stack-rooting
// discipline, just applied recursively instead of linearly.
bool encode_to_js(JSContext *cx, const StarlingJsValue &v, JS::MutableHandleValue out) {
  switch (v.tag) {
  case STARLING_JS_BOOL:
    out.setBoolean(v.bool_val != 0);
    return true;
  case STARLING_JS_I64: {
    JS::BigInt *bi = JS::NumberToBigInt<int64_t>(cx, v.i64_val);
    if (!bi) {
      return false;
    }
    out.setBigInt(bi);
    return true;
  }
  case STARLING_JS_U64: {
    JS::BigInt *bi = JS::NumberToBigInt<uint64_t>(cx, v.u64_val);
    if (!bi) {
      return false;
    }
    out.setBigInt(bi);
    return true;
  }
  case STARLING_JS_F64:
    out.setDouble(v.f64_val);
    return true;
  case STARLING_JS_STRING: {
    JS::RootedString str(
        cx, core::decode(cx, std::string_view(reinterpret_cast<const char *>(v.str_ptr),
                                              v.str_len)));
    if (!str) {
      return false;
    }
    out.setString(str);
    return true;
  }
  case STARLING_JS_BYTES: {
    JS::RootedObject array(cx, JS_NewUint8Array(cx, v.str_len));
    if (!array) {
      return false;
    }
    if (v.str_len > 0) {
      bool is_shared = false;
      JS::AutoCheckCannotGC nogc(cx);
      uint8_t *data = JS_GetUint8ArrayData(array, &is_shared, nogc);
      std::memcpy(data, v.str_ptr, v.str_len);
    }
    out.setObject(*array);
    return true;
  }
  case STARLING_JS_OPTION_NONE:
    out.setNull();
    return true;
  case STARLING_JS_OPTION_SOME:
    if (!v.option_ptr) {
      JS_ReportErrorASCII(cx, "native dispatch: option marked present but missing a value");
      return false;
    }
    return encode_to_js(cx, *v.option_ptr, out);
  case STARLING_JS_RECORD: {
    JS::RootedObject obj(cx, JS_NewPlainObject(cx));
    if (!obj) {
      return false;
    }
    for (size_t i = 0; i < v.fields_len; ++i) {
      const StarlingJsField &field = v.fields_ptr[i];
      if (!field.value) {
        JS_ReportErrorASCII(cx, "native dispatch: record field missing a value");
        return false;
      }
      JS::RootedValue field_value(cx);
      if (!encode_to_js(cx, *field.value, &field_value)) {
        return false;
      }
      std::string name(reinterpret_cast<const char *>(field.name_ptr), field.name_len);
      if (!JS_SetProperty(cx, obj, name.c_str(), field_value)) {
        return false;
      }
    }
    out.setObject(*obj);
    return true;
  }
  case STARLING_JS_LIST: {
    JS::RootedObject arr(cx, JS::NewArrayObject(cx, v.list_len));
    if (!arr) {
      return false;
    }
    for (size_t i = 0; i < v.list_len; ++i) {
      JS::RootedValue item_value(cx);
      if (!encode_to_js(cx, v.list_ptr[i], &item_value)) {
        return false;
      }
      if (!JS_DefineElement(cx, arr, i, item_value, JSPROP_ENUMERATE)) {
        return false;
      }
    }
    out.setObject(*arr);
    return true;
  }
  case STARLING_JS_UNDEFINED:
    out.setUndefined();
    return true;
  }
  JS_ReportErrorASCII(cx, "native dispatch: unrecognized argument tag");
  return false;
}

// Decodes a JS value into a generic `StarlingJsValue` tree, allocated from
// `arena`. This side doesn't know the WIT/Zig target type (that's only known
// on the Zig side, at comptime) -- it just reflects the JS value's actual
// runtime shape, the same way `JS_Stringify` does for the JSON bridge. The
// Zig-side `decodeNative` then maps this generic tree onto the concrete
// `Result` type by field name, the same way `std.json.parseFromSliceLeaky`
// does today.
bool decode_from_js(JSContext *cx, JS::HandleValue v, NativeArena &arena, StarlingJsValue *out) {
  if (v.isNullOrUndefined()) {
    *out = {.tag = STARLING_JS_OPTION_NONE};
    return true;
  }
  if (v.isBoolean()) {
    *out = {.tag = STARLING_JS_BOOL, .bool_val = static_cast<uint8_t>(v.toBoolean())};
    return true;
  }
  if (v.isBigInt()) {
    // A JS export's own return value is lowered into the wasm ABI the same
    // way the real ComponentizeJS/Wasmtime canonical-ABI JS embedding does:
    // per the ECMAScript `ToBigInt64`/`ToBigUint64` abstract operations, an
    // out-of-domain (too large, or negative for u64) BigInt result *wraps*
    // modulo 2**64, it does not throw/trap (empirically re-verified against
    // the pinned ComponentizeJS 0.21.0 reference itself for this exact
    // shape -- see tests/compat/manifest.json known_deviations
    // integer-64-bit-precision and tests/compat/fixtures/integers-64bit's
    // "sum-list-basic" case, which deliberately sums past u64::MAX and
    // expects the wrapped result, matching both pipelines). `ToBigInt64`/
    // `ToBigUint64` compute exactly that modulo-2**64 reinterpretation, so
    // both fields are always populated unconditionally; there is no
    // "doesn't fit" case to reject here. `bigint_fits_i64`/`bigint_fits_u64`
    // /`bigint_is_negative` are kept only as diagnostic metadata (unused by
    // the current Zig-side decode, which now always accepts any BigInt of
    // the correct sign-domain kind), not as a trap gate.
    JS::BigInt *bi = v.toBigInt();
    int64_t i64_out = JS::ToBigInt64(bi);
    uint64_t u64_out = JS::ToBigUint64(bi);
    int64_t fit_probe = 0;
    uint64_t fit_probe_u = 0;
    bool fits_i64 = JS::BigIntFits<int64_t>(bi, &fit_probe);
    bool fits_u64 = JS::BigIntFits<uint64_t>(bi, &fit_probe_u);
    *out = {.tag = STARLING_JS_U64,
            .i64_val = i64_out,
            .u64_val = u64_out,
            .bigint_is_negative = static_cast<uint8_t>(JS::BigIntIsNegative(bi)),
            .bigint_fits_i64 = static_cast<uint8_t>(fits_i64),
            .bigint_fits_u64 = static_cast<uint8_t>(fits_u64)};
    return true;
  }
  if (v.isNumber()) {
    // `i64_val`/`u64_val` are left zeroed here (not derived from `d`): a
    // JS `Number` result is only ever decoded by Zig's non-64-bit integer
    // path, which validates range/integrality directly against `f64_val`
    // (see `decodeNative`). Computing an `int64_t` cast of `d` here would be
    // undefined behavior for any `d` outside the int64 range (e.g. `1e300`),
    // and this tag is never used for exact 64-bit results (those are
    // `isBigInt()` above), so there is nothing useful to precompute.
    double d = v.toNumber();
    *out = {.tag = STARLING_JS_F64, .f64_val = d};
    return true;
  }
  if (v.isString()) {
    JS::RootedString str(cx, v.toString());
    auto utf8 = core::encode(cx, str);
    if (!utf8.ptr) {
      return false;
    }
    const uint8_t *bytes = arena.copy_bytes(utf8.ptr.get(), utf8.len);
    *out = {.tag = STARLING_JS_STRING, .str_ptr = bytes, .str_len = utf8.len};
    return true;
  }
  if (v.isObject()) {
    JS::RootedObject obj(cx, &v.toObject());

    // A `Uint8Array` must be detected before both the Array check and the
    // generic own-property-keys walk below: it is not itself a JS Array
    // (`JS::IsArrayObject` is false for it), so it would otherwise fall
    // through to the generic object walk, which would enumerate its integer
    // indices as string-ish own properties. ComponentizeJS always lifts a
    // WIT `list<u8>` argument to a real `Uint8Array` (never a plain Array),
    // so recognizing one here lets `decodeNative`'s `wit_types.ByteList`
    // path distinguish an actual byte-list result from any other JS array.
    if (JS_IsUint8Array(obj)) {
      uint8_t *data = nullptr;
      bool is_shared = false;
      size_t len = 0;
      if (!JS_GetObjectAsUint8Array(obj, &len, &is_shared, &data)) {
        JS_ReportErrorASCII(cx, "native dispatch: could not read a Uint8Array return value");
        return false;
      }
      const uint8_t *bytes = arena.copy_bytes(reinterpret_cast<const char *>(data), len);
      *out = {.tag = STARLING_JS_BYTES, .str_ptr = bytes, .str_len = len};
      return true;
    }

    // Arrays must be detected *before* the generic own-property-keys walk
    // below: `js::GetPropertyKeys` would enumerate a dense array's elements
    // as integer-valued jsids, which `id.isString()` then filters out
    // entirely (they're not string keys) -- silently coercing every JS
    // array into an empty `STARLING_JS_RECORD` and dropping its contents.
    // WIT `list<T>` results must decode to `STARLING_JS_LIST` instead.
    bool is_array = false;
    if (!JS::IsArrayObject(cx, obj, &is_array)) {
      return false;
    }
    if (is_array) {
      uint32_t len = 0;
      if (!JS::GetArrayLength(cx, obj, &len)) {
        return false;
      }
      StarlingJsValue *items = arena.list_items(len);
      for (uint32_t i = 0; i < len; ++i) {
        JS::RootedValue item_value(cx);
        if (!JS_GetElement(cx, obj, i, &item_value)) {
          return false;
        }
        if (!decode_from_js(cx, item_value, arena, &items[i])) {
          return false;
        }
      }
      *out = {.tag = STARLING_JS_LIST, .list_ptr = items, .list_len = len};
      return true;
    }

    JS::RootedIdVector ids(cx);
    if (!js::GetPropertyKeys(cx, obj, JSITER_OWNONLY, &ids)) {
      return false;
    }
    StarlingJsField *fields = arena.fields(ids.length());
    size_t n = 0;
    for (size_t i = 0; i < ids.length(); ++i) {
      const auto &id = ids[i];
      if (!id.isString()) {
        continue; // skip symbol/index keys; WIT records are string-keyed.
      }
      JS::RootedValue field_value(cx);
      if (!JS_GetPropertyById(cx, obj, id, &field_value)) {
        return false;
      }
      StarlingJsValue *nested = new StarlingJsValue{};
      arena.boxed_values.emplace_back(nested);
      if (!decode_from_js(cx, field_value, arena, nested)) {
        return false;
      }
      JS::RootedString name_str(cx, id.toString());
      auto name_utf8 = core::encode(cx, name_str);
      if (!name_utf8.ptr) {
        return false;
      }
      fields[n++] = {.name_ptr = arena.copy_bytes(name_utf8.ptr.get(), name_utf8.len),
                     .name_len = name_utf8.len,
                     .value = nested};
    }
    *out = {.tag = STARLING_JS_RECORD, .fields_ptr = fields, .fields_len = n};
    return true;
  }
  JS_ReportErrorASCII(cx, "native dispatch: unsupported JavaScript return value shape");
  return false;
}

} // namespace

extern "C" uint32_t starling_js_dispatch_native(const uint8_t *export_name_ptr,
                                                size_t export_name_len,
                                                const StarlingJsValue *args_ptr, size_t args_len,
                                                uint8_t result_is_wit_result,
                                                StarlingJsValue *out_result, void **out_arena) {
  *out_result = {};
  *out_arena = nullptr;

  JSContext *cx = api::Engine::cx();
  if (!cx) {
    return 1;
  }
  JSAutoRealm realm(cx, api::Engine::global());

  JS::RootedValue function(cx);
  const char *error_context = "resolving a JavaScript module export";
  std::string function_name;
  if (!resolve_export_function(cx, &function, export_name_ptr, export_name_len,
                               &error_context, &function_name)) {
    return dispatch_error(cx, error_context);
  }

  JS::RootedValueVector argv(cx);
  if (!argv.reserve(args_len)) {
    JS_ReportOutOfMemory(cx);
    return dispatch_error(cx, "allocating JavaScript arguments");
  }
  for (size_t i = 0; i < args_len; ++i) {
    JS::RootedValue arg(cx);
    if (!encode_to_js(cx, args_ptr[i], &arg) || !argv.append(arg)) {
      return dispatch_error(cx, "encoding a JavaScript argument");
    }
  }

  JS::RootedValue return_value(cx);
  if (!JS::Call(cx, JS::UndefinedHandleValue, function, argv, &return_value)) {
    // ComponentizeJS convention for an export whose own result type is a WIT
    // `result<T, E>`: a thrown value signals `err` (see js_dispatch.h). Only
    // take this path for a plain, still-pending JS exception -- not for the
    // (different, and rarer) cases where `JS::Call` fails without one, e.g.
    // an uncatchable OOM.
    if (result_is_wit_result != 0 && JS_IsExceptionPending(cx)) {
      JS::RootedValue thrown(cx);
      if (!JS_GetPendingException(cx, &thrown)) {
        return dispatch_error(cx, "calling a JavaScript module export");
      }
      JS_ClearPendingException(cx);
      auto *arena = new NativeArena();
      if (!decode_from_js(cx, thrown, *arena, out_result)) {
        delete arena;
        *out_arena = nullptr;
        return dispatch_error(cx, "decoding a thrown JavaScript error value");
      }
      *out_arena = arena;
      return 2;
    }
    return dispatch_error(cx, "calling a JavaScript module export");
  }
  bool is_err_rejection = false;
  if (!resolve_promise_like(cx, function_name.c_str(), result_is_wit_result != 0, &return_value,
                            &is_err_rejection)) {
    return 1;
  }

  auto *arena = new NativeArena();
  if (is_err_rejection) {
    // See resolve_promise_like/js_dispatch.h: a rejected Promise on a
    // result_is_wit_result export is decoded as the `Err(E)` payload here,
    // exactly like the synchronous-throw case above (status 2), not treated
    // as a dispatch failure.
    if (!decode_from_js(cx, return_value, *arena, out_result)) {
      delete arena;
      *out_arena = nullptr;
      return dispatch_error(cx, "decoding a rejected Promise's reason as a WIT result<T, E> error value");
    }
    *out_arena = arena;
    return 2;
  }
  if (!decode_from_js(cx, return_value, *arena, out_result)) {
    delete arena;
    *out_arena = nullptr;
    return dispatch_error(cx, "decoding a JavaScript return value");
  }
  *out_arena = arena;
  return 0;
}

extern "C" void starling_js_dispatch_native_free(void *arena) {
  delete static_cast<NativeArena *>(arena);
}

// ---------------------------------------------------------------------------
// Reverse bridge: host-provided WIT interface imports called *from*
// JavaScript (see js_dispatch.h for the wire-level contract). Weak fallbacks
// below let a build with nothing to bridge -- no `--js-imports`, or no
// eligible interface imports -- link without any Zig-generated definitions
// at all; a strong `pub export fn` from the generated `component_bindings.zig`
// (see component_bindgen.zig's `emitJsImportBridge`) overrides these at link
// time whenever there is at least one such import.
extern "C" __attribute__((weak)) const uint8_t *starling_js_imports_manifest(size_t *out_len) {
  *out_len = 0;
  return nullptr;
}

extern "C" __attribute__((weak)) uint32_t starling_js_import_dispatch(
    const uint8_t *name_ptr, size_t name_len, const StarlingJsValue *argv_ptr, size_t argv_len,
    StarlingJsValue *out_result, void **out_arena) {
  (void)name_ptr;
  (void)name_len;
  (void)argv_ptr;
  (void)argv_len;
  *out_result = {};
  *out_arena = nullptr;
  return 1; // no JS-bridged imports exist in this build.
}

extern "C" __attribute__((weak)) void starling_js_import_result_free(void *arena) { (void)arena; }

namespace {

// Bound as reserved slot 1 (`extra`) of each per-import JSFunction created by
// `wit_imports::install` below; forwards the call to the dispatch key it was
// registered under, reusing `decode_from_js`/`encode_to_js` -- the same pair
// used for export arguments/results -- with the roles reversed: arguments
// come *from* JS (decode) and the result goes back *to* JS (encode).
bool call_import(JSContext *cx, JS::HandleObject receiver, JS::HandleValue extra,
                 JS::CallArgs args) {
  (void)receiver;
  JS::RootedString key_str(cx, extra.toString());
  auto key_utf8 = core::encode(cx, key_str);
  if (!key_utf8.ptr) {
    return false;
  }
  std::string dispatch_key(key_utf8.ptr.get(), key_utf8.len);

  NativeArena arg_arena;
  std::vector<StarlingJsValue> argv;
  argv.reserve(args.length());
  for (unsigned i = 0; i < args.length(); ++i) {
    JS::RootedValue arg(cx, args.get(i));
    StarlingJsValue encoded{};
    if (!decode_from_js(cx, arg, arg_arena, &encoded)) {
      return false;
    }
    argv.push_back(encoded);
  }
  static const StarlingJsValue no_args{};
  const StarlingJsValue *argv_ptr = argv.empty() ? &no_args : argv.data();

  StarlingJsValue out_result{};
  void *out_arena = nullptr;
  uint32_t status = starling_js_import_dispatch(
      reinterpret_cast<const uint8_t *>(dispatch_key.data()), dispatch_key.size(), argv_ptr,
      argv.size(), &out_result, &out_arena);
  if (status != 0) {
    // Build-time-impossible in practice (the dispatch key came straight from
    // the manifest this function was registered from), but reported
    // explicitly rather than silently returning `undefined` in case the
    // manifest and dispatch table ever disagree.
    JS_ReportErrorUTF8(cx,
                       "no host import is registered for '%s' -- the component's world does "
                       "not declare a matching import, or the host did not link an "
                       "implementation for it",
                       dispatch_key.c_str());
    return false;
  }

  JS::RootedValue result_val(cx);
  bool ok = encode_to_js(cx, out_result, &result_val);
  starling_js_import_result_free(out_arena);
  if (!ok) {
    return false;
  }
  args.rval().set(result_val);
  return true;
}

// Splits one manifest TSV line "<module-id>\t<js-name>\t<dispatch-key>\t<arity>"
// into its four columns. Returns false (rather than asserting) on a
// malformed line so a corrupt/mismatched manifest is an actionable JS
// exception rather than an out-of-bounds read.
bool parse_manifest_line(std::string_view line, std::string_view *module_id,
                         std::string_view *js_name, std::string_view *dispatch_key,
                         unsigned *arity) {
  size_t t1 = line.find('\t');
  if (t1 == std::string_view::npos) return false;
  size_t t2 = line.find('\t', t1 + 1);
  if (t2 == std::string_view::npos) return false;
  size_t t3 = line.find('\t', t2 + 1);
  if (t3 == std::string_view::npos) return false;

  *module_id = line.substr(0, t1);
  *js_name = line.substr(t1 + 1, t2 - t1 - 1);
  *dispatch_key = line.substr(t2 + 1, t3 - t2 - 1);
  if (module_id->empty() || js_name->empty() || dispatch_key->empty()) return false;
  std::string_view arity_str = line.substr(t3 + 1);
  unsigned value = 0;
  for (char c : arity_str) {
    if (c < '0' || c > '9') return false;
    value = value * 10 + static_cast<unsigned>(c - '0');
  }
  *arity = value;
  return true;
}

} // namespace

namespace builtins {
namespace wit_imports {

// Registers one builtin ES module per manifest module id. Interface imports
// expose their verbatim WIT function names (for example
// `import { "get-flag" as getFlag } from "test:flags/imports@1.2.3"`).
// World-level function imports use module=<WIT function>, export=default, so
// `import addOne from "add-one"` matches ComponentizeJS 0.21. Runs during
// `install_builtins`, before content scripts' top-level imports execute.
bool install(api::Engine *engine) {
  JSContext *cx = engine->cx();
  size_t manifest_len = 0;
  const uint8_t *manifest_ptr = starling_js_imports_manifest(&manifest_len);
  if (!manifest_ptr || manifest_len == 0) {
    return true; // Nothing to bridge -- default behavior is unaffected.
  }
  std::string_view manifest(reinterpret_cast<const char *>(manifest_ptr), manifest_len);

  std::string current_id;
  JS::RootedObject current_obj(cx);

  size_t pos = 0;
  while (pos < manifest.size()) {
    size_t nl = manifest.find('\n', pos);
    if (nl == std::string_view::npos) break;
    std::string_view line = manifest.substr(pos, nl - pos);
    pos = nl + 1;
    if (line.empty()) continue;

    std::string_view module_id, js_name, dispatch_key;
    unsigned arity = 0;
    if (!parse_manifest_line(line, &module_id, &js_name, &dispatch_key, &arity)) {
      JS_ReportErrorUTF8(cx, "malformed js_import_manifest line: '%.*s'", (int)line.size(),
                         line.data());
      return false;
    }

    if (current_id.empty() || current_id != module_id) {
      if (!current_id.empty()) {
        JS::RootedValue module_val(cx, JS::ObjectValue(*current_obj));
        if (!engine->define_builtin_module(current_id.c_str(), module_val)) {
          return false;
        }
      }
      current_id.assign(module_id);
      current_obj = JS_NewPlainObject(cx);
      if (!current_obj) {
        return false;
      }
    }

    std::string dispatch_key_str(dispatch_key);
    JS::RootedString key_str(cx,
                             JS_NewStringCopyN(cx, dispatch_key_str.data(), dispatch_key_str.size()));
    if (!key_str) {
      return false;
    }
    JS::RootedValue extra(cx, JS::StringValue(key_str));
    std::string js_name_str(js_name);
    JS::RootedObject method(cx, create_internal_method<call_import>(cx, current_obj, extra, arity,
                                                                    js_name_str.c_str()));
    if (!method) {
      return false;
    }
    JS::RootedValue method_val(cx, JS::ObjectValue(*method));
    if (!JS_DefineProperty(cx, current_obj, js_name_str.c_str(), method_val, JSPROP_ENUMERATE)) {
      return false;
    }
  }

  if (!current_id.empty()) {
    JS::RootedValue module_val(cx, JS::ObjectValue(*current_obj));
    if (!engine->define_builtin_module(current_id.c_str(), module_val)) {
      return false;
    }
  }
  return true;
}

} // namespace wit_imports
} // namespace builtins
