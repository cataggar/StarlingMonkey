#!/usr/bin/env bash
# End-to-end coverage for WIT interface imports (the "wit-imports" roadmap
# phase): builds a dedicated dispatch-enabled `starling-raw.wasm` against
# tests/e2e/wit-imports/wit (a fixture-specific full-WASI-closure world that
# additionally imports `test:wit-imports/host@1.2.3` -- see that
# directory's js-dispatch.wit for why this can't reuse the shared
# host-apis/wasi-0.2.10/wit/js-dispatch.wit), componentizes
# tests/e2e/wit-imports/component.js against it, and drives every export
# through a Wasmtime 42 host (tests/compat/runtime/invoker's
# `wit-imports-invoker` binary) that *implements* the custom host import via
# the dynamic `Linker::instance(..).func_new(..)` API -- something
# `wasmtime run --invoke` cannot do, since it only supports WASI-P2/HTTP
# built-in imports, not arbitrary custom WIT imports.
#
# Assertions cover:
#   * requirement 2 (module resolution): component.js's
#     `import { add, ... } from "test:wit-imports/host@1.2.3"` resolves with
#     no user-written glue.
#   * requirement 3 (typed lifting/lowering): exact s64/u64 BigInt
#     (including a value that wraps past 2**64), strings, and a nested
#     record bridged between two independently-declared (but
#     structurally-identical) WIT `point` types.
#   * requirement 5 (repeated calls): `run-repeated-add` calls the same host
#     import 5 times in one export invocation.
#   * requirement 5 (host trap propagation): `run-boom` calls a host
#     function that always traps; the trap must propagate all the way back
#     out through the wasm export call.
#   * requirement 5 (missing import diagnostics): instantiating the SAME
#     component against a linker that deliberately omits `boom`'s host
#     registration must fail with Wasmtime's own actionable "matching
#     implementation was not found" diagnostic, not a silent skip.
#   * requirement 5 (versioned interface names): the fixture's import/export
#     both use the versioned identifier `test:wit-imports/{host,api}@1.2.3`
#     throughout.
#   * void import result contract: `note` (a WIT import with no result)
#     surfaces to JavaScript as exactly `undefined`, and its host-side
#     implementation's observable side effect (an incrementing counter,
#     queried via the side-channel `note-count` import) proves the
#     canonical-ABI import genuinely ran, not merely that the JS call site
#     didn't throw.
#
# Usage: run.sh [zig-binary] [install-prefix]
#   zig-binary defaults to `zig` on PATH; install-prefix defaults to
#   <repo-root>/zig-out-wit-imports-e2e.
#
# Requires a Rust toolchain (tests/compat/runtime/invoker has its own scoped
# rust-toolchain.toml pinning 1.91.0, independent of the repo root's pin) --
# not part of `zig build test`; see build.zig's `wit-imports-e2e-test` step
# doc comment for why this is a separate, explicitly-invoked step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ZIG_BIN="${1:-zig}"
PREFIX="${2:-$REPO_ROOT/zig-out-wit-imports-e2e}"

cd "$REPO_ROOT"

echo "[wit-imports e2e] building dispatch-enabled runtime into $PREFIX"
"$ZIG_BIN" build install --prefix "$PREFIX" \
  -Doptimize=ReleaseSmall \
  -Dcomponent-wit=tests/e2e/wit-imports/wit \
  -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=tests/e2e/wit-imports/wit/deps/test-wit-imports \
  -Ddispatch-world=js-exports

BIN="$PREFIX/bin"
COMPONENT="$PREFIX/wit-imports.wasm"

echo "[wit-imports e2e] componentizing tests/e2e/wit-imports/component.js"
WABT="$REPO_ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
WASM_TOOLS_BIN="$BIN/wasm-tools" \
  "$BIN/componentize.sh" tests/e2e/wit-imports/component.js -o "$COMPONENT"

echo "[wit-imports e2e] validating component"
"$BIN/wasm-tools" validate --features all "$COMPONENT"

echo "[wit-imports e2e] confirming test:wit-imports/host@1.2.3 is a real component-level import"
"$BIN/wasm-tools" component wit "$COMPONENT" | grep -q 'import test:wit-imports/host@1.2.3;' || {
  echo "FAIL: componentized output does not declare test:wit-imports/host@1.2.3 as an import"
  exit 1
}
"$BIN/wasm-tools" component wit "$COMPONENT" | grep -q 'export test:wit-imports/api@1.2.3;' || {
  echo "FAIL: componentized output does not declare test:wit-imports/api@1.2.3 as an export"
  exit 1
}
echo "PASS component declares versioned import/export interface names"

