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
  local metadata="${5:-}"
  local metadata_args=()
  if [ -n "$metadata" ]; then
    metadata_args=(--metadata-out "$metadata")
  fi
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
    "${metadata_args[@]}" \
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
assert metadata["schema"] == "starling-componentize-metadata/v2"
assert metadata["processed_by"]["name"] == "starling-componentize"
assert re.fullmatch(r"[0-9a-f]{64}", metadata["provenance"]["worlds_sha256"])
assert re.fullmatch(r"[0-9a-f]{64}", metadata["provenance"]["tools_sha256"])
PY
"$WASM_TOOLS" metadata show "$OUTPUT" > "$WORK/embedded metadata.txt"
grep -Fq 'language' "$WORK/embedded metadata.txt"
grep -Fq 'JavaScript' "$WORK/embedded metadata.txt"
grep -Fq 'processed-by' "$WORK/embedded metadata.txt"
grep -Fq 'starling-componentize' "$WORK/embedded metadata.txt"
grep -Fq 'zig-sha256' "$WORK/embedded metadata.txt"
grep -Fq 'zig-lib-sha256' "$WORK/embedded metadata.txt"

RELATIVE_DIR="$WORK/read only relative modules"
RELATIVE_SOURCE="$RELATIVE_DIR/main.js"
RELATIVE_OUTPUT="$WORK/relative import component.wasm"
RELATIVE_METADATA="$WORK/relative import metadata.json"
RELATIVE_COPY_DIR="$WORK/clean relative modules copy"
RELATIVE_COPY_SOURCE="$RELATIVE_COPY_DIR/main.js"
RELATIVE_COPY_OUTPUT="$WORK/relative import copy component.wasm"
RELATIVE_COPY_METADATA="$WORK/relative import copy metadata.json"
RELATIVE_CHANGED_OUTPUT="$WORK/relative import changed component.wasm"
RELATIVE_CHANGED_METADATA="$WORK/relative import changed metadata.json"
mkdir -p "$RELATIVE_DIR/nested" "$RELATIVE_COPY_DIR/nested"
cat > "$RELATIVE_DIR/nested/sibling.js" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF
{
  printf 'import { add } from "./nested/sibling.js";\n\n'
  tail -n +5 "$ROOT/tests/fixtures/js-dispatch.js"
} > "$RELATIVE_SOURCE"
cp "$RELATIVE_DIR/nested/sibling.js" \
  "$RELATIVE_COPY_DIR/nested/sibling.js"
cp "$RELATIVE_SOURCE" "$RELATIVE_COPY_SOURCE"
chmod 444 "$RELATIVE_SOURCE" "$RELATIVE_DIR/nested/sibling.js"
chmod 555 "$RELATIVE_DIR" "$RELATIVE_DIR/nested"
chmod 600 "$RELATIVE_COPY_SOURCE"
touch -t 202001020304 "$RELATIVE_COPY_SOURCE" \
  "$RELATIVE_COPY_DIR/nested/sibling.js"
componentize "$RELATIVE_SOURCE" "$RELATIVE_OUTPUT" "" "" "$RELATIVE_METADATA"
componentize "$RELATIVE_COPY_SOURCE" "$RELATIVE_COPY_OUTPUT" "" "" \
  "$RELATIVE_COPY_METADATA"
"$WASM_TOOLS" validate --features all "$RELATIVE_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' \
  "$RELATIVE_OUTPUT")" = 5
cat > "$RELATIVE_COPY_DIR/nested/sibling.js" <<'EOF'
export function add(a, b) {
  return a + b + 1;
}
EOF
componentize "$RELATIVE_COPY_SOURCE" "$RELATIVE_CHANGED_OUTPUT" "" "" \
  "$RELATIVE_CHANGED_METADATA"
"$WASM_TOOLS" validate --features all "$RELATIVE_CHANGED_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' \
  "$RELATIVE_CHANGED_OUTPUT")" = 6
python3 - "$RELATIVE_OUTPUT" "$RELATIVE_METADATA" \
  "$RELATIVE_COPY_OUTPUT" "$RELATIVE_COPY_METADATA" \
  "$RELATIVE_CHANGED_OUTPUT" "$RELATIVE_CHANGED_METADATA" <<'PY'
