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
#   * numeric wraparound (wrap-numbers, sum-list overflow): an out-of-range/
#     negative/fractional Number or BigInt of the *correct* kind wraps
#     modulo 2**bitwidth (ToInt32/ToUint32-family, ToBigInt64/ToBigUint64),
#     matching the pinned ComponentizeJS reference exactly -- this is
#     deliberately NOT a trap, unlike a wrong-*kind* result
#   * existing JSON-path exports (add/greet/notify/move/maybe), as a
#     regression check that non-migrated types still work unchanged
#   * char, list<u8> (vs. string), tuple, enum, flags, variant, and
#     result<T, E> (both nested and as an export's own top-level return
#     type, which uses ComponentizeJS's "return means Ok, throw means Err"
#     calling convention instead of a {tag, val} object)
#   * naming/version edge cases: multi-word record fields/flags labels
#     (camelCased on the JS side) vs. multi-word enum/variant case labels
#     (kept in their original kebab-case spelling), and a kebab-case export
#     name resolved only via the camelCase JS export-name fallback
#   * named-interface topology: `api` is required to be an object containing
#     callable members; flat, missing, non-object, and non-callable shapes
#     all trap instead of being flattened
#   * a battery of wrong-type/invalid-discriminant negative cases for every
#     new value class above, asserting each traps instead of silently
#     decoding to a plausible-looking but wrong value
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

# Every invocation is bounded (see promise-deadlock below): the pump loop's
# "no progress" diagnostic must trap deterministically, never hang, but this
# guards the test itself against ever silently turning a real bug into an
# indefinite CI hang.
TIMEOUT_SECS=30

# expect_eq NAME INVOKE_EXPR EXPECTED_STDOUT
expect_eq() {
  local name="$1" expr="$2" expected="$3" actual status
  actual=$(timeout "$TIMEOUT_SECS" "$WASMTIME" run -S http --invoke "$expr" "$COMPONENT" 2>&1) && status=0 || status=$?
  if [ "$status" -eq 124 ]; then
    echo "FAIL $name: invoking '$expr' timed out after ${TIMEOUT_SECS}s (hung instead of trapping/returning)"
    fail=1
    return
  fi
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
  timeout "$TIMEOUT_SECS" "$WASMTIME" run -S http --invoke "$expr" "$COMPONENT" >/dev/null 2>&1 && status=0 || status=$?
  if [ "$status" -eq 124 ]; then
    echo "FAIL $name: invoking '$expr' timed out after ${TIMEOUT_SECS}s (hung instead of trapping)"
    fail=1
    return
  fi
  if [ "$status" -eq 0 ]; then
    echo "FAIL $name: invoking '$expr' expected a trap, but it exited 0"
    fail=1
    return
  fi
  echo "PASS $name (trapped with exit $status)"
}

# expect_core_diagnostic NAME CORE_MODULE EXPECTED_DIAGNOSTIC [INVOKE_EXPR]
expect_core_diagnostic() {
  local name="$1" core_module="$2" expected_diagnostic="$3"
  local invoke_expr="${4:-starling:js/api#phantom}" actual status
  actual=$(timeout "$TIMEOUT_SECS" "$NAMESPACE_BIN/wasmtime" run \
    -S cli -W unknown-imports-trap \
    --invoke "$invoke_expr" "$core_module" 2>&1) && status=0 || status=$?
  if [ "$status" -eq 124 ]; then
    echo "FAIL $name: invocation timed out after ${TIMEOUT_SECS}s"
    fail=1
    return
  fi
  if [ "$status" -ne 0 ]; then
    if grep -Fxq "Error: $expected_diagnostic" <<<"$actual" && \
       grep -Fq 'wasm trap:' <<<"$actual"; then
      echo "PASS $name (call-time trap contained exact guest diagnostic)"
      return
    fi
    echo "FAIL $name: expected a call-time trap with guest diagnostic [$expected_diagnostic]: $actual"
  else
    echo "FAIL $name: expected a call-time trap, but invocation succeeded: $actual"
  fi
  fail=1
}

