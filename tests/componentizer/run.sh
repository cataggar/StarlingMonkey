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
SOURCE_RACER_PID=""
SOURCE_COMPONENTIZER_PID=""
SNAPSHOT_TEST_PID=""
terminate_and_reap() {
  local pid="${1:-}"
  if [ -z "$pid" ]; then
    return
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}
pid_is_live() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  case "$state" in
    Z*) return 1 ;;
    *) return 0 ;;
  esac
}
wait_for_marker() {
  local marker="$1" pid="$2" label="$3"
  local deadline=$((SECONDS + 30))
  while [ ! -e "$marker" ]; do
    if ! pid_is_live "$pid"; then
      echo "FAIL: $label exited before creating $marker" >&2
      return 1
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "FAIL: timed out waiting for $label marker $marker" >&2
      return 1
    fi
    sleep 0.001
  done
}
cleanup_scratch() {
  terminate_and_reap "$SOURCE_RACER_PID"
  terminate_and_reap "$SOURCE_COMPONENTIZER_PID"
  terminate_and_reap "$SNAPSHOT_TEST_PID"
  SOURCE_RACER_PID=""
  SOURCE_COMPONENTIZER_PID=""
  SNAPSHOT_TEST_PID=""
  if [ -e "$SCRATCH" ]; then
    chmod -R u+w "$SCRATCH" 2>/dev/null || true
    rm -rf "$SCRATCH"
  fi
}
remove_tree() {
  local path
  for path in "$@"; do
    if [ -e "$path" ]; then
      chmod -R u+w "$path" 2>/dev/null || true
    fi
  done
  command rm -rf -- "$@"
}
cleanup_scratch
mkdir -p "$TOOLS" "$WORK/wit package"
trap cleanup_scratch EXIT

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
for fd in /proc/self/fd/*; do
  case "$(readlink "$fd" 2>/dev/null || true)" in
    *".starling-componentize-lock-"*|*/locks/*.lock)
      echo "lock descriptor leaked into Wizer" >&2
      exit 26
      ;;
  esac
done
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
printf '%s\n' "$@" > "$FAKE_WIZER_ARGS_LOG"
if [ -n "${FAKE_ASSERT_SNAPSHOT_NAMES:-}" ]; then
  snapshot=""
  for arg in "$@"; do
    case "$arg" in
      *::*)
        snapshot="${arg%%::*}"
        break
        ;;
    esac
  done
  test -f "$snapshot/.looks.starling-componentize-file.js"
  test -f \
    "$snapshot/.looks.starling-componentize-directory/nested-module.js"
fi
if [ -n "${FAKE_ASSERT_CACHE_SNAPSHOT:-}" ]; then
  snapshot=""
  for arg in "$@"; do
    case "$arg" in
      *::*)
        snapshot="${arg%%::*}"
        break
        ;;
    esac
  done
  test ! -e "$snapshot/$FAKE_EXCLUDED_CACHE_RELATIVE"
  test -f "$snapshot/$FAKE_CACHE_LOOKALIKE_RELATIVE"
fi
if [ -n "${FAKE_ASSERT_GENERATED_SIBLINGS:-}" ]; then
  snapshot=""
  for arg in "$@"; do
    case "$arg" in
      *::*)
        snapshot="${arg%%::*}"
        break
        ;;
    esac
  done
  test -f "$snapshot/dist/helper.js"
  test -f "$snapshot/dist/app.debug/debug-helper.js"
  test -f "$snapshot/dist/app.wasm.lookalike.js"
  test -f "$snapshot/dist/app.json.lookalike.js"
  test -f "$snapshot/dist/app.debug-lookalike/module.js"
  test -f "$snapshot/dist/.starling-componentize-lock-user.js"
  test ! -e "$snapshot/dist/app.wasm"
  test ! -e "$snapshot/dist/app.json"
  test ! -e "$snapshot/dist/app.debug/commands.txt"
fi
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
  if [ "${FAKE_LARGE_OUTPUT:-}" = "1" ]; then
    python3 - <<'PY'
import os
for index in range(256):
    os.write(1, (f"stdout-{index:04d}-" + "o" * 4096 + "\n").encode())
    os.write(2, (f"stderr-{index:04d}-" + "e" * 4096 + "\n").encode())
PY
  elif [ "${FAKE_INVALID_STDERR:-}" = "1" ]; then
    python3 - <<'PY' >&2
import sys
sys.stderr.buffer.write(b"\xff" + b"x" * 128 + b"\xe2\x82")
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
transaction_storage() {
  local fd target
  for fd in /proc/self/fd/*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    case "$target" in
      *".starling-componentize-"*/data/component.wasm)
        dirname "$target"
        return
        ;;
    esac
  done
  return 1
}
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
if [ "$1" = "validate" ] && [ -n "${FAKE_REPLACED_TRANSACTION:-}" ]; then
  storage="$(transaction_storage)"
  transaction="$(dirname "$storage")"
  mv "$transaction" "$FAKE_REPLACED_TRANSACTION"
  mkdir "$transaction"
  printf 'preserve-replacement\n' > "$transaction/sentinel"
fi
if [ "$1" = "validate" ] && [ -n "${FAKE_ADD_TRANSACTION_ENTRY:-}" ]; then
  storage="$(transaction_storage)"
  mkdir "$storage/inputs/late-unowned-tree"
  printf 'preserve-unowned\n' > \
    "$storage/inputs/late-unowned-tree/sentinel"
fi
if [ "$1" = "validate" ] && \
   [ -n "${FAKE_REPLACE_TRANSACTION_INPUTS:-}" ]; then
  storage="$(transaction_storage)"
  mv "$storage/inputs" "$FAKE_REPLACE_TRANSACTION_INPUTS"
  mkdir "$storage/inputs"
  printf 'preserve-owned-replacement\n' > "$storage/inputs/sentinel"
fi
if [ "$1" = "validate" ] && [ -n "${FAKE_RETARGET_PARENT_LINK:-}" ]; then
  rm "$FAKE_RETARGET_PARENT_LINK"
  ln -s "$FAKE_RETARGET_PARENT_TARGET" "$FAKE_RETARGET_PARENT_LINK"
