#!/usr/bin/env bash
#
# Full, real-build component-level tests for the feature-selection build
# options (cataggar/StarlingMonkey#6 Phase 6; see build.zig's "Platform
# feature selection" section and docs/feature-selection/README.md).
#
# Unlike run-build-option-tests.sh (fast, Node-free, part of `zig build
# test`), this script actually builds a full StarlingMonkey runtime for
# each feature combination under test (via the pinned Zig toolchain),
# componentizes tests/feature-selection/fixtures/*.js, inspects the
# resulting component's WASI import/export surface with `wasm-tools
# component wit`, and invokes representative components through
# `wasmtime serve` + curl -- following exactly the same
# `wasmtime serve -S common --addr 0.0.0.0:0` / poll-stderr-for-"Serving
# HTTP" / extract-port pattern as tests/test.sh. It is deliberately NOT a
# dependency of `zig build test` (each full build takes on the order of a
# minute or more; ~8 combinations add up), matching the
# `compat-bridge-test` precedent (tests/compat/runtime) of keeping slow,
# real-build verification in its own opt-in step
# (`feature-selection-runtime-test`).
#
# For the *reference* (real ComponentizeJS 0.21.0) half of this
# comparison, see tests/feature-selection/reference/README.md (opt-in,
# requires Node, and not invoked by this script).
#
# Usage: tests/feature-selection/run-runtime-tests.sh [combo-name ...]
#
# Required environment:
#   ZIG                    Path to the pinned Zig toolchain binary.
#   ZIG_GLOBAL_CACHE_DIR   (optional) defaults to <repo>/.zig-global-cache
#
# Optional environment:
#   KEEP_BUILDS=1          Do not delete tests/feature-selection/.build/*
#                          after the run (useful for debugging).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ZIG="${ZIG:-zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

BUILD_ROOT="$HERE/.build"
mkdir -p "$BUILD_ROOT"

pass_count=0
fail_count=0
fail=0

log() { echo "$@"; }

fail_case() {
  fail_count=$((fail_count + 1))
  fail=1
  echo "FAIL $1 -- $2"
}

pass_case() {
  pass_count=$((pass_count + 1))
  echo "PASS $1"
}

# assert_contains NAME HAYSTACK NEEDLE
assert_contains() {
  if grep -qF -- "$3" <<<"$2"; then
    pass_case "$1 contains '$3'"
    return 0
  fi
  fail_case "$1" "expected output to contain: $3"
  return 1
}

# assert_not_contains NAME HAYSTACK NEEDLE
assert_not_contains() {
  if ! grep -qF -- "$3" <<<"$2"; then
    pass_case "$1 excludes '$3'"
    return 0
  fi
  fail_case "$1" "expected output to NOT contain: $3"
  return 1
}

# build_combo NAME BUILD_FLAGS...
# Builds a full StarlingMonkey runtime with the given -D flags into
# tests/feature-selection/.build/<NAME>/bin. Prints the bin dir on
# success, returns nonzero (with build log on stderr) on failure.
build_combo() {
  local name="$1"; shift
  local prefix="$BUILD_ROOT/$name"
  local log="$BUILD_ROOT/$name.build.log"
  rm -rf "$prefix"
  if ! "$ZIG" build -Doptimize=ReleaseFast --prefix "$prefix" "$@" >"$log" 2>&1; then
    echo "build failed for combo '$name' (see $log):" >&2
    tail -n 60 "$log" >&2
    return 1
  fi
  echo "$prefix/bin"
}

# componentize BIN_DIR FIXTURE_JS OUT_WASM
# Returns the componentize.sh exit code; stdout/stderr are captured to
# $BIN_DIR/$OUT_WASM.out.log / .err.log alongside the requested output.
componentize() {
  local bin="$1" fixture="$2" out="$3"
  ( cd "$bin" && bash componentize.sh "$fixture" -o "$out" \
      >"$out.out.log" 2>"$out.err.log" )
}

# wit_surface BIN_DIR WASM -> prints import/export lines
wit_surface() {
  "$1/wasm-tools" component wit "$2" 2>&1
}