# --- Existing scalar/record regressions -----------------------------------
expect_eq "add (JSON path)" "add(2, 3)" "5"
expect_eq "greet (JSON path)" 'greet("world")' '"Hello, world!"'
expect_eq "move (JSON path)" "move({x: 1, y: 2}, 3, 4)" "{x: 4, y: 6}"
expect_eq "maybe none (native option path)" "maybe(none)" "none"
expect_eq "maybe some (native option path)" "maybe(some(41))" "some(42)"

# --- option<T> JavaScript shape parity ----------------------------------
# These options intentionally use the native bridge even though u32 itself
# is JSON-safe: JSON cannot represent undefined or nested option states.
expect_eq "direct option none lifts to undefined" \
  "direct-option-shape(none)" '"undefined"'
expect_eq "direct option some stays its bare value" \
  "direct-option-shape(some(7))" '"value"'
expect_eq "aggregate option none lifts to undefined in record/list/tuple" \
  "aggregate-option-shapes({direct: none, items: [none, some(1)], pair: (none, some(2)), maybe-shape: none, maybe-result: none})" \
  '["undefined", "undefined", "value", "undefined", "value"]'
expect_eq "nested option outer none is tagged" \
  "nested-option-shape({nested: none})" '"none:missing"'
expect_eq "nested option some-none keeps undefined payload" \
  "nested-option-shape({nested: some(none)})" '"some:undefined"'
expect_eq "nested option some-some keeps value payload" \
  "nested-option-shape({nested: some(some(42))})" '"some:value"'
expect_eq "JS null lowers to option none" "lower-null()" "none"
expect_eq "JS undefined lowers to option none" "lower-undefined()" "none"
expect_eq "option values round-trip in variant and result positions" \
  'echo-option-aggregate({direct: some(4), items: [none, some(1)], pair: (none, some(2)), maybe-shape: some(circle(3)), maybe-result: some(err("bad"))})' \
  '{direct: some(4), items: [none, some(1)], pair: (none, some(2)), maybe-shape: some(circle(3)), maybe-result: some(err("bad"))}'

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

# --- promise-sync: synchronous exports whose JS implementation returns a --
# Promise/thenable are pumped to completion, then lowered exactly like a
# directly-returned value (JSON path first, then the typed native/BigInt
# path). See runtime/js_dispatch.cpp's `resolve_promise_like`.
expect_eq "promise-resolve-add: already-settled Promise.resolve" \
  "promise-resolve-add(2, 3)" "5"
expect_eq "promise-add: microtask chain + nested awaits" \
  "promise-add(2, 3)" "5"
expect_trap "promise-reject: rejection traps instead of decoding" "promise-reject()"
expect_eq "thenable-add: non-Promise thenable object" "thenable-add(2, 3)" "5"
expect_eq "promise-timeout-add: settles via a queued setTimeout task" \
  "promise-timeout-add(2, 3)" "5"
expect_eq "promise-notify: void result reached via a Promise" \
  'promise-notify("hi")' "()"
expect_eq "promise-resolve-point: Promise.resolve of a typed nested record" \
  "promise-resolve-point({x: 1, y: 2}, 3, 4)" "{x: 4, y: 6}"
expect_trap "promise-deadlock: never-settling Promise traps deterministically (no hang)" \
  "promise-deadlock()"

# Same shapes again through the typed native (BigInt) dispatch path.
expect_eq "promise-resolve-big-add: Promise.resolve of a typed BigInt" \
  "promise-resolve-big-add(18446744073709551615, 0)" "18446744073709551615"
expect_eq "promise-big-add: async function awaiting BigInt values" \
  "promise-big-add(18446744073709551614, 1)" "18446744073709551615"
expect_trap "promise-reject-big: rejection traps on the native dispatch path too" \
  "promise-reject-big()"
