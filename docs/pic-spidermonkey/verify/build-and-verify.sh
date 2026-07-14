#!/usr/bin/env bash
#
# pic-spidermonkey verification: proves that
# deps/sm-obj-zig/dist/libspidermonkey.a -- built for wasm32-wasi with the
# pinned Zig toolchain via deps/build-deps.sh's SpiderMonkey step -- can be
# linked (not merely inspected for relocation metadata) into a wasm32-wasi
# `-dynamic -fPIC` module, composed with an independently built "shell" via
# `wasm-tools component link` (the same Shared-Everything Dynamic Linking
# mechanism used in docs/world-shell-spike.md), and actually executed
# end-to-end with wasmtime.
#
# Steps:
#   1. Build libspidermonkey.a from scratch via deps/build-deps.sh's
#      SpiderMonkey step (mozconfig-zig + the zig-cc/zig-cxx/zig-ar
#      wrappers -- see deps/build-deps.sh and deps/zig-wrappers/).
#   2. Compile probe.cpp (real JSAPI calls: JS_Init, JS_NewContext,
#      JS_NewGlobalObject, JS::Evaluate, JS_DestroyContext, JS_ShutDown)
#      with the pinned zig c++ and link it together with the fresh archive
#      into one wasm32-wasi -dynamic -fPIC "engine" module. This is the
#      step that would fail with the exact "recompile with -fPIC" errors
#      from docs/world-shell-spike/engine-pic-fail.excerpt.log if the
#      archive were not PIC.
#   3. Build a thin "shell" module + WIT world, embed and `component link`
#      it against the engine module.
#   4. Run the resulting component with wasmtime and check the returned
#      value, proving the composed call chain (shell -> engine ->
#      libspidermonkey.a's JS_Init/JS_NewContext/JS_NewGlobalObject/
#      JS::Evaluate/JS_DestroyContext/JS_ShutDown, across a shared linear
#      memory) executes correctly -- not just link-clean.
#   5. Inspects the final linked sm-engine.wasm for the concrete markers of
#      the Shared-Everything Dynamic Linking convention (env.__memory_base /
#      env.__table_base imports and GOT.mem/GOT.func indirection), the real
#      signal that its code/data references were emitted PIC-relative
#      rather than as fixed addresses.
#
# Usage (from repo root):
#   unset ZIG_LOCAL_CACHE_DIR
#   export ZIG_GLOBAL_CACHE_DIR=/path/to/.zig-global-cache
#   ZIG=/path/to/zig WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
#     docs/pic-spidermonkey/verify/build-and-verify.sh
#
# Pass SKIP_SM_BUILD=1 to reuse an already-built
# deps/sm-obj-zig/dist/libspidermonkey.a instead of rebuilding it from
# scratch (rebuilding SpiderMonkey takes a while).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(cd ../../.. && pwd)"

ZIG="${ZIG:-zig}"
WASM_TOOLS="${WASM_TOOLS:-wasm-tools}"
WASMTIME="${WASMTIME:-wasmtime}"
ADAPTER="${ADAPTER:-$ROOT/host-apis/wasi-0.2.0/preview1-adapter-release/wasi_snapshot_preview1.wasm}"

DEPS="$ROOT/deps"
SM_SRC="$DEPS/spidermonkey-source"
SM_OBJ="$DEPS/sm-obj-zig"
SM_LIB="$SM_OBJ/dist/libspidermonkey.a"
SM_CONFDEFS="$SM_OBJ/js/src/js-confdefs.h"
SM_INCLUDE="$SM_OBJ/dist/include"
SM_TAG="FIREFOX_147_0_4_RELEASE_STARLING"
SM_REPO="https://github.com/bytecodealliance/firefox.git"
WRAP="$DEPS/zig-wrappers"

