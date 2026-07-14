#!/usr/bin/env bash
# End-to-end coverage for the typed native JS dispatch bridge
# (runtime/js_dispatch.{h,cpp,zig}): builds a dedicated dispatch-enabled
# `starling-raw.wasm`, componentizes tests/fixtures/js-dispatch.js against
# the `starling:js/api` world, and drives every exported function through
# `wasmtime run --invoke`, asserting exact output for the boundary/edge
# cases called out in the typed-bridge-spike review:
#
#   * max/full-domain i64/u64 (including values >= 2**63, which a naive
#     "i64_val < 0" BigInt-sign check misdetects -- see js_dispatch.h/.zig)
#   * a record combining a string field with a u64 field (label-id),
#     exercising the UAF fix directly: both the string and the u64 are
#     decoded from the same native result, after which the C++ NativeArena
#     backing them is freed
#   * optional i64/u64 some/none, decoded from the real "bare tag, no
#     option_some wrapper" shape decode_from_js actually produces
#   * list<u64> (sum-list, echo-list), exercising the LIST tag end to end
#   * a deliberately wrong-typed JS export (wrong-type), asserting it traps
#     instead of silently decoding to 0/false
#   * existing JSON-path exports (add/greet/notify/move/maybe), as a
#     regression check that non-migrated types still work unchanged
#
# Usage: run.sh [zig-binary] [install-prefix]
#   zig-binary defaults to `zig` on PATH; install-prefix defaults to
#   <repo-root>/zig-out-native-dispatch-e2e (kept separate from the normal
#   zig-out/ produced by a plain `zig build`, since this uses a distinct
#   `-Dcomponent-world`).
set -euo pipefail

# Repo root is derived from this script's own location (not the caller's
# cwd), so it's correct whether invoked manually or from `zig build test`
# (whose Run steps execute with the build root as cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ZIG_BIN="${1:-zig}"
PREFIX="${2:-$REPO_ROOT/zig-out-native-dispatch-e2e}"

cd "$REPO_ROOT"

echo "[native-dispatch e2e] building dispatch-enabled runtime into $PREFIX"
"$ZIG_BIN" build install --prefix "$PREFIX" \
  -Doptimize=ReleaseSmall \
  -Dcomponent-wit=host-apis/wasi-0.2.10/wit \
  -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=host-apis/wasi-0.2.10/wit/deps/starling-js \
  -Ddispatch-world=js-exports

BIN="$PREFIX/bin"
COMPONENT="$PREFIX/js-dispatch.wasm"

echo "[native-dispatch e2e] componentizing tests/fixtures/js-dispatch.js"
# See wabt-shim.sh: substitutes wasm-tools for the wabt CLI in this
# environment (a discovered tooling limitation, not a js_dispatch bug).
WABT="$REPO_ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
WASM_TOOLS_BIN="$BIN/wasm-tools" \
  "$BIN/componentize.sh" tests/fixtures/js-dispatch.js -o "$COMPONENT"

echo "[native-dispatch e2e] validating component"
"$BIN/wasm-tools" validate --features all "$COMPONENT"

WASMTIME="$BIN/wasmtime"
fail=0

# expect_eq NAME INVOKE_EXPR EXPECTED_STDOUT
expect_eq() {
  local name="$1" expr="$2" expected="$3" actual status
  actual=$("$WASMTIME" run -S http --invoke "$expr" "$COMPONENT" 2>&1) && status=0 || status=$?
  if [ "$status" -ne 0 ]; then
    echo "FAIL $name: wasmtime exited $status invoking '$expr': $actual"
    fail=1
    return
  fi
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $name: invoking '$expr' expected [$expected] got [$actual]"
    fail=1
    return
  fi
  echo "PASS $name"
}

# expect_trap NAME INVOKE_EXPR
expect_trap() {
  local name="$1" expr="$2" status
  "$WASMTIME" run -S http --invoke "$expr" "$COMPONENT" >/dev/null 2>&1 && status=0 || status=$?
  if [ "$status" -eq 0 ]; then
    echo "FAIL $name: invoking '$expr' expected a trap, but it exited 0"
    fail=1
    return
  fi
  echo "PASS $name (trapped with exit $status)"
}

# --- Existing JSON-path regressions (unmigrated types keep working) -------
expect_eq "add (JSON path)" "add(2, 3)" "5"
expect_eq "greet (JSON path)" 'greet("world")' '"Hello, world!"'
expect_eq "move (JSON path)" "move({x: 1, y: 2}, 3, 4)" "{x: 4, y: 6}"
expect_eq "maybe none (JSON path)" "maybe(none)" "none"
expect_eq "maybe some (JSON path)" "maybe(some(41))" "some(42)"

# --- Full-domain i64/u64 boundaries (native bridge) ------------------------
expect_eq "big-add u64::MAX" "big-add(18446744073709551615, 0)" "18446744073709551615"
expect_eq "big-add at 2**63" "big-add(9223372036854775808, 0)" "9223372036854775808"
expect_eq "big-sub small" "big-sub(10, 3)" "7"
expect_eq "big-sub near i64::MIN" "big-sub(-9223372036854775807, 1)" "-9223372036854775808"

# --- Nested record with string + u64 (the UAF-prone shape) -----------------
expect_eq "tag-point nested record + u64" \
  "tag-point({x: 1, y: 2}, 18446744073709551615)" \
  "{p: {x: 1, y: 2}, id: 18446744073709551615}"
expect_eq "label-id record(string, u64) -- UAF regression" \
  'label-id("hi", 18446744073709551615)' \
  '{label: "hi-tagged", id: 18446744073709551615}'
expect_eq "nul-label preserves embedded NUL bytes" \
  "nul-label(1)" \
  '{label: "a\u{0}b", id: 1}'

# --- Optional i64/u64 some/none --------------------------------------------
expect_eq "maybe-big none" "maybe-big(none)" "none"
expect_eq "maybe-big some near u64::MAX" \
  "maybe-big(some(18446744073709551614))" "some(18446744073709551615)"
expect_eq "maybe-signed none" "maybe-signed(none)" "none"
expect_eq "maybe-signed some near i64::MIN" \
  "maybe-signed(some(-9223372036854775807))" "some(-9223372036854775808)"

# --- list<u64> ---------------------------------------------------------
expect_eq "sum-list with full-domain u64 element" \
  "sum-list([1, 2, 18446744073709551612])" "18446744073709551615"
expect_eq "echo-list round-trips exact values" \
  "echo-list([0, 1, 18446744073709551615])" "[0, 1, 18446744073709551615]"

# --- Wrong JS return type must trap, not silently coerce -------------------
expect_trap "wrong-type traps instead of decoding to 0" "wrong-type()"

if [ "$fail" -ne 0 ]; then
  echo "[native-dispatch e2e] FAILED"
  exit 1
fi
echo "[native-dispatch e2e] all checks passed"
