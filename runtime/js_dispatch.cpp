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

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <print>
#include <string>
#include <string_view>
#include <vector>

namespace {

struct JsonBuffer {
  JSContext *cx;
  std::string bytes;
};

enum class ExportResourceOperationKind {
  Constructor,
  Method,
  Static,
};

struct ExportResourceClassBinding {
  std::string provider;
  std::string name;
  std::string class_name;
  std::unique_ptr<JS::PersistentRootedObject> constructor;
  std::unique_ptr<JS::PersistentRootedObject> prototype;
};

struct ExportResourceOperationBinding {
  ExportResourceOperationKind kind;
  std::string dispatch_key;
  std::string js_name;
  ExportResourceClassBinding *resource;
  std::unique_ptr<JS::PersistentRootedValue> function;
};

struct ExportedResourceEntry {
  int32_t rep;
  std::string provider;
  std::string name;
  std::vector<ExportResourceClassBinding *> candidates;
  bool committed = false;
  bool prepared_owned_argument = false;
  bool canonical_dropped = false;
  std::unique_ptr<JS::PersistentRootedObject> object;
};

std::vector<std::unique_ptr<ExportResourceClassBinding>>
    export_resource_class_bindings;
std::vector<std::unique_ptr<ExportResourceOperationBinding>>
    export_resource_operation_bindings;
std::vector<std::unique_ptr<ExportedResourceEntry>> exported_resource_entries;
int32_t next_exported_resource_rep = 1;

ExportResourceClassBinding *export_resource_class(std::string_view provider,
                                                  std::string_view name) {
  for (const auto &binding : export_resource_class_bindings) {
    if (binding->provider == provider && binding->name == name) {
      return binding.get();
    }
  }
  return nullptr;
}

ExportResourceOperationBinding *
export_resource_operation(std::string_view dispatch_key) {
  for (const auto &binding : export_resource_operation_bindings) {
    if (binding->dispatch_key == dispatch_key) {
      return binding.get();
    }
  }
  return nullptr;
}

ExportedResourceEntry *exported_resource_entry(std::string_view provider,
                                               std::string_view name,
                                               int32_t rep) {
  for (const auto &entry : exported_resource_entries) {
    if (entry->rep == rep && entry->provider == provider &&
        entry->name == name) {
      return entry.get();
    }
  }
  return nullptr;
}

bool erase_exported_resource(std::string_view provider, std::string_view name,
                             int32_t rep, bool require_committed) {
  for (auto it = exported_resource_entries.begin();
       it != exported_resource_entries.end(); ++it) {
    const auto &entry = *it;
    if (entry->rep == rep && entry->provider == provider &&
        entry->name == name) {
      if (require_committed && !entry->committed) {
        return false;
      }
      if (require_committed && entry->prepared_owned_argument) {
        entry->canonical_dropped = true;
        return true;
      }
      exported_resource_entries.erase(it);
      return true;
    }
  }
  return false;
}

void rollback_exported_resource(int32_t rep) {
  for (auto it = exported_resource_entries.begin();
       it != exported_resource_entries.end(); ++it) {
    if ((*it)->rep == rep && !(*it)->committed) {
      exported_resource_entries.erase(it);
      return;
    }
  }
}

bool allocate_exported_resource_rep(JSContext *cx,
                                    const std::vector<ExportResourceClassBinding *> &candidates,
                                    JS::HandleObject object, int32_t *out_rep) {
  for (uint64_t attempts = 0;
       attempts < static_cast<uint64_t>(std::numeric_limits<int32_t>::max());
       ++attempts) {
    const int32_t candidate = next_exported_resource_rep;
    next_exported_resource_rep =
        candidate == std::numeric_limits<int32_t>::max() ? 1 : candidate + 1;
    bool used = false;
    for (const auto &entry : exported_resource_entries) {
      if (entry->rep == candidate) {
        used = true;
        break;
      }
    }
    if (used) {
      continue;
    }

    auto entry = std::make_unique<ExportedResourceEntry>();
    entry->rep = candidate;
    entry->candidates = candidates;
    entry->object =
        std::make_unique<JS::PersistentRootedObject>(cx, object);
    exported_resource_entries.push_back(std::move(entry));
    *out_rep = candidate;
    return true;
  }
  JS_ReportErrorASCII(cx,
                      "native dispatch: exhausted exported resource reps");
  return false;
}

bool exported_resource_classes_for_instance(
    JSContext *cx, JS::HandleObject object,
    std::vector<ExportResourceClassBinding *> *out_bindings) {
  JS::RootedValue value(cx, JS::ObjectValue(*object));
  out_bindings->clear();
  for (const auto &binding : export_resource_class_bindings) {
    JS::RootedObject constructor(cx, binding->constructor->get());
    bool matches = false;
    if (!JS_HasInstance(cx, constructor, value, &matches)) {
      return false;
    }
    if (matches) {
      out_bindings->push_back(binding.get());
    }
  }
  return true;
}

bool reclaim_pending_dispatch_arena();

void finish_prepared_exported_arguments() {
  for (auto it = exported_resource_entries.begin();
       it != exported_resource_entries.end();) {
    ExportedResourceEntry *entry = it->get();
    if (!entry->prepared_owned_argument) {
      ++it;
      continue;
    }
    if (entry->canonical_dropped) {
      it = exported_resource_entries.erase(it);
    } else {
      entry->prepared_owned_argument = false;
      ++it;
    }
  }
}

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
// tries literal names first for both interface namespaces and functions
// (preserving this bridge's original, already-tested convention -- a module
// can still expose a non-identifier name via `export { impl as "big-add" }`),
// and only falls back to camelCase when the literal property doesn't exist.
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

bool resolve_property_lookup(JSContext *cx, JS::HandleObject object, std::string_view literal_name,
                             std::string *lookup_name, bool *has_property) {
  *lookup_name = literal_name;
  if (!JS_HasOwnProperty(cx, object, lookup_name->c_str(), has_property)) {
    return false;
  }
  if (*has_property) {
    return true;
  }

  std::string camel_name = kebab_to_camel_case(literal_name);
  if (camel_name == literal_name) {
    return true;
  }
  *lookup_name = std::move(camel_name);
  return JS_HasOwnProperty(cx, object, lookup_name->c_str(), has_property);
}

bool resolve_export_namespace(JSContext *cx, std::string_view interface_id,
                              JS::MutableHandleObject out_namespace) {
  JS::RootedValue module_namespace(cx, api::Engine::script_value());
  if (!module_namespace.isObject()) {
    JS_ReportErrorASCII(cx, "the top-level JavaScript module has no namespace");
    return false;
  }

  size_t slash = interface_id.rfind('/');
  std::string_view interface_name =
      slash == std::string_view::npos ? interface_id
                                      : interface_id.substr(slash + 1);
  size_t version = interface_name.find('@');
  if (version != std::string_view::npos) {
    interface_name = interface_name.substr(0, version);
  }
  if (interface_name.empty()) {
    JS_ReportErrorASCII(cx, "invalid JavaScript export interface name");
    return false;
  }

  JS::RootedObject module(cx, &module_namespace.toObject());
  std::string literal_name(interface_name);
  std::string lookup_name;
  bool exists = false;
  if (!resolve_property_lookup(cx, module, interface_name, &lookup_name,
                               &exists)) {
    return false;
  }
  if (!exists) {
    JS_ReportErrorUTF8(
        cx, "JavaScript module does not export an '%s' interface namespace",
        literal_name.c_str());
    return false;
  }

  JS::RootedValue namespace_value(cx);
  if (!JS_GetProperty(cx, module, lookup_name.c_str(), &namespace_value)) {
    return false;
  }
  if (!namespace_value.isObject()) {
    JS_ReportErrorUTF8(
        cx, "JavaScript module export '%s' is not an interface namespace object",
        lookup_name.c_str());
    return false;
  }
  out_namespace.set(&namespace_value.toObject());
  return true;
}

// Shared by both dispatch bridges. WABT names root-function exports with
// their bare WIT name and interface functions as
// `<package>/<interface>[@version]#<function>`. Root functions are resolved
// directly on the module namespace. Interface functions are resolved
// through the matching JavaScript namespace object, e.g.
// `starling:js/api#big-add` -> `module.api.bigAdd`. This is the
// ComponentizeJS 0.21 export contract; an interface function must never
// fall back to a same-named flat module export.
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
  if (separator != std::string_view::npos) {
    std::string_view interface_id = export_name.substr(0, separator);
    if (function_name.empty()) {
      JS_ReportErrorASCII(cx, "invalid qualified JavaScript export name");
      *error_context = "parsing a qualified JavaScript module export";
      return false;
    }
    if (!resolve_export_namespace(cx, interface_id, &namespace_object)) {
      *error_context = "resolving a JavaScript interface namespace";
      return false;
    }
  }