if [[ "${SKIP_SM_BUILD:-}" != "1" ]]; then
  echo "== [1/5] Building libspidermonkey.a from scratch (PIC) via deps/build-deps.sh's SpiderMonkey step =="
  if [[ ! -d "$SM_SRC/.git" ]]; then
    git clone --depth 1 --branch "$SM_TAG" "$SM_REPO" "$SM_SRC"
  fi
  for p in mozalloc-abort-wasi.patch memory-fallback-wasi-memalign.patch gc-wasi-aligned-alloc.patch; do
    git -C "$SM_SRC" apply --check "$DEPS/patches/$p" 2>/dev/null \
      && git -C "$SM_SRC" apply "$DEPS/patches/$p" || true
  done

  MOZCONFIG="$DEPS/mozconfig-zig"
  cat > "$MOZCONFIG" <<EOF
ac_add_options --enable-project=js
ac_add_options --disable-js-shell
ac_add_options --target=wasm32-unknown-wasi
ac_add_options --without-system-zlib
ac_add_options --without-intl-api
ac_add_options --disable-jit
ac_add_options --disable-shared-js
ac_add_options --disable-shared-memory
ac_add_options --disable-tests
ac_add_options --disable-clang-plugin
ac_add_options --enable-jitspew
ac_add_options --enable-optimize=-O2
ac_add_options --enable-js-streams
ac_add_options --enable-portable-baseline-interp
ac_add_options --disable-stdcxx-compat
ac_add_options --disable-debug
ac_add_options --prefix=$SM_OBJ/dist
mk_add_options MOZ_OBJDIR=$SM_OBJ
mk_add_options AUTOCLOBBER=1
EOF

  rm -rf "$SM_OBJ" "$DEPS/mozbuild-state"
  # Captured to a log file (not just left on the terminal) so the -fPIC
  # guard below can grep it directly: mach re-runs a second, unrelated
  # "configure" pass immediately after a successful build (its own normal
  # behavior) that touches config.log again right as this script regains
  # control, which makes grepping config.log itself for the -fPIC probe
  # racy. mach's own build console output, which includes each configure
  # probe result on one line ("checking ... -fPIC... yes"), doesn't have
  # that problem.
  BUILD_LOG="$DEPS/sm-build.log"
  MOZCONFIG="$MOZCONFIG" MOZBUILD_STATE_PATH="$DEPS/mozbuild-state" LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib}" \
    env CC="$WRAP/zig-cc" CXX="$WRAP/zig-cxx" AR="$WRAP/zig-ar" HOST_CC="${HOST_CC:-clang}" HOST_CXX="${HOST_CXX:-clang++}" \
    python3 "$SM_SRC/mach" --no-interactive build 2>&1 | tee "$BUILD_LOG"

  # Same loud, fail-fast -fPIC guard as deps/build-deps.sh (see the comment
  # there): don't rely on silently discovering a non-PIC archive later, at
  # the real component-link step below.
  for probe in "checking whether the C compiler supports -fPIC... yes" \
               "checking whether the C++ compiler supports -fPIC... yes"; do
    grep -qF "$probe" "$BUILD_LOG" || {
      echo "ERROR: SpiderMonkey configure did not confirm -fPIC support" \
        "($probe) -- see $BUILD_LOG" >&2
      exit 1
    }
  done
  echo ">>> Confirmed -fPIC is enabled for the SpiderMonkey build (see $BUILD_LOG)"

  SM_OBJS=(
    memory/build/Unified_cpp_memory_build0.o
    memory/mozalloc/Unified_cpp_memory_mozalloc0.o
    mfbt/Unified_cpp_mfbt0.o mfbt/Unified_cpp_mfbt1.o
    mozglue/misc/AutoProfilerLabel.o mozglue/misc/ConditionVariable_noop.o
    mozglue/misc/Debug.o mozglue/misc/Decimal.o mozglue/misc/MmapFaultHandler.o
    mozglue/misc/Mutex_noop.o mozglue/misc/Now.o mozglue/misc/Printf.o
    mozglue/misc/SIMD.o mozglue/misc/StackWalk.o mozglue/misc/TimeStamp.o
    mozglue/misc/TimeStamp_posix.o mozglue/misc/Uptime.o
    mozglue/static/lz4.o mozglue/static/lz4frame.o mozglue/static/lz4hc.o
    mozglue/static/xxhash.o third_party/fmt/Unified_cpp_third_party_fmt0.o
  )
  mkdir -p "$SM_OBJ/dist"
  cp "$SM_OBJ/js/src/build/libjs_static.a" "$SM_LIB"
  ( cd "$SM_OBJ" && "$ZIG" ar -q "$SM_LIB" "${SM_OBJS[@]}" )
  cp -f "$SM_OBJ/js/src/js-confdefs.h" "$SM_OBJ/dist/include/js-confdefs.h"
