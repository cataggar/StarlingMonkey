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
if [ -n "${FAKE_REPLACE_SOURCE:-}" ]; then
  printf 'replaced-source\n' > "$FAKE_REPLACE_SOURCE"
  printf 'replaced-engine\n' > "$FAKE_REPLACE_ENGINE"
  printf 'replaced-adapter\n' > "$FAKE_REPLACE_ADAPTER"
  printf 'package test:componentizer;\nworld replaced {}\n' > \
    "$FAKE_REPLACE_WIT/world.wit"
  for tool in "$FAKE_REPLACE_WABT" "$FAKE_REPLACE_WASM_TOOLS"; do
    printf '#!/usr/bin/env bash\nexit 99\n' > "$tool"
    chmod +x "$tool"
  done
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

cat > "$TOOLS/fake wabt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
stage="$1 $2"
if [ "${FAKE_FAIL_STAGE:-}" = "$stage" ]; then
  if [ "${FAKE_INVALID_STDERR:-}" = "1" ]; then
    python3 - <<'PY' >&2
import sys
sys.stderr.buffer.write(b"\xff" + b"x" * 16383 + "€".encode())
PY
  else
    echo "injected $stage failure" >&2
  fi
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
if [ "$1" = "validate" ] && [ -n "${FAKE_RACE_DESTINATION:-}" ]; then
  rm -f "$FAKE_RACE_DESTINATION"
  case "$FAKE_RACE_KIND" in
    directory)
      mkdir "$FAKE_RACE_DESTINATION"
      printf 'preserve-tree\n' > "$FAKE_RACE_DESTINATION/sentinel"
      ;;
    symlink)
      ln -s "$FAKE_RACE_TARGET" "$FAKE_RACE_DESTINATION"
      ;;
  esac
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
mkdir -p "$prefix/bin/runtime-build-tools"
cp "$FAKE_WASIP3_BINDGEN" "$prefix/bin/runtime-build-tools/wasip3-bindgen"
cp "$FAKE_WASM_OPT" "$prefix/bin/runtime-build-tools/wasm-opt"
cat > "$prefix/bin/runtime-build-tools.json" <<'JSON'
{
  "schema": "starling-componentize-build-tools/v1",
  "tools": [
    {"name": "wasip3-bindgen", "path": "runtime-build-tools/wasip3-bindgen"},
    {"name": "wasm-opt", "path": "runtime-build-tools/wasm-opt"}
  ]
}
JSON
for arg in "$@"; do
  if [ "$arg" = "-Dcomponentizer-debug-bindings=true" ]; then
    cp "$FAKE_BINDINGS" "$prefix/bin/component-bindings.zig"
  fi
