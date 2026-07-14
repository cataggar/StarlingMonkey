#include "js_dispatch.h"

#include "extension-api.h"
#include "decode.h"

#include "js/Array.h"
#include "js/CallAndConstruct.h"
#include "js/CharacterEncoding.h"
#include "js/JSON.h"
#include "js/Promise.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>

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
  JS::RootedValue module_namespace(cx, api::Engine::script_value());
  if (!module_namespace.isObject()) {
    JS_ReportErrorASCII(cx, "the top-level JavaScript module has no namespace");
    return dispatch_error(cx, "resolving the JavaScript module namespace");
  }

  std::string_view export_name(reinterpret_cast<const char *>(export_name_ptr),
                               export_name_len);
  size_t separator = export_name.rfind('#');
  std::string function_name(
      separator == std::string_view::npos ? export_name : export_name.substr(separator + 1));

  JS::RootedObject namespace_object(cx, &module_namespace.toObject());
  JS::RootedValue function(cx);
  if (!JS_GetProperty(cx, namespace_object, function_name.c_str(), &function)) {
    return dispatch_error(cx, "resolving a JavaScript module export");
  }
  if (!function.isObject() || !JS::IsCallable(&function.toObject())) {
    JS_ReportErrorUTF8(cx, "JavaScript module export '%s' is not a function",
                       function_name.c_str());
    return dispatch_error(cx, "resolving a JavaScript module export");
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