else
  echo "== [1/5] Skipping SpiderMonkey build (SKIP_SM_BUILD=1); using existing $SM_LIB =="
fi
[[ -f "$SM_LIB" ]] || { echo "missing $SM_LIB"; exit 1; }

work="$(mktemp -d ./.verify-work-XXXXXX)"
trap 'rm -rf "$work"' EXIT

echo
echo "== [2/5] Compiling probe.cpp and linking it + libspidermonkey.a into one wasm32-wasi -dynamic -fPIC module =="
echo "   (this is the step that fails with R_WASM_MEMORY_ADDR_* 'recompile with -fPIC' errors"
echo "    -- see ../../world-shell-spike/engine-pic-fail.excerpt.log -- if the archive isn't PIC)"
#   probe.cpp is the harness itself, not the code under test, so we disable
#   clang's default UBSan instrumentation (-fno-sanitize=undefined) for its
#   compile: with -OReleaseSmall, `zig build-lib` does not auto-link its own
#   safety runtime, so any __ubsan_handle_* references left in probe.o would
#   otherwise show up as unrelated "undefined symbol" noise that has nothing
#   to do with PIC/relocation correctness.
"$ZIG" c++ -target wasm32-wasi -fPIC -std=gnu++23 \
  -fno-rtti -fno-exceptions -fno-sized-deallocation -fno-aligned-new \
  -fno-sanitize=undefined \
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
  -I"$SM_SRC/js/src" -I"$SM_OBJ/js/src" -I"$SM_INCLUDE" \
  -include "$SM_CONFDEFS" \
  -c probe.cpp -o "$work/probe.o"
"$ZIG" build-lib "$work/probe.o" "$SM_LIB" \
  -target wasm32-wasi -dynamic -fPIC -OReleaseSmall -lc -lc++ \
  --export=engine_verify --export=__wasm_call_ctors \
  -femit-bin="$work/sm-engine.wasm"

echo
echo "== Verifying the linked module is valid wasm and a real PIC dylib (has a dylink.0 section) =="
"$WASM_TOOLS" validate "$work/sm-engine.wasm"
"$WASM_TOOLS" print "$work/sm-engine.wasm" > "$work/sm-engine.wat"
grep -q '(@dylink.0' "$work/sm-engine.wat" \
  || { echo "FAIL: no dylink.0 section -- not a PIC dylib"; exit 1; }
echo "OK: valid wasm32-wasi PIC dylib with a dylink.0 section"

echo
echo "== [3/5] Building thin shell.wasm, embedding + composing with the engine module =="
# --export=__wasm_call_ctors on both modules: `zig build-lib -dynamic` does
# not export C++ static-initializer/PIC-global-relocation entry points by
# default (unlike Zig's own `export fn`), so without this,
# `wasm-tools component link`'s synthesized init function has nothing to
# call and the engine's static state is left uninitialized.
"$ZIG" build-lib shell.zig -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
  --export=__wasm_call_ctors \
  -femit-bin="$work/shell.wasm"
"$WASM_TOOLS" component embed --world demo -o "$work/shell-embedded.wasm" wit/ "$work/shell.wasm"
"$WASM_TOOLS" component link \
  engine="$work/sm-engine.wasm" shell="$work/shell-embedded.wasm" \
  --adapt wasi_snapshot_preview1="$ADAPTER" \
  -o "$work/linked.component.wasm"

