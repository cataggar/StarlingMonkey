#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <starling-componentize>" >&2
  exit 2
fi

COMPONENTIZER="$(realpath "$1")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.scratch"
TOOLS="$SCRATCH/fake tools"
WORK="$SCRATCH/work with spaces"
rm -rf "$SCRATCH"
mkdir -p "$TOOLS" "$WORK/wit package"
trap 'rm -rf "$SCRATCH"' EXIT

SOURCE="$WORK/source module.js"
ENGINE="$WORK/fake engine.wasm"
ADAPTER="$WORK/fake adapter.wasm"
WIT="$WORK/wit package"
printf 'export const api = {};\n' > "$SOURCE"
printf 'engine-bytes\n' > "$ENGINE"
printf 'adapter-bytes\n' > "$ADAPTER"
cat > "$WIT/world.wit" <<'EOF'
package test:componentizer;
world exports {}
EOF

cat > "$TOOLS/fake wizer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_FAIL_STAGE:-}" = "wizer" ]; then
  echo "injected wizer failure" >&2
  exit 23
fi
test -z "${STARLINGMONKEY_CONFIG+x}"
for arg in "$@"; do
  case "$arg" in
    -S|-W)
      echo "standalone Wizer received a Wasmtime-only argument: $arg" >&2
      exit 24
      ;;
  esac
done
printf '%s\n' "$*" | grep -q -- '--allow-wasi'
printf '%s\n' "$*" | grep -q -- '--init-func wizer-initialize'
printf '%s\n' "$*" | grep -q -- '--inherit-env true'
printf '%s\n' "$*" | grep -q -- '--wasm-bulk-memory true'
cat > "$FAKE_RUNTIME_ARGS_LOG"
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
input="${!#}"
cp "$input" "$out"
EOF

cat > "$TOOLS/fake wabt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
stage="$1 $2"
if [ "${FAKE_FAIL_STAGE:-}" = "$stage" ]; then
  echo "injected $stage failure" >&2
  exit 23
fi
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
input="${!#}"
cp "$input" "$out"
EOF

cat > "$TOOLS/fake wasm-tools" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
stage="$1${2:+ $2}"
if [ "${FAKE_FAIL_STAGE:-}" = "$stage" ] || \
   { [ "${FAKE_FAIL_STAGE:-}" = "validate" ] && [ "$1" = "validate" ]; }; then
  echo "injected $stage failure" >&2
  exit 23
fi
if [ "$1" = "validate" ] && [ -n "${FAKE_CREATE_DEBUG_COLLISION:-}" ]; then
  mkdir -p "$FAKE_CREATE_DEBUG_COLLISION"
  printf 'racing-debug-output\n' > "$FAKE_CREATE_DEBUG_COLLISION/sentinel"
fi
if [ "$1 $2" = "component new" ]; then
  out=""
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--output" ]; then
      j=$((i + 1))
      out="${!j}"
    fi
  done
  cp "${!#}" "$out"
elif [ "$1 $2" = "metadata add" ]; then
  out=""
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--output" ]; then
      j=$((i + 1))
      out="${!j}"
    fi
  done
  cp "${!#}" "$out"
fi
EOF

cat > "$TOOLS/fake zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_FAIL_STAGE:-}" = "zig build" ]; then
  echo "injected zig build failure" >&2
  exit 23
fi
if [ -n "${FAKE_ZIG_ACTIVE_DIR:-}" ]; then
  if ! mkdir "$FAKE_ZIG_ACTIVE_DIR"; then
    echo "concurrent same-key Zig builds overlapped" >&2
    exit 25
  fi
  trap 'rmdir "$FAKE_ZIG_ACTIVE_DIR"' EXIT
  sleep "${FAKE_ZIG_DELAY:-0}"
fi
prefix=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--prefix" ]; then
    j=$((i + 1))
    prefix="${!j}"
  fi
done
printf '%s\n' "$prefix" >> "$FAKE_ZIG_PREFIX_LOG"
printf '%s|%s\n' "${ZIG_LOCAL_CACHE_DIR-unset}" "$ZIG_GLOBAL_CACHE_DIR" \
  >> "$FAKE_ZIG_ENV_LOG"