fi
if [ "$1" = "validate" ] && \
   [ -n "${FAKE_REPLACE_COMPONENT_BACKUP:-}" ]; then
  storage="$(transaction_storage)"
  (
    while [ ! -e "$storage/previous-component" ]; do
      sleep 0.001
    done
    mv "$storage/previous-component" "$FAKE_REPLACED_COMPONENT_BACKUP"
    printf 'preserve-backup-replacement\n' > "$storage/previous-component"
  ) </dev/null >/dev/null 2>&1 &
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
for fd in /proc/self/fd/*; do
  case "$(readlink "$fd" 2>/dev/null || true)" in
    *".starling-componentize-lock-"*|*/locks/*.lock)
      echo "lock descriptor leaked into Zig" >&2
      exit 26
      ;;
  esac
done
if [ "${1:-}" = "env" ]; then
  test -d "$FAKE_ZIG_LIB_DIR"
  printf '.{\n    .lib_dir = "%s",\n}\n' "$FAKE_ZIG_LIB_DIR"
  exit 0
fi
prefix=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--prefix" ]; then
    j=$((i + 1))
    prefix="${!j}"
  fi
done
if [ "${FAKE_FAIL_STAGE:-}" = "zig build" ]; then
  if [ -n "${FAKE_ECHO_RUNTIME_PATHS:-}" ]; then
    printf 'runtime stdout executable=%s argv=%s\n' "$0" "$*"
    printf 'runtime stderr executable=%s argv=%s\n' "$0" "$*" >&2
  fi
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
if [ -n "${FAKE_MUTATE_ZIG_LIB_DIR:-}" ]; then
  printf 'mutated-original\n' > "$FAKE_MUTATE_ZIG_LIB_DIR/marker"
fi
test "$(cat "$ZIG_LIB_DIR/marker")" = "immutable-zig-lib"
if [ -n "${FAKE_ZIG_BARRIER:-}" ]; then
  printf 'ready\n' > "$FAKE_ZIG_BARRIER.ready"
  while [ ! -e "$FAKE_ZIG_BARRIER.release" ]; do
    sleep 0.001
  done
fi
prefix_real="$(realpath "$prefix")"
local_cache_real="$(realpath "$ZIG_LOCAL_CACHE_DIR")"
global_cache_real="$(realpath "$ZIG_GLOBAL_CACHE_DIR")"
zig_lib_real="$(realpath "$ZIG_LIB_DIR")"
printf '%s\n' "$prefix_real" >> "$FAKE_ZIG_PREFIX_LOG"
printf '%s|%s|%s\n' "$local_cache_real" \
  "$global_cache_real" "$zig_lib_real" \
  >> "$FAKE_ZIG_ENV_LOG"
printf 'local-cache-write\n' > "$ZIG_LOCAL_CACHE_DIR/fake-zig-local"
printf 'global-cache-write\n' > "$ZIG_GLOBAL_CACHE_DIR/fake-zig-global"
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
export FAKE_WIZER_ARGS_LOG="$SCRATCH/wizer args.log"
export FAKE_ENGINE="$ENGINE"
export FAKE_ADAPTER="$ADAPTER"
export FAKE_ZIG_PREFIX_LOG="$SCRATCH/zig prefixes.log"
export FAKE_ZIG_ENV_LOG="$SCRATCH/zig env.log"
export FAKE_BINDINGS="$SCRATCH/component-bindings.zig"
export FAKE_WASIP3_BINDGEN="$TOOLS/fake wasip3-bindgen"
export FAKE_WASM_OPT="$TOOLS/fake wasm-opt"
export FAKE_ZIG_LIB_DIR="$SCRATCH/fake zig direct/lib"
export STARLINGMONKEY_CONFIG="--ambient-config-must-not-reach-wizer"
mkdir -p "$FAKE_ZIG_LIB_DIR"
printf 'immutable-zig-lib\n' > "$FAKE_ZIG_LIB_DIR/marker"

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
if grep -Fq -- '.starling-componentize-' "$FAKE_RUNTIME_ARGS_LOG"; then
  echo "FAIL: Wizer consumed randomized runtime arguments" >&2
  exit 1
fi
grep -Fq -- "::$WORK" "$FAKE_WIZER_ARGS_LOG"
test -f "$DEBUG_DIR/initialized.wasm"
test -f "$DEBUG_DIR/embedded.wasm"
test -f "$DEBUG_DIR/component.wasm"
test -f "$DEBUG_DIR/commands.txt"
test -f "$DEBUG_DIR/imports.json"
test -f "$DEBUG_DIR/metadata.json"
python3 - "$DEBUG_DIR/imports.json" "$DEBUG_DIR/metadata.json" \
  "$DEBUG_DIR/runtime-args.txt" <<'PY'
import hashlib, json, sys
imports = json.load(open(sys.argv[1], encoding="utf-8"))
metadata = json.load(open(sys.argv[2], encoding="utf-8"))
assert imports["complete"] is False
assert imports["imports"] == []
assert metadata["provenance"]["features"] is None
assert metadata["provenance"]["features_sha256"] is None
runtime_args = open(sys.argv[3], "rb").read()
assert metadata["provenance"]["inputs"]["runtime_arguments_sha256"] == \
    hashlib.sha256(runtime_args).hexdigest()
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
grep -Fq -- "\"$SOURCE_ALIAS_DIR/source.js\"" "$FAKE_RUNTIME_ARGS_LOG"
cmp "$ENGINE" "$SOURCE_ALIAS_OUTPUT"
rm "$SOURCE_ALIAS"

SYMLINK_OUTPUT="$WORK/symlinked inputs.wasm"
SYMLINK_INPUT_DIR="$SCRATCH/symlinked tool inputs"
mkdir "$SYMLINK_INPUT_DIR"
ln -s "$ENGINE" "$SYMLINK_INPUT_DIR/engine link.wasm"
ln -s "$ADAPTER" "$SYMLINK_INPUT_DIR/adapter link.wasm"
ln -s "$TOOLS/fake wizer" "$SYMLINK_INPUT_DIR/wizer link"
ln -s "$TOOLS/fake wabt" "$SYMLINK_INPUT_DIR/wabt link"
ln -s "$TOOLS/fake wasm-tools" "$SYMLINK_INPUT_DIR/wasm-tools link"
"$COMPONENTIZER" \
  --engine "$SYMLINK_INPUT_DIR/engine link.wasm" \
  --preview2-adapter "$SYMLINK_INPUT_DIR/adapter link.wasm" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$SYMLINK_INPUT_DIR/wizer link" \
  --wabt-bin "$SYMLINK_INPUT_DIR/wabt link" \
  --wasm-tools-bin "$SYMLINK_INPUT_DIR/wasm-tools link" \
  --out "$SYMLINK_OUTPUT" \
  "$SOURCE"
cmp "$ENGINE" "$SYMLINK_OUTPUT"

PROVENANCE_ROOT="$SCRATCH/provenance roots"
PROVENANCE_A="$PROVENANCE_ROOT/clean root a"
PROVENANCE_B="$PROVENANCE_ROOT/clean root b"
mkdir -p "$PROVENANCE_A/nested" "$PROVENANCE_B/nested"
mkdir -p "$PROVENANCE_A/.looks.starling-componentize-directory" \
  "$PROVENANCE_B/.looks.starling-componentize-directory"
cat > "$PROVENANCE_A/main.js" <<'EOF'
import { value } from "./alias.js";
export const result = value;
EOF
printf 'export const value = 1;\n' > "$PROVENANCE_A/nested/module.js"
printf 'export const value = 1;\n' > "$PROVENANCE_A/nested/other.js"
printf 'export const hiddenFile = 1;\n' > \
  "$PROVENANCE_A/.looks.starling-componentize-file.js"
printf 'export const hiddenDirectory = 1;\n' > \
  "$PROVENANCE_A/.looks.starling-componentize-directory/nested-module.js"
ln -s nested/module.js "$PROVENANCE_A/alias.js"
ln -s nested/module.js "$PROVENANCE_B/alias.js"
printf 'export const value = 1;\n' > "$PROVENANCE_B/nested/other.js"
printf 'export const value = 1;\n' > "$PROVENANCE_B/nested/module.js"
cp "$PROVENANCE_A/main.js" "$PROVENANCE_B/main.js"
cp "$PROVENANCE_A/.looks.starling-componentize-file.js" \
  "$PROVENANCE_B/.looks.starling-componentize-file.js"
cp "$PROVENANCE_A/.looks.starling-componentize-directory/nested-module.js" \
  "$PROVENANCE_B/.looks.starling-componentize-directory/nested-module.js"
chmod 600 "$PROVENANCE_B/main.js"
touch -t 202001020304 "$PROVENANCE_B/main.js" \
  "$PROVENANCE_B/nested/module.js"

source_provenance() {
  local source="$1" output="$2" metadata="$3"
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$metadata" \
    --out "$output" \
    "$source"
}

GENERATED_SIBLING_ROOT="$SCRATCH/generated destination siblings"
GENERATED_SIBLING_SOURCE="$GENERATED_SIBLING_ROOT/main.js"
GENERATED_SIBLING_DIST="$GENERATED_SIBLING_ROOT/dist"
GENERATED_SIBLING_OUTPUT="$GENERATED_SIBLING_DIST/app.wasm"
GENERATED_SIBLING_METADATA="$GENERATED_SIBLING_DIST/app.json"
GENERATED_SIBLING_DEBUG="$GENERATED_SIBLING_DIST/app.debug"
mkdir -p "$GENERATED_SIBLING_DEBUG" \
  "$GENERATED_SIBLING_DIST/app.debug-lookalike"
cat > "$GENERATED_SIBLING_SOURCE" <<'EOF'
import { helper } from "./dist/helper.js";
import { debugHelper } from "./dist/app.debug/debug-helper.js";
import { wasmLookalike } from "./dist/app.wasm.lookalike.js";
import { metadataLookalike } from "./dist/app.json.lookalike.js";
import { debugLookalike } from "./dist/app.debug-lookalike/module.js";
import { lockLookalike } from "./dist/.starling-componentize-lock-user.js";
export const generatedSiblingTotal =
  helper + debugHelper + wasmLookalike + metadataLookalike + debugLookalike +
  lockLookalike;
EOF
printf 'export const helper = 1;\n' > "$GENERATED_SIBLING_DIST/helper.js"
printf 'export const debugHelper = 2;\n' > \
  "$GENERATED_SIBLING_DEBUG/debug-helper.js"
printf 'export const wasmLookalike = 3;\n' > \
  "$GENERATED_SIBLING_DIST/app.wasm.lookalike.js"
printf 'export const metadataLookalike = 4;\n' > \
  "$GENERATED_SIBLING_DIST/app.json.lookalike.js"
printf 'export const debugLookalike = 5;\n' > \
  "$GENERATED_SIBLING_DIST/app.debug-lookalike/module.js"
printf 'export const lockLookalike = 6;\n' > \
  "$GENERATED_SIBLING_DIST/.starling-componentize-lock-user.js"
printf 'old-component\n' > "$GENERATED_SIBLING_OUTPUT"
printf 'old-metadata\n' > "$GENERATED_SIBLING_METADATA"
printf 'old-generated-command\n' > "$GENERATED_SIBLING_DEBUG/commands.txt"

generated_sibling_run() {
  local suffix="$1"
  FAKE_ASSERT_GENERATED_SIBLINGS=1 "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$GENERATED_SIBLING_METADATA" \
    --debug-dir "$GENERATED_SIBLING_DEBUG" \
    --out "$GENERATED_SIBLING_OUTPUT" \
    "$GENERATED_SIBLING_SOURCE"
  cp "$GENERATED_SIBLING_METADATA" \
    "$SCRATCH/generated-sibling-$suffix.json"
}

generated_sibling_run first
generated_sibling_run second
printf 'export const helper = 11;\n' > "$GENERATED_SIBLING_DIST/helper.js"
generated_sibling_run changed
test -f "$GENERATED_SIBLING_DEBUG/debug-helper.js"
test -f "$GENERATED_SIBLING_DIST/app.debug-lookalike/module.js"
python3 - "$SCRATCH/generated-sibling-first.json" \
  "$SCRATCH/generated-sibling-second.json" \
  "$SCRATCH/generated-sibling-changed.json" <<'PY'
import json, sys
digests = [
    json.load(open(path, encoding="utf-8"))["provenance"]["inputs"]
    ["source_tree"]["sha256"]
    for path in sys.argv[1:]
]
assert digests[0] == digests[1], digests
assert digests[1] != digests[2], digests
PY

FAKE_ASSERT_SNAPSHOT_NAMES=1 source_provenance "$PROVENANCE_A/main.js" \
  "$WORK/provenance clean a.wasm" "$WORK/provenance clean a.json"
source_provenance "$PROVENANCE_B/main.js" \
  "$WORK/provenance clean b.wasm" "$WORK/provenance clean b.json"
printf 'export const hiddenFile = 2;\n' > \
  "$PROVENANCE_B/.looks.starling-componentize-file.js"
source_provenance "$PROVENANCE_B/main.js" \
  "$WORK/provenance hidden file changed.wasm" \
  "$WORK/provenance hidden file changed.json"
cp "$PROVENANCE_A/.looks.starling-componentize-file.js" \
  "$PROVENANCE_B/.looks.starling-componentize-file.js"
printf 'export const hiddenDirectory = 2;\n' > \
  "$PROVENANCE_B/.looks.starling-componentize-directory/nested-module.js"
source_provenance "$PROVENANCE_B/main.js" \
  "$WORK/provenance hidden directory changed.wasm" \
  "$WORK/provenance hidden directory changed.json"
cp "$PROVENANCE_A/.looks.starling-componentize-directory/nested-module.js" \
  "$PROVENANCE_B/.looks.starling-componentize-directory/nested-module.js"
printf 'export const value = 2;\n' > "$PROVENANCE_B/nested/module.js"
source_provenance "$PROVENANCE_B/main.js" \
  "$WORK/provenance nested changed.wasm" \
  "$WORK/provenance nested changed.json"
printf 'export const value = 1;\n' > "$PROVENANCE_B/nested/module.js"
rm "$PROVENANCE_B/alias.js"
ln -s nested/other.js "$PROVENANCE_B/alias.js"
source_provenance "$PROVENANCE_B/main.js" \
  "$WORK/provenance link changed.wasm" \
  "$WORK/provenance link changed.json"
python3 - "$WORK/provenance clean a.json" \
  "$WORK/provenance clean b.json" \
  "$WORK/provenance hidden file changed.json" \
  "$WORK/provenance hidden directory changed.json" \
  "$WORK/provenance nested changed.json" \
  "$WORK/provenance link changed.json" <<'PY'
import json, sys
clean_a, clean_b, hidden_file, hidden_directory, nested, link = [
    json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]
]
inputs = [doc["provenance"]["inputs"] for doc in (
    clean_a, clean_b, hidden_file, hidden_directory, nested, link
)]
assert all(value["source_tree"]["entry"] == "main.js" for value in inputs)
assert inputs[0]["source_tree"]["sha256"] == \
    inputs[1]["source_tree"]["sha256"]
assert all(inputs[1]["source_tree"]["sha256"] != value["source_tree"]["sha256"]
           for value in inputs[2:])
assert len({value["source_sha256"] for value in inputs}) == 1
assert all(value["initializer_tree"] is None for value in inputs)
assert clean_b["provenance"] != hidden_file["provenance"]
assert clean_b["provenance"] != hidden_directory["provenance"]
assert clean_b["provenance"] != nested["provenance"]
assert clean_b["provenance"] != link["provenance"]
PY

READ_ONLY_DIR="$WORK/read only source"
READ_ONLY_SOURCE="$READ_ONLY_DIR/read only.js"
READ_ONLY_INITIALIZER="$READ_ONLY_DIR/initializer.js"
READ_ONLY_OUTPUT="$WORK/read only output.wasm"
READ_ONLY_METADATA="$WORK/read only metadata.json"
mkdir "$READ_ONLY_DIR"
printf 'export const readOnly = true;\n' > "$READ_ONLY_SOURCE"
printf 'globalThis.initialized = true;\n' > "$READ_ONLY_INITIALIZER"
chmod 444 "$READ_ONLY_SOURCE" "$READ_ONLY_INITIALIZER"
chmod 555 "$READ_ONLY_DIR"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --initializer-script-path "$READ_ONLY_INITIALIZER" \
  --metadata-out "$READ_ONLY_METADATA" \
  --out "$READ_ONLY_OUTPUT" \
  "$READ_ONLY_SOURCE"
chmod 755 "$READ_ONLY_DIR"
grep -Fq -- "\"$READ_ONLY_SOURCE\"" "$FAKE_RUNTIME_ARGS_LOG"
grep -Fq -- "\"$READ_ONLY_INITIALIZER\"" "$FAKE_RUNTIME_ARGS_LOG"
cmp "$ENGINE" "$READ_ONLY_OUTPUT"
python3 - "$READ_ONLY_METADATA" <<'PY'
import json, sys
inputs = json.load(open(sys.argv[1], encoding="utf-8"))["provenance"]["inputs"]
assert inputs["source_tree"]["entry"] == "read only.js"
assert inputs["initializer_tree"]["entry"] == "initializer.js"
assert inputs["initializer_tree"]["shares_source_tree"] is True
assert inputs["initializer_tree"]["sha256"] == inputs["source_tree"]["sha256"]
PY

SHARED_FILE_DIR="$SCRATCH/shared source tree"
SHARED_FILE_SOURCE="$SHARED_FILE_DIR/shared.js"
SHARED_FILE_ALIAS_DIR="$SCRATCH/shared source aliases"
SHARED_FILE_ALIAS="$SHARED_FILE_ALIAS_DIR/shared alias.js"
SHARED_FILE_EXACT_METADATA="$WORK/shared exact metadata.json"
SHARED_FILE_ALIAS_METADATA="$WORK/shared alias metadata.json"
mkdir -p "$SHARED_FILE_DIR" "$SHARED_FILE_ALIAS_DIR"
printf 'export const shared = true;\n' > "$SHARED_FILE_SOURCE"
ln -s "$SHARED_FILE_SOURCE" "$SHARED_FILE_ALIAS"
for initializer_case in exact alias; do
  initializer="$SHARED_FILE_SOURCE"
  metadata_path="$SHARED_FILE_EXACT_METADATA"
  if [ "$initializer_case" = alias ]; then
    initializer="$SHARED_FILE_ALIAS"
    metadata_path="$SHARED_FILE_ALIAS_METADATA"
  fi
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --initializer-script-path "$initializer" \
    --metadata-out "$metadata_path" \
    --out "$WORK/shared $initializer_case.wasm" \
    "$SHARED_FILE_SOURCE"
done
python3 - "$SHARED_FILE_EXACT_METADATA" "$SHARED_FILE_ALIAS_METADATA" <<'PY'
import json, sys
exact, alias = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
for document in (exact, alias):
    inputs = document["provenance"]["inputs"]
    assert inputs["initializer_sha256"] == inputs["source_sha256"]
    assert inputs["initializer_tree"]["shares_source_tree"] is True
    assert inputs["initializer_tree"]["entry"] == \
        inputs["source_tree"]["entry"] == "shared.js"
    assert inputs["initializer_tree"]["sha256"] == \
        inputs["source_tree"]["sha256"]
assert exact == alias
PY

NESTED_SHARED_ROOT="$SCRATCH/nested shared root"
NESTED_SHARED_SOURCE="$NESTED_SHARED_ROOT/deep/branch/main.js"
NESTED_SHARED_INITIALIZER="$NESTED_SHARED_ROOT/initializer.js"
NESTED_SHARED_ALIASES="$SCRATCH/nested shared aliases"
mkdir -p "$(dirname "$NESTED_SHARED_SOURCE")" "$NESTED_SHARED_ALIASES"
printf 'export const nestedShared = true;\n' > "$NESTED_SHARED_SOURCE"
printf 'globalThis.nestedInitialized = true;\n' > \
  "$NESTED_SHARED_INITIALIZER"
printf 'export const sibling = true;\n' > \
  "$NESTED_SHARED_ROOT/deep/sibling.js"
ln -s "$NESTED_SHARED_SOURCE" "$NESTED_SHARED_ALIASES/source.js"
ln -s "$NESTED_SHARED_INITIALIZER" \
  "$NESTED_SHARED_ALIASES/initializer.js"
for nested_case in exact repeat aliases; do
  nested_source="$NESTED_SHARED_SOURCE"
  nested_initializer="$NESTED_SHARED_INITIALIZER"
  if [ "$nested_case" = aliases ]; then
    nested_source="$NESTED_SHARED_ALIASES/source.js"
    nested_initializer="$NESTED_SHARED_ALIASES/initializer.js"
  fi
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --initializer-script-path "$nested_initializer" \
    --metadata-out "$WORK/nested shared $nested_case.json" \
    --out "$WORK/nested shared $nested_case.wasm" \
    "$nested_source"
done
python3 - "$NESTED_SHARED_SOURCE" \
  "$WORK/nested shared exact.json" \
  "$WORK/nested shared repeat.json" \
  "$WORK/nested shared aliases.json" <<'PY'
import hashlib, json, sys
source = open(sys.argv[1], "rb").read()
documents = [json.load(open(path, encoding="utf-8")) for path in sys.argv[2:]]
inputs = [document["provenance"]["inputs"] for document in documents]
assert all(value["source_tree"]["entry"] == "deep/branch/main.js"
           for value in inputs), inputs
assert all(value["initializer_tree"]["entry"] == "initializer.js"
           for value in inputs), inputs
assert all(value["initializer_tree"]["shares_source_tree"] is True
           for value in inputs), inputs
assert all(value["source_sha256"] == hashlib.sha256(source).hexdigest()
           for value in inputs), inputs
assert len({value["source_tree"]["sha256"] for value in inputs}) == 1, inputs
assert all(value["initializer_tree"]["sha256"] ==
           value["source_tree"]["sha256"] for value in inputs), inputs
assert documents[0] == documents[1] == documents[2]
PY

UNREADABLE_SOURCE="$WORK/unreadable source.js"
UNREADABLE_ERROR="$SCRATCH/unreadable-source.jsonl"
printf 'export const unreadable = true;\n' > "$UNREADABLE_SOURCE"
chmod 000 "$UNREADABLE_SOURCE"
if "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/unreadable source.wasm" \
  "$UNREADABLE_SOURCE" >/dev/null 2> "$UNREADABLE_ERROR"
then
  echo "FAIL: unreadable source unexpectedly componentized" >&2
  exit 1
fi
chmod 644 "$UNREADABLE_SOURCE"
python3 - "$UNREADABLE_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
PY
test ! -e "$WORK/unreadable source.wasm"

RACED_SOURCE="$WORK/raced source.js"
RACED_ORIGINAL="$SCRATCH/raced source original.js"
RACED_ERROR="$SCRATCH/raced-source.jsonl"
python3 - "$RACED_SOURCE" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as source:
    source.write("// immutable input race padding\n" * 500000)
    source.write("export const raced = true;\n")
PY
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/raced source.wasm" \
  "$RACED_SOURCE" >/dev/null 2> "$RACED_ERROR" &
SOURCE_COMPONENTIZER_PID=$!
python3 - "$WORK" "$RACED_SOURCE" "$RACED_ORIGINAL" \
  "$SOURCE_COMPONENTIZER_PID" <<'PY' &
import os, sys, time
work, source, original, componentizer = sys.argv[1:]
componentizer = int(componentizer)
prefix = ".raced source.wasm.starling-componentize-"
deadline = time.monotonic() + 30
while not any(name.startswith(prefix) for name in os.listdir(work)):
    if time.monotonic() >= deadline:
        raise SystemExit("timed out waiting for raced-source transaction")
    try:
        os.kill(componentizer, 0)
    except ProcessLookupError:
        raise SystemExit("componentizer exited before raced-source transaction")
    time.sleep(0.0001)
os.rename(source, original)
with open(source, "w", encoding="utf-8") as replacement:
    replacement.write("export const replacement = true;\n")
PY
SOURCE_RACER_PID=$!
source_race_deadline=$((SECONDS + 35))
while pid_is_live "$SOURCE_COMPONENTIZER_PID"; do
  if [ -n "$SOURCE_RACER_PID" ] && ! pid_is_live "$SOURCE_RACER_PID"; then
    if ! wait "$SOURCE_RACER_PID"; then
      SOURCE_RACER_PID=""
      terminate_and_reap "$SOURCE_COMPONENTIZER_PID"
      SOURCE_COMPONENTIZER_PID=""
      echo "FAIL: raced-source synchronizer exited early" >&2
      exit 1
    fi
    SOURCE_RACER_PID=""
  fi
  if [ "$SECONDS" -ge "$source_race_deadline" ]; then
    terminate_and_reap "$SOURCE_COMPONENTIZER_PID"
    SOURCE_COMPONENTIZER_PID=""
    terminate_and_reap "$SOURCE_RACER_PID"
    SOURCE_RACER_PID=""
    echo "FAIL: raced-source regression exceeded its deadline" >&2
    exit 1
  fi
  sleep 0.01
done
if wait "$SOURCE_COMPONENTIZER_PID"; then
  SOURCE_COMPONENTIZER_PID=""
  echo "FAIL: raced source unexpectedly componentized" >&2
  exit 1
fi
SOURCE_COMPONENTIZER_PID=""
if [ -n "$SOURCE_RACER_PID" ]; then
  wait "$SOURCE_RACER_PID"
  SOURCE_RACER_PID=""
fi
python3 - "$RACED_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
PY
test "$(cat "$RACED_SOURCE")" = "export const replacement = true;"
test ! -e "$WORK/raced source.wasm"

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

for invalid_destination in metadata debug; do
  invalid_output="$WORK/invalid-$invalid_destination-destination.wasm"
  invalid_log="$SCRATCH/invalid-$invalid_destination-destination.jsonl"
  destination_args=(--metadata-out "$invalid_output")
  expected_cause=InvalidMetadataDestination
  if [ "$invalid_destination" = debug ]; then
    destination_args=(--debug-dir "$invalid_output")
    expected_cause=DebugOutputCollision
  fi
  if "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    "${destination_args[@]}" \
    --out "$invalid_output" \
    "$SOURCE" >/dev/null 2> "$invalid_log"
  then
    echo "FAIL: invalid $invalid_destination destination succeeded" >&2
    exit 1
  fi
  python3 - "$invalid_log" "$expected_cause" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["schema"] == "starling-componentize-diagnostic/v1"
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == sys.argv[2], diagnostic
PY
  test ! -e "$invalid_output"
done

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

python3 - "$COMPONENTIZER" "$SCRATCH" "$SOURCE" "$ENGINE" "$ADAPTER" \
  "$TOOLS/fake wizer" "$TOOLS/fake wasm-tools" <<'PY'
import json, os, shutil, subprocess, sys

componentizer, scratch, source, engine, adapter, wizer, wasm_tools = [
    os.fsencode(value) for value in sys.argv[1:]
]
invalid_root = os.path.join(scratch, b"invalid-\xff-paths")
os.mkdir(invalid_root)
invalid_source = os.path.join(invalid_root, b"source-\xff.js")
invalid_initializer = os.path.join(invalid_root, b"initializer-\xff.js")
invalid_output = os.path.join(invalid_root, b"output-\xff.wasm")
invalid_wit = os.path.join(invalid_root, b"wit-\xff")
invalid_tool = os.path.join(invalid_root, b"tool-\xff")
tree_root = os.path.join(invalid_root, b"tree")
os.mkdir(invalid_wit)
os.mkdir(tree_root)
for path, data in (
    (invalid_source, b"export const invalidSource = true;\n"),
    (invalid_initializer, b"globalThis.invalidInitializer = true;\n"),
    (os.path.join(invalid_wit, b"world.wit"),
     b"package test:invalid; world exports {}\n"),
    (os.path.join(tree_root, b"main.js"),
     b"export const invalidTree = true;\n"),
    (os.path.join(tree_root, b"nested-\xff.js"),
     b"export const invalidEntry = true;\n"),
):
    with open(path, "wb") as output:
        output.write(data)
shutil.copyfile(wasm_tools, invalid_tool)
os.chmod(invalid_tool, 0o755)

common = [
    b"--engine", engine,
    b"--preview2-adapter", adapter,
    b"--wizer-bin", wizer,
    b"--wasm-tools-bin", wasm_tools,
]
cases = {
    "source": [b"--out", os.path.join(invalid_root, b"source-result.wasm"),
               invalid_source],
    "initializer": [
        b"--initializer-script-path", invalid_initializer,
        b"--out", os.path.join(invalid_root, b"initializer-result.wasm"),
        source,
    ],
    "output": [b"--out", invalid_output, source],
    "wit": [
        b"--wit", invalid_wit, b"--world-name", b"exports",
        b"--out", os.path.join(invalid_root, b"wit-result.wasm"),
        source,
    ],
    "tool": [
        b"--wasm-tools-bin", invalid_tool,
        b"--out", os.path.join(invalid_root, b"tool-result.wasm"),
        source,
    ],
    "tree-entry": [
        b"--out", os.path.join(invalid_root, b"tree-result.wasm"),
        os.path.join(tree_root, b"main.js"),
    ],
}
for name, case_args in cases.items():
    for mode in ("human", "json"):
        mode_args = [b"--json-diagnostics"] if mode == "json" else []
        result = subprocess.run(
            [componentizer, *mode_args, *common, *case_args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert result.returncode != 0, (name, mode)
        result.stderr.decode("utf-8")
        if mode == "json":
            diagnostic = json.loads(result.stderr)
            assert diagnostic["code"] == "SMC1001", (name, diagnostic)
            assert diagnostic["phase"] == "inputs", (name, diagnostic)
            assert diagnostic["cause"] == "InvalidUtf8Path", (name, diagnostic)
            assert isinstance(diagnostic["message"], str)
        else:
            assert b"error[SMC1001] inputs:" in result.stderr, (name, result.stderr)
            assert b"InvalidUtf8Path" in result.stderr, (name, result.stderr)
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

LARGE_CHILD_ERROR="$SCRATCH/large-child-error.jsonl"
if FAKE_FAIL_STAGE="component embed" FAKE_LARGE_OUTPUT=1 "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/large-child-output.wasm" \
  "$SOURCE" >/dev/null 2> "$LARGE_CHILD_ERROR"
then
  echo "FAIL: large child-output injection unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$LARGE_CHILD_ERROR" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
assert len(raw) < 17 * 1024
diagnostic = json.loads(raw)
assert diagnostic["phase"] == "embed"
assert "[child stderr truncated; showing final output]" in diagnostic["detail"]
assert "stderr-0255-" in diagnostic["detail"]
PY
test ! -e "$WORK/large-child-output.wasm"

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

RUNTIME_FAILURE_ROOT_A="$SCRATCH/runtime failure root a"
RUNTIME_FAILURE_ROOT_B="$SCRATCH/runtime failure root b"
RUNTIME_CACHE="$WORK/failing runtime cache"
RUNTIME_ERROR_A="$SCRATCH/runtime-build-error-a.jsonl"
RUNTIME_ERROR_B="$SCRATCH/runtime-build-error-b.jsonl"
mkdir "$RUNTIME_FAILURE_ROOT_A" "$RUNTIME_FAILURE_ROOT_B"
for runtime_root in "$RUNTIME_FAILURE_ROOT_A" "$RUNTIME_FAILURE_ROOT_B"; do
  runtime_error="$RUNTIME_ERROR_A"
  if [ "$runtime_root" = "$RUNTIME_FAILURE_ROOT_B" ]; then
    runtime_error="$RUNTIME_ERROR_B"
  fi
  if FAKE_FAIL_STAGE="zig build" FAKE_ECHO_RUNTIME_PATHS=1 "$COMPONENTIZER" \
    --json-diagnostics \
    --build-root "$ROOT" \
    --cache-dir "$RUNTIME_CACHE" \
    --zig-bin "$TOOLS/fake zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$runtime_root/runtime-build-failure.wasm" \
    "$SOURCE" > "$runtime_root/stdout" 2> "$runtime_error"
  then
    echo "FAIL: injected runtime build failure unexpectedly succeeded" >&2
    exit 1
  fi
  test ! -s "$runtime_root/stdout"
  test ! -e "$runtime_root/runtime-build-failure.wasm"
done
cmp "$RUNTIME_ERROR_A" "$RUNTIME_ERROR_B"
python3 - "$RUNTIME_ERROR_A" "$RUNTIME_CACHE" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC2001"
assert diagnostic["phase"] == "runtime_build"
assert diagnostic["command"] == "zig build runtime"
assert diagnostic["exit_code"] == 23
assert "<transaction>" in diagnostic["detail"], diagnostic
assert ".starling-componentize-" not in diagnostic["detail"], diagnostic
assert sys.argv[2] in diagnostic["detail"], diagnostic
PY

RUNTIME_HUMAN_ROOT="$SCRATCH/runtime human root"
RUNTIME_HUMAN_STDOUT="$SCRATCH/runtime-human.stdout"
RUNTIME_HUMAN_STDERR="$SCRATCH/runtime-human.stderr"
mkdir "$RUNTIME_HUMAN_ROOT"
if FAKE_FAIL_STAGE="zig build" FAKE_ECHO_RUNTIME_PATHS=1 "$COMPONENTIZER" \
  --verbose \
  --build-root "$ROOT" \
  --cache-dir "$RUNTIME_CACHE" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$RUNTIME_HUMAN_ROOT/runtime-build-failure.wasm" \
  "$SOURCE" > "$RUNTIME_HUMAN_STDOUT" 2> "$RUNTIME_HUMAN_STDERR"
then
  echo "FAIL: human runtime build failure unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq '<transaction>' "$RUNTIME_HUMAN_STDOUT"
grep -Fq '<transaction>' "$RUNTIME_HUMAN_STDERR"
grep -Fq "$RUNTIME_CACHE" "$RUNTIME_HUMAN_STDERR"
if grep -Fq '.starling-componentize-' \
  "$RUNTIME_HUMAN_STDOUT" "$RUNTIME_HUMAN_STDERR"; then
  echo "FAIL: runtime build diagnostic leaked a transaction path" >&2
  exit 1
fi

if find "$WORK" -maxdepth 1 -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: a negative stage left transaction artifacts" >&2
  exit 1
fi

REPLACED_OUTPUT="$WORK/replaced transaction.wasm"
REPLACED_OWNED="$WORK/replaced transaction owned"
REPLACED_ERROR="$SCRATCH/replaced-transaction-error.log"
if FAKE_REPLACED_TRANSACTION="$REPLACED_OWNED" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$REPLACED_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$REPLACED_ERROR"
then
  echo "FAIL: replaced transaction unexpectedly published" >&2
  exit 1
fi
REPLACEMENT_ROOT="$(find "$WORK" -maxdepth 1 -type d \
  -name '.replaced transaction.wasm.starling-componentize-*' -print -quit)"
test -n "$REPLACEMENT_ROOT"
test "$(cat "$REPLACEMENT_ROOT/sentinel")" = "preserve-replacement"
test -f "$REPLACED_OWNED/data/component.wasm"
test ! -e "$REPLACED_OUTPUT"
remove_tree "$REPLACEMENT_ROOT" "$REPLACED_OWNED"

IDENTITY_OUTPUT="$WORK/identity cleanup.wasm"
FAKE_ADD_TRANSACTION_ENTRY=1 "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$IDENTITY_OUTPUT" \
  "$SOURCE"
IDENTITY_ROOT="$(find "$WORK" -maxdepth 1 -type d \
  -name '.identity cleanup.wasm.starling-componentize-*' -print -quit)"
test -n "$IDENTITY_ROOT"
test "$(cat "$IDENTITY_ROOT/data/inputs/late-unowned-tree/sentinel")" = \
  "preserve-unowned"
cmp "$ENGINE" "$IDENTITY_OUTPUT"
remove_tree "$IDENTITY_ROOT"

CHANGED_INPUT_OUTPUT="$WORK/changed owned input.wasm"
CHANGED_INPUT_SAVED="$SCRATCH/changed-owned-input-original"
CHANGED_INPUT_ERROR="$SCRATCH/changed-owned-input.jsonl"
if FAKE_REPLACE_TRANSACTION_INPUTS="$CHANGED_INPUT_SAVED" "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$CHANGED_INPUT_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$CHANGED_INPUT_ERROR"
then
  echo "FAIL: replaced immutable input snapshot reported success" >&2
  exit 1
fi
CHANGED_INPUT_ROOT="$(find "$WORK" -maxdepth 1 -type d \
  -name '.changed owned input.wasm.starling-componentize-*' -print -quit)"
test -n "$CHANGED_INPUT_ROOT"
test "$(cat "$CHANGED_INPUT_ROOT/data/inputs/sentinel")" = \
  "preserve-owned-replacement"
test -f "$CHANGED_INPUT_SAVED/source/source module.js"
test ! -e "$CHANGED_INPUT_OUTPUT"
python3 - "$CHANGED_INPUT_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC5001", diagnostic
assert diagnostic["phase"] == "validate", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
remove_tree "$CHANGED_INPUT_ROOT" "$CHANGED_INPUT_SAVED"

PUBLICATION_A="$SCRATCH/publication-a"
PUBLICATION_B="$SCRATCH/publication-b"
PUBLICATION_LINK="$SCRATCH/publication-link"
mkdir "$PUBLICATION_A" "$PUBLICATION_B"
ln -s "$PUBLICATION_A" "$PUBLICATION_LINK"
printf 'unrelated-a\n' > "$PUBLICATION_A/unrelated"
printf 'unrelated-b\n' > "$PUBLICATION_B/unrelated"
RETARGET_HUMAN_LOG="$SCRATCH/retarget-human.log"
FAKE_RETARGET_PARENT_LINK="$PUBLICATION_LINK" \
FAKE_RETARGET_PARENT_TARGET="$PUBLICATION_B" \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$PUBLICATION_LINK/retarget-safe.wasm" \
  "$SOURCE" 2> "$RETARGET_HUMAN_LOG"
test "$(readlink "$PUBLICATION_LINK")" = "$PUBLICATION_B"
cmp "$ENGINE" "$PUBLICATION_A/retarget-safe.wasm"
test ! -e "$PUBLICATION_B/retarget-safe.wasm"
grep -Fq "into $PUBLICATION_A/retarget-safe.wasm" "$RETARGET_HUMAN_LOG"
if grep -Fq "into $PUBLICATION_LINK/retarget-safe.wasm" \
  "$RETARGET_HUMAN_LOG"; then
  echo "FAIL: human success reported retargetable lexical output" >&2
  exit 1
fi
test "$(cat "$PUBLICATION_A/unrelated")" = "unrelated-a"
test "$(cat "$PUBLICATION_B/unrelated")" = "unrelated-b"

rm "$PUBLICATION_LINK"
ln -s "$PUBLICATION_A" "$PUBLICATION_LINK"
RETARGET_JSON_LOG="$SCRATCH/retarget-json.log"
FAKE_RETARGET_PARENT_LINK="$PUBLICATION_LINK" \
FAKE_RETARGET_PARENT_TARGET="$PUBLICATION_B" \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$PUBLICATION_LINK/retarget-json.wasm" \
  "$SOURCE" 2> "$RETARGET_JSON_LOG"
cmp "$ENGINE" "$PUBLICATION_A/retarget-json.wasm"
test ! -e "$PUBLICATION_B/retarget-json.wasm"
python3 - "$RETARGET_JSON_LOG" \
  "$PUBLICATION_A/retarget-json.wasm" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC0000", diagnostic
assert diagnostic["output"] == sys.argv[2], diagnostic
PY
if find "$PUBLICATION_A" "$PUBLICATION_B" \
  -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: parent-symlink retarget left transaction artifacts" >&2
  exit 1
fi

RENAMED_PUBLICATION="$SCRATCH/renamed publication"
MOVED_PUBLICATION="$SCRATCH/renamed publication moved"
RENAMED_OUTPUT="$RENAMED_PUBLICATION/component.wasm"
RENAMED_METADATA="$RENAMED_PUBLICATION/component.json"
RENAMED_DEBUG="$RENAMED_PUBLICATION/component.debug"
RENAMED_ERROR="$SCRATCH/renamed-publication-error.jsonl"
mkdir "$RENAMED_PUBLICATION" "$RENAMED_DEBUG"
printf 'original-renamed-component\n' > "$RENAMED_OUTPUT"
printf 'original-renamed-metadata\n' > "$RENAMED_METADATA"
python3 - "$RENAMED_DEBUG" <<'PY'
import os, sys
for index in range(4000):
    with open(os.path.join(sys.argv[1], f"unrelated-{index}"), "w") as entry:
        entry.write(f"preserve-{index}\n")
PY
python3 - "$RENAMED_PUBLICATION" "$MOVED_PUBLICATION" \
  "$RENAMED_OUTPUT" <<'PY' &
import os, sys, time
publication, moved, output = sys.argv[1:]
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if not os.path.exists(output):
        os.rename(publication, moved)
        os.mkdir(publication)
        with open(os.path.join(publication, "replacement-sentinel"), "w") as entry:
            entry.write("preserve-replacement-directory\n")
        with open(output, "w") as entry:
            entry.write("preserve-replacement-component\n")
        break
    time.sleep(0.0001)
else:
    raise SystemExit("failed to synchronize publication-directory rename")
PY
renamed_publication_racer=$!
if "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$RENAMED_METADATA" \
  --debug-dir "$RENAMED_DEBUG" \
  --out "$RENAMED_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$RENAMED_ERROR"
then
  wait "$renamed_publication_racer" 2>/dev/null || true
  echo "FAIL: renamed publication directory reported false success" >&2
  exit 1
fi
wait "$renamed_publication_racer"
test "$(cat "$MOVED_PUBLICATION/component.wasm")" = \
  "original-renamed-component"
test "$(cat "$MOVED_PUBLICATION/component.json")" = \
  "original-renamed-metadata"
test "$(cat "$MOVED_PUBLICATION/component.debug/unrelated-3999")" = \
  "preserve-3999"
test "$(cat "$RENAMED_OUTPUT")" = "preserve-replacement-component"
test "$(cat "$RENAMED_PUBLICATION/replacement-sentinel")" = \
  "preserve-replacement-directory"
python3 - "$RENAMED_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC7001", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
assert diagnostic["cause"] == "PublicationDirectoryChanged", diagnostic
assert diagnostic["message"] == \
    "the canonical publication directory changed before commit", diagnostic
assert "original publication was restored" in diagnostic["hint"], diagnostic
PY
if find "$RENAMED_PUBLICATION" "$MOVED_PUBLICATION" -maxdepth 1 \
  -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: rolled-back directory rename retained a transaction" >&2
  exit 1
fi

ROLLBACK_RACE_OUTPUT="$WORK/rollback completeness.wasm"
ROLLBACK_RACE_METADATA="$WORK/rollback completeness.json"
ROLLBACK_RACE_DEBUG="$WORK/rollback completeness.debug"
ROLLBACK_RACE_ERROR="$SCRATCH/rollback-completeness-error.jsonl"
printf 'original-component\n' > "$ROLLBACK_RACE_OUTPUT"
printf 'original-metadata\n' > "$ROLLBACK_RACE_METADATA"
mkdir "$ROLLBACK_RACE_DEBUG"
python3 - "$ROLLBACK_RACE_DEBUG" <<'PY'
import os, sys
for index in range(1000):
    with open(os.path.join(sys.argv[1], f"unrelated-{index}"), "w") as output:
        output.write(f"preserve-{index}\n")
PY
python3 - "$ROLLBACK_RACE_METADATA" <<'PY' &
import os, sys, time
metadata = sys.argv[1]
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        fd = os.open(metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        continue
    with os.fdopen(fd, "wb") as replacement:
        replacement.write(b"replacement-metadata\n")
    break
else:
    raise SystemExit("failed to inject metadata publication race")
PY
rollback_racer=$!
if "$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$ROLLBACK_RACE_METADATA" \
  --debug-dir "$ROLLBACK_RACE_DEBUG" \
  --out "$ROLLBACK_RACE_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$ROLLBACK_RACE_ERROR"
then
  kill "$rollback_racer" 2>/dev/null || true
  wait "$rollback_racer" 2>/dev/null || true
  echo "FAIL: metadata publication race unexpectedly succeeded" >&2
  exit 1
fi
wait "$rollback_racer"
test "$(cat "$ROLLBACK_RACE_OUTPUT")" = "original-component"
test "$(cat "$ROLLBACK_RACE_METADATA")" = "replacement-metadata"
test "$(cat "$ROLLBACK_RACE_DEBUG/unrelated-999")" = "preserve-999"
ROLLBACK_RACE_ROOT="$(find "$WORK" -maxdepth 1 -type d \
  -name '.rollback completeness.wasm.starling-componentize-*' -print -quit)"
test -n "$ROLLBACK_RACE_ROOT"
test "$(cat "$ROLLBACK_RACE_ROOT/data/previous-metadata")" = \
  "original-metadata"
cmp "$ENGINE" "$ROLLBACK_RACE_ROOT/data/component.wasm"
python3 - "$ROLLBACK_RACE_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC7001", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
assert diagnostic["cause"] == "RollbackIncomplete", diagnostic
assert "transaction storage was retained" in diagnostic["message"], diagnostic
PY
remove_tree "$ROLLBACK_RACE_ROOT"

BACKUP_RACE_OUTPUT="$WORK/backup identity race.wasm"
BACKUP_RACE_DEBUG="$WORK/backup identity race.debug"
BACKUP_RACE_SAVED="$SCRATCH/original component backup"
printf 'original-component-backup\n' > "$BACKUP_RACE_OUTPUT"
mkdir "$BACKUP_RACE_DEBUG"
python3 - "$BACKUP_RACE_DEBUG" <<'PY'
import os, sys
for index in range(4000):
    with open(os.path.join(sys.argv[1], f"unrelated-{index}"), "w") as entry:
        entry.write(f"preserve-{index}\n")
os.mkdir(os.path.join(sys.argv[1], "commands.txt"))
with open(os.path.join(sys.argv[1], "commands.txt", "sentinel"), "w") as entry:
    entry.write("preserve-generated-tree\n")
PY
if FAKE_REPLACE_COMPONENT_BACKUP=1 \
  FAKE_REPLACED_COMPONENT_BACKUP="$BACKUP_RACE_SAVED" \
  "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$BACKUP_RACE_DEBUG" \
  --out "$BACKUP_RACE_OUTPUT" \
  "$SOURCE" >/dev/null 2>&1
then
  echo "FAIL: replaced component backup unexpectedly published" >&2
  exit 1
fi
BACKUP_RACE_ROOT="$(find "$WORK" -maxdepth 1 -type d \
  -name '.backup identity race.wasm.starling-componentize-*' -print -quit)"
test -n "$BACKUP_RACE_ROOT"
test "$(cat "$BACKUP_RACE_SAVED")" = "original-component-backup"
test "$(cat "$BACKUP_RACE_ROOT/data/previous-component")" = \
  "preserve-backup-replacement"
test "$(cat "$BACKUP_RACE_DEBUG/commands.txt/sentinel")" = \
  "preserve-generated-tree"
test "$(cat "$BACKUP_RACE_DEBUG/unrelated-3999")" = "preserve-3999"
test ! -e "$BACKUP_RACE_OUTPUT"
remove_tree "$BACKUP_RACE_ROOT" "$BACKUP_RACE_DEBUG"

for commit_artifact in component metadata debug; do
  for commit_action in replacement removal; do
    commit_slug="$commit_artifact-$commit_action"
    commit_output="$WORK/commit $commit_slug.wasm"
    commit_metadata="$WORK/commit $commit_slug.json"
    commit_debug="$WORK/commit $commit_slug.debug"
    commit_error="$SCRATCH/commit-$commit_slug.jsonl"
    commit_barrier="$SCRATCH/commit-$commit_slug-barrier"
    commit_saved="$SCRATCH/commit-$commit_slug-published"
    printf 'old-component-%s\n' "$commit_slug" > "$commit_output"
    printf 'old-metadata-%s\n' "$commit_slug" > "$commit_metadata"
    mkdir "$commit_debug"
    printf 'old-debug-%s\n' "$commit_slug" > "$commit_debug/unrelated.txt"

    STARLING_COMPONENTIZER_TEST_COMMIT_BARRIER="$commit_barrier" \
    "$COMPONENTIZER" \
      --json-diagnostics \
      --engine "$ENGINE" \
      --preview2-adapter "$ADAPTER" \
      --wizer-bin "$TOOLS/fake wizer" \
      --wasm-tools-bin "$TOOLS/fake wasm-tools" \
      --metadata-out "$commit_metadata" \
      --debug-dir "$commit_debug" \
      --out "$commit_output" \
      "$SOURCE" >/dev/null 2> "$commit_error" &
    commit_pid=$!
    commit_ready=0
    for _ in $(seq 1 30000); do
      if [ -e "$commit_barrier.ready" ]; then
        commit_ready=1
        break
      fi
      if ! kill -0 "$commit_pid" 2>/dev/null; then
        break
      fi
      sleep 0.001
    done
    if [ "$commit_ready" -ne 1 ]; then
      wait "$commit_pid" 2>/dev/null || true
      echo "FAIL: commit barrier was not reached for $commit_slug" >&2
      exit 1
    fi

    commit_destination="$commit_output"
    if [ "$commit_artifact" = metadata ]; then
      commit_destination="$commit_metadata"
    elif [ "$commit_artifact" = debug ]; then
      commit_destination="$commit_debug"
    fi
    if [ "$commit_action" = replacement ]; then
      mv "$commit_destination" "$commit_saved"
      if [ "$commit_artifact" = debug ]; then
        mkdir "$commit_destination"
        printf 'replacement-debug-%s\n' "$commit_slug" > \
          "$commit_destination/sentinel"
      else
        printf 'replacement-%s\n' "$commit_slug" > "$commit_destination"
      fi
    elif [ "$commit_artifact" = debug ]; then
      remove_tree "$commit_destination"
    else
      rm "$commit_destination"
    fi
    : > "$commit_barrier.release"
    if wait "$commit_pid"; then
      echo "FAIL: $commit_slug after publication reported success" >&2
      exit 1
    fi

    python3 - "$commit_error" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC7001", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
assert diagnostic["cause"] == "RollbackIncomplete", diagnostic
PY
    if [ "$commit_action" = replacement ]; then
      if [ "$commit_artifact" = debug ]; then
        test "$(cat "$commit_debug/sentinel")" = \
          "replacement-debug-$commit_slug"
      else
        test "$(cat "$commit_destination")" = \
          "replacement-$commit_slug"
      fi
    else
      test "$(cat "$commit_output")" = "old-component-$commit_slug"
      test "$(cat "$commit_metadata")" = "old-metadata-$commit_slug"
      test "$(cat "$commit_debug/unrelated.txt")" = \
        "old-debug-$commit_slug"
    fi
    if [ "$commit_artifact" != component ]; then
      test "$(cat "$commit_output")" = "old-component-$commit_slug"
    fi
    if [ "$commit_artifact" != metadata ]; then
      test "$(cat "$commit_metadata")" = "old-metadata-$commit_slug"
    fi
    if [ "$commit_artifact" != debug ]; then
      test "$(cat "$commit_debug/unrelated.txt")" = \
        "old-debug-$commit_slug"
    fi
    commit_root="$(find "$WORK" -maxdepth 1 -type d \
      -name ".commit $commit_slug.wasm.starling-componentize-*" \
      -print -quit)"
    test -n "$commit_root"
    test -d "$commit_root/data"
    if [ "$commit_action" = replacement ]; then
      case "$commit_artifact" in
        component)
          test "$(cat "$commit_root/data/previous-component")" = \
            "old-component-$commit_slug"
          ;;
        metadata)
          test "$(cat "$commit_root/data/previous-metadata")" = \
            "old-metadata-$commit_slug"
          ;;
        debug)
          test "$(cat "$commit_root/data/previous-debug/unrelated.txt")" = \
            "old-debug-$commit_slug"
          ;;
      esac
    fi
    remove_tree "$commit_root" "$commit_debug" "$commit_saved"
    rm -f "$commit_output" "$commit_metadata" \
      "$commit_barrier.ready" "$commit_barrier.release"
  done
done

for mutation_artifact in component metadata debug; do
  mutation_output="$WORK/mutation-$mutation_artifact.wasm"
  mutation_metadata="$WORK/mutation-$mutation_artifact.json"
  mutation_debug="$WORK/mutation-$mutation_artifact.debug"
  mutation_error="$SCRATCH/mutation-$mutation_artifact.jsonl"
  mutation_barrier="$SCRATCH/mutation-$mutation_artifact-barrier"
  printf 'old-component-%s\n' "$mutation_artifact" > "$mutation_output"
  printf 'old-metadata-%s\n' "$mutation_artifact" > "$mutation_metadata"
  mkdir "$mutation_debug"
  printf 'old-debug-%s\n' "$mutation_artifact" > \
    "$mutation_debug/unrelated.txt"

  STARLING_COMPONENTIZER_TEST_COMMIT_BARRIER="$mutation_barrier" \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$mutation_metadata" \
    --debug-dir "$mutation_debug" \
    --out "$mutation_output" \
    "$SOURCE" >/dev/null 2> "$mutation_error" &
  mutation_pid=$!
  wait_for_marker "$mutation_barrier.ready" "$mutation_pid" \
    "$mutation_artifact publication mutation"

  mutation_target="$mutation_output"
  if [ "$mutation_artifact" = metadata ]; then
    mutation_target="$mutation_metadata"
  elif [ "$mutation_artifact" = debug ]; then
    mutation_target="$mutation_debug/component.wasm"
  fi
  chmod u+w "$mutation_target"
  printf 'mutated-published-%s\n' "$mutation_artifact" > "$mutation_target"
  : > "$mutation_barrier.release"
  if wait "$mutation_pid"; then
    echo "FAIL: in-place $mutation_artifact mutation reported success" >&2
    exit 1
  fi
  python3 - "$mutation_error" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC7001", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
  test "$(cat "$mutation_output")" = \
    "old-component-$mutation_artifact"
  test "$(cat "$mutation_metadata")" = \
    "old-metadata-$mutation_artifact"
  test "$(cat "$mutation_debug/unrelated.txt")" = \
    "old-debug-$mutation_artifact"
  if find "$WORK" -maxdepth 1 -type d \
    -name ".mutation-$mutation_artifact.wasm.starling-componentize-*" \
    | grep -q .; then
    echo "FAIL: $mutation_artifact mutation retained a transaction" >&2
    exit 1
  fi
  remove_tree "$mutation_debug"
  rm -f "$mutation_output" "$mutation_metadata" \
    "$mutation_barrier.ready" "$mutation_barrier.release"
done

publication_fault_rollback() {
  local fault="$1" slug="${1//[^a-zA-Z0-9]/-}"
  local fault_output="$WORK/fault-$slug.wasm"
  local fault_metadata="$WORK/fault-$slug.json"
  local fault_debug="$WORK/fault-$slug.debug"
  local fault_error="$SCRATCH/fault-$slug.jsonl"
  printf 'old-component-%s\n' "$fault" > "$fault_output"
  printf 'old-metadata-%s\n' "$fault" > "$fault_metadata"
  mkdir "$fault_debug"
  printf 'old-debug-%s\n' "$fault" > "$fault_debug/unrelated.txt"
  if STARLING_COMPONENTIZER_TEST_PUBLICATION_FAULT="$fault" \
    "$COMPONENTIZER" \
      --json-diagnostics \
      --engine "$ENGINE" \
      --preview2-adapter "$ADAPTER" \
      --wizer-bin "$TOOLS/fake wizer" \
      --wasm-tools-bin "$TOOLS/fake wasm-tools" \
      --metadata-out "$fault_metadata" \
      --debug-dir "$fault_debug" \
      --out "$fault_output" \
      "$SOURCE" >/dev/null 2> "$fault_error"
  then
    echo "FAIL: pre-commit publication fault $fault reported success" >&2
    exit 1
  fi
  test "$(cat "$fault_output")" = "old-component-$fault"
  test "$(cat "$fault_metadata")" = "old-metadata-$fault"
  test "$(cat "$fault_debug/unrelated.txt")" = "old-debug-$fault"
  python3 - "$fault_error" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC7001", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
assert diagnostic["cause"] == "CommandFailed", diagnostic
PY
  if find "$WORK" -maxdepth 1 -type d \
    -name ".fault-$slug.wasm.starling-componentize-*" | grep -q .; then
    echo "FAIL: exact rollback for $fault retained a transaction" >&2
    exit 1
  fi
  remove_tree "$fault_debug"
  rm -f "$fault_output" "$fault_metadata"
}

publication_rollback_faults=(
  backup-component-after-rename
  backup-component-after-stat
  backup-component-after-identity
  backup-component-after-record
  backup-metadata-after-rename
  backup-metadata-after-stat
  backup-metadata-after-identity
  backup-metadata-after-record
  backup-debug-after-rename
  backup-debug-after-stat
  backup-debug-after-identity
  backup-debug-after-record
  backup-debug-after-open-backup
  backup-debug-after-open-staged
  backup-debug-after-scan
  backup-debug-after-verify
  backup-debug-after-record-tree
  backup-debug-after-copy
  backup-debug-after-final-verify
  final-recovery-attached
  final-recovery-component
  final-recovery-metadata
  final-recovery-debug
  final-recovery-after
  final-publication-before
  final-publication-parent-before
  final-lock-before
  final-component
  final-metadata
  final-debug
  final-lock-after
  final-publication-after
  final-before-commit
)
for publication_fault in "${publication_rollback_faults[@]}"; do
  publication_fault_rollback "$publication_fault"
done

for cleanup_fault in \
  cleanup-component-before cleanup-component-after \
  cleanup-metadata-before cleanup-metadata-after \
  cleanup-debug-before cleanup-debug-after
do
  cleanup_slug="${cleanup_fault//[^a-zA-Z0-9]/-}"
  cleanup_output="$WORK/cleanup-$cleanup_slug.wasm"
  cleanup_metadata="$WORK/cleanup-$cleanup_slug.json"
  cleanup_debug="$WORK/cleanup-$cleanup_slug.debug"
  cleanup_log="$SCRATCH/cleanup-$cleanup_slug.jsonl"
  printf 'old-component-%s\n' "$cleanup_fault" > "$cleanup_output"
  printf 'old-metadata-%s\n' "$cleanup_fault" > "$cleanup_metadata"
  mkdir "$cleanup_debug"
  printf 'old-debug-%s\n' "$cleanup_fault" > \
    "$cleanup_debug/unrelated.txt"
  STARLING_COMPONENTIZER_TEST_PUBLICATION_FAULT="$cleanup_fault" \
    "$COMPONENTIZER" \
      --json-diagnostics \
      --engine "$ENGINE" \
      --preview2-adapter "$ADAPTER" \
      --wizer-bin "$TOOLS/fake wizer" \
      --wasm-tools-bin "$TOOLS/fake wasm-tools" \
      --metadata-out "$cleanup_metadata" \
      --debug-dir "$cleanup_debug" \
      --out "$cleanup_output" \
      "$SOURCE" >/dev/null 2> "$cleanup_log"
  cmp "$ENGINE" "$cleanup_output"
  cmp "$ENGINE" "$cleanup_debug/component.wasm"
  test "$(cat "$cleanup_debug/unrelated.txt")" = "old-debug-$cleanup_fault"
  python3 - "$cleanup_log" "$cleanup_output" "$cleanup_metadata" <<'PY'
import hashlib, json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC0000", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
component = open(sys.argv[2], "rb").read()
document = json.load(open(sys.argv[3], encoding="utf-8"))
assert document["component_sha256"] == hashlib.sha256(component).hexdigest()
PY
  cleanup_root="$(find "$WORK" -maxdepth 1 -type d \
    -name ".cleanup-$cleanup_slug.wasm.starling-componentize-*" \
    -print -quit)"
  test -n "$cleanup_root"
  remove_tree "$cleanup_root" "$cleanup_debug"
  rm -f "$cleanup_output" "$cleanup_metadata"
done

CONCURRENT_BUNDLE_OUTPUT="$WORK/concurrent bundle.wasm"
CONCURRENT_BUNDLE_METADATA="$WORK/concurrent bundle.json"
CONCURRENT_BUNDLE_DEBUG="$WORK/concurrent bundle.debug"
CONCURRENT_BUNDLE_ENGINE_A="$SCRATCH/concurrent-engine-a.wasm"
CONCURRENT_BUNDLE_ENGINE_B="$SCRATCH/concurrent-engine-b.wasm"
CONCURRENT_BUNDLE_LOG_A="$SCRATCH/concurrent-bundle-a.jsonl"
CONCURRENT_BUNDLE_LOG_B="$SCRATCH/concurrent-bundle-b.jsonl"
CONCURRENT_BUNDLE_BARRIER_A="$SCRATCH/concurrent-bundle-a-lock"
CONCURRENT_BUNDLE_BARRIER_B="$SCRATCH/concurrent-bundle-b-lock"
printf 'concurrent-engine-a\n' > "$CONCURRENT_BUNDLE_ENGINE_A"
printf 'concurrent-engine-b\n' > "$CONCURRENT_BUNDLE_ENGINE_B"
STARLING_COMPONENTIZER_TEST_LOCK_BARRIER="$CONCURRENT_BUNDLE_BARRIER_A" \
STARLING_COMPONENTIZER_TEST_LOCK_BARRIER_MODE=after \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$CONCURRENT_BUNDLE_ENGINE_A" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$CONCURRENT_BUNDLE_METADATA" \
  --debug-dir "$CONCURRENT_BUNDLE_DEBUG" \
  --out "$CONCURRENT_BUNDLE_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$CONCURRENT_BUNDLE_LOG_A" &
concurrent_bundle_pid_a=$!
wait_for_marker "$CONCURRENT_BUNDLE_BARRIER_A.acquired" \
  "$concurrent_bundle_pid_a" "first publication locker"
STARLING_COMPONENTIZER_TEST_LOCK_BARRIER="$CONCURRENT_BUNDLE_BARRIER_B" \
STARLING_COMPONENTIZER_TEST_LOCK_BARRIER_MODE=before \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$CONCURRENT_BUNDLE_ENGINE_B" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$CONCURRENT_BUNDLE_METADATA" \
  --debug-dir "$CONCURRENT_BUNDLE_DEBUG" \
  --out "$CONCURRENT_BUNDLE_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$CONCURRENT_BUNDLE_LOG_B" &
concurrent_bundle_pid_b=$!
wait_for_marker "$CONCURRENT_BUNDLE_BARRIER_B.before" \
  "$concurrent_bundle_pid_b" "second publication locker"
: > "$CONCURRENT_BUNDLE_BARRIER_B.enter"
wait_for_marker "$CONCURRENT_BUNDLE_BARRIER_B.attempting" \
  "$concurrent_bundle_pid_b" "second publication lock attempt"
test ! -e "$CONCURRENT_BUNDLE_BARRIER_B.acquired"
: > "$CONCURRENT_BUNDLE_BARRIER_A.release"
wait "$concurrent_bundle_pid_a"
wait_for_marker "$CONCURRENT_BUNDLE_BARRIER_B.acquired" \
  "$concurrent_bundle_pid_b" "second publication lock acquisition"
wait "$concurrent_bundle_pid_b"
cmp "$CONCURRENT_BUNDLE_ENGINE_B" "$CONCURRENT_BUNDLE_OUTPUT"
cmp "$CONCURRENT_BUNDLE_ENGINE_B" \
  "$CONCURRENT_BUNDLE_DEBUG/component.wasm"
python3 - "$CONCURRENT_BUNDLE_LOG_A" "$CONCURRENT_BUNDLE_LOG_B" \
  "$CONCURRENT_BUNDLE_OUTPUT" "$CONCURRENT_BUNDLE_METADATA" <<'PY'
import hashlib, json, sys
for path in sys.argv[1:3]:
    diagnostic = json.load(open(path, encoding="utf-8"))
    assert diagnostic["code"] == "SMC0000", diagnostic
    assert diagnostic["phase"] == "publish", diagnostic
component = open(sys.argv[3], "rb").read()
metadata = json.load(open(sys.argv[4], encoding="utf-8"))
assert metadata["component_sha256"] == hashlib.sha256(component).hexdigest()
PY

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
rm "$SYMLINK_RACE_METADATA"

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
rm "$SYMLINK_DEBUG_DIR"

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
BUILD_SOURCE_DIR="$SCRATCH/runtime build source"
BUILD_SOURCE="$BUILD_SOURCE_DIR/source module.js"
mkdir "$BUILD_SOURCE_DIR"
cp "$SOURCE" "$BUILD_SOURCE"
build_with_selected_zig() {
  local zig="$1" output="$2"
  shift 2
  "$COMPONENTIZER" \
    --build-root "$ROOT" \
    --cache-dir "$CACHE" \
    --zig-bin "$zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    "$@" \
    --out "$output" \
    "$BUILD_SOURCE"
}
build_with_fake_zig() {
  local output="$1"
  shift
  build_with_selected_zig "$TOOLS/fake zig" "$output" "$@"
}
build_with_fake_zig "$BUILD_OUTPUT_1"
build_with_fake_zig "$BUILD_OUTPUT_2"
printf '\n// cache invalidation\n' >> "$WIT/world.wit"
build_with_fake_zig "$BUILD_OUTPUT_3"

METADATA_OUTPUT="$WORK/public metadata.json"
METADATA_REFERENCE="$SCRATCH/public metadata reference.json"
BUILD_DEBUG_DIR="$WORK/build debug bindings"
build_with_fake_zig "$WORK/metadata component.wasm" \
  --metadata-out "$METADATA_OUTPUT" \
  --debug-dir "$BUILD_DEBUG_DIR"
cp "$METADATA_OUTPUT" "$METADATA_REFERENCE"
test -s "$BUILD_DEBUG_DIR/component-bindings.zig"
test -s "$BUILD_DEBUG_DIR/imports.json"
cmp "$METADATA_OUTPUT" "$BUILD_DEBUG_DIR/metadata.json"
python3 - "$METADATA_OUTPUT" "$BUILD_DEBUG_DIR/imports.json" \
  "$BUILD_DEBUG_DIR/runtime-args.txt" <<'PY'
import hashlib, json, re, sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
imports = json.load(open(sys.argv[2], encoding="utf-8"))
sha256 = re.compile(r"^[0-9a-f]{64}$")
assert metadata["schema"] == "starling-componentize-metadata/v2"
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
inputs = provenance["inputs"]
assert all(sha256.match(inputs[k]) for k in (
    "source_sha256", "runtime_arguments_sha256", "engine_sha256",
    "preview2_adapter_sha256",
))
assert inputs["initializer_sha256"] is None
assert inputs["source_tree"]["entry"] == "source module.js"
assert sha256.match(inputs["source_tree"]["sha256"])
assert inputs["initializer_tree"] is None
assert [f["name"] for f in provenance["features"]] == [
    "stdio", "random", "clocks", "http", "fetch-event",
]
assert all(f["enabled"] for f in provenance["features"])
assert [t["name"] for t in provenance["tools"]] == [
    "zig", "wasip3-bindgen", "wasm-opt", "wizer", "wabt", "wasm-tools",
]
assert all(sha256.match(t["sha256"]) for t in provenance["tools"])
assert sha256.match(provenance["tools"][0]["lib_tree_sha256"])
assert all(t["lib_tree_sha256"] is None for t in provenance["tools"][1:])
assert sha256.match(metadata["component_sha256"])
runtime_args = open(sys.argv[3], "rb").read()
assert provenance["inputs"]["runtime_arguments_sha256"] == \
    hashlib.sha256(runtime_args).hexdigest()
PY
build_with_fake_zig "$WORK/metadata component.wasm" \
  --metadata-out "$METADATA_OUTPUT" \
  --debug-dir "$BUILD_DEBUG_DIR"
cmp "$METADATA_REFERENCE" "$METADATA_OUTPUT"

DIRECT_ZIG_ROOT="$SCRATCH/direct Zig layout with spaces"
INSTALLED_ZIG_ROOT="$SCRATCH/installed Zig layout with spaces"
ZIG_LINK_ROOT="$SCRATCH/symlinked Zig path with spaces"
mkdir -p "$DIRECT_ZIG_ROOT/lib" "$INSTALLED_ZIG_ROOT/bin" \
  "$INSTALLED_ZIG_ROOT/lib/zig" "$ZIG_LINK_ROOT"
cp "$TOOLS/fake zig" "$DIRECT_ZIG_ROOT/zig"
cp "$TOOLS/fake zig" "$INSTALLED_ZIG_ROOT/bin/zig"
chmod +x "$DIRECT_ZIG_ROOT/zig" "$INSTALLED_ZIG_ROOT/bin/zig"
printf 'immutable-zig-lib\n' > "$DIRECT_ZIG_ROOT/lib/marker"
printf 'immutable-zig-lib\n' > "$INSTALLED_ZIG_ROOT/lib/zig/marker"
ln -s "$INSTALLED_ZIG_ROOT/bin/zig" "$ZIG_LINK_ROOT/zig link"
FAKE_ZIG_LIB_DIR="$DIRECT_ZIG_ROOT/lib" \
FAKE_MUTATE_ZIG_LIB_DIR="$DIRECT_ZIG_ROOT/lib" \
  build_with_selected_zig "$DIRECT_ZIG_ROOT/zig" \
    "$WORK/direct Zig layout.wasm"
test "$(cat "$DIRECT_ZIG_ROOT/lib/marker")" = "mutated-original"
FAKE_ZIG_LIB_DIR="$INSTALLED_ZIG_ROOT/lib/zig" \
  build_with_selected_zig "$INSTALLED_ZIG_ROOT/bin/zig" \
    "$WORK/installed Zig layout.wasm"
FAKE_ZIG_LIB_DIR="$INSTALLED_ZIG_ROOT/lib/zig" \
  build_with_selected_zig "$ZIG_LINK_ROOT/zig link" \
    "$WORK/symlinked Zig layout.wasm"
ZIG_LIB_DIR="$INSTALLED_ZIG_ROOT/lib/zig" \
  build_with_selected_zig "$INSTALLED_ZIG_ROOT/bin/zig" \
    "$WORK/explicit Zig lib layout.wasm"

ZIG_PROVENANCE_ROOT="$SCRATCH/Zig provenance roots"
ZIG_PROVENANCE_A="$ZIG_PROVENANCE_ROOT/clean a"
ZIG_PROVENANCE_B="$ZIG_PROVENANCE_ROOT/clean b"
mkdir -p "$ZIG_PROVENANCE_A/lib" "$ZIG_PROVENANCE_B/lib"
cp "$TOOLS/fake zig" "$ZIG_PROVENANCE_A/zig"
cp "$TOOLS/fake zig" "$ZIG_PROVENANCE_B/zig"
chmod +x "$ZIG_PROVENANCE_A/zig" "$ZIG_PROVENANCE_B/zig"
printf 'immutable-zig-lib\n' > "$ZIG_PROVENANCE_A/lib/marker"
printf 'immutable-zig-lib\n' > "$ZIG_PROVENANCE_B/lib/marker"
ZIG_PROVENANCE_A_METADATA="$WORK/Zig provenance clean a.json"
ZIG_PROVENANCE_B_METADATA="$WORK/Zig provenance clean b.json"
ZIG_PROVENANCE_CHANGED_METADATA="$WORK/Zig provenance changed.json"
FAKE_ZIG_LIB_DIR="$ZIG_PROVENANCE_A/lib" \
  build_with_selected_zig "$ZIG_PROVENANCE_A/zig" \
    "$WORK/Zig provenance clean a.wasm" \
    --metadata-out "$ZIG_PROVENANCE_A_METADATA"
FAKE_ZIG_LIB_DIR="$ZIG_PROVENANCE_B/lib" \
  build_with_selected_zig "$ZIG_PROVENANCE_B/zig" \
    "$WORK/Zig provenance clean b.wasm" \
    --metadata-out "$ZIG_PROVENANCE_B_METADATA"
mkdir "$ZIG_PROVENANCE_B/lib/nested"
printf 'library-only-change\n' > \
  "$ZIG_PROVENANCE_B/lib/nested/provenance-input"
FAKE_ZIG_LIB_DIR="$ZIG_PROVENANCE_B/lib" \
  build_with_selected_zig "$ZIG_PROVENANCE_B/zig" \
    "$WORK/Zig provenance changed.wasm" \
    --metadata-out "$ZIG_PROVENANCE_CHANGED_METADATA"
python3 - "$ZIG_PROVENANCE_A_METADATA" "$ZIG_PROVENANCE_B_METADATA" \
  "$ZIG_PROVENANCE_CHANGED_METADATA" <<'PY'
import json, sys
clean_a, clean_b, changed = [
    json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]
]
assert clean_a["provenance"] == clean_b["provenance"]
clean_tools = {tool["name"]: tool for tool in clean_b["provenance"]["tools"]}
changed_tools = {tool["name"]: tool for tool in changed["provenance"]["tools"]}
assert clean_tools["zig"]["sha256"] == changed_tools["zig"]["sha256"]
assert clean_tools["zig"]["lib_tree_sha256"] != \
    changed_tools["zig"]["lib_tree_sha256"]
assert {
    name: tool for name, tool in clean_tools.items() if name != "zig"
} == {
    name: tool for name, tool in changed_tools.items() if name != "zig"
}
assert clean_b["provenance"]["tools_sha256"] != \
    changed["provenance"]["tools_sha256"]
PY

remove_tree "$CACHE"
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
test "${#prefixes[@]}" -eq 14
for prefix in "${prefixes[@]}"; do
  case "$prefix" in
    *".starling-componentize-"*/data/runtime-prefix) ;;
    *)
      echo "FAIL: Zig build escaped its private anchored prefix: $prefix" >&2
      exit 1
      ;;
  esac
