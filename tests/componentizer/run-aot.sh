#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 8 ]; then
  echo "usage: $0 <componentizer> <zig> <wasmtime> <wasm-tools> <wabt> <adapter> <weval> <starling-aot-cache>" >&2
  exit 2
fi

COMPONENTIZER="$1"
ZIG="$2"
WASMTIME="$3"
WASM_TOOLS="$4"
WABT="$5"
ADAPTER="$6"
WEVAL="$7"
CACHE_TOOL="$8"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="$ROOT/tests/componentizer/.aot-real-cache"
WORK="$CACHE/work with spaces"
WIZER_OUTPUT="$WORK/wizer component.wasm"
AOT_OUTPUT="$WORK/aot component.wasm"
AOT_CACHED_OUTPUT="$WORK/aot cached component.wasm"
AOT_REPRIMED_OUTPUT="$WORK/aot reprimed component.wasm"
AOT_RUNTIME_OUTPUT="$WORK/aot runtime component.wasm"
AOT_RUNTIME_INVOKE_OUTPUT="$WORK/aot runtime invocation component.wasm"
SOURCE="$ROOT/tests/fixtures/js-dispatch.js"
PRIMER="$ROOT/tools/componentizer/aot-cache-primer.js"
PRIMER_BACKUP="$CACHE/aot-cache-primer.js.original"

if [ -e "$CACHE" ]; then
  chmod -R u+w "$CACHE" 2>/dev/null || true
  rm -rf "$CACHE"