# serve_and_curl BIN_DIR WASM PATH -> prints "STATUS\nBODY"
# Starts `wasmtime serve` on an OS-assigned port (0.0.0.0:0, exactly like
# tests/test.sh), waits for it to report "Serving HTTP", curls the given
# path, then tears the server down.
serve_and_curl() {
  local bin="$1" wasm="$2" path="${3:-}"
  local stdout_log="$wasm.serve.out.log" stderr_log="$wasm.serve.err.log"
  "$bin/wasmtime" serve -S common --addr 0.0.0.0:0 "$wasm" \
    >"$stdout_log" 2>"$stderr_log" &
  local pid="$!"
  local waited=0
  until grep -q -m1 "Serving HTTP" "$stderr_log" 2>/dev/null || ! kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then break; fi
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "STATUS:000"
    echo "wasmtime exited early:"
    cat "$stderr_log"
    return 0
  fi
  local port
  port="$(head -n 1 "$stderr_log" | tail -c 7 | head -c 5)"
  local status body
  status="$(curl -s -m 10 -o "$wasm.body.log" -w '%{http_code}' "http://127.0.0.1:$port/$path")"
  body="$(cat "$wasm.body.log" 2>/dev/null)"
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "STATUS:$status"
  echo "$body"
}

# ---------------------------------------------------------------------
# Combo table. Each entry: name, build flags (array), fixture, and a
# case-specific check function (defined below the table).
# ---------------------------------------------------------------------

ALL_COMBOS=(defaults stdio-disabled random-disabled clocks-disabled http-disabled fetch-event-disabled http-and-fetch-event-disabled all-disabled)
REQUESTED=("${@:-${ALL_COMBOS[@]}}")

flags_for() {
  case "$1" in
    defaults) echo "" ;;
    stdio-disabled) echo "-Dfeature-stdio=false" ;;
    random-disabled) echo "-Dfeature-random=false" ;;
    clocks-disabled) echo "-Dfeature-clocks=false" ;;
    http-disabled) echo "-Dfeature-http=false" ;;
    fetch-event-disabled) echo "-Dfeature-fetch-event=false" ;;
    http-and-fetch-event-disabled) echo "-Dfeature-http=false -Dfeature-fetch-event=false" ;;
    all-disabled) echo "-Dfeature-stdio=false -Dfeature-random=false -Dfeature-clocks=false -Dfeature-http=false -Dfeature-fetch-event=false" ;;
    *) echo "" ;;
  esac
}