done
test "$(printf '%s\n' "${prefixes[@]}" | sort -u | wc -l)" -eq 14
test "$(find "$CACHE/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
  -ge 1
cmp "$ENGINE" "$WORK/concurrent output 1.wasm"
cmp "$ENGINE" "$WORK/concurrent output 2.wasm"
while IFS='|' read -r local_cache global_cache zig_lib; do
  test "$local_cache" = "$CACHE/zig-local-cache"
  test "$global_cache" = "$CACHE/zig-global-cache"
  case "$zig_lib" in
    */zig-install/lib) ;;
    *)
      echo "FAIL: Zig build did not consume snapshotted library: $zig_lib" >&2
      exit 1
      ;;
  esac
done < "$FAKE_ZIG_ENV_LOG"
cmp "$ENGINE" "$BUILD_OUTPUT_1"
cmp "$ENGINE" "$BUILD_OUTPUT_2"
cmp "$ENGINE" "$BUILD_OUTPUT_3"

DEFAULT_SOURCE_PARENT="$SCRATCH/default cache source parent"
DEFAULT_BUILD_ROOT="$DEFAULT_SOURCE_PARENT/build root with spaces"
DEFAULT_SOURCE="$DEFAULT_SOURCE_PARENT/source module.js"
DEFAULT_CACHE="$DEFAULT_BUILD_ROOT/.zig-cache/starling-componentizer"
DEFAULT_CACHE_RELATIVE="build root with spaces/.zig-cache/starling-componentizer"
DEFAULT_LOOKALIKE_RELATIVE="build root with spaces/.zig-cache/starling-componentizer-user/cache module.js"
mkdir -p "$DEFAULT_BUILD_ROOT/runtime" \
  "$DEFAULT_BUILD_ROOT/tools/componentizer" \
  "$DEFAULT_BUILD_ROOT/.zig-cache/starling-componentizer-user"
