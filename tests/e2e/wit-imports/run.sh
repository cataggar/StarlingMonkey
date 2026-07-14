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
#   * kebab-case interface namespace mapping: the exact versioned
#     `test:wit-imports/incoming-handler@1.2.3` export resolves through the
#     ComponentizeJS `incomingHandler` spelling, while a second component
#     proves literal namespace/member spellings take precedence when both
#     literal and camelCase properties exist.
#   * root-function preservation: `root-add` remains a callable top-level
#     export beside the versioned named `api` interface.
#   * void import result contract: `note` (a WIT import with no result)
#     surfaces to JavaScript as exactly `undefined`, and its host-side
#     implementation's observable side effect (an incrementing counter,
#     queried via the side-channel `note-count` import) proves the
#     canonical-ABI import genuinely ran, not merely that the JS call site
#     didn't throw.
#   * nested option parity: `option<option<u32>>` preserves outer none,
#     some-none, and some-some across both export and reverse-import paths.
#   * requirement 5 (every synchronous type, reverse direction): nesting (a
#     list of lists), `char`/`option<char>`, `list<u8>` (a genuine JS
#     `Uint8Array`, plus its `option<list<u8>>` nested/optional form),
#     `tuple`, `enum`/`option<enum>`, `flags`/`option<flags>` (<=32
#     labels), `variant` (a void case and payload cases of different
#     types), and `result<T,E>` (both a both-payload form and a
#     void-ok-payload form) all round-trip through the reverse bridge,
#     each with a real host-side transform (not a bare passthrough) so the
#     assertions prove the host import actually ran. This is enabled by
#     cataggar/wabt PR #335 (build.zig.zon's `.wasip3` pin), which fixed
#     `nativeBridgeSupported`'s type gate and `list<u8>`'s import-parameter
#     lowering in build/bindgen/component_bindgen.zig. The one type this
#     bridge structurally cannot support is a `flags` with more than 32
#     labels (a 32-bit backing representation limit, not a bug) -- see
#     tests/compat/manifest.json's
#     `wit-imports-flags-over-32-labels-unsupported` known_deviation.
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
"$BIN/wasm-tools" component wit "$COMPONENT" | grep -q 'export test:wit-imports/incoming-handler@1.2.3;' || {
  echo "FAIL: componentized output does not declare the kebab-case versioned interface export"
  exit 1
}
"$BIN/wasm-tools" component wit "$COMPONENT" | grep -q 'export root-add: func' || {
  echo "FAIL: componentized output moved root-add away from the component root"
  exit 1
}
echo "PASS component declares exact versioned interfaces and root-function topology"
for root_import in add-one root-note root-note-count root-boom root-transform root-chain; do
  "$BIN/wasm-tools" component wit "$COMPONENT" | grep -q "import ${root_import}: func" || {
    echo "FAIL: componentized output does not declare root function import ${root_import}"
    exit 1
  }
done
echo "PASS component declares all world-level function imports"

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
  {"function": "run-sum-nested-lists", "args": [[[1, 2], [3, 4], [5, 6]]]},

  {"function": "run-char", "args": ["A"]},
  {"function": "run-option-char", "args": ["m"]},
  {"function": "run-option-char", "args": [null]},

  {"function": "run-bytes-is-uint8array", "args": [[1, 2, 3]]},
  {"function": "run-sum-bytes", "args": [[1, 2, 3, 4]]},
  {"function": "run-xor-bytes", "args": [[1, 2, 3], 255]},
  {"function": "run-optional-bytes", "args": [[1, 2, 3]]},
  {"function": "run-optional-bytes", "args": [null]},
  {"function": "run-describe-nested-option", "args": [{"nested": {"tag": "none"}}]},
  {"function": "run-describe-nested-option", "args": [{"nested": {"tag": "some", "val": null}}]},
  {"function": "run-describe-nested-option", "args": [{"nested": {"tag": "some", "val": 42}}]},
  {"function": "run-identity-nested-option", "args": [{"nested": {"tag": "some", "val": null}}]},
  {"function": "run-identity-nested-option", "args": [{"nested": {"tag": "some", "val": 42}}]},

  {"function": "run-swap-tuple", "args": [[5, "abc"]]},

  {"function": "run-color", "args": ["red"]},
  {"function": "run-option-color", "args": ["blue"]},
  {"function": "run-option-color", "args": [null]},

  {"function": "run-permissions", "args": [["read"]]},
  {"function": "run-option-permissions", "args": [["read", "write"]]},
  {"function": "run-option-permissions", "args": [null]},

  {"function": "run-shape", "args": [{"tag": "empty"}]},
  {"function": "run-shape", "args": [{"tag": "circle", "val": 2}]},
  {"function": "run-shape", "args": [{"tag": "named", "val": "hi"}]},

  {"function": "run-checked-div", "args": [10, 2]},
  {"function": "run-checked-div", "args": [10, 0]},
  {"function": "run-validate-non-negative", "args": [5]},
  {"function": "run-validate-non-negative", "args": [-1]},

  {"function": "run-root-add", "args": [41]},
  {"function": "run-root-repeated", "args": [7]},
  {"function": "run-root-note-count", "args": []},
  {"function": "run-root-note", "args": []},
  {"function": "run-root-note-count", "args": []},
  {"function": "run-root-note", "args": []},
  {"function": "run-root-note-count", "args": []},
  {"function": "run-root-transform", "args": [{"coordinate": {"x": 5, "y": 8}, "labels": ["alpha", "beta"]}]},
  {"function": "run-root-chain", "args": [{"tag": "item", "val": {"x": 5, "y": 8}}]},
  {"function": "root-add", "args": [20, 22], "interface": null},
  {"function": "kebab-interface-add", "args": [41], "interface": "test:wit-imports/incoming-handler@1.2.3"},
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
assert_field "run-sum-nested-lists sums a nested list<list<u32>>" 10 "rec['value']" "21"

