#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage: $0 <componentizer> <zig> <wasmtime> <wasm-tools> <wabt> <adapter>" >&2
  exit 2
fi

COMPONENTIZER="$1"
ZIG="$2"
WASMTIME="$3"
WASM_TOOLS="$4"
WABT="$5"
ADAPTER="$6"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="$ROOT/tests/componentizer/.real-cache"
WORK="$CACHE/work with spaces"
OUTPUT="$WORK/native component.wasm"
CACHED_OUTPUT="$WORK/native component cached.wasm"
FAILURE_OUTPUT="$WORK/unchanged-on-failure.wasm"
V2_OUTPUT="$WORK/native component v2.wasm"
DEBUG_DIR="$WORK/debug bindings"

rm -rf "$CACHE"
mkdir -p "$WORK"
trap 'rm -rf "$CACHE"' EXIT

componentize() {
  local source="$1" output="$2"
  local dispatch_wit="${3:-$ROOT/host-apis/wasi-0.2.10/wit/deps/starling-js}"
  local component_world="${4:-js-dispatch}"
  WASM_TOOLS_BIN="$WASM_TOOLS" "$COMPONENTIZER" \
    --build-root "$ROOT" \
    --cache-dir "$CACHE/runtime cache" \
    --zig-bin "$ZIG" \
    --wit "$dispatch_wit" \
    --world-name js-exports \
    --component-wit "$ROOT/host-apis/wasi-0.2.10/wit" \
    --component-world-name "$component_world" \
    --wasmtime-bin "$WASMTIME" \
    --wabt-bin "$WABT" \
    --wasm-tools-bin "$WASM_TOOLS" \
    --preview2-adapter "$ADAPTER" \
    --out "$output" \
    "$source"
}

WASM_TOOLS_BIN="$WASM_TOOLS" "$COMPONENTIZER" \
  --build-root "$ROOT" \
  --cache-dir "$CACHE/runtime cache" \
  --zig-bin "$ZIG" \
  --wit "$ROOT/host-apis/wasi-0.2.10/wit/deps/starling-js" \
  --world-name js-exports \
  --component-wit "$ROOT/host-apis/wasi-0.2.10/wit" \
  --component-world-name js-dispatch \
  --wasmtime-bin "$WASMTIME" \
  --wabt-bin "$WABT" \
  --wasm-tools-bin "$WASM_TOOLS" \
  --preview2-adapter "$ADAPTER" \
  --debug-dir "$DEBUG_DIR" \
  --out "$OUTPUT" \
  "$ROOT/tests/fixtures/js-dispatch.js"
"$WASM_TOOLS" validate --features all "$OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$OUTPUT")" = 5
test -s "$DEBUG_DIR/component-bindings.zig"
test -s "$DEBUG_DIR/commands.txt"

# A second identical WIT selection reuses the same monolithic Zig cache entry.
componentize "$ROOT/tests/fixtures/js-dispatch.js" "$CACHED_OUTPUT"
"$WASM_TOOLS" validate --features all "$CACHED_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$CACHED_OUTPUT")" = 5
test "$(find "$CACHE/runtime cache/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1

# A different dispatch and component world must produce an observably
# different relink rather than reusing or restaging the first runtime.
componentize \
  "$ROOT/tests/componentizer/js-dispatch-v2.js" \
  "$V2_OUTPUT" \
  "$ROOT/host-apis/wasi-0.2.10/wit/deps/starling-js-v2" \
  js-dispatch-v2
"$WASM_TOOLS" validate --features all "$V2_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'subtract(7, 2)' "$V2_OUTPUT")" = 5
test "$(find "$CACHE/runtime cache/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2

# Export preflight fails before publication and preserves an existing output.
printf 'existing-output\n' > "$FAILURE_OUTPUT"
if componentize "$ROOT/tests/fixtures/js-dispatch-missing-member.js" "$FAILURE_OUTPUT"; then
  echo "FAIL: invalid export surface unexpectedly componentized" >&2
  exit 1
fi
test "$(cat "$FAILURE_OUTPUT")" = "existing-output"

echo "native componentizer real E2E passed"