touch "$DEFAULT_BUILD_ROOT/build.zig" "$DEFAULT_BUILD_ROOT/build.zig.zon" \
  "$DEFAULT_BUILD_ROOT/runtime/js.cpp" \
  "$DEFAULT_BUILD_ROOT/tools/componentizer/main.zig"
printf 'export const defaultCache = true;\n' > "$DEFAULT_SOURCE"
printf 'export const userCacheModule = 1;\n' > \
  "$DEFAULT_SOURCE_PARENT/$DEFAULT_LOOKALIKE_RELATIVE"
default_cache_run() {
  local suffix="$1"
  FAKE_ASSERT_CACHE_SNAPSHOT=1 \
  FAKE_EXCLUDED_CACHE_RELATIVE="$DEFAULT_CACHE_RELATIVE" \
  FAKE_CACHE_LOOKALIKE_RELATIVE="$DEFAULT_LOOKALIKE_RELATIVE" \
  "$COMPONENTIZER" \
    --build-root "$DEFAULT_BUILD_ROOT" \
    --zig-bin "$TOOLS/fake zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --metadata-out "$WORK/default cache $suffix.json" \
    --out "$WORK/default cache $suffix.wasm" \
    "$DEFAULT_SOURCE"
}
default_cache_run first
default_cache_run second
printf 'export const userCacheModule = 2;\n' > \
  "$DEFAULT_SOURCE_PARENT/$DEFAULT_LOOKALIKE_RELATIVE"