# --- Numeric wraparound (ComponentizeJS/ECMAScript modular semantics, not a
# trap) for out-of-range/negative/fractional Numbers and BigInts of the
# correct kind -- re-verified against the pinned reference itself (see
# tests/compat/fixtures/integers-64bit "sum-list-basic").
expect_eq "wrap-numbers wraps out-of-range/negative/fractional numeric results instead of trapping" \
  "wrap-numbers()" \
  "{overflow-u8: 44, negative-u8: 251, fractional-u8: 3, overflow-s32: -2147483648, negative-u64: 18446744073709551611, overflow-s64: 0}"
expect_eq "sum-list wraps past u64::MAX instead of trapping" \
  "sum-list([18446744073709551615, 1])" "0"

# --- char -------------------------------------------------------------
expect_eq "echo-char ascii" "echo-char('e')" "'e'"
expect_eq "echo-char multi-byte scalar value" "echo-char('é')" "'é'"
expect_trap "wrong-type-char traps on a non-string result" "wrong-type-char()"
expect_trap "invalid-char-multi-codepoint traps on more than one scalar value" \
  "invalid-char-multi-codepoint()"

# --- list<u8> vs string -------------------------------------------------
expect_eq "echo-bytes round-trips a Uint8Array" "echo-bytes([1, 2, 3])" "[1, 2, 3]"
expect_eq "bytes-len counts bytes, not codepoints" "bytes-len([1, 2, 3])" "3"
expect_trap "wrong-type-bytes traps on neither Uint8Array nor Array" "wrong-type-bytes()"

# --- tuple ---------------------------------------------------------------
expect_eq "swap-pair round-trips as a positional array" \
  'swap-pair((5, "hi"))' '("hi", 5)'
expect_trap "wrong-type-tuple traps on a non-array result" "wrong-type-tuple()"

# --- enum ------------------------------------------------------------
expect_eq "echo-direction single-word case" "echo-direction(north)" "north"
expect_eq "echo-direction kebab-case multi-word case" "echo-direction(north-east)" "north-east"
expect_trap "invalid-enum-case traps on an unrecognized case string" "invalid-enum-case()"
expect_trap "wrong-type-enum traps on a non-string result" "wrong-type-enum()"

# --- flags -----------------------------------------------------------
expect_eq "echo-perms round-trips a partial flag set" \
  "echo-perms({can-read, can-execute})" "{can-read, can-execute}"
expect_eq "echo-perms round-trips the empty flag set" "echo-perms({})" "{}"
expect_trap "missing-flags-property traps on a missing required label" \
  "missing-flags-property()"
expect_trap "wrong-type-flags traps on a non-object result" "wrong-type-flags()"

# --- variant -----------------------------------------------------------
expect_eq "echo-shape payload case" "echo-shape(circle(5))" "circle(5)"
expect_eq "echo-shape void-payload case" "echo-shape(point)" "point"
expect_trap "invalid-variant-tag traps on an unrecognized discriminant" \
  "invalid-variant-tag()"
expect_trap "wrong-type-variant traps on a non-object result" "wrong-type-variant()"

# --- result<T, E> --------------------------------------------------------
expect_eq "echo-wrapped-result nested ok case" \
  "echo-wrapped-result({r: ok(5)})" "{r: ok(5)}"
expect_eq "echo-wrapped-result nested err case" \
  'echo-wrapped-result({r: err("bad")})' '{r: err("bad")}'
expect_eq "divide ok (top-level result, return-means-ok convention)" "divide(10, 2)" "ok(5)"
expect_eq "divide err (top-level result, throw-means-err convention)" \
  "divide(10, 0)" 'err("division by zero")'
expect_eq "checked-negate ok (void-E result on success)" "checked-negate(5)" "ok(-5)"
expect_eq "checked-negate err (void-E result, throwing anything signals err)" \
  "checked-negate(-2147483648)" "err"

# --- naming/version edge cases -------------------------------------------
expect_eq "echo-multi-word-record camelCases field names on the JS side" \
  'echo-multi-word-record({first-value: 1, second-value: "x"})' \
  '{first-value: 1, second-value: "x"}'
expect_eq "echo-multi-word-flags camelCases label names on the JS side" \
  "echo-multi-word-flags({can-read-write})" "{can-read-write}"
