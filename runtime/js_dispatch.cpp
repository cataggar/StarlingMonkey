#include "js_dispatch.h"

#include "extension-api.h"
#include "decode.h"
#include "encode.h"

#include "js/Array.h"
#include "js/BigInt.h"
#include "js/CallAndConstruct.h"
#include "js/CharacterEncoding.h"
#include "js/JSON.h"
#include "js/Promise.h"
#include "js/PropertyAndElement.h"

#include <cstdlib>
#include <cstring>
#include <memory>
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

// Shared by both the JSON and the typed-native bridge: looks up
// `<top-level module>[function_name]` (the bare WIT function name, taken
// verbatim from after the last '#' of the qualified export name -- e.g.
// "starling:js/api#big-add" -> "big-add"; a module can expose that literal
// (non-identifier) name via `export { impl as "big-add" }`). Assumes `cx` is
// valid and its realm has already been entered by the caller.
bool resolve_export_function(JSContext *cx, JS::MutableHandleValue out_function,
                             const uint8_t *export_name_ptr, size_t export_name_len,
                             const char **error_context) {
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
  if (!JS_GetProperty(cx, namespace_object, function_name.c_str(), out_function)) {
    *error_context = "resolving a JavaScript module export";
    return false;
  }
  if (!out_function.isObject() || !JS::IsCallable(&out_function.toObject())) {
    JS_ReportErrorUTF8(cx, "JavaScript module export '%s' is not a function",
                       function_name.c_str());
    *error_context = "resolving a JavaScript module export";
    return false;
  }
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
  if (!resolve_export_function(cx, &function, export_name_ptr, export_name_len,
                               &error_context)) {
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
  if (return_value.isObject()) {
    JS::RootedObject return_object(cx, &return_value.toObject());
    if (JS::IsPromiseObject(return_object)) {
      JS_ReportErrorASCII(cx, "synchronous component exports cannot return a Promise");
      return dispatch_error(cx, "calling a JavaScript module export");
    }
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
    // `ToBigInt64`/`ToBigUint64` only reinterpret bits (they don't report
    // whether the BigInt actually fits the target domain), so use the
    // exact-fit queries instead: they report both the precise value and
    // whether the BigInt's true mathematical value fits, letting the Zig
    // side validate the full s64/u64 domains without being fooled by two's
    // complement wraparound (see the field comments in js_dispatch.h).
    JS::BigInt *bi = v.toBigInt();
    int64_t i64_out = 0;
    uint64_t u64_out = 0;
    bool fits_i64 = JS::BigIntFits<int64_t>(bi, &i64_out);
    bool fits_u64 = JS::BigIntFits<uint64_t>(bi, &u64_out);
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
  if (!resolve_export_function(cx, &function, export_name_ptr, export_name_len,
                               &error_context)) {
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
    return dispatch_error(cx, "calling a JavaScript module export");
  }
  if (return_value.isObject()) {
    JS::RootedObject return_object(cx, &return_value.toObject());
    if (JS::IsPromiseObject(return_object)) {
      JS_ReportErrorASCII(cx, "synchronous component exports cannot return a Promise");
      return dispatch_error(cx, "calling a JavaScript module export");
    }
  }

  auto *arena = new NativeArena();
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