default_cache_run lookalike-changed
python3 - "$WORK/default cache first.json" \
  "$WORK/default cache second.json" \
  "$WORK/default cache lookalike-changed.json" <<'PY'
import json, sys
digests = [
    json.load(open(path, encoding="utf-8"))["provenance"]["inputs"]
    ["source_tree"]["sha256"]
    for path in sys.argv[1:]
]
assert digests[0] == digests[1], digests
assert digests[1] != digests[2], digests
PY
tail -n 3 "$FAKE_ZIG_ENV_LOG" |
while IFS='|' read -r local_cache global_cache zig_lib; do
  test "$local_cache" = "$DEFAULT_CACHE/zig-local-cache"
  test "$global_cache" = "$DEFAULT_CACHE/zig-global-cache"
  case "$zig_lib" in
    */zig-install/lib) ;;
    *) exit 1 ;;
  esac
done

cache_identity_race() {
  local race_kind="$1"
  local race_cache="$SCRATCH/cache identity $race_kind"
  local race_held="$SCRATCH/cache identity $race_kind held"
  local race_target="$SCRATCH/cache identity $race_kind user target"
  local race_output="$WORK/cache identity $race_kind.wasm"
  local race_error="$SCRATCH/cache-identity-$race_kind.jsonl"
  local race_barrier="$SCRATCH/cache-identity-$race_kind"
  remove_tree "$race_cache" "$race_held" "$race_target"
  FAKE_ZIG_BARRIER="$race_barrier" "$COMPONENTIZER" \
    --json-diagnostics \
    --build-root "$ROOT" \
    --cache-dir "$race_cache" \
    --zig-bin "$TOOLS/fake zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$race_output" \
    "$BUILD_SOURCE" >/dev/null 2> "$race_error" &
  local race_pid=$!
  local race_ready=0
  for _ in $(seq 1 30000); do
    if [ -e "$race_barrier.ready" ]; then
      race_ready=1
      break
    fi
    if ! kill -0 "$race_pid" 2>/dev/null; then
      break
    fi
    sleep 0.001
  done
  if [ "$race_ready" -ne 1 ]; then
    wait "$race_pid" 2>/dev/null || true
    echo "FAIL: cache race barrier was not reached for $race_kind" >&2
    exit 1
  fi

  if [ "$race_kind" = root ]; then
    mv "$race_cache" "$race_held"
    mkdir "$race_cache"
    printf 'user-root-replacement\n' > "$race_cache/sentinel"
  else
    local child="$race_kind"
    if [ "$race_kind" = runtime-prefix ] ||
       [ "$race_kind" = runtime-bin ] ||
       [ "$race_kind" = runtime-artifact ]; then
      child="runtimes/$(basename "$(find "$race_cache/runtimes" \
        -mindepth 1 -maxdepth 1 -type d -print -quit)")"
    fi
    if [ "$race_kind" = runtime-bin ]; then
      child="$child/bin"
    fi
    mkdir "$race_target"
    printf 'user-child-replacement\n' > "$race_target/sentinel"
    if [ "$race_kind" = runtime-artifact ]; then
      printf 'external-artifact\n' > "$race_target/external.wasm"
      ln -s "$race_target/external.wasm" \
        "$race_cache/$child/bin/starling-raw.wasm"
    else
      mv "$race_cache/$child" "$race_held"
      ln -s "$race_target" "$race_cache/$child"
    fi
  fi
  : > "$race_barrier.release"
  if wait "$race_pid"; then
    echo "FAIL: cache $race_kind replacement reported success" >&2
    exit 1
  fi
  test ! -e "$race_output"
  python3 - "$race_error" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC2001", diagnostic
assert diagnostic["phase"] == "runtime_build", diagnostic
assert diagnostic["cause"] == "CacheDirectoryChanged", diagnostic
PY
  if [ "$race_kind" = root ]; then
    test "$(cat "$race_cache/sentinel")" = "user-root-replacement"
    test "$(find "$race_cache" -mindepth 1 ! -name sentinel | wc -l)" -eq 0
    test -f "$race_held/zig-local-cache/fake-zig-local"
    test -f "$race_held/zig-global-cache/fake-zig-global"
  else
    test "$(cat "$race_target/sentinel")" = "user-child-replacement"
    if [ "$race_kind" = runtime-artifact ]; then
      test "$(cat "$race_target/external.wasm")" = "external-artifact"
    else
      test "$(find "$race_target" -mindepth 1 ! -name sentinel | wc -l)" -eq 0
    fi
  fi
  remove_tree "$race_cache" "$race_held" "$race_target"
  rm -f "$race_barrier.ready" "$race_barrier.release"
}