expect_eq "echo-multi-word-enum keeps kebab-case case labels" \
  "echo-multi-word-enum(south-west)" "south-west"
expect_eq "echo-multi-word-variant keeps kebab-case discriminants" \
  "echo-multi-word-variant(left-turn(3))" "left-turn(3)"
expect_eq "multi-word-echo resolves via the camelCase export-name fallback" \
  "multi-word-echo(5)" "6"

# --- Named-interface topology ---------------------------------------------
# Missing-export validation intentionally remains call-time behavior here,
# but interface-qualified dispatch must reject every invalid namespace
# shape. A flat `phantom` must not stand in for `api.phantom`.
#
# Use a focused real WIT interface and retain each Wizer-frozen core reactor
# for stderr assertions. Invoking that core export directly keeps the guest
# diagnostic visible; invoking the subsequently adapted component masks a
# first stderr write behind the preview1 adapter's lazy initialization trap.
# The componentized form is still built and validated below, while the core
# invocation proves the dispatch failure itself happens at call time.
NAMESPACE_WIT="$PREFIX/namespace-wit"
python3 tests/compat/lib/gen_bridge_wit.py \
  host-apis/wasi-0.2.10/wit \
  tests/e2e/native-dispatch/namespace-wit \
  "$NAMESPACE_WIT" >/dev/null
NAMESPACE_WIT_REL="$(realpath --relative-to="$REPO_ROOT" "$NAMESPACE_WIT")"
NAMESPACE_PREFIX="$PREFIX/namespace-runtime"
"$ZIG_BIN" build install --prefix "$NAMESPACE_PREFIX" \
  -Doptimize=ReleaseSmall \
  -Dcomponent-wit="$NAMESPACE_WIT_REL" \
  -Dcomponent-world=js-dispatch \
  -Ddispatch-wit="$NAMESPACE_WIT_REL/deps/starling-js" \
  -Ddispatch-world=js-exports
NAMESPACE_BIN="$NAMESPACE_PREFIX/bin"

for shape in flat missing-namespace nonobject-namespace missing-member noncallable-member; do
  fixture="$REPO_ROOT/tests/fixtures/js-dispatch-$shape.js"
  core_module="$PREFIX/js-dispatch-$shape.core.wasm"
  shape_component="$PREFIX/js-dispatch-$shape.wasm"
  echo "[native-dispatch e2e] componentizing namespace-shape fixture: $shape"
  echo " $fixture" | WASMTIME_BACKTRACE_DETAILS=1 \
    "$NAMESPACE_BIN/wasmtime" wizer \
      -S cli -S inherit-env -W bulk-memory -W unknown-imports-trap \
      --dir "$(dirname "$fixture")" \
      -o "$core_module" "$NAMESPACE_BIN/starling-raw.wasm"
  WABT="$REPO_ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
  WASM_TOOLS_BIN="$NAMESPACE_BIN/wasm-tools" \
    "$NAMESPACE_BIN/componentize.sh" "$fixture" -o "$shape_component"
  "$NAMESPACE_BIN/wasm-tools" validate --features all "$shape_component"
  case "$shape" in
    flat|missing-namespace)
      diagnostic="JavaScript module does not export an 'api' interface namespace"
      ;;
    nonobject-namespace)
      diagnostic="JavaScript module export 'api' is not an interface namespace object"
      ;;
    missing-member)
      diagnostic="JavaScript module does not export 'phantom'"
      ;;
    noncallable-member)
      diagnostic="JavaScript module export 'phantom' is not a function"
      ;;
  esac
  expect_core_diagnostic "interface namespace rejects $shape shape" \
    "$core_module" "$diagnostic"
  if [ "$shape" = missing-member ]; then
    expect_core_diagnostic "interface namespace rejects inherited prototype members" \
      "$core_module" "JavaScript module does not export 'to-string'" \
      "starling:js/api#to-string"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "[native-dispatch e2e] FAILED"
  exit 1
fi
echo "[native-dispatch e2e] all checks passed"