mkdir -p "$prefix/bin"
cp "$FAKE_ENGINE" "$prefix/bin/starling-raw.wasm"
cp "$FAKE_ADAPTER" "$prefix/bin/preview1-adapter.wasm"
for arg in "$@"; do
  if [ "$arg" = "-Dcomponentizer-debug-bindings=true" ]; then
    cp "$FAKE_BINDINGS" "$prefix/bin/component-bindings.zig"
  fi
done
EOF
chmod +x "$TOOLS"/*

export FAKE_RUNTIME_ARGS_LOG="$SCRATCH/runtime args.log"
export FAKE_ENGINE="$ENGINE"
export FAKE_ADAPTER="$ADAPTER"
export FAKE_ZIG_PREFIX_LOG="$SCRATCH/zig prefixes.log"
export FAKE_ZIG_ENV_LOG="$SCRATCH/zig env.log"
export FAKE_BINDINGS="$SCRATCH/component-bindings.zig"
export STARLINGMONKEY_CONFIG="--ambient-config-must-not-reach-wizer"

cat > "$FAKE_BINDINGS" <<'EOF'
pub const js_import_manifest: []const u8 =
    "R\ttest:componentizer/host@1.0.0\tcounter\tCounter\n" ++
    "M\ttest:componentizer/host@1.0.0\tcounter\tincrement\ttest:componentizer/host@1.0.0#[method]counter.increment\t1\n" ++
    "test:componentizer/host@1.0.0\tadd\ttest:componentizer/host@1.0.0#add\t2\n" ++
    "root-log\tdefault\t$root#root-log\t1\n" ++
    "";
EOF

OUTPUT="$WORK/output component.wasm"
DEBUG_DIR="$WORK/debug output"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --runtime-arg -d \
  --js-heap-limit-mib 256 \
  --debug-dir "$DEBUG_DIR" \
  --out "$OUTPUT" \
  "$SOURCE"

cmp "$ENGINE" "$OUTPUT"
grep -Fq -- '-d' "$FAKE_RUNTIME_ARGS_LOG"
grep -Fq -- '--js-heap-limit-mib 256' "$FAKE_RUNTIME_ARGS_LOG"
grep -Fq -- "\"$SOURCE\"" "$FAKE_RUNTIME_ARGS_LOG"
test -f "$DEBUG_DIR/initialized.wasm"
test -f "$DEBUG_DIR/embedded.wasm"
test -f "$DEBUG_DIR/component.wasm"
test -f "$DEBUG_DIR/commands.txt"
test -f "$DEBUG_DIR/imports.json"
test -f "$DEBUG_DIR/metadata.json"
python3 - "$DEBUG_DIR/imports.json" <<'PY'
import json, sys
imports = json.load(open(sys.argv[1], encoding="utf-8"))
assert imports["complete"] is False
assert imports["imports"] == []
PY
grep -Fq '<transaction>' "$DEBUG_DIR/commands.txt"
if grep -Fq '.starling-componentize-' "$DEBUG_DIR/commands.txt"; then
  echo "FAIL: debug command log retained random transaction paths" >&2
  exit 1
fi

SOURCE_ALIAS_DIR="$SCRATCH/real sources"
SOURCE_ALIAS="$WORK/source alias.js"
SOURCE_ALIAS_OUTPUT="$WORK/source alias.wasm"
mkdir -p "$SOURCE_ALIAS_DIR"
printf 'export const aliased = true;\n' > "$SOURCE_ALIAS_DIR/source.js"
ln -s "$SOURCE_ALIAS_DIR/source.js" "$SOURCE_ALIAS"
(
  cd "$WORK"
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    "$SOURCE_ALIAS"
)
grep -Fq -- "\"$SOURCE_ALIAS_DIR/source.js\"" "$FAKE_RUNTIME_ARGS_LOG"
cmp "$ENGINE" "$SOURCE_ALIAS_OUTPUT"

SOURCE_CONTENT="$(cat "$SOURCE")"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$SOURCE" \
  "$SOURCE"
then
  echo "FAIL: source/output collision unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$SOURCE")" = "$SOURCE_CONTENT"

printf 'original-output\n' > "$OUTPUT"
HUMAN_ERROR="$SCRATCH/human-error.log"
if FAKE_FAIL_STAGE="component embed" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$OUTPUT" \
  "$SOURCE" 2> "$HUMAN_ERROR"
then
  echo "FAIL: injected component-embed failure unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$OUTPUT")" = "original-output"
grep -Fq 'error[SMC4101] embed:' "$HUMAN_ERROR"
grep -Fq 'injected component embed failure' "$HUMAN_ERROR"
if find "$WORK" -maxdepth 1 -name '.output component.wasm.starling-componentize-*' \
  | grep -q .; then
  echo "FAIL: failed componentization left transaction artifacts" >&2
  exit 1
fi

JSON_ERROR="$SCRATCH/json-error.log"
if FAKE_FAIL_STAGE="component embed" "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/json failure.wasm" \
  "$SOURCE" 2> "$JSON_ERROR"
then
  echo "FAIL: JSON diagnostic failure unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$JSON_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["schema"] == "starling-componentize-diagnostic/v1"
assert diagnostic["code"] == "SMC4101"
assert diagnostic["phase"] == "embed"
assert diagnostic["cause"] == "CommandFailed"
assert diagnostic["command"] == "wabt component embed"
assert diagnostic["exit_code"] == 23
assert diagnostic["signal"] is None
assert "injected component embed failure" in diagnostic["detail"]
PY
test ! -e "$WORK/json failure.wasm"

PARSE_ERROR="$SCRATCH/parse-error.log"
if "$COMPONENTIZER" --diagnostic-format=json --not-an-option 2> "$PARSE_ERROR"; then
  echo "FAIL: invalid CLI unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$PARSE_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC0001"
assert diagnostic["phase"] == "arguments"
assert diagnostic["cause"] == "UnknownArgument"
PY

negative_stage() {
  local injected="$1" mode="$2" slug="${1// /-}"
  local failed_output="$WORK/negative-$slug.wasm"
  local failed_metadata="$WORK/negative-$slug.json"
  local failed_debug="$WORK/negative-$slug.debug"
  local -a world_args=()
  if [ "$mode" = "wit" ]; then
    world_args=(--wit "$WIT" --world-name exports --wabt-bin "$TOOLS/fake wabt")
  fi
  if FAKE_FAIL_STAGE="$injected" "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    "${world_args[@]}" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$failed_metadata" \
    --debug-dir "$failed_debug" \
    --out "$failed_output" \
    "$SOURCE" >/dev/null 2>&1
  then
    echo "FAIL: injected $injected failure unexpectedly succeeded" >&2
    exit 1
  fi
  test ! -e "$failed_output"
  test ! -e "$failed_metadata"
  test ! -e "$failed_debug"
}

negative_stage wizer wit
negative_stage "module strip" wit
negative_stage "component embed" wit
negative_stage "component new" wit
negative_stage "metadata add" wit
negative_stage validate wit
negative_stage "component new" no-wit

UNAVAILABLE_OUTPUT="$WORK/unavailable metadata.wasm"
UNAVAILABLE_METADATA="$WORK/unavailable metadata.json"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$UNAVAILABLE_METADATA" \
  --out "$UNAVAILABLE_OUTPUT" \
  "$SOURCE" >/dev/null 2>&1
then
  echo "FAIL: public imports metadata without generated bindings succeeded" >&2
  exit 1
fi
test ! -e "$UNAVAILABLE_OUTPUT"
test ! -e "$UNAVAILABLE_METADATA"

RUNTIME_FAILURE="$WORK/runtime-build-failure.wasm"
RUNTIME_ERROR="$SCRATCH/runtime-build-error.log"
if FAKE_FAIL_STAGE="zig build" "$COMPONENTIZER" \
  --json-diagnostics \
  --build-root "$ROOT" \
  --cache-dir "$WORK/failing runtime cache" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$RUNTIME_FAILURE" \
  "$SOURCE" >/dev/null 2> "$RUNTIME_ERROR"
then
  echo "FAIL: injected runtime build failure unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$RUNTIME_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC2001"
assert diagnostic["phase"] == "runtime_build"
assert diagnostic["command"] == "zig build runtime"
assert diagnostic["exit_code"] == 23
PY
test ! -e "$RUNTIME_FAILURE"

if find "$WORK" -maxdepth 1 -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: a negative stage left transaction artifacts" >&2
  exit 1
fi

RACE_OUTPUT="$WORK/publish-race.wasm"
RACE_METADATA="$WORK/publish-race.json"
RACE_DEBUG="$WORK/publish-race.debug"
RACE_ERROR="$SCRATCH/publish-race-error.log"
printf 'existing-component\n' > "$RACE_OUTPUT"
printf 'existing-metadata\n' > "$RACE_METADATA"
if FAKE_CREATE_DEBUG_COLLISION="$RACE_DEBUG" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$RACE_METADATA" \
  --debug-dir "$RACE_DEBUG" \
  --out "$RACE_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$RACE_ERROR"
then
  echo "FAIL: publish-time debug race unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$RACE_OUTPUT")" = "existing-component"
test "$(cat "$RACE_METADATA")" = "existing-metadata"
test "$(cat "$RACE_DEBUG/sentinel")" = "racing-debug-output"
grep -Fq 'error[SMC7001] publish:' "$RACE_ERROR"
if find "$WORK" -maxdepth 1 -name '.publish-race.wasm.starling-componentize-*' \
  | grep -q .; then
  echo "FAIL: publish rollback left transaction artifacts" >&2
  exit 1
fi

COLLISION_DIR="$WORK/debug collision"
COLLISION_OUTPUT="$COLLISION_DIR/component.wasm"
mkdir -p "$COLLISION_DIR"
printf 'collision-output\n' > "$COLLISION_OUTPUT"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$COLLISION_DIR" \
  --out "$COLLISION_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: debug/output collision unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$COLLISION_OUTPUT")" = "collision-output"

SYMLINK_DEBUG_DIR="$WORK/debug symlink"
SYMLINK_OUTPUT="$WORK/component.wasm"
ln -s "$WORK" "$SYMLINK_DEBUG_DIR"
printf 'symlink-collision-output\n' > "$SYMLINK_OUTPUT"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$SYMLINK_DEBUG_DIR" \
  --out "$SYMLINK_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: symlinked debug/output collision unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$SYMLINK_OUTPUT")" = "symlink-collision-output"

LINK_DEBUG_DIR="$WORK/debug file link"
LINK_TARGET="$WORK/commands link target.txt"
LINK_OUTPUT="$WORK/link-safe output.wasm"
mkdir -p "$LINK_DEBUG_DIR"
printf 'link-target\n' > "$LINK_TARGET"
ln -s "$LINK_TARGET" "$LINK_DEBUG_DIR/commands.txt"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$LINK_DEBUG_DIR" \
  --out "$LINK_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: existing debug directory unexpectedly accepted" >&2
  exit 1
fi
test "$(cat "$LINK_TARGET")" = "link-target"
test -L "$LINK_DEBUG_DIR/commands.txt"
test ! -e "$LINK_OUTPUT"

CACHE="$WORK/runtime cache"
BUILD_OUTPUT_1="$WORK/built output 1.wasm"
BUILD_OUTPUT_2="$WORK/built output 2.wasm"
BUILD_OUTPUT_3="$WORK/built output 3.wasm"
build_with_fake_zig() {
  local output="$1"
  shift
  "$COMPONENTIZER" \
    --build-root "$ROOT" \
    --cache-dir "$CACHE" \
    --zig-bin "$TOOLS/fake zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    "$@" \
    --out "$output" \
    "$SOURCE"
}
build_with_fake_zig "$BUILD_OUTPUT_1"
build_with_fake_zig "$BUILD_OUTPUT_2"
printf '\n// cache invalidation\n' >> "$WIT/world.wit"
build_with_fake_zig "$BUILD_OUTPUT_3"

METADATA_OUTPUT="$WORK/public metadata.json"
METADATA_REFERENCE="$WORK/public metadata reference.json"
BUILD_DEBUG_DIR="$WORK/build debug bindings"
build_with_fake_zig "$WORK/metadata component.wasm" \
  --metadata-out "$METADATA_OUTPUT" \
  --debug-dir "$BUILD_DEBUG_DIR"
cp "$METADATA_OUTPUT" "$METADATA_REFERENCE"
test -s "$BUILD_DEBUG_DIR/component-bindings.zig"
test -s "$BUILD_DEBUG_DIR/imports.json"
cmp "$METADATA_OUTPUT" "$BUILD_DEBUG_DIR/metadata.json"
python3 - "$METADATA_OUTPUT" "$BUILD_DEBUG_DIR/imports.json" <<'PY'
import json, re, sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
imports = json.load(open(sys.argv[2], encoding="utf-8"))
sha256 = re.compile(r"^[0-9a-f]{64}$")
assert metadata["schema"] == "starling-componentize-metadata/v1"
assert metadata["processed_by"] == {
    "name": "starling-componentize",
    "version": "0.3.0",
}
assert metadata["imports_complete"] is True
assert metadata["imports"] == [
    ["test:componentizer/host@1.0.0", "Counter"],
    ["test:componentizer/host@1.0.0", "add"],
    ["root-log", "default"],
]
assert imports["imports"] == metadata["imports"]
assert imports["complete"] is True
assert [b["kind"] for b in metadata["bindings"]] == [
    "resource", "method", "function", "function",
]
provenance = metadata["provenance"]
assert provenance["dispatch_world"]["name"] == "exports"
assert provenance["component_world"]["name"] == "exports"
assert all(sha256.match(provenance[k]) for k in (
    "worlds_sha256", "features_sha256", "tools_sha256",
))
assert all(sha256.match(v) for k, v in provenance["inputs"].items() if v)
assert [f["name"] for f in provenance["features"]] == [
    "stdio", "random", "clocks", "http", "fetch-event",
]
assert all(f["enabled"] for f in provenance["features"])
assert [t["name"] for t in provenance["tools"]] == [
    "zig", "wizer", "wabt", "wasm-tools",
]
assert all(sha256.match(t["sha256"]) for t in provenance["tools"])
assert sha256.match(metadata["component_sha256"])
PY
build_with_fake_zig "$WORK/metadata component.wasm" \
  --metadata-out "$METADATA_OUTPUT"
cmp "$METADATA_REFERENCE" "$METADATA_OUTPUT"

rm -rf "$CACHE"
export FAKE_ZIG_ACTIVE_DIR="$SCRATCH/fake-zig-active"
export FAKE_ZIG_DELAY=1
build_with_fake_zig "$WORK/concurrent output 1.wasm" &
pid1=$!
build_with_fake_zig "$WORK/concurrent output 2.wasm" &
pid2=$!
wait "$pid1"
wait "$pid2"
unset FAKE_ZIG_ACTIVE_DIR FAKE_ZIG_DELAY

mapfile -t prefixes < "$FAKE_ZIG_PREFIX_LOG"
test "${#prefixes[@]}" -eq 7
test "${prefixes[0]}" = "${prefixes[1]}"
test "${prefixes[0]}" != "${prefixes[2]}"
test "${prefixes[2]}" = "${prefixes[3]}"
test "${prefixes[2]}" = "${prefixes[4]}"
test "${prefixes[2]}" = "${prefixes[5]}"
test "${prefixes[2]}" = "${prefixes[6]}"
cmp "$ENGINE" "$WORK/concurrent output 1.wasm"
cmp "$ENGINE" "$WORK/concurrent output 2.wasm"
while IFS='|' read -r local_cache global_cache; do
  test "$local_cache" = "unset"
  test "$global_cache" = "$CACHE/zig-global-cache"
done < "$FAKE_ZIG_ENV_LOG"
cmp "$ENGINE" "$BUILD_OUTPUT_1"
cmp "$ENGINE" "$BUILD_OUTPUT_2"
cmp "$ENGINE" "$BUILD_OUTPUT_3"

echo "native componentizer fake-tool tests passed"