cache_identity_race root
cache_identity_race runtimes
cache_identity_race runtime-prefix
cache_identity_race runtime-bin
cache_identity_race runtime-artifact
cache_identity_race locks
cache_identity_race zig-global-cache
cache_identity_race zig-local-cache

SNAPSHOT_SOURCE_ROOT="$SCRATCH/stable snapshot source"
SNAPSHOT_SOURCE="$SNAPSHOT_SOURCE_ROOT/main.js"
mkdir "$SNAPSHOT_SOURCE_ROOT"
printf 'export const stableSnapshot = true;\n' > "$SNAPSHOT_SOURCE"

SNAPSHOT_MUTATION_OUTPUT="$WORK/snapshot-mutation.wasm"
SNAPSHOT_MUTATION_ERROR="$SCRATCH/snapshot-mutation.jsonl"
SNAPSHOT_MUTATION_BARRIER="$SCRATCH/snapshot-mutation"
printf 'old-snapshot-mutation-output\n' > "$SNAPSHOT_MUTATION_OUTPUT"
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_MUTATION_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE=wizer \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$SNAPSHOT_MUTATION_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2> "$SNAPSHOT_MUTATION_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SNAPSHOT_MUTATION_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "retained snapshot mutation"
snapshot_root="$(find "$WORK" -maxdepth 1 -type d \
  -name '.snapshot-mutation.wasm.starling-componentize-*' -print -quit)"