fi
mkdir -p "$WORK"
cp -p "$PRIMER" "$PRIMER_BACKUP"
cleanup() {
  cp -p "$PRIMER_BACKUP" "$PRIMER"
  chmod -R u+w "$CACHE" 2>/dev/null || true
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

prime_clean_cache() {
  local directory="$1" primer="$2"
  local primer_input="${primer#"$ROOT/"}"
  mkdir -p "$directory"
  (
    cd "$ROOT"
    printf '%s\n' "$primer_input" |
      env -u STARLINGMONKEY_CONFIG -u ENABLE_PBL \
        RUST_MIN_STACK=8388608 WASMTIME_BACKTRACE_DETAILS=1 \
        "$WEVAL" weval -w \
          --init-func starling-aot-cache-initialize \
          --dir . \
          --cache "$directory/raw.wevalcache" \
          -i "$AOT_BUNDLE/starling-raw.wasm" \
          -o "$directory/primed-starling-raw.wasm"
  )
  "$CACHE_TOOL" seal \
    --engine "$AOT_BUNDLE/starling-raw.wasm" \
    --weval "$WEVAL" \
    --cache "$directory/raw.wevalcache" \
    --cache-out "$directory/starling-ics.wevalcache" \
    --primer "$primer" \
    --feature-abi 'reproducibility-test-v1' \
    --out "$directory/starling-ics.wevalcache.manifest"
}

REPRO_ONE="$CACHE/repro clean one"
REPRO_TWO="$CACHE/repro clean two"
REPRO_CHANGED="$CACHE/repro changed primer"
prime_clean_cache "$REPRO_ONE" "$PRIMER"
sleep 1
prime_clean_cache "$REPRO_TWO" "$PRIMER"
python3 - "$REPRO_ONE" "$REPRO_TWO" <<'PY'
import sqlite3
import sys

raw_times = []
for directory in sys.argv[1:]:
    raw = sqlite3.connect(directory + "/raw.wevalcache")
    times = [row[0] for row in raw.execute(
        "select created_time from weval_cache order by module_hash, key, result"
    )]
    raw.close()
    assert times and all(value > 0 for value in times), times
    raw_times.append(times)

assert raw_times[0] != raw_times[1], raw_times
for directory in sys.argv[1:]:
    sealed = sqlite3.connect(directory + "/starling-ics.wevalcache")
    times = [row[0] for row in sealed.execute(
        "select created_time from weval_cache"
    )]
    assert times and set(times) == {0}, times
    assert sealed.execute("pragma integrity_check").fetchone() == ("ok",)
    sealed.close()
PY

seal_existing_cache() {
  local directory="$1"
  "$CACHE_TOOL" seal \
    --engine "$AOT_BUNDLE/starling-raw.wasm" \
    --weval "$WEVAL" \
    --cache "$directory/raw.wevalcache" \
    --cache-out "$directory/starling-ics.wevalcache" \
    --primer "$PRIMER" \
    --feature-abi 'reproducibility-test-v1' \
    --out "$directory/starling-ics.wevalcache.manifest"
}

REPRO_SQLITE_OLD="$CACHE/repro sqlite 3044000"
REPRO_SQLITE_NEW="$CACHE/repro sqlite 3045003"
mkdir "$REPRO_SQLITE_OLD" "$REPRO_SQLITE_NEW"
cp "$REPRO_ONE/raw.wevalcache" "$REPRO_SQLITE_OLD/raw.wevalcache"
cp "$REPRO_ONE/raw.wevalcache" "$REPRO_SQLITE_NEW/raw.wevalcache"
python3 - "$REPRO_SQLITE_OLD/raw.wevalcache" \
  "$REPRO_SQLITE_NEW/raw.wevalcache" <<'PY'
import sys

for path, version in zip(sys.argv[1:], (3044000, 3045003)):
    with open(path, "r+b") as cache:
        cache.seek(96)
        cache.write(version.to_bytes(4, "big"))
PY
seal_existing_cache "$REPRO_SQLITE_OLD"
seal_existing_cache "$REPRO_SQLITE_NEW"
cmp "$REPRO_SQLITE_OLD/starling-ics.wevalcache" \
  "$REPRO_SQLITE_NEW/starling-ics.wevalcache"
cmp "$REPRO_SQLITE_OLD/starling-ics.wevalcache.manifest" \
  "$REPRO_SQLITE_NEW/starling-ics.wevalcache.manifest"
python3 - "$REPRO_SQLITE_OLD/starling-ics.wevalcache" <<'PY'
import sqlite3
import sys

with open(sys.argv[1], "rb") as cache:
    cache.seek(96)
    assert int.from_bytes(cache.read(4), "big") == 3044000
db = sqlite3.connect(sys.argv[1])
assert db.execute("pragma integrity_check").fetchone() == ("ok",)
assert db.execute("select count(*) from weval_cache where created_time = 0").fetchone()[0] > 0
db.close()
PY
cmp "$REPRO_ONE/starling-ics.wevalcache" \
  "$REPRO_TWO/starling-ics.wevalcache"
cmp "$REPRO_ONE/starling-ics.wevalcache.manifest" \
  "$REPRO_TWO/starling-ics.wevalcache.manifest"
test "$(sha256sum "$REPRO_ONE/starling-ics.wevalcache" | cut -d ' ' -f 1)" = \
  "$(sha256sum "$REPRO_TWO/starling-ics.wevalcache" | cut -d ' ' -f 1)"
test "$(sha256sum "$REPRO_ONE/starling-ics.wevalcache.manifest" | cut -d ' ' -f 1)" = \
  "$(sha256sum "$REPRO_TWO/starling-ics.wevalcache.manifest" | cut -d ' ' -f 1)"
test "$(sed -n 's/^key=//p' "$REPRO_ONE/starling-ics.wevalcache.manifest")" = \
  "$(sed -n 's/^key=//p' "$REPRO_TWO/starling-ics.wevalcache.manifest")"

CHANGED_PRIMER="$CACHE/repro-changed-primer.js"
cat > "$CHANGED_PRIMER" <<'EOF'
function reproducibilityPrimer(value) {
  return value + 1;
}
function main() {
  let value = 0;
  for (let i = 0; i < 20000; i++) {
    value = reproducibilityPrimer(value);
  }
  if (value !== 20000) {
    throw new Error("cache primer failed");
  }
}
EOF
prime_clean_cache "$REPRO_CHANGED" "$CHANGED_PRIMER"
if cmp -s "$REPRO_ONE/starling-ics.wevalcache" \
  "$REPRO_CHANGED/starling-ics.wevalcache" &&
  cmp -s "$REPRO_ONE/starling-ics.wevalcache.manifest" \
    "$REPRO_CHANGED/starling-ics.wevalcache.manifest"; then
  echo "FAIL: changed primer did not alter the sealed artifact" >&2
  exit 1
fi
test "$(sed -n 's/^key=//p' "$REPRO_ONE/starling-ics.wevalcache.manifest")" != \
  "$(sed -n 's/^key=//p' "$REPRO_CHANGED/starling-ics.wevalcache.manifest")"
echo "Clean AOT cache reproducibility passed"

"$AOT_BUNDLE/componentize.sh" --output "$AOT_RUNTIME_OUTPUT"
"$WASM_TOOLS" validate --features all "$AOT_RUNTIME_OUTPUT"
"$COMPONENTIZER" \
  --aot \
  --build-root "$ROOT" \
  --cache-dir "$CACHE/runtime-only cache" \
  --zig-bin "$ZIG" \
  --weval-bin "$WEVAL" \
  --preview2-adapter "$ADAPTER" \
  --wasm-tools-bin "$WASM_TOOLS" \
  --out "$AOT_RUNTIME_INVOKE_OUTPUT"
"$WASM_TOOLS" validate --features all "$AOT_RUNTIME_INVOKE_OUTPUT"
runtime_env_output="$(
  "$WASMTIME" run -S cli -S http \
    --env "STARLINGMONKEY_CONFIG=-e console.log('runtime-env-config')" \
    "$AOT_RUNTIME_INVOKE_OUTPUT"
)"
test "$runtime_env_output" = "Log: runtime-env-config"
runtime_arg_output="$(
  "$WASMTIME" run -S cli -S http "$AOT_RUNTIME_INVOKE_OUTPUT" \
    -e "console.log('runtime-argument-config')"
)"
test "$runtime_arg_output" = "Log: runtime-argument-config"

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