import hashlib, json, sys
components = [open(path, "rb").read() for path in sys.argv[1::2]]
metadata = [json.load(open(path, encoding="utf-8")) for path in sys.argv[2::2]]
inputs = [document["provenance"]["inputs"] for document in metadata]
assert inputs[0]["source_tree"] == inputs[1]["source_tree"]
assert inputs[0]["source_tree"]["entry"] == "main.js"
assert inputs[1]["source_tree"]["sha256"] != \
    inputs[2]["source_tree"]["sha256"]
assert len({value["source_sha256"] for value in inputs}) == 1
assert components[1] != components[2]
for component, document in zip(components, metadata):
    assert document["component_sha256"] == hashlib.sha256(component).hexdigest()
PY
chmod 755 "$RELATIVE_DIR" "$RELATIVE_DIR/nested"
chmod 644 "$RELATIVE_SOURCE" "$RELATIVE_DIR/nested/sibling.js"

GENERATED_ROOT="$WORK/generated destination relative modules"
GENERATED_DIST="$GENERATED_ROOT/dist"
GENERATED_SOURCE="$GENERATED_ROOT/main.js"
GENERATED_OUTPUT="$GENERATED_DIST/app.wasm"
GENERATED_METADATA="$GENERATED_DIST/app.json"
GENERATED_DEBUG="$GENERATED_DIST/app.debug"
GENERATED_FIRST_METADATA="$WORK/generated destination first.json"
GENERATED_SECOND_METADATA="$WORK/generated destination second.json"
GENERATED_CHANGED_METADATA="$WORK/generated destination changed.json"
mkdir -p "$GENERATED_DEBUG" "$GENERATED_DIST/app.debug-lookalike"
cat > "$GENERATED_DIST/helper.js" <<'EOF'
export const helper = 1;
EOF
cat > "$GENERATED_DEBUG/debug-helper.js" <<'EOF'
export const debugHelper = 2;
EOF
cat > "$GENERATED_DIST/app.wasm.lookalike.js" <<'EOF'
export const wasmLookalike = 3;
EOF
cat > "$GENERATED_DIST/app.json.lookalike.js" <<'EOF'
export const metadataLookalike = 4;
EOF
cat > "$GENERATED_DIST/app.debug-lookalike/module.js" <<'EOF'
export const debugLookalike = 5;
EOF
cat > "$GENERATED_DIST/.starling-componentize-lock-user.js" <<'EOF'
export const lockLookalike = 6;
EOF
{
  cat <<'EOF'
import { helper } from "./dist/helper.js";
import { debugHelper } from "./dist/app.debug/debug-helper.js";
import { wasmLookalike } from "./dist/app.wasm.lookalike.js";
import { metadataLookalike } from "./dist/app.json.lookalike.js";
import { debugLookalike } from "./dist/app.debug-lookalike/module.js";
import { lockLookalike } from "./dist/.starling-componentize-lock-user.js";
export function add(a, b) {
  return a + b + helper + debugHelper + wasmLookalike +
    metadataLookalike + debugLookalike + lockLookalike;
}
EOF
  tail -n +5 "$ROOT/tests/fixtures/js-dispatch.js"
} > "$GENERATED_SOURCE"

generated_destination_componentize() {
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
    --debug-dir "$GENERATED_DEBUG" \
    --metadata-out "$GENERATED_METADATA" \
    --out "$GENERATED_OUTPUT" \
    "$GENERATED_SOURCE"
}

generated_destination_componentize
cp "$GENERATED_METADATA" "$GENERATED_FIRST_METADATA"
"$WASM_TOOLS" validate --features all "$GENERATED_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' \
  "$GENERATED_OUTPUT")" = 26
generated_destination_componentize
cp "$GENERATED_METADATA" "$GENERATED_SECOND_METADATA"
cat > "$GENERATED_DIST/helper.js" <<'EOF'
export const helper = 11;
EOF
generated_destination_componentize
cp "$GENERATED_METADATA" "$GENERATED_CHANGED_METADATA"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' \
  "$GENERATED_OUTPUT")" = 36
test -f "$GENERATED_DEBUG/debug-helper.js"
test -f "$GENERATED_DIST/app.debug-lookalike/module.js"
python3 - "$GENERATED_FIRST_METADATA" "$GENERATED_SECOND_METADATA" \
  "$GENERATED_CHANGED_METADATA" <<'PY'
import json, sys
digests = [
    json.load(open(path, encoding="utf-8"))["provenance"]["inputs"]
    ["source_tree"]["sha256"]
    for path in sys.argv[1:]
]
assert digests[0] == digests[1], digests
assert digests[1] != digests[2], digests
PY

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
