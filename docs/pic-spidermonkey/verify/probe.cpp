// Minimal "engine" translation unit used only to prove that
// deps/sm-obj-zig/dist/libspidermonkey.a -- rebuilt with the pinned Zig
// toolchain via deps/build-deps.sh -- can be linked (not merely inspected
// for relocation metadata) into a `wasm32-wasi -dynamic -fPIC` module.
//
// This calls real, exported JSAPI symbols (JS_Init, JS_NewContext,
// JS_NewGlobalObject, JS::Evaluate, JS_DestroyContext, JS_ShutDown), the
// same sequence runtime/engine.cpp's init_js()/create_content_global() use
// to start the real engine, and actually parses and executes a JS
// expression built from the two arguments -- so a successful link+run
// exercises the GC, self-hosted/allocator plumbing, the parser/bytecode
// emitter and the interpreter, not just JS_Init().
//
// If libspidermonkey.a still contained absolute-address relocations
// (R_WASM_MEMORY_ADDR_LEB/SLEB/I32) against non-PIC-compiled members,
// linking this file together with the archive with `-dynamic -fPIC` below
// would fail exactly like the world-shell-spike `engine-dylib-experiment`
// failure recorded in docs/world-shell-spike/engine-pic-fail.excerpt.log.

#include "jsapi.h"
#include "js/CompilationAndEvaluation.h"
#include "js/Initialization.h"
#include "js/SourceText.h"
#include "jsfriendapi.h"
#include "gc/Memory.h"

#include <cstdio>
#include <cstring>
#include <unistd.h>

// libspidermonkey.a alone (without the sibling OpenSSL/Rust archives that
// the real StarlingMonkey build links alongside it -- see
// deps/build-deps.sh and build.zig) references a fixed, small set of
// symbols normally supplied by target/wasm32-wasip1/release/librust_staticlib.a:
// the encoding_c_mem/rust-hooks FFI functions used by js/src's UTF-8/UTF-16
// helpers (mfbt/Utf8.h) and js::MozCrash. These stand-ins exist only so this
// narrow, SpiderMonkey-only verification link can complete without also
// rebuilding the Rust bundle (out of scope for the pic-spidermonkey todo --
// see fix/pic-rust); none of them are exercised by engine_verify()'s
// "(a + b)" evaluation below, so their bodies are unreachable and only need
// to satisfy the linker with the real declared signatures
// (third_party/rust/encoding_c_mem/include/encoding_rs_mem.h,
// crates/rust-hooks/src/lib.rs). (build-and-verify.sh compiles this file
// with -fno-sanitize=undefined, so no __ubsan_handle_* stand-ins are needed
// here -- those symbols would only come from this TU's own compile, not
// from libspidermonkey.a, which references none of them.)
extern "C" {
void install_rust_hooks() {}
void encoding_mem_convert_latin1_to_utf16(const char*, size_t, char16_t*,
                                          size_t) {}
void encoding_mem_convert_latin1_to_utf8_partial(const char*, size_t*, char*,
                                                 size_t*) {}
void encoding_mem_convert_utf16_to_latin1_lossy(const char16_t*, size_t,
                                                char*, size_t) {}
size_t encoding_mem_convert_utf16_to_utf8(const char16_t*, size_t, char*,
                                          size_t) {
  return 0;
}
void encoding_mem_convert_utf16_to_utf8_partial(const char16_t*, size_t*,
                                                char*, size_t*) {}
void encoding_mem_ensure_utf16_validity(char16_t*, size_t) {}
bool encoding_mem_is_ascii(const char*, size_t) { return true; }
bool encoding_mem_is_basic_latin(const char16_t*, size_t) { return true; }
bool encoding_mem_is_utf16_latin1(const char16_t*, size_t) { return true; }
bool encoding_mem_is_utf8_latin1(const char*, size_t) { return true; }
size_t encoding_mem_utf16_valid_up_to(const char16_t*, size_t len) {
  return len;
}
size_t encoding_ascii_valid_up_to(const uint8_t*, size_t len) { return len; }
size_t encoding_utf8_valid_up_to(const uint8_t*, size_t len) { return len; }
}