echo
echo "== [4/5] Running the composed component with wasmtime =="
out=$("$WASMTIME" run --invoke 'shell-call(5, 7)' "$work/linked.component.wasm")
echo "shell-call(5, 7) = $out"
echo "(expected 112 = 5 + 7 + 100: +100 is only returned by engine_verify in probe.cpp after"
echo " JS_Init/JS_NewContext/JS_NewGlobalObject succeeded AND JS::Evaluate parsed and executed"
echo " '(5 + 7)' and returned 12, proving the PIC-linked archive's GC, parser, bytecode emitter"
echo " and interpreter all round-tripped correctly across the engine/shell module boundary)"
[ "$out" = "112" ] || { echo "FAIL: expected 112, got $out"; exit 1; }

echo
echo "== [5/5] Confirming sm-engine.wasm is a genuine PIC dylib (GOT-indirected, not just link-clean) =="
# The authoritative proof that libspidermonkey.a is PIC is that step 2 above
# succeeded at all: wasm-ld runs in `-shared` mode and aborts with
# "R_WASM_MEMORY_ADDR_SLEB ... recompile with -fPIC" (see
# ../../world-shell-spike/engine-pic-fail.excerpt.log for the exact error)
# the moment it hits a non-PIC-compiled archive member it cannot relocate at
# load time -- and `set -euo pipefail` above means this script would
# already have aborted had that happened.
#
# An earlier version of this step instead grepped every archive member's
# own, pre-link relocation records for "absolute-looking" forms
# (R_WASM_MEMORY_ADDR_I32/R_WASM_TABLE_INDEX_I32). That turned out to be an
# unreliable signal: it flags false positives even on probe.cpp's own
# known-good `-fPIC` compile (e.g. a R_WASM_MEMORY_ADDR_I32 relocation
# against JS::DefaultGlobalClassOpsE, which wasm-ld fixes up correctly
# while statically combining objects into the shared object). Individual
# .o files legitimately contain a mix of relocation forms that get resolved
# when objects are merged, regardless of whether the *final* linked module
# ends up PIC -- so per-object metadata/grep alone cannot tell PIC and
# non-PIC archives apart; only the real link (steps 2-4) and the final
# module's own structure (below) can.
#
# So instead we inspect the actual linked sm-engine.wasm for the concrete,
# load-bearing markers of the WebAssembly "Shared-Everything Dynamic
# Linking" convention
# (https://github.com/WebAssembly/tool-conventions/blob/main/DynamicLinking.md)
# that only appear when code/data references were genuinely emitted
# relative to a runtime-supplied base rather than baked in as fixed
# addresses:
#   - it imports env.__memory_base / env.__table_base, the bases every PIC
#     reference in the module is computed relative to at load time, and
#   - it imports a large number of GOT.mem / GOT.func entries, the
#     indirection cells archive-derived code/data symbols route through
#     instead of embedding literal addresses.
"$WASM_TOOLS" print "$work/sm-engine.wasm" > "$work/sm-engine-final.wat"
grep -q '(import "env" "__memory_base"' "$work/sm-engine-final.wat" \
  || { echo "FAIL: sm-engine.wasm does not import env.__memory_base"; exit 1; }
grep -q '(import "env" "__table_base"' "$work/sm-engine-final.wat" \
  || { echo "FAIL: sm-engine.wasm does not import env.__table_base"; exit 1; }
got_count=$(grep -cE '\(import "GOT\.(mem|func)"' "$work/sm-engine-final.wat" || true)
echo "sm-engine.wasm imports $got_count GOT.mem/GOT.func entries"
if [[ "$got_count" -eq 0 ]]; then
  echo "FAIL: no GOT.mem/GOT.func imports -- archive-derived code/data may not be PIC-relocated"
  exit 1
fi
echo "OK: sm-engine.wasm imports env.__memory_base/env.__table_base and $got_count GOT.mem/GOT.func entries"

echo
echo "PASS: libspidermonkey.a is PIC and links + runs as a wasm32-wasi dynamic library."
