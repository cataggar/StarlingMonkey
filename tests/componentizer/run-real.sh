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
METADATA="$WORK/native component metadata.json"
CACHED_OUTPUT="$WORK/native component cached.wasm"
CACHED_METADATA="$WORK/native component cached metadata.json"
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
  --metadata-out "$METADATA" \
  --out "$OUTPUT" \
  "$ROOT/tests/fixtures/js-dispatch.js"
"$WASM_TOOLS" validate --features all "$OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$OUTPUT")" = 5
test -s "$DEBUG_DIR/component-bindings.zig"
test -s "$DEBUG_DIR/commands.txt"
test -s "$DEBUG_DIR/imports.json"
test -s "$METADATA"
python3 - "$METADATA" <<'PY'
import json, re, sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
assert metadata["schema"] == "starling-componentize-metadata/v1"
assert metadata["processed_by"]["name"] == "starling-componentize"
assert re.fullmatch(r"[0-9a-f]{64}", metadata["provenance"]["worlds_sha256"])
assert re.fullmatch(r"[0-9a-f]{64}", metadata["provenance"]["tools_sha256"])
PY
"$WASM_TOOLS" metadata show "$OUTPUT" > "$WORK/embedded metadata.txt"
grep -Fq 'language' "$WORK/embedded metadata.txt"
grep -Fq 'JavaScript' "$WORK/embedded metadata.txt"
grep -Fq 'processed-by' "$WORK/embedded metadata.txt"
grep -Fq 'starling-componentize' "$WORK/embedded metadata.txt"

RELATIVE_DIR="$WORK/read only relative modules"
RELATIVE_SOURCE="$RELATIVE_DIR/main.js"
RELATIVE_OUTPUT="$WORK/relative import component.wasm"
mkdir "$RELATIVE_DIR"
cat > "$RELATIVE_DIR/sibling.js" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF
{
  printf 'import { add } from "./sibling.js";\n\n'
  tail -n +5 "$ROOT/tests/fixtures/js-dispatch.js"
} > "$RELATIVE_SOURCE"
chmod 444 "$RELATIVE_SOURCE" "$RELATIVE_DIR/sibling.js"
chmod 555 "$RELATIVE_DIR"
componentize "$RELATIVE_SOURCE" "$RELATIVE_OUTPUT"
"$WASM_TOOLS" validate --features all "$RELATIVE_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' \
  "$RELATIVE_OUTPUT")" = 5
chmod 755 "$RELATIVE_DIR"
chmod 644 "$RELATIVE_SOURCE" "$RELATIVE_DIR/sibling.js"

# A second identical WIT selection reuses the same monolithic Zig cache entry.
"$COMPONENTIZER" \
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
  --metadata-out "$CACHED_METADATA" \
  --out "$CACHED_OUTPUT" \
  "$ROOT/tests/fixtures/js-dispatch.js"
"$WASM_TOOLS" validate --features all "$CACHED_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$CACHED_OUTPUT")" = 5
test "$(find "$CACHE/runtime cache/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1
python3 - "$OUTPUT" "$METADATA" "$CACHED_OUTPUT" "$CACHED_METADATA" <<'PY'
import hashlib, json, sys
first = json.load(open(sys.argv[2], encoding="utf-8"))
second = json.load(open(sys.argv[4], encoding="utf-8"))
for component_path, metadata in ((sys.argv[1], first), (sys.argv[3], second)):
    component_hash = hashlib.sha256(open(component_path, "rb").read()).hexdigest()
    assert metadata.pop("component_sha256") == component_hash
assert first == second
PY

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