// wasi-libc (as bundled by the pinned Zig/clang-22 toolchain) implements
// `PAGESIZE`/`PAGE_SIZE` (used by sysconf(_SC_PAGESIZE), getpagesize(), and
// therefore by js/src/gc/Memory.cpp's InitMemorySubsystem()) as
// `(unsigned long)&__wasm_first_page_end`
// (lib/libc/include/wasm-wasi-musl/__macro_PAGESIZE.h). That identity only
// holds for a non-relocatable *main* module, where segment 0 legitimately
// starts at absolute address 0 and `__wasm_first_page_end` sits at exactly
// 0x10000. In a `-fPIC`/`-dynamic` *side* module composed via
// `wasm-tools component link`, every data symbol's address is
// `__memory_base + offset`, so `&__wasm_first_page_end` instead evaluates
// to some large, meaningless address -- confirmed by reproducing the exact
// same wrong value with a minimal, SpiderMonkey-free `-dynamic -fPIC`
// module that only calls sysconf(_SC_PAGESIZE). This is a real bug in how
// wasi-libc's PAGESIZE macro interacts with PIC/dynamically-linked wasm32
// modules, independent of libspidermonkey.a's own PIC-ness (it reproduces
// with zero SpiderMonkey code). We work around it here, narrowly, so this
// probe can exercise real GC/allocator code end-to-end instead of stopping
// at JS_NewContext's first page-size query.
extern "C" long sysconf(int name) {
  switch (name) {
    case _SC_PAGESIZE:  // == _SC_PAGE_SIZE
      return 65536;
    case _SC_NPROCESSORS_CONF:
    case _SC_NPROCESSORS_ONLN:
      return 1;
    case _SC_CLK_TCK:
      return 100;
    default:
      return -1;
  }
}
extern "C" int getpagesize() { return 65536; }

extern "C" int32_t engine_verify(int32_t a, int32_t b) {
  if (!JS_Init()) {
    return a + b;
  }

  JSContext* cx = JS_NewContext(JS::DefaultHeapMaxBytes);
  if (!cx) {
    JS_ShutDown();
    return a + b + 1;
  }

  // Mirrors runtime/engine.cpp's init_js(): JS::InitSelfHostedCode must run
  // once per context, before the first JS_NewGlobalObject call, or global
  // creation crashes deep inside the engine (this is a real SpiderMonkey
  // API requirement, unrelated to PIC-ness -- confirmed by reproducing the
  // same crash with a fully static, non-PIC, non-dynamic direct link of
  // this file + libspidermonkey.a before this fix was added).
  if (!js::UseInternalJobQueues(cx) || !JS::InitSelfHostedCode(cx)) {
    JS_DestroyContext(cx);
    JS_ShutDown();
    return a + b + 2;
  }

  int32_t result = a + b + 3;
  {
    static JSClass global_class = {"global", JSCLASS_GLOBAL_FLAGS,
                                    &JS::DefaultGlobalClassOps};
    JS::RealmOptions options;
    JS::RootedObject global(
        cx, JS_NewGlobalObject(cx, &global_class, nullptr,
                                JS::FireOnNewGlobalHook, options));
    if (global) {
      JSAutoRealm ar(cx, global);

      char code[64];
      std::snprintf(code, sizeof(code), "(%d + %d)", a, b);

      JS::CompileOptions opts(cx);
      opts.setFileAndLine("pic-spidermonkey-probe.js", 1);

      JS::SourceText<mozilla::Utf8Unit> srcBuf;
      if (srcBuf.init(cx, code, std::strlen(code),
                       JS::SourceOwnership::Borrowed)) {
        JS::RootedValue rval(cx);
        if (JS::Evaluate(cx, opts, srcBuf, &rval) && rval.isInt32() &&
            rval.toInt32() == a + b) {
          // Every step -- GC/context init, global creation, parsing,
          // bytecode emission and interpretation -- round-tripped
          // successfully through the PIC-linked archive.
          result = a + b + 100;
        }
      }
    }
  }

  JS_DestroyContext(cx);
  JS_ShutDown();
  return result;
}