  std::string lookup_name;
  bool has_function = false;
  if (!resolve_property_lookup(cx, namespace_object, function_name, &lookup_name, &has_function)) {
    *error_context = "resolving a JavaScript module export";
    return false;
  }
  if (!has_function) {
    JS_ReportErrorUTF8(cx, "JavaScript module does not export '%s'", function_name.c_str());
    *error_context = "resolving a JavaScript module export";
    return false;
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

extern "C" __attribute__((weak)) const uint8_t *starling_js_exports_manifest(size_t *out_len) {
  *out_len = 0;
  return nullptr;
}

std::vector<std::string_view> split_manifest_fields(std::string_view line) {
  std::vector<std::string_view> fields;
  size_t pos = 0;
  while (true) {
    const size_t tab = line.find('\t', pos);
    fields.push_back(line.substr(
        pos, tab == std::string_view::npos ? line.size() - pos : tab - pos));
    if (tab == std::string_view::npos) {
      return fields;
    }
    pos = tab + 1;
  }
}

bool starling_validate_required_exports() {
  size_t manifest_len = 0;
  const uint8_t *manifest_ptr = starling_js_exports_manifest(&manifest_len);
  if (manifest_len == 0) {
    return true;
  }

  JSContext *cx = api::Engine::cx();
  if (!cx || !manifest_ptr) {
    return false;
  }
  JSAutoRealm realm(cx, api::Engine::global());
  std::string_view manifest(reinterpret_cast<const char *>(manifest_ptr), manifest_len);

  export_resource_operation_bindings.clear();
  export_resource_class_bindings.clear();
  exported_resource_entries.clear();
  next_exported_resource_rep = 1;

  size_t resource_pos = 0;
  while (resource_pos < manifest.size()) {
    const size_t newline = manifest.find('\n', resource_pos);
    if (newline == std::string_view::npos) {
      JS_ReportErrorASCII(cx,
                          "malformed JavaScript export manifest: unterminated entry");
      return false;
    }
    const std::string_view line =
        manifest.substr(resource_pos, newline - resource_pos);
    resource_pos = newline + 1;
    const auto fields = split_manifest_fields(line);
    if (fields.empty() || fields[0] != "ER") {
      continue;
    }
    if (fields.size() != 4 || fields[1].empty() || fields[2].empty() ||
        fields[3].empty() || export_resource_class(fields[1], fields[2])) {
      JS_ReportErrorUTF8(cx,
                         "malformed or duplicate JavaScript exported resource "
                         "manifest entry '%.*s'",
                         static_cast<int>(line.size()), line.data());
      return false;
    }

    JS::RootedObject interface_namespace(cx);
    if (!resolve_export_namespace(cx, fields[1], &interface_namespace)) {
      return false;
    }
    std::string class_name(fields[3]);
    bool exists = false;
    if (!JS_HasOwnProperty(cx, interface_namespace, class_name.c_str(),
                           &exists)) {
      return false;
    }
    if (!exists) {
      JS_ReportErrorUTF8(
          cx, "JavaScript interface does not export resource class '%s'",
          class_name.c_str());
      return false;
    }

    JS::RootedValue constructor_value(cx);
    if (!JS_GetProperty(cx, interface_namespace, class_name.c_str(),
                        &constructor_value)) {
      return false;
    }
    if (!constructor_value.isObject() ||
        !JS::IsConstructor(&constructor_value.toObject())) {
      JS_ReportErrorUTF8(cx,
                         "JavaScript resource export '%s' is not a constructor",
                         class_name.c_str());
      return false;
    }
    JS::RootedObject constructor(cx, &constructor_value.toObject());
    JS::RootedValue prototype_value(cx);
    if (!JS_GetProperty(cx, constructor, "prototype", &prototype_value)) {
      return false;
    }
    if (!prototype_value.isObject()) {
      JS_ReportErrorUTF8(
          cx, "JavaScript resource export '%s' has no prototype object",
          class_name.c_str());
      return false;
    }

    auto binding = std::make_unique<ExportResourceClassBinding>();
    binding->provider = fields[1];
    binding->name = fields[2];
    binding->class_name = std::move(class_name);
    binding->constructor =
        std::make_unique<JS::PersistentRootedObject>(cx, constructor);
    binding->prototype = std::make_unique<JS::PersistentRootedObject>(
        cx, &prototype_value.toObject());
    export_resource_class_bindings.push_back(std::move(binding));
  }

  size_t pos = 0;
  while (pos < manifest.size()) {
    size_t newline = manifest.find('\n', pos);
    if (newline == std::string_view::npos) {
      JS_ReportErrorASCII(cx, "malformed JavaScript export manifest: unterminated entry");
      return false;
    }
    std::string_view line = manifest.substr(pos, newline - pos);
    pos = newline + 1;
    const auto fields = split_manifest_fields(line);
    if (!fields.empty() && fields[0] == "ER") {
      continue;
    }
    if (!fields.empty() &&
        (fields[0] == "EC" || fields[0] == "EM" ||
         fields[0] == "ES")) {
      if (fields.size() != 6 || fields[1].empty() || fields[2].empty() ||
          fields[3].empty() || fields[4].empty() || fields[5].empty()) {
        JS_ReportErrorUTF8(cx,
                           "malformed JavaScript exported resource operation "
                           "manifest entry '%.*s'",
                           static_cast<int>(line.size()), line.data());
        return false;
      }
      ExportResourceClassBinding *resource =
          export_resource_class(fields[1], fields[2]);
      if (!resource || export_resource_operation(fields[4])) {
        JS_ReportErrorUTF8(
            cx,
            "unknown resource or duplicate JavaScript exported resource "
            "operation '%.*s'",
            static_cast<int>(fields[4].size()), fields[4].data());
        return false;
      }

      const ExportResourceOperationKind kind =
          fields[0] == "EC"
              ? ExportResourceOperationKind::Constructor
              : fields[0] == "EM" ? ExportResourceOperationKind::Method
                                    : ExportResourceOperationKind::Static;
      JS::RootedValue function(cx);
      if (kind == ExportResourceOperationKind::Constructor) {
        function.setObject(*resource->constructor->get());
      } else {
        JS::RootedObject target(
            cx, kind == ExportResourceOperationKind::Method
                    ? resource->prototype->get()
                    : resource->constructor->get());
        std::string js_name(fields[3]);
        bool exists = false;
        if (!JS_HasOwnProperty(cx, target, js_name.c_str(), &exists)) {
          return false;
        }
        if (!exists ||
            !JS_GetProperty(cx, target, js_name.c_str(), &function) ||
            !function.isObject() ||
            !JS::IsCallable(&function.toObject())) {
          JS_ReportErrorUTF8(
              cx, "JavaScript resource member '%s.%s' is not callable",
              resource->class_name.c_str(), js_name.c_str());
          return false;
        }
      }

      auto operation = std::make_unique<ExportResourceOperationBinding>();
      operation->kind = kind;
      operation->dispatch_key = fields[4];
      operation->js_name = fields[3];
      operation->resource = resource;
      operation->function =
          std::make_unique<JS::PersistentRootedValue>(cx, function);
      export_resource_operation_bindings.push_back(std::move(operation));
      continue;
    }
    if (!fields.empty() && fields[0] == "ED") {
      if (fields.size() != 4 || !export_resource_class(fields[1], fields[2]) ||
          fields[3].empty()) {
        JS_ReportErrorUTF8(
            cx, "malformed JavaScript exported resource destructor manifest "
                "entry '%.*s'",
            static_cast<int>(line.size()), line.data());
        return false;
      }
      continue;
    }
    if (line.size() < 3 || line[1] != '\t' ||
        (line[0] != 'I' && line[0] != 'R')) {
      JS_ReportErrorUTF8(cx, "malformed JavaScript export manifest entry '%.*s'",
                         static_cast<int>(line.size()), line.data());
      return false;
    }

    std::string_view export_name = line.substr(2);
    bool is_interface = export_name.find('#') != std::string_view::npos;
    if (export_name.empty() || (line[0] == 'I') != is_interface) {
      JS_ReportErrorUTF8(cx, "malformed JavaScript export manifest entry '%.*s'",
                         static_cast<int>(line.size()), line.data());
      return false;
    }

    JS::RootedValue function(cx);
    const char *error_context = "validating a JavaScript module export";
    std::string function_name;
    if (!resolve_export_function(
            cx, &function, reinterpret_cast<const uint8_t *>(export_name.data()),
            export_name.size(), &error_context, &function_name)) {
      return false;
    }
  }
  return true;
}

static uint32_t dispatch_json_impl(const uint8_t *export_name_ptr, size_t export_name_len,
                                   const uint8_t *args_json_ptr, size_t args_json_len,
                                   StarlingJSDispatchResult *result) {
  result->ptr = nullptr;
  result->len = 0;

  JSContext *cx = api::Engine::cx();
  if (!cx) {
    return 1;
  }
  JSAutoRealm realm(cx, api::Engine::global());

  const std::string_view dispatch_key(
      reinterpret_cast<const char *>(export_name_ptr), export_name_len);
  ExportResourceOperationBinding *resource_operation =
      export_resource_operation(dispatch_key);
  JS::RootedValue function(cx);
  const char *error_context = "resolving a JavaScript module export";
  std::string function_name;
  if (resource_operation) {
    function.set(resource_operation->function->get());
    function_name = resource_operation->js_name;
  } else {
    if (!resolve_export_function(cx, &function, export_name_ptr,
                                 export_name_len, &error_context,
                                 &function_name)) {
      return dispatch_error(cx, error_context);
    }
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
  bool call_succeeded = false;
  if (!resource_operation) {
    call_succeeded =
        JS::Call(cx, JS::UndefinedHandleValue, function, argv, &return_value);
  } else if (resource_operation->kind ==
             ExportResourceOperationKind::Constructor) {
    JS::RootedObject instance(cx);
    call_succeeded = JS::Construct(cx, function, argv, &instance);
    if (call_succeeded) {
      return_value.setObject(*instance);
    }
  } else if (resource_operation->kind ==
             ExportResourceOperationKind::Method) {
    if (argv.empty() || !argv[0].isObject()) {
      JS_ReportErrorASCII(
          cx, "native dispatch: exported resource method has no receiver");
      return dispatch_error(cx, "calling a JavaScript resource method");
    }
    const JS::HandleValueArray all_args(argv);
    const JS::HandleValueArray method_args = JS::HandleValueArray::subarray(
        all_args, 1, all_args.length() - 1);
    call_succeeded =
        JS::Call(cx, argv[0], function, method_args, &return_value);
  } else {
    JS::RootedValue receiver(
        cx, JS::ObjectValue(*resource_operation->resource->constructor->get()));
    call_succeeded = JS::Call(cx, receiver, function, argv, &return_value);
  }
  if (!call_succeeded) {
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

extern "C" uint32_t starling_js_dispatch(const uint8_t *export_name_ptr,
                                         size_t export_name_len,
                                         const uint8_t *args_json_ptr,
                                         size_t args_json_len,
                                         StarlingJSDispatchResult *result) {
  result->ptr = nullptr;
  result->len = 0;
  JSContext *cx = api::Engine::cx();
  if (!cx || !reclaim_pending_dispatch_arena()) {
    return 1;
  }
  auto *engine = api::Engine::get(cx);
  auto &registry = engine->resource_registry();
  if (registry.dispatch_depth() == 0 && !starling::drain_resource_drops(engine)) {
    return 1;
  }
  const uint32_t status =
      dispatch_json_impl(export_name_ptr, export_name_len, args_json_ptr, args_json_len, result);
  if (registry.dispatch_depth() == 0 && !starling::drain_resource_drops(engine)) {
    std::free(result->ptr);
    result->ptr = nullptr;
    result->len = 0;
    return 1;
  }
  return status;
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
  std::vector<std::unique_ptr<JS::PersistentRootedObject>> resource_roots;
  std::vector<int32_t> pending_exported_resource_reps;
  api::Engine *dispatch_engine = nullptr;
  bool owns_dispatch_scope = false;

  ~NativeArena() {
    for (int32_t rep : pending_exported_resource_reps) {
      rollback_exported_resource(rep);
    }
  }

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
  void root_resource(JSContext *cx, JS::HandleObject obj) {
    resource_roots.push_back(std::make_unique<JS::PersistentRootedObject>(cx, obj));
  }
};

NativeArena *pending_dispatch_arena = nullptr;

bool finish_native_arena(NativeArena *arena) {
  if (!arena) {
    return true;
  }
  if (pending_dispatch_arena == arena) {
    pending_dispatch_arena = nullptr;
  }
  api::Engine *engine = arena->dispatch_engine;
  const bool owns_scope = arena->owns_dispatch_scope;
  delete arena;
  if (!owns_scope) {
    return true;
  }
  const bool outermost = engine->resource_registry().leave_dispatch();
  return !outermost || starling::drain_resource_drops(engine);
}

bool reclaim_pending_dispatch_arena() {
  NativeArena *stale = pending_dispatch_arena;
  return !stale || finish_native_arena(stale);
}

struct ResourceObjectData {
  starling::ResourceRegistry *registry;
  starling::ResourceToken token;
};

enum class ResourceObjectSlot : uint32_t {
  Data,
  Count,
};

void finalize_resource_object(JS::GCContext *, JSObject *obj) {
  auto *data = static_cast<ResourceObjectData *>(
      JS::GetReservedSlot(obj, std::to_underlying(ResourceObjectSlot::Data)).toPrivate());
  if (!data) {
    return;
  }
  if (data->token.ownership == starling::ResourceOwnership::Own) {
    // This only changes registry state. Host/Zig drop code runs later at a
    // depth-zero safe point, never from SpiderMonkey finalization.
    (void)data->registry->queue_drop(data->token);
  }
  delete data;
}

static constexpr JSClassOps resource_object_class_ops{
    .finalize = finalize_resource_object,
};

static constexpr JSClass resource_object_class{
    "WITResource",
    JSCLASS_HAS_RESERVED_SLOTS(std::to_underlying(ResourceObjectSlot::Count)) |
        JSCLASS_FOREGROUND_FINALIZE,
    &resource_object_class_ops,
};

struct ResourceClassBinding {
  std::string module_id;
  std::string class_name;
  std::string provider;
  std::string name;
  std::unique_ptr<JS::PersistentRootedObject> prototype;
  std::unique_ptr<JS::PersistentRootedObject> constructor;
};

std::vector<std::unique_ptr<ResourceClassBinding>> resource_class_bindings;

JSObject *resource_prototype(std::string_view provider, std::string_view name) {
  for (const auto &binding : resource_class_bindings) {
    if (binding->provider == provider && binding->name == name) {
      return binding->prototype->get();
    }
  }
  return nullptr;
}

ResourceClassBinding *resource_class(std::string_view module_id,
                                     std::string_view resource_name) {
  for (const auto &binding : resource_class_bindings) {
    if (binding->module_id == module_id &&
        binding->name == resource_name) {
      return binding.get();
    }
  }
  return nullptr;
}

ResourceClassBinding *resource_class_for_prototype(JSObject *prototype) {
  for (const auto &binding : resource_class_bindings) {
    if (binding->prototype->get() == prototype) {
      return binding.get();
    }
  }
  return nullptr;
}

const char *resource_error_message(starling::ResourceError error) {
  switch (error) {
  case starling::ResourceError::None:
    return "none";
  case starling::ResourceError::NotInDispatch:
    return "resource used outside an active dispatch";
  case starling::ResourceError::WrongOwnership:
    return "resource ownership mismatch";
  case starling::ResourceError::UnknownResource:
    return "unknown resource";
  case starling::ResourceError::StaleToken:
    return "stale resource generation";
  case starling::ResourceError::ExpiredBorrow:
    return "expired borrowed resource";
  case starling::ResourceError::InvalidState:
    return "resource was moved, dropped, or already has an owner";
  }
  return "unrecognized resource registry error";
}

bool report_resource_error(JSContext *cx, const char *operation,
                           starling::ResourceError error) {
  JS_ReportErrorUTF8(cx, "native dispatch: cannot %s: %s", operation,
                     resource_error_message(error));
  return false;
}

std::optional<starling::ResourceOwnership>
resource_ownership_from_abi(StarlingJsResourceOwnership ownership) {
  switch (ownership) {
  case STARLING_JS_RESOURCE_OWN:
    return starling::ResourceOwnership::Own;
  case STARLING_JS_RESOURCE_BORROW:
    return starling::ResourceOwnership::Borrow;
  }
  return std::nullopt;
}

StarlingJsResourceOwnership resource_ownership_to_abi(starling::ResourceOwnership ownership) {
  switch (ownership) {
  case starling::ResourceOwnership::Own:
    return STARLING_JS_RESOURCE_OWN;
  case starling::ResourceOwnership::Borrow:
    return STARLING_JS_RESOURCE_BORROW;
  }
  MOZ_CRASH("unrecognized resource ownership");
}

bool encode_resource_to_js(JSContext *cx, const StarlingJsValue &value,
                           JS::MutableHandleValue out) {
  if (!value.resource_provider_ptr || value.resource_provider_len == 0 ||
      !value.resource_name_ptr || value.resource_name_len == 0) {
    JS_ReportErrorASCII(cx, "native dispatch: resource descriptor is missing");
    return false;
  }
  const auto ownership = resource_ownership_from_abi(value.resource_ownership);
  if (!ownership) {
    JS_ReportErrorASCII(cx, "native dispatch: resource ownership is invalid");
    return false;
  }

  const std::string_view provider(
      reinterpret_cast<const char *>(value.resource_provider_ptr),
      value.resource_provider_len);
  const std::string_view name(reinterpret_cast<const char *>(value.resource_name_ptr),
                              value.resource_name_len);
  if (export_resource_class(provider, name)) {
    ExportedResourceEntry *entry =
        exported_resource_entry(provider, name, value.resource_handle);
    if (!entry || !entry->committed) {
      JS_ReportErrorUTF8(
          cx,
          "native dispatch: exported resource '%.*s/%.*s' has a stale or "
          "unknown representation",
          static_cast<int>(provider.size()), provider.data(),
          static_cast<int>(name.size()), name.data());
      return false;
    }
    out.setObject(*entry->object->get());
    return true;
  }
  JS::RootedObject proto(cx, resource_prototype(provider, name));
  JS::RootedObject obj(
      cx, JS_NewObjectWithGivenProto(cx, &resource_object_class, proto));
  if (!obj) {
    return false;
  }
  JS::SetReservedSlot(obj, std::to_underlying(ResourceObjectSlot::Data),
                      JS::PrivateValue(nullptr));

  auto &registry = api::Engine::get(cx)->resource_registry();
  const starling::ResourceTokenResult acquired =
      *ownership == starling::ResourceOwnership::Own
          ? registry.acquire_owned(provider, name, value.resource_handle)
          : registry.acquire_borrow(provider, name, value.resource_handle);
  if (!acquired) {
    return report_resource_error(cx, "create a JavaScript resource wrapper", acquired.error);
  }

  auto *data = new (std::nothrow) ResourceObjectData{
      .registry = &registry,
      .token = acquired.token,
  };
  if (!data) {
    if (*ownership == starling::ResourceOwnership::Own) {
      (void)registry.queue_drop(acquired.token);
    }
    JS_ReportOutOfMemory(cx);
    return false;
  }
  JS::SetReservedSlot(obj, std::to_underlying(ResourceObjectSlot::Data),
                      JS::PrivateValue(data));
  out.setObject(*obj);
  return true;
}

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
    // A direct WIT option<T>::none lifts to JavaScript undefined. Nested
    // options are represented by the Zig encoder as {tag, val} records so
    // their three canonical states remain distinguishable.
    out.setUndefined();
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
  case STARLING_JS_RESOURCE:
    return encode_resource_to_js(cx, v, out);
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

    if (JS::GetClass(obj) == &resource_object_class) {
      auto *data = static_cast<ResourceObjectData *>(
          JS::GetReservedSlot(obj, std::to_underlying(ResourceObjectSlot::Data)).toPrivate());
      if (!data) {
        JS_ReportErrorASCII(cx, "native dispatch: resource wrapper has no registry token");
        return false;
      }
      const starling::ResourceError valid = data->registry->validate(data->token);
      if (valid != starling::ResourceError::None) {
        return report_resource_error(cx, "use a JavaScript resource wrapper", valid);
      }
      const auto *descriptor = data->registry->descriptor(data->token.type_id);
      if (!descriptor) {
        JS_ReportErrorASCII(cx, "native dispatch: resource type is not registered");
        return false;
      }
      // Recursive decoding releases each field/element's stack root before
      // moving to the next one. Keep resource wrappers alive until Zig has
      // validated the complete aggregate and committed or rejected ownership.
      arena.root_resource(cx, obj);
      *out = {
          .tag = STARLING_JS_RESOURCE,
          .resource_provider_ptr =
              reinterpret_cast<const uint8_t *>(descriptor->provider.data()),
          .resource_provider_len = descriptor->provider.size(),
          .resource_name_ptr = reinterpret_cast<const uint8_t *>(descriptor->name.data()),
          .resource_name_len = descriptor->name.size(),
          .resource_type_id = data->token.type_id,
          .resource_handle = data->token.handle,
          .resource_ownership = resource_ownership_to_abi(data->token.ownership),
          .resource_generation = data->token.generation,
          .resource_borrow_epoch = data->token.borrow_epoch,
      };
      return true;
    }

    std::vector<ExportResourceClassBinding *> exported_classes;
    if (!exported_resource_classes_for_instance(cx, obj, &exported_classes)) {
      return false;
    }
    if (!exported_classes.empty()) {
      int32_t rep = 0;
      if (!allocate_exported_resource_rep(cx, exported_classes, obj, &rep)) {
        return false;
      }
      arena.pending_exported_resource_reps.push_back(rep);
      *out = {
          .tag = STARLING_JS_RESOURCE,
          .resource_provider_ptr = nullptr,
          .resource_provider_len = 0,
          .resource_name_ptr = nullptr,
          .resource_name_len = 0,
          .resource_type_id = 0,
          .resource_handle = rep,
          .resource_ownership = STARLING_JS_RESOURCE_OWN,
          .resource_generation = 0,
          .resource_borrow_epoch = 0,
      };
      return true;
    }

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

static uint32_t dispatch_native_impl(const uint8_t *export_name_ptr, size_t export_name_len,
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

  const std::string_view dispatch_key(
      reinterpret_cast<const char *>(export_name_ptr), export_name_len);
  ExportResourceOperationBinding *resource_operation =
      export_resource_operation(dispatch_key);
  JS::RootedValue function(cx);
  const char *error_context = "resolving a JavaScript module export";
  std::string function_name;
  if (resource_operation) {
    function.set(resource_operation->function->get());
    function_name = resource_operation->js_name;
  } else {
    if (!resolve_export_function(cx, &function, export_name_ptr,
                                 export_name_len, &error_context,
                                 &function_name)) {
      return dispatch_error(cx, error_context);
    }
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
  bool call_succeeded = false;
  if (!resource_operation) {
    call_succeeded =
        JS::Call(cx, JS::UndefinedHandleValue, function, argv, &return_value);
  } else if (resource_operation->kind ==
             ExportResourceOperationKind::Constructor) {
    JS::RootedObject instance(cx);
    call_succeeded = JS::Construct(cx, function, argv, &instance);
    if (call_succeeded) {
      return_value.setObject(*instance);
    }
  } else if (resource_operation->kind ==
             ExportResourceOperationKind::Method) {
    if (argv.empty() || !argv[0].isObject()) {
      JS_ReportErrorASCII(
          cx, "native dispatch: exported resource method has no receiver");
      return dispatch_error(cx, "calling a JavaScript resource method");
    }
    const JS::HandleValueArray all_args(argv);
    const JS::HandleValueArray method_args = JS::HandleValueArray::subarray(
        all_args, 1, all_args.length() - 1);
    call_succeeded =
        JS::Call(cx, argv[0], function, method_args, &return_value);
  } else {
    JS::RootedValue receiver(
        cx, JS::ObjectValue(*resource_operation->resource->constructor->get()));
    call_succeeded = JS::Call(cx, receiver, function, argv, &return_value);
  }
  if (!call_succeeded) {
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

extern "C" uint32_t starling_js_dispatch_native(const uint8_t *export_name_ptr,
                                                size_t export_name_len,
                                                const StarlingJsValue *args_ptr, size_t args_len,
                                                uint8_t result_is_wit_result,
                                                StarlingJsValue *out_result, void **out_arena) {
  JSContext *cx = api::Engine::cx();
  if (!cx) {
    finish_prepared_exported_arguments();
    return 1;
  }
  auto *engine = api::Engine::get(cx);
  auto &registry = engine->resource_registry();
  if (!reclaim_pending_dispatch_arena()) {
    finish_prepared_exported_arguments();
    return 1;
  }
  if (registry.dispatch_depth() == 0 && !starling::drain_resource_drops(engine)) {
    finish_prepared_exported_arguments();
    return 1;
  }
  registry.enter_dispatch();
  const uint32_t result =
      dispatch_native_impl(export_name_ptr, export_name_len, args_ptr, args_len,
                           result_is_wit_result, out_result, out_arena);
  finish_prepared_exported_arguments();
  if ((result == 0 || result == 2) && *out_arena) {
    auto *arena = static_cast<NativeArena *>(*out_arena);
    arena->dispatch_engine = engine;
    arena->owns_dispatch_scope = true;
    pending_dispatch_arena = arena;
    return result;
  }
  const bool outermost = registry.leave_dispatch();
  if (outermost && !starling::drain_resource_drops(engine)) return 1;
  return result;
}

extern "C" uint32_t starling_js_dispatch_native_free(void *opaque_arena) {
  return finish_native_arena(static_cast<NativeArena *>(opaque_arena)) ? 0 : 1;
}

extern "C" uint32_t starling_js_resource_validate(
    uint32_t type_id, int32_t handle, uint64_t generation,
    StarlingJsResourceOwnership ownership, uint64_t borrow_epoch) {
  JSContext *cx = api::Engine::cx();
  if (!cx) {
    return static_cast<uint32_t>(starling::ResourceError::UnknownResource);
  }
  const auto native_ownership = resource_ownership_from_abi(ownership);
  if (!native_ownership) {
    return static_cast<uint32_t>(starling::ResourceError::WrongOwnership);
  }
  starling::ResourceToken token{
      .type_id = type_id,
      .handle = handle,
      .generation = generation,
      .ownership = *native_ownership,
      .borrow_epoch = borrow_epoch,
  };
  auto &registry = api::Engine::get(cx)->resource_registry();
  return static_cast<uint32_t>(registry.validate(token));
}

extern "C" uint32_t
starling_js_resource_transfer_many(const starling::ResourceToken *tokens, size_t len) {
  JSContext *cx = api::Engine::cx();
  if (!cx) {
    return static_cast<uint32_t>(starling::ResourceError::UnknownResource);
  }
  auto &registry = api::Engine::get(cx)->resource_registry();
  return static_cast<uint32_t>(
      registry.transfer_owned_many(std::span<const starling::ResourceToken>(tokens, len)));
}

extern "C" uint32_t starling_js_exported_resource_select(
    int32_t rep, const uint8_t *provider_ptr, size_t provider_len,
    const uint8_t *name_ptr, size_t name_len) {
  if (!provider_ptr || !name_ptr) {
    return 1;
  }
  const std::string_view provider(
      reinterpret_cast<const char *>(provider_ptr), provider_len);
  const std::string_view name(reinterpret_cast<const char *>(name_ptr),
                              name_len);
  for (const auto &entry : exported_resource_entries) {
    if (entry->rep != rep || entry->committed) {
      continue;
    }
    if (!entry->provider.empty() || !entry->name.empty()) {
      return entry->provider == provider && entry->name == name ? 0 : 1;
    }
    for (ExportResourceClassBinding *candidate : entry->candidates) {
      if (candidate->provider == provider && candidate->name == name) {
        entry->provider = candidate->provider;
        entry->name = candidate->name;
        return 0;
      }
    }
    return 1;
  }
  return 1;
}

extern "C" uint32_t starling_js_exported_resource_prepare_own(
    const uint8_t *provider_ptr, size_t provider_len,
    const uint8_t *name_ptr, size_t name_len, int32_t rep) {
  if (!provider_ptr || !name_ptr) {
    return 1;
  }
  const std::string_view provider(
      reinterpret_cast<const char *>(provider_ptr), provider_len);
  const std::string_view name(reinterpret_cast<const char *>(name_ptr),
                              name_len);
  ExportedResourceEntry *entry =
      exported_resource_entry(provider, name, rep);
  if (!entry || !entry->committed || entry->prepared_owned_argument) {
    return 1;
  }
  entry->prepared_owned_argument = true;
  entry->canonical_dropped = false;
  return 0;
}

extern "C" uint32_t
starling_js_exported_resource_commit_many(const int32_t *reps, size_t len) {
  for (size_t i = 0; i < len; ++i) {
    ExportedResourceEntry *entry = nullptr;
    for (const auto &candidate : exported_resource_entries) {
      if (candidate->rep == reps[i]) {
        entry = candidate.get();
        break;
      }
    }
    if (!entry || entry->committed) {
      return 1;
    }
    for (size_t j = 0; j < i; ++j) {
      if (reps[j] == reps[i]) {
        return 1;
      }
    }
  }
  for (size_t i = 0; i < len; ++i) {
    for (const auto &entry : exported_resource_entries) {
      if (entry->rep == reps[i]) {
        entry->committed = true;
        break;
      }
    }
  }
  return 0;
}

extern "C" uint32_t starling_js_resources_commit_many(
    const starling::ResourceToken *tokens, size_t token_len,
    const int32_t *reps, size_t rep_len) {
  JSContext *cx = api::Engine::cx();
  if (!cx) {
    return 1;
  }
  auto &registry = api::Engine::get(cx)->resource_registry();
  for (size_t i = 0; i < token_len; ++i) {
    if (tokens[i].ownership != starling::ResourceOwnership::Own ||
        registry.validate(tokens[i]) != starling::ResourceError::None) {
      return 1;
    }
    for (size_t j = 0; j < i; ++j) {
      if (tokens[j].type_id == tokens[i].type_id &&
          tokens[j].handle == tokens[i].handle &&
          tokens[j].generation == tokens[i].generation) {
        return 1;
      }
    }
  }
  for (size_t i = 0; i < rep_len; ++i) {
    ExportedResourceEntry *entry = nullptr;
    for (const auto &candidate : exported_resource_entries) {
      if (candidate->rep == reps[i]) {
        entry = candidate.get();
        break;
      }
    }
    if (!entry || entry->committed || entry->provider.empty() ||
        entry->name.empty()) {
      return 1;
    }
    for (size_t j = 0; j < i; ++j) {
      if (reps[j] == reps[i]) {
        return 1;
      }
    }
  }

  if (registry.transfer_owned_many(
          std::span<const starling::ResourceToken>(tokens, token_len)) !=
      starling::ResourceError::None) {
    return 1;
  }
  for (size_t i = 0; i < rep_len; ++i) {
    for (const auto &entry : exported_resource_entries) {
      if (entry->rep == reps[i]) {
        entry->committed = true;
        break;
      }
    }
  }
  return 0;
}

extern "C" uint32_t starling_js_exported_resource_drop(
    const uint8_t *provider_ptr, size_t provider_len, const uint8_t *name_ptr,
    size_t name_len, int32_t rep) {
  if (!provider_ptr || !name_ptr) {
    return 1;
  }
  const std::string_view provider(
      reinterpret_cast<const char *>(provider_ptr), provider_len);
  const std::string_view name(reinterpret_cast<const char *>(name_ptr),
                              name_len);
  return erase_exported_resource(provider, name, rep, true) ? 0 : 1;
}

extern "C" __attribute__((weak)) uint32_t starling_js_resource_drop(
    const uint8_t *provider_ptr, size_t provider_len, const uint8_t *name_ptr,
    size_t name_len, int32_t handle) {
  (void)provider_ptr;
  (void)provider_len;
  (void)name_ptr;
  (void)name_len;
  (void)handle;
  return 1;
}

namespace starling {

size_t exported_resource_count() {
  return exported_resource_entries.size();
}

bool drain_resource_drops(api::Engine *engine) {
  auto &registry = engine->resource_registry();
  while (auto request = registry.take_queued_drop()) {
    const ResourceDescriptor *descriptor = registry.descriptor(request->token.type_id);
    if (!descriptor) {
      JS_ReportErrorASCII(engine->cx(),
                          "native dispatch: queued drop has an unknown resource type");
      return false;
    }
    if (starling_js_resource_drop(
            reinterpret_cast<const uint8_t *>(descriptor->provider.data()),
            descriptor->provider.size(),
            reinterpret_cast<const uint8_t *>(descriptor->name.data()),
            descriptor->name.size(), request->token.handle) != 0) {
      JS_ReportErrorUTF8(engine->cx(),
                         "native dispatch: host drop failed for resource '%s/%s'",
                         descriptor->provider.c_str(), descriptor->name.c_str());
      return false;
    }
  }
  return true;
}

bool shutdown_resources(api::Engine *engine) {
  if (!reclaim_pending_dispatch_arena()) {
    return false;
  }
  auto &registry = engine->resource_registry();
  if (registry.dispatch_depth() != 0) {
    JS_ReportErrorASCII(engine->cx(),
                        "native dispatch: cannot shut down resources during a dispatch");
    return false;
  }
  registry.queue_all_owned();
  return drain_resource_drops(engine);
}

} // namespace starling

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
bool call_import_impl(JSContext *cx, JS::HandleObject receiver, JS::HandleValue extra,
                      JS::CallArgs args, bool prepend_this) {
  JS::RootedString key_str(cx, extra.toString());
  auto key_utf8 = core::encode(cx, key_str);
  if (!key_utf8.ptr) {
    return false;
  }
  std::string dispatch_key(key_utf8.ptr.get(), key_utf8.len);

  NativeArena arg_arena;
  std::vector<StarlingJsValue> argv;
  argv.reserve(args.length() + prepend_this);
  if (prepend_this) {
    JS::RootedValue this_value(cx, args.thisv());
    if (!this_value.isObject() ||
        JS::GetClass(&this_value.toObject()) != &resource_object_class) {
      JS_ReportErrorASCII(cx, "native dispatch: resource method receiver is invalid");
      return false;
    }
    auto *binding = resource_class_for_prototype(receiver);
    auto *data = static_cast<ResourceObjectData *>(
        JS::GetReservedSlot(&this_value.toObject(),
                            std::to_underlying(ResourceObjectSlot::Data))
            .toPrivate());
    const starling::ResourceDescriptor *descriptor =
        data ? data->registry->descriptor(data->token.type_id) : nullptr;
    if (!binding || !descriptor || descriptor->provider != binding->provider ||
        descriptor->name != binding->name) {
      JS_ReportErrorASCII(
          cx, "native dispatch: resource method receiver has the wrong type");
      return false;
    }
    StarlingJsValue encoded{};
    if (!decode_from_js(cx, this_value, arg_arena, &encoded)) {
      return false;
    }
    argv.push_back(encoded);
  }
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
    starling_js_import_result_free(out_arena);
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

bool call_import_scoped(JSContext *cx, JS::HandleObject receiver,
                        JS::HandleValue extra, JS::CallArgs args,
                        bool prepend_this) {
  auto *engine = api::Engine::get(cx);
  if (!reclaim_pending_dispatch_arena()) {
    return false;
  }
  auto &registry = engine->resource_registry();
  if (registry.dispatch_depth() == 0 && !starling::drain_resource_drops(engine)) {
    return false;
  }
  registry.enter_dispatch();
  const bool result = call_import_impl(cx, receiver, extra, args, prepend_this);
  const bool outermost = registry.leave_dispatch();
  if (outermost && !starling::drain_resource_drops(engine)) {
    return false;
  }
  return result;
}

bool call_import(JSContext *cx, JS::HandleObject receiver, JS::HandleValue extra,
                 JS::CallArgs args) {
  return call_import_scoped(cx, receiver, extra, args, false);
}

bool call_resource_method(JSContext *cx, JS::HandleObject receiver,
                          JS::HandleValue extra, JS::CallArgs args) {
  return call_import_scoped(cx, receiver, extra, args, true);
}

bool call_resource_constructor(JSContext *cx, JS::HandleObject receiver,
                               JS::HandleValue extra, JS::CallArgs args) {
  if (!args.isConstructing()) {
    JS_ReportErrorASCII(cx, "native dispatch: resource constructor requires 'new'");
    return false;
  }
  return call_import(cx, receiver, extra, args);
}

bool call_unavailable_resource_constructor(JSContext *cx,
                                           JS::HandleObject receiver,
                                           JS::HandleValue extra,
                                           JS::CallArgs args) {
  (void)receiver;
  (void)extra;
  (void)args;
  JS_ReportErrorASCII(cx, "native dispatch: this resource has no constructor");
  return false;
}

template <InternalMethod fun>
JSObject *create_resource_constructor(JSContext *cx,
                                      JS::HandleObject receiver,
                                      JS::HandleValue extra, unsigned arity,
                                      const char *name) {
  JSFunction *function = js::NewFunctionWithReserved(
      cx, internal_method<fun>, arity, JSFUN_CONSTRUCTOR, name);
  if (!function) {
    return nullptr;
  }
  JS::RootedObject function_obj(cx, JS_GetFunctionObject(function));
  js::SetFunctionNativeReserved(function_obj, 0,
                                JS::ObjectValue(*receiver));
  js::SetFunctionNativeReserved(function_obj, 1, extra);
  return function_obj;
}

bool define_unique_property(JSContext *cx, JS::HandleObject target,
                            const char *name, JS::HandleValue value,
                            unsigned attrs) {
  bool exists = false;
  if (!JS_HasOwnProperty(cx, target, name, &exists)) {
    return false;
  }
  if (exists) {
    JS_ReportErrorUTF8(cx,
                       "duplicate JavaScript import binding '%s' in WIT "
                       "import manifest",
                       name);
    return false;
  }
  return JS_DefineProperty(cx, target, name, value, attrs);
}

bool make_dispatch_key(JSContext *cx, const std::string &dispatch_key,
                       JS::MutableHandleValue extra) {
  JS::RootedString key_str(
      cx, JS_NewStringCopyN(cx, dispatch_key.data(), dispatch_key.size()));
  if (!key_str) {
    return false;
  }
  extra.setString(key_str);
  return true;
}

enum class ImportManifestKind {
  Function,
  Resource,
  Constructor,
  Method,
  Static,
};

struct ImportManifestEntry {
  ImportManifestKind kind;
  std::string module_id;
  std::string class_name;
  std::string js_name;
  std::string provider;
  std::string resource_name;
  std::string dispatch_key;
  unsigned arity = 0;
};

bool parse_manifest_arity(std::string_view text, unsigned *arity) {
  if (text.empty()) {
    return false;
  }
  unsigned value = 0;
  for (char c : text) {
    if (c < '0' || c > '9') {
      return false;
    }
    const unsigned digit = static_cast<unsigned>(c - '0');
    if (value > (std::numeric_limits<unsigned>::max() - digit) / 10) {
      return false;
    }
    value = value * 10 + digit;
  }
  *arity = value;
  return true;
}

bool parse_manifest_line(std::string_view line, ImportManifestEntry *entry) {
  std::vector<std::string_view> fields;
  size_t pos = 0;
  while (true) {
    const size_t tab = line.find('\t', pos);
    fields.push_back(line.substr(pos, tab == std::string_view::npos
                                         ? line.size() - pos
                                         : tab - pos));
    if (tab == std::string_view::npos) {
      break;
    }
    pos = tab + 1;
  }
  for (const auto field : fields) {
    if (field.empty()) {
      return false;
    }
  }

  if (fields.size() == 4 && fields[0] != "R") {
    entry->kind = ImportManifestKind::Function;
    entry->module_id = fields[0];
    entry->js_name = fields[1];
    entry->dispatch_key = fields[2];
    return parse_manifest_arity(fields[3], &entry->arity);
  }
  if (fields.size() == 4 && fields[0] == "R") {
    entry->kind = ImportManifestKind::Resource;
    entry->module_id = fields[1];
    entry->provider = fields[1];
    entry->resource_name = fields[2];
    entry->class_name = fields[3];
    return true;
  }
  if (fields.size() == 6 &&
      (fields[0] == "C" || fields[0] == "M" || fields[0] == "S")) {
    entry->kind = fields[0] == "C"
                      ? ImportManifestKind::Constructor
                      : fields[0] == "M" ? ImportManifestKind::Method
                                          : ImportManifestKind::Static;
    entry->module_id = fields[1];
    entry->provider = fields[1];
    entry->resource_name = fields[2];
    entry->js_name = fields[3];
    entry->dispatch_key = fields[4];
    return parse_manifest_arity(fields[5], &entry->arity);
  }
  return false;
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
  resource_class_bindings.clear();
  if (!manifest_ptr || manifest_len == 0) {
    return true; // Nothing to bridge -- default behavior is unaffected.
  }
  std::string_view manifest(reinterpret_cast<const char *>(manifest_ptr), manifest_len);

  std::vector<ImportManifestEntry> entries;
  size_t pos = 0;
  while (pos < manifest.size()) {
    const size_t nl = manifest.find('\n', pos);
    const std::string_view line =
        manifest.substr(pos, nl == std::string_view::npos
                                 ? manifest.size() - pos
                                 : nl - pos);
    pos = nl == std::string_view::npos ? manifest.size() : nl + 1;
    if (line.empty()) {
      continue;
    }

    ImportManifestEntry entry;
    if (!parse_manifest_line(line, &entry)) {
      JS_ReportErrorUTF8(cx, "malformed js_import_manifest line: '%.*s'",
                         static_cast<int>(line.size()), line.data());
      return false;
    }
    entries.push_back(std::move(entry));
  }

  std::vector<std::string> module_ids;
  for (const auto &entry : entries) {
    bool known = false;
    for (const auto &module_id : module_ids) {
      if (module_id == entry.module_id) {
        known = true;
        break;
      }
    }
    if (!known) {
      module_ids.push_back(entry.module_id);
    }
  }

  for (const auto &module_id : module_ids) {
    JS::RootedObject module(cx, JS_NewPlainObject(cx));
    if (!module) {
      return false;
    }
    std::vector<std::string> replaced_intrinsic_statics;

    for (const auto &resource : entries) {
      if (resource.module_id != module_id ||
          resource.kind != ImportManifestKind::Resource) {
        continue;
      }
      if (resource_class(module_id, resource.resource_name)) {
        JS_ReportErrorUTF8(cx,
                           "duplicate resource class '%s' in WIT import "
                           "module '%s'",
                           resource.class_name.c_str(), module_id.c_str());
        return false;
      }

      const ImportManifestEntry *constructor_entry = nullptr;
      for (const auto &candidate : entries) {
        if (candidate.module_id == module_id &&
            candidate.resource_name == resource.resource_name &&
            candidate.kind == ImportManifestKind::Constructor) {
          if (constructor_entry) {
            JS_ReportErrorUTF8(
                cx, "duplicate constructor for resource class '%s'",
                resource.class_name.c_str());
            return false;
          }
          constructor_entry = &candidate;
        }
      }

      JS::RootedObject prototype(cx, JS_NewPlainObject(cx));
      if (!prototype) {
        return false;
      }

      JS::RootedValue extra(cx);
      JS::RootedObject constructor(cx);
      if (constructor_entry) {
        if (!make_dispatch_key(cx, constructor_entry->dispatch_key, &extra)) {
          return false;
        }
        constructor = create_resource_constructor<call_resource_constructor>(
            cx, module, extra, constructor_entry->arity,
            resource.class_name.c_str());
      } else {
        extra.setUndefined();
        constructor =
            create_resource_constructor<call_unavailable_resource_constructor>(
                cx, module, extra, 0, resource.class_name.c_str());
      }
      if (!constructor) {
        return false;
      }

      JS::RootedValue prototype_value(cx, JS::ObjectValue(*prototype));
      if (!JS_DefineProperty(cx, constructor, "prototype", prototype_value,
                             JSPROP_PERMANENT)) {
        return false;
      }
      JS::RootedValue constructor_value(cx, JS::ObjectValue(*constructor));
      if (!define_unique_property(cx, prototype, "constructor",
                                  constructor_value, 0) ||
          !define_unique_property(cx, module, resource.class_name.c_str(),
                                  constructor_value, JSPROP_ENUMERATE)) {
        return false;
      }

      auto binding = std::make_unique<ResourceClassBinding>();
      binding->module_id = module_id;
      binding->class_name = resource.class_name;
      binding->provider = resource.provider;
      binding->name = resource.resource_name;
      binding->prototype =
          std::make_unique<JS::PersistentRootedObject>(cx, prototype);
      binding->constructor =
          std::make_unique<JS::PersistentRootedObject>(cx, constructor);
      resource_class_bindings.push_back(std::move(binding));
    }

    for (const auto &entry : entries) {
      if (entry.module_id != module_id) {
        continue;
      }
      if (entry.kind == ImportManifestKind::Resource ||
          entry.kind == ImportManifestKind::Constructor) {
        continue;
      }

      JS::RootedValue extra(cx);
      if (!make_dispatch_key(cx, entry.dispatch_key, &extra)) {
        return false;
      }

      JS::RootedObject target(cx, module);
      JS::RootedObject function(cx);
      unsigned attrs = JSPROP_ENUMERATE;
      bool replace_function_intrinsic = false;
      if (entry.kind == ImportManifestKind::Function) {
        function = create_internal_method<call_import>(
            cx, module, extra, entry.arity, entry.js_name.c_str());
      } else {
        ResourceClassBinding *binding =
            resource_class(module_id, entry.resource_name);
        if (!binding) {
          JS_ReportErrorUTF8(
              cx, "resource member '%s.%s' has no resource declaration",
              entry.resource_name.c_str(), entry.js_name.c_str());
          return false;
        }
        attrs = 0;
        if (entry.kind == ImportManifestKind::Method) {
          target = binding->prototype->get();
          function = create_internal_method<call_resource_method>(
              cx, target, extra, entry.arity, entry.js_name.c_str());
        } else {
          target = binding->constructor->get();
          function = create_internal_method<call_import>(
              cx, target, extra, entry.arity, entry.js_name.c_str());
          replace_function_intrinsic =
              entry.js_name == "name" || entry.js_name == "length";
          if (replace_function_intrinsic) {
            const std::string member_key =
                entry.resource_name + "\n" + entry.js_name;
            if (std::find(replaced_intrinsic_statics.begin(),
                          replaced_intrinsic_statics.end(),
                          member_key) != replaced_intrinsic_statics.end()) {
              JS_ReportErrorUTF8(
                  cx,
                  "duplicate JavaScript import binding '%s' in WIT import "
                  "manifest",
                  entry.js_name.c_str());
              return false;
            }
            replaced_intrinsic_statics.push_back(member_key);
          }
        }
      }
      if (!function) {
        return false;
      }
      JS::RootedValue function_value(cx, JS::ObjectValue(*function));
      const bool defined =
          replace_function_intrinsic
              ? JS_DefineProperty(cx, target, entry.js_name.c_str(),
                                  function_value, attrs)
              : define_unique_property(cx, target, entry.js_name.c_str(),
                                       function_value, attrs);
      if (!defined) {
        return false;
      }
    }

    JS::RootedValue module_value(cx, JS::ObjectValue(*module));
    if (!engine->define_builtin_module(module_id.c_str(), module_value)) {
      return false;
    }
  }
  return true;
}

} // namespace wit_imports
} // namespace builtins