echo "[wit-imports e2e] building wit-imports-invoker (tests/compat/runtime/invoker)"
INVOKER_DIR="$REPO_ROOT/tests/compat/runtime/invoker"
( cd "$INVOKER_DIR" && cargo build --quiet --bin wit-imports-invoker )
INVOKER="$INVOKER_DIR/target/debug/wit-imports-invoker"

CALLS_JSON="$PREFIX/calls.json"
cat > "$CALLS_JSON" <<'EOF'
[
  {"function": "run-add", "args": [40, 2]},
  {"function": "run-sum-list", "args": [[1, 2, 18446744073709551615]]},
  {"function": "run-greet", "args": ["world"]},
  {"function": "run-scale", "args": [3, 4, 10]},
  {"function": "run-repeated-add", "args": []},
  {"function": "run-note-count", "args": []},
  {"function": "run-note", "args": []},
  {"function": "run-note-count", "args": []},
  {"function": "run-note", "args": []},
  {"function": "run-note-count", "args": []},
  {"function": "run-boom", "args": []}
]
EOF

echo "[wit-imports e2e] invoking exports (host import fully registered)"
OUTPUT_JSON="$PREFIX/output.json"
"$INVOKER" "$COMPONENT" "$CALLS_JSON" > "$OUTPUT_JSON"
cat "$OUTPUT_JSON"

fail=0

# assert_json_path INDEX PY_EXPR EXPECTED_REPR
# Uses python3's json module (no jq dependency) to pick a field out of the
# INDEX-th record of the invoker's JSON array (read from OUTPUT_JSON, not
# interpolated into the script -- the trap message legitimately contains
# embedded newlines, which would otherwise break heredoc/shell quoting) and
# compares its Python repr.
assert_field() {
  local name="$1" index="$2" expr="$3" expected="$4" actual
  actual=$(python3 - "$OUTPUT_JSON" "$index" "$expr" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
idx = int(sys.argv[2])
expr = sys.argv[3]
rec = data[idx]
print(eval(expr, {"rec": rec}))
PYEOF
)
  if [ "$actual" != "$expected" ]; then
    echo "FAIL $name: expected [$expected] got [$actual]"
    fail=1
    return
  fi
  echo "PASS $name"
}

assert_field "run-add exact s64 add" 0 "rec['value']" "42"
assert_field "run-sum-list exact u64 wraparound (1+2+u64::MAX mod 2**64)" 1 "rec['value']" "2"
assert_field "run-greet string round-trip" 2 "rec['value']" "Hello from host, world!"
assert_field "run-scale nested record bridged across independent point types" 3 "rec['value']" "{'x': 30, 'y': 40}"
assert_field "run-repeated-add calls host import 5 times" 4 "rec['value']" "[10, 11, 12, 13, 14]"
assert_field "note-count starts at 0 (before any 'note' call)" 5 "rec['value']" "0"
assert_field "run-note: JS observes exactly undefined for a void import" 6 "rec['value']" "True"
assert_field "note-count is 1 after one 'note' call (host side effect proves the import ran)" 7 "rec['value']" "1"
assert_field "run-note: undefined result is consistent across repeated calls" 8 "rec['value']" "True"
assert_field "note-count is 2 after a second 'note' call" 9 "rec['value']" "2"
assert_field "run-boom host trap propagates" 10 "rec['ok']" "False"
assert_field "run-boom trap message names the deliberate host error" 10 \
  "'boom: deliberate host-side trap' in rec['trap']" "True"

echo "[wit-imports e2e] instantiating with 'boom' host import OMITTED (missing-import diagnostics)"
EMPTY_CALLS_JSON="$PREFIX/calls_empty.json"
echo '[]' > "$EMPTY_CALLS_JSON"
if OMIT_OUTPUT=$("$INVOKER" --omit-boom "$COMPONENT" "$EMPTY_CALLS_JSON" 2>&1); then
  echo "FAIL missing-import diagnostics: expected instantiation to fail, but it succeeded: $OMIT_OUTPUT"
  fail=1
else
  if echo "$OMIT_OUTPUT" | grep -q "test:wit-imports/host@1.2.3" && \
     echo "$OMIT_OUTPUT" | grep -qi "not found in the linker"; then
    echo "PASS missing-import diagnostics: Wasmtime reported an actionable error naming the unresolved import"
  else
    echo "FAIL missing-import diagnostics: error message did not name the missing import actionably: $OMIT_OUTPUT"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "[wit-imports e2e] FAILED"
  exit 1
fi
echo "[wit-imports e2e] all checks passed"