# -- advanced synchronous value types (requirement 5): every remaining
# type the native bridge supports, now wired through the reverse
# (JS-imports) direction by cataggar/wabt PR #335. Each case below applies
# a real host-side transform (see wit_imports_invoker.rs's
# `add_host_import`), so a passing assertion proves the host import
# genuinely executed and its result genuinely round-tripped back through
# the export call, not merely that componentization succeeded. Must all
# run BEFORE run-boom below: this invoker instantiates the component once
# and replays every call against that same instance (see
# wit_imports_invoker.rs's main()), and a real Wasmtime trap poisons the
# instance for any later call ("cannot enter component instance") -- so
# the deliberately-trapping call has to be last.

# char / option<char>: codepoint shifted by one; `none` stays `none`.
assert_field "run-char shifts a codepoint by one" 11 "rec['value']" "B"
assert_field "run-option-char (some) shifts the wrapped codepoint" 12 "rec['value']" "n"
assert_field "run-option-char (none) round-trips as None" 13 "rec['value']" "None"

# list<u8> (bytes): a genuine Uint8Array on the JS side; sum/xor prove
# both parameter-lowering and result-lifting of a *direct* list<u8>;
# the optional case covers list<u8> nested inside option<T>.
assert_field "run-bytes-is-uint8array: export argument is a real Uint8Array" 14 "rec['value']" "True"
assert_field "run-sum-bytes sums a direct list<u8> parameter" 15 "rec['value']" "10"
assert_field "run-xor-bytes XORs a direct list<u8> result" 16 "rec['value']" "[254, 253, 252]"
assert_field "run-optional-bytes (some) reverses the wrapped list<u8>" 17 "rec['value']" "[3, 2, 1]"
assert_field "run-optional-bytes (none) round-trips as None" 18 "rec['value']" "None"

# option<option<u32>>: the tagged JSON input here maps to the exact
# ComponentizeJS JS representation. The descriptor proves JS -> host
# lowering distinguishes every canonical state; identity covers host -> JS
# lifting and the enclosing export's lowering back to Wasmtime.
assert_field "nested option outer none remains distinct" 19 "rec['value']" "none"
assert_field "nested option some-none remains distinct" 20 "rec['value']" "some-none"
assert_field "nested option some-some preserves payload" 21 "rec['value']" "some-some-42"
assert_field "nested option some-none reverse result returns inner none" 22 "rec['value']" "{'nested': None}"
assert_field "nested option some-some reverse result preserves payload" 23 "rec['value']" "{'nested': 42}"

# tuple: position AND type swapped, with a real transform on each element.
assert_field "run-swap-tuple swaps position/type and transforms both elements" 24 "rec['value']" "['ABC', 6]"

# enum / option<enum>: cycles red -> green -> blue -> red.
assert_field "run-color cycles red -> green" 25 "rec['value']" "green"
assert_field "run-option-color (some) cycles blue -> red" 26 "rec['value']" "red"
assert_field "run-option-color (none) round-trips as None" 27 "rec['value']" "None"

# flags (3 labels, well under the 32-label limit) / option<flags>: every
# bit flipped.
assert_field "run-permissions flips every bit ({read} -> {write, execute})" 28 "rec['value']" "['write', 'execute']"
assert_field "run-option-permissions (some) flips every bit ({read,write} -> {execute})" 29 "rec['value']" "['execute']"
assert_field "run-option-permissions (none) round-trips as None" 30 "rec['value']" "None"

# variant: a void case and two differently-typed payload cases, each with
# its own deterministic transform.
assert_field "run-shape: empty -> circle(1)" 31 "rec['value']" "{'tag': 'circle', 'val': 1}"
assert_field "run-shape: circle(2) -> circle(4)" 32 "rec['value']" "{'tag': 'circle', 'val': 4}"
assert_field "run-shape: named('hi') -> named('hi!')" 33 "rec['value']" "{'tag': 'named', 'val': 'hi!'}"