done
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/fake wasip3-bindgen"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TOOLS/fake wasm-opt"
chmod +x "$TOOLS"/*

export FAKE_RUNTIME_ARGS_LOG="$SCRATCH/runtime args.log"
export FAKE_ENGINE="$ENGINE"
export FAKE_ADAPTER="$ADAPTER"
export FAKE_ZIG_PREFIX_LOG="$SCRATCH/zig prefixes.log"
export FAKE_ZIG_ENV_LOG="$SCRATCH/zig env.log"
export FAKE_BINDINGS="$SCRATCH/component-bindings.zig"
export FAKE_WASIP3_BINDGEN="$TOOLS/fake wasip3-bindgen"
export FAKE_WASM_OPT="$TOOLS/fake wasm-opt"
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
grep -Fq -- 'starling-componentize-source-' "$FAKE_RUNTIME_ARGS_LOG"
test -f "$DEBUG_DIR/initialized.wasm"
test -f "$DEBUG_DIR/embedded.wasm"
test -f "$DEBUG_DIR/component.wasm"
test -f "$DEBUG_DIR/commands.txt"
test -f "$DEBUG_DIR/imports.json"
test -f "$DEBUG_DIR/metadata.json"
python3 - "$DEBUG_DIR/imports.json" "$DEBUG_DIR/metadata.json" <<'PY'
import json, sys
imports = json.load(open(sys.argv[1], encoding="utf-8"))
metadata = json.load(open(sys.argv[2], encoding="utf-8"))
assert imports["complete"] is False
assert imports["imports"] == []
assert metadata["provenance"]["features"] is None
assert metadata["provenance"]["features_sha256"] is None
PY
grep -Fq '<transaction>' "$DEBUG_DIR/commands.txt"
if grep -Fq '.starling-componentize-' "$DEBUG_DIR/commands.txt"; then
  echo "FAIL: debug command log retained random transaction paths" >&2
  exit 1
fi

printf 'keep-me\n' > "$DEBUG_DIR/unrelated.txt"
mkdir "$DEBUG_DIR/unrelated-tree"
printf 'keep-tree\n' > "$DEBUG_DIR/unrelated-tree/sentinel"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$DEBUG_DIR" \
  --out "$OUTPUT" \
  "$SOURCE"
test "$(cat "$DEBUG_DIR/unrelated.txt")" = "keep-me"
test "$(cat "$DEBUG_DIR/unrelated-tree/sentinel")" = "keep-tree"
test -f "$DEBUG_DIR/commands.txt"

SNAPSHOT_DIR="$WORK/snapshot race debug"
SNAPSHOT_OUTPUT="$WORK/snapshot race.wasm"
cp "$SOURCE" "$SCRATCH/original-source"
cp "$ENGINE" "$SCRATCH/original-engine"
cp "$ADAPTER" "$SCRATCH/original-adapter"
cp "$WIT/world.wit" "$SCRATCH/original-world.wit"
cp "$TOOLS/fake wabt" "$SCRATCH/original-wabt"
cp "$TOOLS/fake wasm-tools" "$SCRATCH/original-wasm-tools"
FAKE_REPLACE_SOURCE="$SOURCE" \
FAKE_REPLACE_ENGINE="$ENGINE" \
FAKE_REPLACE_ADAPTER="$ADAPTER" \
FAKE_REPLACE_WIT="$WIT" \
FAKE_REPLACE_WABT="$TOOLS/fake wabt" \
FAKE_REPLACE_WASM_TOOLS="$TOOLS/fake wasm-tools" \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$SNAPSHOT_DIR" \
  --out "$SNAPSHOT_OUTPUT" \
  "$SOURCE"
cmp "$SCRATCH/original-engine" "$SNAPSHOT_OUTPUT"
python3 - "$SNAPSHOT_DIR/metadata.json" \
  "$SCRATCH/original-source" "$SCRATCH/original-engine" \
  "$SCRATCH/original-adapter" "$SCRATCH/original-world.wit" \
  "$SCRATCH/original-wabt" "$SCRATCH/original-wasm-tools" <<'PY'
import hashlib, json, sys
digest = lambda path: hashlib.sha256(open(path, "rb").read()).hexdigest()
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
inputs = metadata["provenance"]["inputs"]
assert inputs["source_sha256"] == digest(sys.argv[2])
assert inputs["engine_sha256"] == digest(sys.argv[3])
assert inputs["preview2_adapter_sha256"] == digest(sys.argv[4])
wit = hashlib.sha256()
wit.update(b"world.wit\0")
wit.update(open(sys.argv[5], "rb").read())
wit.update(b"\xff")
assert metadata["provenance"]["dispatch_world"]["wit_sha256"] == wit.hexdigest()
tools = {tool["name"]: tool["sha256"] for tool in metadata["provenance"]["tools"]}
assert tools["wabt"] == digest(sys.argv[6])
assert tools["wasm-tools"] == digest(sys.argv[7])
PY
cp "$SCRATCH/original-source" "$SOURCE"
cp "$SCRATCH/original-engine" "$ENGINE"
cp "$SCRATCH/original-adapter" "$ADAPTER"
cp "$SCRATCH/original-world.wit" "$WIT/world.wit"
cp "$SCRATCH/original-wabt" "$TOOLS/fake wabt"
cp "$SCRATCH/original-wasm-tools" "$TOOLS/fake wasm-tools"
if find "$WORK" -name '*.starling-componentize-source-*' -o \
  -name '*.starling-componentize-initializer-*' | grep -q .; then
  echo "FAIL: immutable input snapshots were not cleaned up" >&2
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
grep -Fq -- "$SOURCE_ALIAS_DIR/.source.starling-componentize-source-" \
  "$FAKE_RUNTIME_ARGS_LOG"
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
  local injected="$1" mode="$2" expected_code="$3" expected_phase="$4"
  local expected_command="$5" slug="${1// /-}"
  local failed_output="$WORK/negative-$slug.wasm"
  local failed_metadata="$WORK/negative-$slug.json"
  local failed_debug="$WORK/negative-$slug.debug"
  local diagnostic_output="$SCRATCH/negative-$slug.diagnostic.jsonl"
  local -a world_args=()
  if [ "$mode" = "wit" ]; then
    world_args=(--wit "$WIT" --world-name exports --wabt-bin "$TOOLS/fake wabt")
  fi
  if FAKE_FAIL_STAGE="$injected" "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    "${world_args[@]}" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$failed_metadata" \
    --debug-dir "$failed_debug" \
    --out "$failed_output" \
    "$SOURCE" >/dev/null 2> "$diagnostic_output"
  then
    echo "FAIL: injected $injected failure unexpectedly succeeded" >&2
    exit 1
  fi
  test ! -e "$failed_output"
  test ! -e "$failed_metadata"
  test ! -e "$failed_debug"
  python3 - "$diagnostic_output" "$expected_code" "$expected_phase" \
    "$expected_command" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == sys.argv[2], diagnostic
assert diagnostic["phase"] == sys.argv[3], diagnostic
assert diagnostic["cause"] == "CommandFailed", diagnostic
assert diagnostic["command"] == sys.argv[4], diagnostic
assert diagnostic["exit_code"] == 23, diagnostic
assert diagnostic["signal"] is None, diagnostic
PY
}

negative_stage wizer wit SMC3001 initialize wizer
negative_stage "module strip" wit SMC4001 strip "wabt module strip"
negative_stage "component embed" wit SMC4101 embed "wabt component embed"
negative_stage "component new" wit SMC4201 adapt "wabt component new"
negative_stage "metadata add" wit SMC4301 metadata "wasm-tools metadata add"
negative_stage validate wit SMC5001 validate "wasm-tools validate"
negative_stage "component new" no-wit SMC4201 adapt "wasm-tools component new"

INVALID_UTF8_ERROR="$SCRATCH/invalid-utf8-error.jsonl"
if FAKE_FAIL_STAGE="component embed" FAKE_INVALID_STDERR=1 "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/invalid-utf8.wasm" \
  "$SOURCE" >/dev/null 2> "$INVALID_UTF8_ERROR"
then
  echo "FAIL: invalid-UTF8 diagnostic injection unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$INVALID_UTF8_ERROR" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
raw.decode("utf-8")
diagnostic = json.loads(raw)
assert diagnostic["phase"] == "embed"
assert "\ufffd" in diagnostic["detail"]
assert len(diagnostic["detail"].encode("utf-8")) < 17 * 1024
PY

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
FAKE_CREATE_DEBUG_COLLISION="$RACE_DEBUG" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$RACE_METADATA" \
  --debug-dir "$RACE_DEBUG" \
  --out "$RACE_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$RACE_ERROR"
cmp "$ENGINE" "$RACE_OUTPUT"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$RACE_METADATA"
test "$(cat "$RACE_DEBUG/sentinel")" = "racing-debug-output"
if find "$WORK" -maxdepth 1 -name '.publish-race.wasm.starling-componentize-*' \
  | grep -q .; then
  echo "FAIL: publish-time debug merge left transaction artifacts" >&2
  exit 1
fi

for artifact in component metadata; do
  unsafe_output="$WORK/unsafe-$artifact.wasm"
  unsafe_metadata="$WORK/unsafe-$artifact.json"
  unsafe_target="$WORK/unsafe-$artifact-target"
  unsafe_destination="$unsafe_output"
  if [ "$artifact" = metadata ]; then
    unsafe_destination="$unsafe_metadata"
  fi
  printf 'old-component\n' > "$unsafe_output"
  printf 'old-metadata\n' > "$unsafe_metadata"
  mkdir "$unsafe_target"
  printf 'target-tree\n' > "$unsafe_target/sentinel"
  if FAKE_RACE_DESTINATION="$unsafe_destination" \
    FAKE_RACE_KIND=directory "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$unsafe_metadata" \
    --out "$unsafe_output" \
    "$SOURCE" >/dev/null 2>&1
  then
    echo "FAIL: raced $artifact directory unexpectedly published" >&2
    exit 1
  fi
  test -d "$unsafe_destination"
  test "$(cat "$unsafe_destination/sentinel")" = "preserve-tree"
  test "$(cat "$unsafe_target/sentinel")" = "target-tree"
done

SYMLINK_RACE_OUTPUT="$WORK/unsafe-symlink.wasm"
SYMLINK_RACE_METADATA="$WORK/unsafe-symlink.json"
SYMLINK_RACE_TARGET="$WORK/unsafe-symlink-target"
printf 'old-component\n' > "$SYMLINK_RACE_OUTPUT"
printf 'old-metadata\n' > "$SYMLINK_RACE_METADATA"
printf 'symlink-target\n' > "$SYMLINK_RACE_TARGET"
if FAKE_RACE_DESTINATION="$SYMLINK_RACE_METADATA" \
  FAKE_RACE_KIND=symlink FAKE_RACE_TARGET="$SYMLINK_RACE_TARGET" \
  "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$SYMLINK_RACE_METADATA" \
  --out "$SYMLINK_RACE_OUTPUT" \
  "$SOURCE" >/dev/null 2>&1
then
  echo "FAIL: raced metadata symlink unexpectedly published" >&2
  exit 1
fi
test -L "$SYMLINK_RACE_METADATA"
test "$(cat "$SYMLINK_RACE_TARGET")" = "symlink-target"

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
"$COMPONENTIZER" \
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
test "$(cat "$LINK_TARGET")" = "link-target"
test -f "$LINK_DEBUG_DIR/commands.txt"
test ! -L "$LINK_DEBUG_DIR/commands.txt"
cmp "$ENGINE" "$LINK_OUTPUT"

DIRECTORY_DEBUG_DIR="$WORK/debug generated directory"
DIRECTORY_DEBUG_OUTPUT="$WORK/debug generated directory.wasm"
mkdir -p "$DIRECTORY_DEBUG_DIR/commands.txt"
printf 'preserve-generated-tree\n' > "$DIRECTORY_DEBUG_DIR/commands.txt/sentinel"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$DIRECTORY_DEBUG_DIR" \
  --out "$DIRECTORY_DEBUG_OUTPUT" \
  "$SOURCE" >/dev/null 2>&1
then
  echo "FAIL: generated-name directory was recursively replaced" >&2
  exit 1
fi
test "$(cat "$DIRECTORY_DEBUG_DIR/commands.txt/sentinel")" = \
  "preserve-generated-tree"
test ! -e "$DIRECTORY_DEBUG_OUTPUT"

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
    "zig", "wasip3-bindgen", "wasm-opt", "wizer", "wabt", "wasm-tools",
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