test -n "$snapshot_root"
chmod u+w "$snapshot_root/data/engine.wasm"
printf 'mutated-retained-engine\n' > "$snapshot_root/data/engine.wasm"
: > "$SNAPSHOT_MUTATION_BARRIER.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: retained snapshot mutation reported success" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$SNAPSHOT_MUTATION_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC3001", diagnostic
assert diagnostic["phase"] == "initialize", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
test "$(cat "$SNAPSHOT_MUTATION_OUTPUT")" = \
  "old-snapshot-mutation-output"

SNAPSHOT_UNRESTORED_OUTPUT="$WORK/snapshot-unrestored.wasm"
SNAPSHOT_UNRESTORED_ERROR="$SCRATCH/snapshot-unrestored.jsonl"
SNAPSHOT_UNRESTORED_BARRIER="$SCRATCH/snapshot-unrestored"
SNAPSHOT_UNRESTORED_ORIGINAL="$SCRATCH/snapshot-unrestored-engine"
printf 'old-snapshot-unrestored-output\n' > "$SNAPSHOT_UNRESTORED_OUTPUT"
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_UNRESTORED_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE=wizer \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$SNAPSHOT_UNRESTORED_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2> "$SNAPSHOT_UNRESTORED_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SNAPSHOT_UNRESTORED_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "unrestored snapshot substitution"
snapshot_root="$(find "$WORK" -maxdepth 1 -type d \
  -name '.snapshot-unrestored.wasm.starling-componentize-*' -print -quit)"
test -n "$snapshot_root"
mv "$snapshot_root/data/engine.wasm" "$SNAPSHOT_UNRESTORED_ORIGINAL"
printf 'substituted-unrestored-engine\n' > "$snapshot_root/data/engine.wasm"
: > "$SNAPSHOT_UNRESTORED_BARRIER.release"
wait_for_marker "$SNAPSHOT_UNRESTORED_BARRIER.complete" \
  "$SNAPSHOT_TEST_PID" "unrestored snapshot completion"
: > "$SNAPSHOT_UNRESTORED_BARRIER.verify"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: unrestored snapshot substitution reported success" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$SNAPSHOT_UNRESTORED_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC3001", diagnostic
assert diagnostic["phase"] == "initialize", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
test "$(cat "$SNAPSHOT_UNRESTORED_OUTPUT")" = \
  "old-snapshot-unrestored-output"
test "$(cat "$snapshot_root/data/engine.wasm")" = \
  "substituted-unrestored-engine"
remove_tree "$snapshot_root"
rm -f "$SNAPSHOT_UNRESTORED_ORIGINAL"

SNAPSHOT_WIZER_OUTPUT="$WORK/snapshot-wizer.wasm"
SNAPSHOT_WIZER_METADATA="$WORK/snapshot-wizer.json"
SNAPSHOT_WIZER_BARRIER="$SCRATCH/snapshot-wizer"
SNAPSHOT_WIZER_EXTERNAL="$SCRATCH/snapshot-wizer-external"
printf 'external-output\n' > "$SNAPSHOT_WIZER_EXTERNAL"
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_WIZER_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE=wizer \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$SNAPSHOT_WIZER_METADATA" \
  --out "$SNAPSHOT_WIZER_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2>&1 &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SNAPSHOT_WIZER_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "Wizer snapshot substitution"
snapshot_root="$(find "$WORK" -maxdepth 1 -type d \
  -name '.snapshot-wizer.wasm.starling-componentize-*' -print -quit)"
test -n "$snapshot_root"
snapshot_storage="$snapshot_root/data"
mkdir "$SCRATCH/snapshot-wizer-saved"
mv "$snapshot_storage/wizer" "$SCRATCH/snapshot-wizer-saved/wizer"
mv "$snapshot_storage/engine.wasm" \
  "$SCRATCH/snapshot-wizer-saved/engine.wasm"
mv "$snapshot_storage/inputs/source" \
  "$snapshot_storage/inputs/source.saved"