# result<T,E>: this export's own top-level return type gets
# ComponentizeJS's throw-means-err convention (unlike the plain {tag,val}
# object the host *import* itself returns -- see component.js's module
# doc comment), so both a both-payload result<s32,string> and a
# void-ok-payload result<_,string> are exercised here as the export's own
# result, not the host import's raw shape.
assert_field "run-checked-div ok: 10/2 = 5" 34 "rec['value']" "{'tag': 'ok', 'val': 5}"
assert_field "run-checked-div err: division by zero" 35 "rec['value']" "{'tag': 'err', 'val': 'division by zero'}"
assert_field "run-validate-non-negative ok (void payload, no 'val' key)" 36 "rec['value']" "{'tag': 'ok'}"
assert_field "run-validate-non-negative err: negative value rejected" 37 "rec['value']" "{'tag': 'err', 'val': 'value is negative'}"

assert_field "root add-one carries an argument and result" 38 "rec['value']" "42"
assert_field "root add-one supports repeated calls" 39 "rec['value']" "[8, 9, 10, 11, 12]"
assert_field "root-note-count starts at 0" 40 "rec['value']" "0"
assert_field "root void result is exactly undefined" 41 "rec['value']" "True"
assert_field "root-note side effect ran once" 42 "rec['value']" "1"
assert_field "root void result stays undefined on repeat" 43 "rec['value']" "True"
assert_field "root-note side effect ran twice" 44 "rec['value']" "2"
assert_field "root named aggregate recursively lowers and lifts" 45 \
  "rec['value']" "{'tag': 'accepted', 'val': {'coordinate': {'x': 6, 'y': 10}, 'labels': ['beta', 'alpha', 'host']}}"
assert_field "root use alias chain lowers and lifts through its source interface" 46 \
  "rec['value']" "{'tag': 'item', 'val': {'x': 8, 'y': 12}}"
assert_field "root function export remains callable beside the api namespace" 47 "rec['value']" "42"

assert_field "kebab-case versioned interface resolves through camelCase namespace/member fallback" 48 \
  "rec['value']" "42"

assert_field "run-boom host trap propagates" 49 "rec['ok']" "False"
assert_field "run-boom trap message names the deliberate host error" 49 \
  "'boom: deliberate host-side trap' in rec['trap']" "True"

echo "[wit-imports e2e] invoking root-boom in a fresh instance"
ROOT_TRAP_CALLS_JSON="$PREFIX/root_trap_calls.json"
echo '[{"function":"run-root-boom","args":[]}]' > "$ROOT_TRAP_CALLS_JSON"
OUTPUT_JSON="$PREFIX/root_trap_output.json"
"$INVOKER" "$COMPONENT" "$ROOT_TRAP_CALLS_JSON" > "$OUTPUT_JSON"
assert_field "root-boom host trap propagates" 0 "rec['ok']" "False"
assert_field "root-boom trap names the world-level host function" 0 \
  "'root-boom: deliberate host-side trap' in rec['trap']" "True"

echo "[wit-imports e2e] checking literal namespace/member precedence over camelCase"
LITERAL_COMPONENT="$PREFIX/wit-imports-literal-names.wasm"
WABT="$REPO_ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
WASM_TOOLS_BIN="$BIN/wasm-tools" \
  "$BIN/componentize.sh" tests/e2e/wit-imports/component-literal-names.js -o "$LITERAL_COMPONENT"
"$BIN/wasm-tools" validate --features all "$LITERAL_COMPONENT"
LITERAL_CALLS_JSON="$PREFIX/calls_literal_names.json"
cat > "$LITERAL_CALLS_JSON" <<'EOF'
[
  {"function": "kebab-interface-add", "args": [41], "interface": "test:wit-imports/incoming-handler@1.2.3"}
]
EOF
LITERAL_OUTPUT_JSON="$PREFIX/output_literal_names.json"
"$INVOKER" "$LITERAL_COMPONENT" "$LITERAL_CALLS_JSON" > "$LITERAL_OUTPUT_JSON"
OUTPUT_JSON="$LITERAL_OUTPUT_JSON"
assert_field "literal kebab-case namespace/member take precedence over camelCase aliases" 0 \
  "rec['value']" "42"
OUTPUT_JSON="$PREFIX/output.json"

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

echo "[wit-imports e2e] instantiating with root-boom OMITTED"
if OMIT_OUTPUT=$("$INVOKER" --omit-root-boom "$COMPONENT" "$EMPTY_CALLS_JSON" 2>&1); then
  echo "FAIL root missing-import diagnostics: expected instantiation to fail, but it succeeded: $OMIT_OUTPUT"
  fail=1
else
  if echo "$OMIT_OUTPUT" | grep -q "root-boom" && \
     echo "$OMIT_OUTPUT" | grep -qi "not found in the linker"; then
    echo "PASS root missing-import diagnostics: Wasmtime named the unresolved root function"
  else
    echo "FAIL root missing-import diagnostics: error did not name root-boom actionably: $OMIT_OUTPUT"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "[wit-imports e2e] FAILED"
  exit 1
fi
echo "[wit-imports e2e] all checks passed"