check_combo() {
  local name="$1" bin="$2"
  local features_json
  features_json="$(cat "$bin/features.json" 2>/dev/null || echo "{}")"

  case "$name" in
    defaults)
      assert_contains "$name/features.json" "$features_json" '"stdio": true'
      assert_contains "$name/features.json" "$features_json" '"random": true'
      assert_contains "$name/features.json" "$features_json" '"clocks": true'
      assert_contains "$name/features.json" "$features_json" '"http": true'
      assert_contains "$name/features.json" "$features_json" '"fetch-event": true'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      assert_contains "$name/imports" "$wit" "wasi:random/random@0.2.10"
      assert_contains "$name/imports" "$wit" "wasi:http/outgoing-handler@0.2.10"
      assert_contains "$name/imports" "$wit" "wasi:cli/terminal-input@0.2.10"
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve" "$result" "STATUS:200"
      assert_contains "$name/serve" "$result" "random:ok:"
      assert_contains "$name/serve" "$result" "clocks:ok"
      assert_contains "$name/serve" "$result" "http:"
      ;;

    stdio-disabled)
      assert_contains "$name/features.json" "$features_json" '"stdio": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      assert_not_contains "$name/imports" "$wit" "wasi:cli/terminal-input@0.2.10"
      assert_not_contains "$name/imports" "$wit" "wasi:cli/terminal-output@0.2.10"
      assert_not_contains "$name/imports" "$wit" "wasi:cli/terminal-stdin@0.2.10"
      assert_not_contains "$name/imports" "$wit" "wasi:cli/terminal-stdout@0.2.10"
      assert_not_contains "$name/imports" "$wit" "wasi:cli/terminal-stderr@0.2.10"
      # Documented residual (adapter-level, unavoidable -- see
      # docs/feature-selection/README.md "Known deviations"): the
      # preview1->preview2 adapter always imports these three regardless
      # of whether the core module still calls fd_write/fd_fdstat_get.
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:cli/stdin@0.2.10"
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:cli/stdout@0.2.10"
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:cli/stderr@0.2.10"
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve" "$result" "STATUS:200"
      assert_contains "$name/serve" "$result" "random:ok:"
      ;;

    random-disabled)
      assert_contains "$name/features.json" "$features_json" '"random": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      assert_not_contains "$name/imports" "$wit" "wasi:random/random@0.2.10"
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve" "$result" "STATUS:200"
      # Deterministic splitmix64 stub output for a zeroed/first call --
      # asserting the response is well-formed and marked "ok" (not
      # "caught") is the key behavioral property; the exact byte values
      # are an internal implementation detail, not a compatibility
      # requirement (see docs/feature-selection/README.md).
      assert_contains "$name/serve" "$result" "random:ok:"
      assert_not_contains "$name/serve" "$result" "random:caught:"
      ;;

    clocks-disabled)
      assert_contains "$name/features.json" "$features_json" '"clocks": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      # Documented deviation from the ComponentizeJS reference (which
      # drops wasi:clocks/monotonic-clock when clocks is disabled): this
      # repository deliberately keeps MonotonicClock::subscribe/unsubscribe
      # real because the async task scheduler depends on them for
      # unrelated fetch/stream fairness -- see
      # docs/feature-selection/README.md "Known deviations". Both clock
      # imports are therefore expected to remain present.
      assert_contains "$name/imports (documented deviation)" "$wit" "wasi:clocks/monotonic-clock@0.2.10"
      assert_contains "$name/imports (documented deviation)" "$wit" "wasi:clocks/wall-clock@0.2.10"
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve" "$result" "STATUS:200"
      assert_contains "$name/serve" "$result" "clocks:caught:setTimeout is disabled by build configuration (feature-selection: clocks disabled)"
      ;;

    http-disabled)
      assert_contains "$name/features.json" "$features_json" '"http": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      assert_not_contains "$name/imports" "$wit" "wasi:http/outgoing-handler@0.2.10"
      assert_contains "$name/imports" "$wit" "wasi:http/types@0.2.10"
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve" "$result" "STATUS:200"
      assert_contains "$name/serve" "$result" "http:caught:"
      ;;

    fetch-event-disabled)
      assert_contains "$name/features.json" "$features_json" '"fetch-event": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      # fetch-event alone does not change the HTTP import surface --
      # matches the ComponentizeJS reference exactly (see
      # tests/feature-selection/reference/expected/import-surfaces.json's
      # "disable-fetch-event-only" case, identical to "defaults").
      assert_contains "$name/imports" "$wit" "wasi:http/outgoing-handler@0.2.10"
      assert_contains "$name/imports" "$wit" "wasi:http/types@0.2.10"
      # probe.js's addEventListener('fetch', ...) throws and is caught, so
      # no handler is registered; a live request must still fail
      # deterministically via the pre-existing REQUEST_HANDLER_ONLY guard,
      # not hang.
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve (no handler registered)" "$result" "STATUS:500"
      # Diagnostic-text check: a *separate*, deliberately-uncaught fixture
      # must print the exact FeatureDisabled message to stderr during
      # componentize.sh (stdio remains enabled in this combo).
      componentize "$bin" "$HERE/fixtures/uncaught-fetch-event.js" "uncaught.wasm"
      local err; err="$(cat "$bin/uncaught.wasm.err.log" 2>/dev/null || true)"
      assert_contains "$name/diagnostic" "$err" "addEventListener('fetch', ...) is disabled by build configuration (feature-selection: fetch-event disabled)"
      ;;

    http-and-fetch-event-disabled)
      assert_contains "$name/features.json" "$features_json" '"http": false'
      assert_contains "$name/features.json" "$features_json" '"fetch-event": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      assert_not_contains "$name/imports" "$wit" "wasi:http/outgoing-handler@0.2.10"
      # Documented residual (see docs/feature-selection/README.md "Known
      # deviations"): wasi:http/types and the wasi:http/incoming-handler
      # export remain even with both http and fetch-event disabled,
      # because they are baked into the fixed, prebuilt component-type
      # descriptor shared by every StarlingMonkey build (bindings_
      # component_type.o), which is out of this phase's scope to modify
      # (owned by the sibling wit-imports/promise agents). The
      # pre-existing MOZ_RELEASE_ASSERT(REQUEST_HANDLER) guard in
      # host_api.cpp already makes an incoming request deterministically
      # fail regardless.
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:http/types@0.2.10"
      assert_contains "$name/exports (documented residual)" "$wit" "wasi:http/incoming-handler@0.2.10"
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve (no handler registered)" "$result" "STATUS:500"
      componentize "$bin" "$HERE/fixtures/uncaught-fetch-event.js" "uncaught.wasm"
      local err; err="$(cat "$bin/uncaught.wasm.err.log" 2>/dev/null || true)"
      assert_contains "$name/diagnostic" "$err" "addEventListener('fetch', ...) is disabled by build configuration (feature-selection: fetch-event disabled)"
      ;;

    all-disabled)
      assert_contains "$name/features.json" "$features_json" '"stdio": false'
      assert_contains "$name/features.json" "$features_json" '"random": false'
      assert_contains "$name/features.json" "$features_json" '"clocks": false'
      assert_contains "$name/features.json" "$features_json" '"http": false'
      assert_contains "$name/features.json" "$features_json" '"fetch-event": false'
      componentize "$bin" "$HERE/fixtures/probe.js" "probe.wasm"
      local wit; wit="$(wit_surface "$bin" "$bin/probe.wasm")"
      # Pure-mode "smallest viable import surface": every prunable import
      # is gone (terminal-*, random/random, http/outgoing-handler).
      assert_not_contains "$name/imports" "$wit" "wasi:cli/terminal-input@0.2.10"
      assert_not_contains "$name/imports" "$wit" "wasi:random/random@0.2.10"
      assert_not_contains "$name/imports" "$wit" "wasi:http/outgoing-handler@0.2.10"
      # Documented structural residuals (adapter-level stdio/clocks
      # imports and the fixed http/types+incoming-handler component
      # shape; see docs/feature-selection/README.md "Known deviations").
      # This is NOT a zero-import surface, unlike ComponentizeJS's
      # disable-all probe (tests/feature-selection/reference/expected/
      # import-surfaces.json), because StarlingMonkey's WASI closure
      # includes many structural imports (filesystem, sockets, cli/
      # environment+exit, the preview1 adapter's fixed baseline) that are
      # out of this phase's scope (only stdio/random/clocks/http/
      # fetch-event are gated).
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:cli/stdin@0.2.10"
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:clocks/monotonic-clock@0.2.10"
      assert_contains "$name/imports (documented residual)" "$wit" "wasi:http/types@0.2.10"
      # No working handler can be registered (fetch-event disabled); a
      # live request must still fail deterministically (HTTP 500 via the
      # pre-existing REQUEST_HANDLER_ONLY guard), not hang or corrupt
      # state, even with stdio (and thus all diagnostic output) disabled.
      local result; result="$(serve_and_curl "$bin" "$bin/probe.wasm" "")"
      assert_contains "$name/serve (no handler registered)" "$result" "STATUS:500"
      ;;

    *)
      fail_case "$name" "unknown combo name"
      ;;
  esac
}

for name in "${REQUESTED[@]}"; do
  echo "== $name =="
  flags="$(flags_for "$name")"
  # shellcheck disable=SC2086
  bin="$(build_combo "$name" $flags)"
  if [ -z "$bin" ]; then
    fail_case "$name/build" "componentization build failed"
    continue
  fi
  check_combo "$name" "$bin"
done

if [ "${KEEP_BUILDS:-0}" != "1" ]; then
  rm -rf "$BUILD_ROOT"
fi

echo ""
echo "feature-selection runtime tests: $pass_count passed, $fail_count failed"
[ "$fail" = 0 ]