mv "$snapshot_storage/initialized.wasm" \
  "$SCRATCH/snapshot-wizer-saved/initialized.wasm"
printf '#!/usr/bin/env bash\nexit 97\n' > "$snapshot_storage/wizer"
chmod +x "$snapshot_storage/wizer"
printf 'substituted-engine\n' > "$snapshot_storage/engine.wasm"
mkdir "$snapshot_storage/inputs/source"
printf 'export const substituted = true;\n' > \
  "$snapshot_storage/inputs/source/main.js"
ln -s "$SNAPSHOT_WIZER_EXTERNAL" "$snapshot_storage/initialized.wasm"
: > "$SNAPSHOT_WIZER_BARRIER.release"
wait_for_marker "$SNAPSHOT_WIZER_BARRIER.complete" \
  "$SNAPSHOT_TEST_PID" "Wizer snapshot completion"
test "$(cat "$SNAPSHOT_WIZER_EXTERNAL")" = "external-output"
rm -f "$snapshot_storage/wizer" "$snapshot_storage/engine.wasm" \
  "$snapshot_storage/initialized.wasm"
remove_tree "$snapshot_storage/inputs/source"
mv "$SCRATCH/snapshot-wizer-saved/wizer" "$snapshot_storage/wizer"
mv "$SCRATCH/snapshot-wizer-saved/engine.wasm" \
  "$snapshot_storage/engine.wasm"
mv "$snapshot_storage/inputs/source.saved" \
  "$snapshot_storage/inputs/source"
mv "$SCRATCH/snapshot-wizer-saved/initialized.wasm" \
  "$snapshot_storage/initialized.wasm"
: > "$SNAPSHOT_WIZER_BARRIER.verify"
wait "$SNAPSHOT_TEST_PID"
SNAPSHOT_TEST_PID=""
cmp "$ENGINE" "$SNAPSHOT_WIZER_OUTPUT"
python3 - "$SNAPSHOT_SOURCE" "$ENGINE" "$SNAPSHOT_WIZER_METADATA" <<'PY'
import hashlib, json, sys
digest = lambda path: hashlib.sha256(open(path, "rb").read()).hexdigest()
document = json.load(open(sys.argv[3], encoding="utf-8"))
inputs = document["provenance"]["inputs"]
assert inputs["source_sha256"] == digest(sys.argv[1]), inputs
assert inputs["engine_sha256"] == digest(sys.argv[2]), inputs
PY

SNAPSHOT_WASM_OUTPUT="$WORK/snapshot-wasm-tools.wasm"
SNAPSHOT_WASM_METADATA="$WORK/snapshot-wasm-tools.json"
SNAPSHOT_WASM_BARRIER="$SCRATCH/snapshot-wasm-tools"
SNAPSHOT_WASM_EXTERNAL="$SCRATCH/snapshot-wasm-tools-external"
printf 'external-output\n' > "$SNAPSHOT_WASM_EXTERNAL"
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_WASM_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE="wasm-tools component new" \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$SNAPSHOT_WASM_METADATA" \
  --out "$SNAPSHOT_WASM_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2>&1 &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SNAPSHOT_WASM_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "wasm-tools snapshot substitution"
snapshot_root="$(find "$WORK" -maxdepth 1 -type d \
  -name '.snapshot-wasm-tools.wasm.starling-componentize-*' -print -quit)"
snapshot_storage="$snapshot_root/data"
mkdir "$SCRATCH/snapshot-wasm-tools-saved"
for snapshot_name in wasm-tools preview2-adapter.wasm initialized.wasm \
  candidate.wasm
do
  mv "$snapshot_storage/$snapshot_name" \
    "$SCRATCH/snapshot-wasm-tools-saved/$snapshot_name"
done
printf '#!/usr/bin/env bash\nexit 97\n' > "$snapshot_storage/wasm-tools"
chmod +x "$snapshot_storage/wasm-tools"
printf 'substituted-adapter\n' > "$snapshot_storage/preview2-adapter.wasm"
printf 'substituted-initialized\n' > "$snapshot_storage/initialized.wasm"
ln -s "$SNAPSHOT_WASM_EXTERNAL" "$snapshot_storage/candidate.wasm"
: > "$SNAPSHOT_WASM_BARRIER.release"
wait_for_marker "$SNAPSHOT_WASM_BARRIER.complete" \
  "$SNAPSHOT_TEST_PID" "wasm-tools snapshot completion"
test "$(cat "$SNAPSHOT_WASM_EXTERNAL")" = "external-output"
rm -f "$snapshot_storage/wasm-tools" \
  "$snapshot_storage/preview2-adapter.wasm" \
  "$snapshot_storage/initialized.wasm" "$snapshot_storage/candidate.wasm"
for snapshot_name in wasm-tools preview2-adapter.wasm initialized.wasm \
  candidate.wasm
do
  mv "$SCRATCH/snapshot-wasm-tools-saved/$snapshot_name" \
    "$snapshot_storage/$snapshot_name"
done
: > "$SNAPSHOT_WASM_BARRIER.verify"
wait "$SNAPSHOT_TEST_PID"
SNAPSHOT_TEST_PID=""
cmp "$ENGINE" "$SNAPSHOT_WASM_OUTPUT"
python3 - "$ADAPTER" "$SNAPSHOT_WASM_METADATA" <<'PY'
import hashlib, json, sys
expected = hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()
document = json.load(open(sys.argv[2], encoding="utf-8"))
assert document["provenance"]["inputs"]["preview2_adapter_sha256"] == expected
PY

SNAPSHOT_WIT_OUTPUT="$WORK/snapshot-wit.wasm"
SNAPSHOT_WIT_DEBUG="$WORK/snapshot-wit.debug"
SNAPSHOT_WIT_BARRIER="$SCRATCH/snapshot-wit"
SNAPSHOT_WIT_EXTERNAL="$SCRATCH/snapshot-wit-external"
SNAPSHOT_WIT_LOG="$SCRATCH/snapshot-wit.log"
printf 'external-output\n' > "$SNAPSHOT_WIT_EXTERNAL"
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_WIT_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE="wabt component embed" \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$SNAPSHOT_WIT_DEBUG" \
  --out "$SNAPSHOT_WIT_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2> "$SNAPSHOT_WIT_LOG" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SNAPSHOT_WIT_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "WIT snapshot substitution"
snapshot_root="$(find "$WORK" -maxdepth 1 -type d \
  -name '.snapshot-wit.wasm.starling-componentize-*' -print -quit)"
snapshot_storage="$snapshot_root/data"
mkdir "$SCRATCH/snapshot-wit-saved"
mv "$snapshot_storage/wabt" "$SCRATCH/snapshot-wit-saved/wabt"
mv "$snapshot_storage/dispatch-wit" \
  "$snapshot_storage/dispatch-wit.saved"
mv "$snapshot_storage/stripped.wasm" \
  "$SCRATCH/snapshot-wit-saved/stripped.wasm"
mv "$snapshot_storage/embedded.wasm" \
  "$SCRATCH/snapshot-wit-saved/embedded.wasm"
printf '#!/usr/bin/env bash\nexit 97\n' > "$snapshot_storage/wabt"
chmod +x "$snapshot_storage/wabt"
mkdir "$snapshot_storage/dispatch-wit"
printf 'package test:substituted;\nworld substituted {}\n' > \
  "$snapshot_storage/dispatch-wit/world.wit"
printf 'substituted-stripped\n' > "$snapshot_storage/stripped.wasm"
ln -s "$SNAPSHOT_WIT_EXTERNAL" "$snapshot_storage/embedded.wasm"
: > "$SNAPSHOT_WIT_BARRIER.release"
wait_for_marker "$SNAPSHOT_WIT_BARRIER.complete" \
  "$SNAPSHOT_TEST_PID" "WIT snapshot completion"
test "$(cat "$SNAPSHOT_WIT_EXTERNAL")" = "external-output"
rm -f "$snapshot_storage/wabt" "$snapshot_storage/stripped.wasm" \
  "$snapshot_storage/embedded.wasm"
remove_tree "$snapshot_storage/dispatch-wit"
mv "$SCRATCH/snapshot-wit-saved/wabt" "$snapshot_storage/wabt"
mv "$snapshot_storage/dispatch-wit.saved" \
  "$snapshot_storage/dispatch-wit"
mv "$SCRATCH/snapshot-wit-saved/stripped.wasm" \
  "$snapshot_storage/stripped.wasm"
mv "$SCRATCH/snapshot-wit-saved/embedded.wasm" \
  "$snapshot_storage/embedded.wasm"
: > "$SNAPSHOT_WIT_BARRIER.verify"
if ! wait "$SNAPSHOT_TEST_PID"; then
  cat "$SNAPSHOT_WIT_LOG" >&2
  echo "FAIL: stable WIT snapshot run failed" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
cmp "$ENGINE" "$SNAPSHOT_WIT_OUTPUT"
python3 - "$WIT/world.wit" "$SNAPSHOT_WIT_DEBUG/metadata.json" <<'PY'
import hashlib, json, sys
hasher = hashlib.sha256()
hasher.update(b"world.wit\0")
hasher.update(open(sys.argv[1], "rb").read())
hasher.update(b"\xff")
document = json.load(open(sys.argv[2], encoding="utf-8"))
assert document["provenance"]["dispatch_world"]["wit_sha256"] == \
    hasher.hexdigest()
PY

SNAPSHOT_ZIG_CACHE="$SCRATCH/snapshot-zig-cache"
SNAPSHOT_ZIG_OUTPUT="$WORK/snapshot-zig.wasm"
SNAPSHOT_ZIG_METADATA="$WORK/snapshot-zig.json"
SNAPSHOT_ZIG_BARRIER="$SCRATCH/snapshot-zig"
SNAPSHOT_ZIG_EXTERNAL="$SCRATCH/snapshot-zig-external"
mkdir "$SNAPSHOT_ZIG_EXTERNAL"
printf 'external-prefix\n' > "$SNAPSHOT_ZIG_EXTERNAL/sentinel"
FAKE_ZIG_BARRIER="$SNAPSHOT_ZIG_BARRIER-child" \
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_ZIG_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE="zig build runtime" \
"$COMPONENTIZER" \
  --build-root "$ROOT" \
  --cache-dir "$SNAPSHOT_ZIG_CACHE" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$SNAPSHOT_ZIG_METADATA" \
  --out "$SNAPSHOT_ZIG_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2>&1 &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SNAPSHOT_ZIG_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "Zig snapshot substitution"
snapshot_root="$(find "$WORK" -maxdepth 1 -type d \
  -name '.snapshot-zig.wasm.starling-componentize-*' -print -quit)"
snapshot_storage="$snapshot_root/data"
mkdir "$SCRATCH/snapshot-zig-saved"
mv "$snapshot_storage/zig-install/bin/zig" \
  "$SCRATCH/snapshot-zig-saved/zig"
mv "$snapshot_storage/dispatch-wit" \
  "$snapshot_storage/dispatch-wit.saved"
mv "$snapshot_storage/runtime-prefix" \
  "$snapshot_storage/runtime-prefix.saved"
printf '#!/usr/bin/env bash\nexit 97\n' > \
  "$snapshot_storage/zig-install/bin/zig"
chmod +x "$snapshot_storage/zig-install/bin/zig"
mkdir "$snapshot_storage/dispatch-wit"
printf 'package test:substituted;\nworld substituted {}\n' > \
  "$snapshot_storage/dispatch-wit/world.wit"
ln -s "$SNAPSHOT_ZIG_EXTERNAL" "$snapshot_storage/runtime-prefix"
: > "$SNAPSHOT_ZIG_BARRIER.release"
wait_for_marker "$SNAPSHOT_ZIG_BARRIER-child.ready" \
  "$SNAPSHOT_TEST_PID" "stable Zig child"
: > "$SNAPSHOT_ZIG_BARRIER-child.release"
wait_for_marker "$SNAPSHOT_ZIG_BARRIER.complete" \
  "$SNAPSHOT_TEST_PID" "Zig snapshot completion"
test "$(cat "$SNAPSHOT_ZIG_EXTERNAL/sentinel")" = "external-prefix"
rm -f "$snapshot_storage/zig-install/bin/zig" \
  "$snapshot_storage/runtime-prefix"
remove_tree "$snapshot_storage/dispatch-wit"
mv "$SCRATCH/snapshot-zig-saved/zig" \
  "$snapshot_storage/zig-install/bin/zig"
mv "$snapshot_storage/dispatch-wit.saved" \
  "$snapshot_storage/dispatch-wit"
mv "$snapshot_storage/runtime-prefix.saved" \
  "$snapshot_storage/runtime-prefix"
: > "$SNAPSHOT_ZIG_BARRIER.verify"
wait "$SNAPSHOT_TEST_PID"
SNAPSHOT_TEST_PID=""
cmp "$ENGINE" "$SNAPSHOT_ZIG_OUTPUT"
python3 - "$TOOLS/fake zig" "$SNAPSHOT_ZIG_METADATA" <<'PY'
import hashlib, json, sys
expected = hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()
document = json.load(open(sys.argv[2], encoding="utf-8"))
tools = {tool["name"]: tool for tool in document["provenance"]["tools"]}
assert tools["zig"]["sha256"] == expected, tools["zig"]
PY

if find "$WORK" -type d -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: successful componentizations retained transaction storage" >&2
  exit 1
fi

echo "native componentizer fake-tool tests passed"
