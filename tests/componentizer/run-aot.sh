#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "usage: $0 <componentizer> <zig> <wasmtime> <wasm-tools> <wabt> <adapter> <weval>" >&2
  exit 2
fi

COMPONENTIZER="$1"
ZIG="$2"
WASMTIME="$3"
WASM_TOOLS="$4"
WABT="$5"
ADAPTER="$6"
WEVAL="$7"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="$ROOT/tests/componentizer/.aot-real-cache"
WORK="$CACHE/work with spaces"
WIZER_OUTPUT="$WORK/wizer component.wasm"
AOT_OUTPUT="$WORK/aot component.wasm"
AOT_CACHED_OUTPUT="$WORK/aot cached component.wasm"
AOT_REPRIMED_OUTPUT="$WORK/aot reprimed component.wasm"
AOT_RUNTIME_OUTPUT="$WORK/aot runtime component.wasm"
SOURCE="$ROOT/tests/fixtures/js-dispatch.js"
PRIMER="$ROOT/tools/componentizer/aot-cache-primer.js"
PRIMER_BACKUP="$CACHE/aot-cache-primer.js.original"

rm -rf "$CACHE"
mkdir -p "$WORK"
cp -p "$PRIMER" "$PRIMER_BACKUP"
cleanup() {
  cp -p "$PRIMER_BACKUP" "$PRIMER"
  rm -rf "$CACHE"
}
trap cleanup EXIT

componentize() {
  local mode="$1" output="$2"
  local -a aot_args=()
  if [ "$mode" = aot ]; then
    aot_args=(
      --aot
      --weval-bin "$WEVAL"
      --aot-min-stack-size 8388608
    )
  fi
  "$COMPONENTIZER" \
    "${aot_args[@]}" \
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
    --out "$output" \
    "$SOURCE"
}

componentize wizer "$WIZER_OUTPUT"
componentize aot "$AOT_OUTPUT"
componentize aot "$AOT_CACHED_OUTPUT"

for component in "$WIZER_OUTPUT" "$AOT_OUTPUT" "$AOT_CACHED_OUTPUT"; do
  "$WASM_TOOLS" validate --features all "$component"
done

wizer_add="$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$WIZER_OUTPUT")"
aot_add="$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$AOT_OUTPUT")"
aot_cached_add="$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$AOT_CACHED_OUTPUT")"
test "$wizer_add" = 5
test "$aot_add" = "$wizer_add"
test "$aot_cached_add" = "$wizer_add"

wizer_greet="$("$WASMTIME" run -S cli -S http --invoke 'greet("AOT")' "$WIZER_OUTPUT")"
aot_greet="$("$WASMTIME" run -S cli -S http --invoke 'greet("AOT")' "$AOT_OUTPUT")"
test "$aot_greet" = "$wizer_greet"

wizer_big="$("$WASMTIME" run -S cli -S http --invoke 'big-add(18446744073709551615, 0)' "$WIZER_OUTPUT")"
aot_big="$("$WASMTIME" run -S cli -S http --invoke 'big-add(18446744073709551615, 0)' "$AOT_OUTPUT")"
test "$wizer_big" = 18446744073709551615
test "$aot_big" = "$wizer_big"

wizer_promise="$("$WASMTIME" run -S cli -S http --invoke 'promise-add(2, 3)' "$WIZER_OUTPUT")"
aot_promise="$("$WASMTIME" run -S cli -S http --invoke 'promise-add(2, 3)' "$AOT_OUTPUT")"
test "$wizer_promise" = 5
test "$aot_promise" = "$wizer_promise"

test "$(find "$CACHE/runtime cache/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2
mapfile -t manifests < <(
  find "$CACHE/runtime cache/runtimes" -name starling-ics.wevalcache.manifest -type f
)
test "${#manifests[@]}" -eq 1
AOT_BUNDLE="$(dirname "${manifests[0]}")"
test -s "$AOT_BUNDLE/starling-raw.wasm"
test -s "$AOT_BUNDLE/starling-ics.wevalcache"
grep -Fq 'engine_abi=spidermonkey-pbl-weval-aot-ics-v1' "${manifests[0]}"

"$AOT_BUNDLE/componentize.sh" --output "$AOT_RUNTIME_OUTPUT"
"$WASM_TOOLS" validate --features all "$AOT_RUNTIME_OUTPUT"

OLD_CACHE_SHA="$(sha256sum "$AOT_BUNDLE/starling-ics.wevalcache" | cut -d ' ' -f 1)"
OLD_PRIMER_SHA="$(sed -n 's/^primer_sha256=//p' "${manifests[0]}")"
test "$OLD_PRIMER_SHA" = "$(sha256sum "$PRIMER" | cut -d ' ' -f 1)"

cat > "$PRIMER" <<'EOF'
function reviewFindingPrimer(value) {
  return { next: value + 1 }.next;
}
function main() {
  let value = 0;
  for (let i = 0; i < 20000; i++) {
    value = reviewFindingPrimer(value);
  }
  if (value !== 20000) {
    throw new Error("cache primer failed");
  }
}
EOF
componentize aot "$AOT_REPRIMED_OUTPUT"
"$WASM_TOOLS" validate --features all "$AOT_REPRIMED_OUTPUT"
test "$("$WASMTIME" run -S cli -S http --invoke 'add(2, 3)' "$AOT_REPRIMED_OUTPUT")" = 5

NEW_CACHE_SHA="$(sha256sum "$AOT_BUNDLE/starling-ics.wevalcache" | cut -d ' ' -f 1)"
NEW_MANIFEST_CACHE_SHA="$(sed -n 's/^cache_sha256=//p' "${manifests[0]}")"
NEW_MANIFEST_PRIMER_SHA="$(sed -n 's/^primer_sha256=//p' "${manifests[0]}")"
test "$NEW_CACHE_SHA" != "$OLD_CACHE_SHA"
test "$NEW_MANIFEST_CACHE_SHA" = "$NEW_CACHE_SHA"
test "$NEW_MANIFEST_PRIMER_SHA" != "$OLD_PRIMER_SHA"
test "$NEW_MANIFEST_PRIMER_SHA" = "$(sha256sum "$PRIMER" | cut -d ' ' -f 1)"

echo "Wizer/AOT behavioral equivalence passed"
