#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <starling-componentize> <host-api>" >&2
  echo "usage: $0 <starling-componentize> <starling-aot-cache>" >&2
  exit 2
fi

COMPONENTIZER="$(realpath "$1")"
EXPECTED_HOST_API="$2"
CACHE_TOOL="$(realpath "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/.zig-cache/componentizer-test-scratch"
BARRIERS="$SCRATCH/test barriers"
TOOLS="$SCRATCH/fake tools"
WORK="$SCRATCH/work with spaces"
FAKE_BUILD_ROOT="$SCRATCH/fake native build root"
FAKE_HOST_API_DIR="$FAKE_BUILD_ROOT/host-apis/$EXPECTED_HOST_API"
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
mkdir -p "$TOOLS" "$WORK/wit package" "$FAKE_BUILD_ROOT/runtime" \
  "$BARRIERS" \
  "$SCRATCH/cache parent" \
  "$FAKE_BUILD_ROOT/tools/componentizer" \
  "$FAKE_HOST_API_DIR/preview1-adapter-release"
printf 'captured-build-root\n' > "$FAKE_BUILD_ROOT/build.zig"
touch "$FAKE_BUILD_ROOT/build.zig.zon" "$FAKE_BUILD_ROOT/runtime/js.cpp" \
  "$FAKE_BUILD_ROOT/tools/componentizer/main.zig"
printf 'adapter-bytes\n' > \
  "$FAKE_HOST_API_DIR/preview1-adapter-release/wasi_snapshot_preview1.wasm"
trap cleanup_scratch EXIT

if cmake -S "$ROOT" -B "$SCRATCH/cmake aot rejected" -DWEVAL=ON \
  >"$SCRATCH/cmake aot.log" 2>&1
then
  echo "FAIL: CMake accepted an unsealed WEVAL=ON build" >&2
  exit 1
fi
grep -Fq 'cannot produce the sealed, validated' "$SCRATCH/cmake aot.log"
grep -Fq 'AOT cache.' "$SCRATCH/cmake aot.log"
grep -Fq 'zig build -Doptimize=ReleaseSmall -Daot-engine=true' "$SCRATCH/cmake aot.log"

SOURCE="$WORK/source module.js"
ENGINE_BUNDLE="$WORK/default engine bundle"
ENGINE="$ENGINE_BUNDLE/fake engine.wasm"
ENGINE_BASE="$WORK/fake engine base.wasm"
ADAPTER="$ENGINE_BUNDLE/preview1-adapter.wasm"
WIT="$WORK/wit package"
mkdir -p "$ENGINE_BUNDLE"
printf 'export const api = {};\n' > "$SOURCE"
printf '\0asm\1\0\0\0\0\6\4seedA' > "$ENGINE_BASE"
python3 "$ROOT/tools/embed-engine-provenance.py" \
  "$ENGINE_BASE" "$ENGINE" "$(basename "$EXPECTED_HOST_API")" 11111 \
  exports exports
printf 'adapter-bytes\n' > "$ADAPTER"
cat > "$WIT/world.wit" <<'EOF'
package test:componentizer;
world exports {}
EOF
mkdir -p "$WORK/feature-wit" "$WORK/component-wit" "$WORK/surface-wit"
printf 'package test:feature; world feature {}\n' \
  > "$WORK/feature-wit/feature.wit"
cp "$WIT/world.wit" "$WORK/component-wit/world.wit"
cp "$WIT/world.wit" "$WORK/surface-wit/world.wit"
cat > "$WORK/features.json" <<EOF
{
  "host-api": "$(basename "$EXPECTED_HOST_API")",
  "component-world": "exports",
  "surface-world": "exports",
  "stdio": true,
  "random": true,
  "clocks": true,
  "http": true,
  "fetch-event": true
}
EOF
cp "$WORK/features.json" "$ENGINE_BUNDLE/features.json"
cp -a "$WORK/feature-wit" "$WORK/component-wit" "$WORK/surface-wit" \
  "$ENGINE_BUNDLE/"

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
if [ -n "${FAKE_ASSERT_PREOPEN_SNAPSHOT:-}" ]; then
  matched=0
  for arg in "$@"; do
    case "$arg" in
      *::"$FAKE_PREOPEN_GUEST")
        snapshot="${arg%%::*}"
        test "$snapshot" != "$FAKE_PREOPEN_GUEST"
        if [ ! -f "$snapshot/marker.txt" ]; then
          echo "retained preopen marker missing at $snapshot" >&2
          ls -la "$snapshot" >&2 || true
          exit 27
        fi
        if [ "$(cat "$snapshot/marker.txt")" != \
             "${FAKE_EXPECT_PREOPEN:-captured-preopen}" ]; then
          echo "retained preopen marker has substituted bytes" >&2
          exit 28
        fi
        matched=1
        ;;
    esac
  done
  test "$matched" -eq 1
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

cat > "$TOOLS/fake weval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -z "${STARLINGMONKEY_CONFIG+x}"
test "${RUST_MIN_STACK:-}" = "${EXPECTED_RUST_MIN_STACK:-8388608}"
test "$1" = "weval"
printf '%s\n' "$*" | grep -q -- '--cache-ro'
if printf '%s\n' "$*" | grep -Eq -- '(^| )--cache( |$)'; then
  echo "AOT componentization attempted to mutate its read-only cache" >&2
  exit 26
fi
printf '%s\0' "$@" > "$FAKE_AOT_ARGV_LOG"
cat > "$FAKE_AOT_RUNTIME_ARGS_LOG"
out=""
input=""
cache=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    -o)
      j=$((i + 1))
      out="${!j}"
      ;;
    -i)
      j=$((i + 1))
      input="${!j}"
      ;;
    --cache-ro)
      j=$((i + 1))
      cache="${!j}"
      ;;
  esac
done
if [ "${EXPECT_AOT_SNAPSHOT:-0}" = 1 ]; then
  test "$0" != "$ORIGINAL_AOT_WEVAL"
  test "$input" != "$ORIGINAL_AOT_ENGINE"
  test "$cache" != "$ORIGINAL_AOT_CACHE"
  test "$(dirname "$0")" = "$(dirname "$input")"
  test "$(dirname "$input")" = "$(dirname "$cache")"
  test "$(stat -c %a "$(dirname "$input")")" = 700
  printf 'replacement engine\n' > "$ORIGINAL_AOT_ENGINE"
  printf 'replacement cache\n' > "$ORIGINAL_AOT_CACHE"
  printf '# replaced after validation\n' > "$ORIGINAL_AOT_WEVAL"
  cmp "$input" "$EXPECTED_AOT_ENGINE"
  cmp "$cache" "$EXPECTED_AOT_CACHE"
fi
if [ "${FAKE_AOT_FAIL:-0}" = 1 ]; then
  exit 27
fi
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
if [ "$stage" = "component embed" ] &&
   [ -n "${FAKE_ASSERT_WIT_SNAPSHOT:-}" ]; then
  wit_index=$(($# - 1))
  wit="${!wit_index}"
  grep -Fq "world captured" "$wit/world.wit"
  ! grep -Fq "substituted" "$wit/world.wit"
fi
if [ "$stage" = "component compose" ]; then
  provider_count=0
  for arg in "$@"; do
    if [ "$arg" = "-d" ]; then
      provider_count=$((provider_count + 1))
    fi
  done
  test "$provider_count" -ge 1
  if [ -n "${FAKE_WABT_COMPOSE_COUNT_FILE:-}" ]; then
    count=0
    if [ -f "$FAKE_WABT_COMPOSE_COUNT_FILE" ]; then
      count="$(cat "$FAKE_WABT_COMPOSE_COUNT_FILE")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_WABT_COMPOSE_COUNT_FILE"
    if [ "$count" = "${FAKE_WABT_COMPOSE_BARRIER_CALL:-0}" ]; then
      : > "$FAKE_WABT_COMPOSE_BARRIER.ready"
      while [ ! -e "$FAKE_WABT_COMPOSE_BARRIER.release" ]; do
        sleep 0.001
      done
    fi
  fi
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
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ] || [ "${!i}" = "--output" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
if [ "${FAKE_FAIL_STAGE:-}" = "$1 $2" ]; then
  echo "injected $1 $2 failure" >&2
  exit 23
fi
if [ "$1" = "strip" ]; then
  cp "${!#}" "$out"
elif [ "$1 $2" = "component new" ]; then
  input=""
  for arg in "${@:3}"; do
    if [ -f "$arg" ] && [ "$arg" != "$out" ]; then
      input="$arg"
    fi
  done
  cp "$input" "$out"
elif [ "$1 $2" = "metadata add" ]; then
  out=""
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--output" ]; then
      j=$((i + 1))
      out="${!j}"
    fi
  done
  cp "${!#}" "$out"
elif [ "$1" = "print" ]; then
  if [ "${FAKE_CANDIDATE_WASI_IMPORT:-0}" = 1 ]; then
    cat > "$out" <<'WAT'
(component
  (import "wasi:random/insecure@0.2.0" (instance))
)
WAT
  else
    cat > "$out" <<'WAT'
(component)
WAT
  fi
elif [ "$1 $2" = "component wit" ]; then
  out_dir=""
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--out-dir" ]; then
      j=$((i + 1))
      out_dir="${!j}"
    fi
  done
  if [ -n "$out_dir" ]; then
    mkdir -p "$out_dir"
    out="$out_dir/custom-runtime.wit"
    if [ "${FAKE_MISSING_WIT_ROOT:-0}" = 1 ]; then
      exit 0
    fi
    if [ "${FAKE_PROVIDER_WIT:-0}" = 1 ]; then
      mkdir -p "$out_dir/deps"
      printf 'package wasi:http; type duration = u64;\n' \
        > "$out_dir/deps/http.wit"
      printf 'package wasi:sockets; type duration = u64;\n' \
        > "$out_dir/deps/sockets.wit"
    fi
    if [ "${FAKE_AMBIGUOUS_WIT:-0}" = 1 ]; then
      cat > "$out_dir/second-root.wit" <<'WIT'
package test:second;
world second {}
WIT
    fi
  fi
  if [ "${FAKE_MULTI_PROVIDER_WIT:-0}" = 1 ] && \
     [[ "$out" = *feature-0-provider-surface.wit ]]; then
    cat > "$out" <<'WIT'
package test:fake;
world fake {
  import wasi:random/insecure@0.2.0;
}
WIT
  elif [ "${FAKE_MULTI_PROVIDER_WIT:-0}" = 1 ] && \
       [[ "$out" = *feature-1-provider-surface.wit ]]; then
    cat > "$out" <<'WIT'
package test:fake;
world fake {
  import wasi:random/insecure-seed@0.2.0;
}
WIT
  elif [ "${FAKE_PROVIDER_WIT:-0}" = 1 ] && [[ "$out_dir" = *platform-wit* ]]; then
    cat > "$out" <<'WIT'
package test:fake;
world fake {
  import wasi:random/insecure@0.2.0;
}
WIT
  else
    cat > "$out" <<'WIT'
package test:fake;
world fake {}
WIT
  fi
elif [ "$1 $2" = "component embed" ]; then
  input="${!#}"
  if [ -f "$input" ] && [ "$input" != "$out" ]; then
    cp "$input" "$out"
  else
    printf 'dummy-core\n' > "$out"
  fi
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
if [ "${1:-}" = "version" ]; then
  printf '%s\n' "${FAKE_ZIG_VERSION:-0.17.0-dev.902+7255f3e72}"
  exit 0
fi
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
if [ -n "${FAKE_ASSERT_RETAINED_ADAPTER:-}" ]; then
  retained_adapter=""
  for arg in "$@"; do
    case "$arg" in
      -Dpreview1-adapter=*)
        retained_adapter="${arg#-Dpreview1-adapter=}"
        ;;
    esac
  done
  test -n "$retained_adapter"
  test "$(cat "$retained_adapter")" = "$FAKE_ASSERT_RETAINED_ADAPTER"
fi
if [ -n "${FAKE_ASSERT_DEREFERENCED_TARGET:-}" ]; then
  test "$(cat deps/sm-obj-zig/dist/include/js/Guarded.h)" = \
    "$FAKE_ASSERT_DEREFERENCED_TARGET"
fi
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
if [ -n "${FAKE_ASSERT_BUILD_SNAPSHOT:-}" ]; then
  test "$(cat build.zig)" = "captured-build-root"
  test "$(pwd -P)" != "$FAKE_BUILD_ROOT_GUEST"
fi
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
printf '%s\n' "$*" >> "$FAKE_ZIG_ARGS_LOG"
mkdir -p "$prefix/bin"
cp "$FAKE_ENGINE" "$prefix/bin/starling-raw.wasm"
if [ -z "${FAKE_OMIT_GENERATED_ADAPTER:-}" ]; then
  cp "$FAKE_ADAPTER" "$prefix/bin/preview1-adapter.wasm"
fi
mkdir -p "$prefix/bin/feature-wit" \
  "$prefix/bin/component-wit" \
  "$prefix/bin/surface-wit"
printf 'package test:feature; world feature {}\n' \
  > "$prefix/bin/feature-wit/feature.wit"
printf 'package test:component; world bindings {}\n' \
  > "$prefix/bin/component-wit/component.wit"
printf 'package test:surface; world caller {}\n' \
  > "$prefix/bin/surface-wit/caller.wit"
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

cat > "$TOOLS/fake wasmtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = wizer
shift
cat > "$FAKE_RUNTIME_ARGS_LOG"
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
cp "${!#}" "$out"
EOF
chmod +x "$TOOLS"/*
for tool in zig wizer wasmtime wabt wasm-tools weval; do
  ln -s "fake $tool" "$TOOLS/path-$tool"
done

WRAPPER_DIR="$SCRATCH/wrapper with spaces"
mkdir -p "$WRAPPER_DIR"
python3 - "$ROOT/componentize.sh.in" "$WRAPPER_DIR/componentize.sh" <<'PY'
import sys

data = open(sys.argv[1], encoding="utf-8").read()
replacements = {
    "@WASMTIME_DIR@": ".",
    "@WASM_TOOLS_BIN@": "wasm-tools",
    "@WEVAL_BIN@": "weval",
    "@COMPONENT_WORLD@": "",
    "@COMPONENT_WIT_DIR@": "component wit",
    "@AOT@": "1",
    "@AOT_DRIVER@": "native",
}
for old, new in replacements.items():
    data = data.replace(old, new)
open(sys.argv[2], "w", encoding="utf-8").write(data)
PY
cat > "$WRAPPER_DIR/starling-componentize" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$WRAPPER_LOG"
EOF
chmod +x "$WRAPPER_DIR/componentize.sh" "$WRAPPER_DIR/starling-componentize"
touch "$WRAPPER_DIR/starling-raw.wasm" "$WRAPPER_DIR/preview1-adapter.wasm"
export WRAPPER_LOG="$SCRATCH/wrapper args.bin"
PREOPEN_DIR="$WORK/preopen dir" "$WRAPPER_DIR/componentize.sh" \
  --output "$WORK/wrapper output.wasm" "$SOURCE"
python3 - "$WRAPPER_LOG" "$WORK/preopen dir" "$WORK/wrapper output.wasm" "$SOURCE" <<'PY'
import sys

args = open(sys.argv[1], "rb").read().split(b"\0")[:-1]
args = [arg.decode() for arg in args]
assert "--legacy-wrapper-preopen" in args
preopen = args.index("--preopen-dir")
assert args[preopen + 1] == sys.argv[2]
assert args[-3:] == ["--output", sys.argv[3], sys.argv[4]]
PY
WASM_TOOLS=path-wasm-tools WABT=path-wabt WEVAL=path-weval \
  "$WRAPPER_DIR/componentize.sh" --output "$WORK/wrapper path output.wasm" "$SOURCE"
python3 - "$WRAPPER_LOG" <<'PY'
import sys

args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert args[args.index("--wasm-tools-bin") + 1] == "path-wasm-tools"
assert args[args.index("--wabt-bin") + 1] == "path-wabt"
assert args[args.index("--weval-bin") + 1] == "path-weval"
PY
"$WRAPPER_DIR/componentize.sh" "$SOURCE" "$WORK/positional output.wasm"
python3 - "$WRAPPER_LOG" "$SOURCE" "$WORK/positional output.wasm" <<'PY'
import sys
args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert "--legacy-wrapper-preopen" in args
assert args[-2:] == sys.argv[2:]
PY
"$WRAPPER_DIR/componentize.sh" --output "$WORK/runtime only.wasm"
python3 - "$WRAPPER_LOG" "$WORK/runtime only.wasm" <<'PY'
import sys
args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert "--legacy-wrapper-preopen" in args
assert args[-2:] == ["--output", sys.argv[2]]
PY

export FAKE_RUNTIME_ARGS_LOG="$SCRATCH/runtime args.log"
export FAKE_WIZER_ARGS_LOG="$SCRATCH/wizer args.log"
export FAKE_AOT_RUNTIME_ARGS_LOG="$SCRATCH/aot runtime args.log"
export FAKE_AOT_ARGV_LOG="$SCRATCH/aot argv.bin"
export FAKE_ENGINE="$ENGINE"
export FAKE_ADAPTER="$ADAPTER"
export FAKE_ZIG_PREFIX_LOG="$SCRATCH/zig prefixes.log"
export FAKE_ZIG_ENV_LOG="$SCRATCH/zig env.log"
export FAKE_BINDINGS="$SCRATCH/component-bindings.zig"
export FAKE_WASIP3_BINDGEN="$TOOLS/fake wasip3-bindgen"
export FAKE_WASM_OPT="$TOOLS/fake wasm-opt"
export FAKE_ZIG_LIB_DIR="$SCRATCH/fake zig direct/lib"
export FAKE_ZIG_ARGS_LOG="$SCRATCH/zig args.log"
export WABT="$TOOLS/fake wabt"
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
EXPECTED_ZIG_GLOBAL_CACHE="${ZIG_GLOBAL_CACHE_DIR:-}"

PATH_OVERRIDE_OUTPUT="$WORK/path override output.wasm"
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin path-wizer \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$PATH_OVERRIDE_OUTPUT" \
  "$SOURCE"
cmp "$ENGINE" "$PATH_OVERRIDE_OUTPUT"

PATH_ENV_OUTPUT="$WORK/path environment output.wasm"
env PATH="$TOOLS:$PATH" \
  WIZER_BIN=path-wizer WABT=path-wabt WASM_TOOLS_BIN=path-wasm-tools \
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --out "$PATH_ENV_OUTPUT" \
    "$SOURCE"
cmp "$ENGINE" "$PATH_ENV_OUTPUT"

PATH_WASMTIME_OUTPUT="$WORK/path wasmtime output.wasm"
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wasmtime-bin path-wasmtime \
  --wasm-tools-bin path-wasm-tools \
  --out "$PATH_WASMTIME_OUTPUT" \
  "$SOURCE"
cmp "$ENGINE" "$PATH_WASMTIME_OUTPUT"

PATH_WASMTIME_ENV_OUTPUT="$WORK/path wasmtime environment output.wasm"
env PATH="$TOOLS:$PATH" \
  WASMTIME_BIN=path-wasmtime WASM_TOOLS_BIN=path-wasm-tools \
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --out "$PATH_WASMTIME_ENV_OUTPUT" \
    "$SOURCE"
cmp "$ENGINE" "$PATH_WASMTIME_ENV_OUTPUT"

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
assert [feature["name"] for feature in metadata["provenance"]["features"]] == [
    "stdio", "random", "clocks", "http", "fetch-event",
]
assert all(feature["enabled"] for feature in metadata["provenance"]["features"])
assert len(metadata["provenance"]["features_sha256"]) == 64
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
FAKE_PROVIDER_WIT=1 \
FAKE_CANDIDATE_WASI_IMPORT=1 \
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

make_engine_bundle() {
  local name="$1" tuple="$2"
  local bundle="$WORK/$name engine bundle"
  mkdir -p "$bundle"
  cp "$ADAPTER" "$bundle/preview1-adapter.wasm"
  cp -a "$WORK/component-wit" "$WORK/surface-wit" "$bundle/"
  printf 'package test:surface; world caller {}\n' \
    > "$bundle/surface-wit/world.wit"
  mkdir -p "$bundle/feature-wit"
  printf 'package test:feature; world feature {}\n' \
    > "$bundle/feature-wit/feature.wit"
  python3 "$ROOT/tools/embed-engine-provenance.py" \
    "$ENGINE_BASE" "$bundle/starling-raw.wasm" \
    "$(basename "$EXPECTED_HOST_API")" "$tuple" bindings caller
  local stdio="${tuple:0:1}" random="${tuple:1:1}" clocks="${tuple:2:1}"
  local http="${tuple:3:1}" fetch_event="${tuple:4:1}"
  cat > "$bundle/features.json" <<EOF
{
  "host-api": "$(basename "$EXPECTED_HOST_API")",
  "component-world": "bindings",
  "surface-world": "caller",
  "stdio": $([ "$stdio" = 1 ] && echo true || echo false),
  "random": $([ "$random" = 1 ] && echo true || echo false),
  "clocks": $([ "$clocks" = 1 ] && echo true || echo false),
  "http": $([ "$http" = 1 ] && echo true || echo false),
  "fetch-event": $([ "$fetch_event" = 1 ] && echo true || echo false),
  "future-compatible-field": {"ignored": true}
}
EOF
  printf '%s\n' "$bundle"
}

componentize_external_engine() {
  local engine="$1" output="$2"
  local diagnostics=()
  if [ "${JSON_DIAGNOSTICS:-0}" = 1 ]; then
    diagnostics+=(--json-diagnostics)
  fi
  "$COMPONENTIZER" \
    "${diagnostics[@]}" \
    --engine "$engine" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$output" \
    "$SOURCE"
}

assert_json_diagnostic() {
  local path="$1" code="$2" phase="$3" cause="$4" detail="$5"
  python3 - "$path" "$code" "$phase" "$cause" "$detail" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == sys.argv[2], diagnostic
assert diagnostic["phase"] == sys.argv[3], diagnostic
assert diagnostic["cause"] == sys.argv[4], diagnostic
if sys.argv[5]:
    assert sys.argv[5] in diagnostic["detail"], diagnostic
PY
}

assert_external_json_diagnostic() {
  assert_json_diagnostic "$1" SMC1001 inputs "$2" "$3"
}

PURE_ENGINE_DIR="$(make_engine_bundle pure 00000)"
MIXED_ENGINE_DIR="$(make_engine_bundle mixed 01001)"
PURE_EXTERNAL_METADATA="$WORK/pure external metadata.json"
MIXED_EXTERNAL_METADATA="$WORK/mixed external metadata.json"
"$COMPONENTIZER" \
  --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$PURE_EXTERNAL_METADATA" \
  --out "$WORK/pure engine output.wasm" \
  "$SOURCE"
"$COMPONENTIZER" \
  --engine "$MIXED_ENGINE_DIR/starling-raw.wasm" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$MIXED_EXTERNAL_METADATA" \
  --out "$WORK/mixed engine output.wasm" \
  "$SOURCE"
python3 - "$PURE_EXTERNAL_METADATA" "$MIXED_EXTERNAL_METADATA" \
  "$PURE_ENGINE_DIR/component-wit/world.wit" \
  "$PURE_ENGINE_DIR/surface-wit/world.wit" <<'PY'
import hashlib, json, sys

def wit_digest(path):
    digest = hashlib.sha256()
    digest.update(b"world.wit\0")
    digest.update(open(path, "rb").read())
    digest.update(b"\xff")
    return digest.hexdigest()

pure, mixed = [json.load(open(path, encoding="utf-8"))
               for path in sys.argv[1:3]]
component_digest = wit_digest(sys.argv[3])
surface_digest = wit_digest(sys.argv[4])
for document, enabled in ((pure, [False] * 5),
                          (mixed, [False, True, False, False, True])):
    provenance = document["provenance"]
    assert provenance["dispatch_world"] == {
        "name": "caller", "wit_sha256": surface_digest,
    }, provenance
    assert provenance["component_world"] == {
        "name": "bindings", "wit_sha256": component_digest,
    }, provenance
    assert [feature["enabled"] for feature in provenance["features"]] == enabled
PY

"$COMPONENTIZER" \
  --engine "$MIXED_ENGINE_DIR/starling-raw.wasm" \
  --preview2-adapter "$MIXED_ENGINE_DIR/preview1-adapter.wasm" \
  --wit "$MIXED_ENGINE_DIR/surface-wit" \
  --world-name caller \
  --component-wit "$MIXED_ENGINE_DIR/component-wit" \
  --component-world-name bindings \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/agreed external overrides.wasm" \
  "$SOURCE"
cmp "$MIXED_ENGINE_DIR/starling-raw.wasm" \
  "$WORK/agreed external overrides.wasm"

for required_asset in \
  features.json \
  preview1-adapter.wasm \
  component-wit \
  surface-wit \
  feature-wit
do
  incomplete_bundle="$WORK/missing ${required_asset//\\//-} engine bundle"
  incomplete_error="$WORK/missing ${required_asset//\\//-}.jsonl"
  cp -a "$PURE_ENGINE_DIR" "$incomplete_bundle"
  rm -rf "$incomplete_bundle/$required_asset"
  if "$COMPONENTIZER" \
      --json-diagnostics \
      --engine "$incomplete_bundle/starling-raw.wasm" \
      --preview2-adapter "$ADAPTER" \
      --wit "$WIT" \
      --world-name exports \
      --wizer-bin "$TOOLS/fake wizer" \
      --wabt-bin "$TOOLS/fake wabt" \
      --wasm-tools-bin "$TOOLS/fake wasm-tools" \
      --out "$WORK/missing ${required_asset//\\//-}.wasm" \
      "$SOURCE" >/dev/null 2>"$incomplete_error"
  then
    echo "FAIL: external engine missing $required_asset succeeded via overrides" >&2
    exit 1
  fi
  case "$required_asset" in
    features.json)
      missing_detail="requires sibling features.json"
      ;;
    *)
      missing_detail="requires sibling $required_asset"
      ;;
  esac
  assert_external_json_diagnostic \
    "$incomplete_error" InputChanged "$missing_detail"
done

MISMATCHED_OVERRIDE_WIT="$WORK/mismatched override wit"
mkdir "$MISMATCHED_OVERRIDE_WIT"
printf 'package test:mismatch; world mismatch {}\n' \
  > "$MISMATCHED_OVERRIDE_WIT/world.wit"
INCOMPATIBLE_OVERRIDE_ERROR="$WORK/incompatible external overrides.jsonl"
if "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
    --wit "$MISMATCHED_OVERRIDE_WIT" \
    --world-name caller \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$WORK/incompatible external overrides.wasm" \
    "$SOURCE" >/dev/null 2>"$INCOMPATIBLE_OVERRIDE_ERROR"
then
  echo "FAIL: incompatible external engine package overrides succeeded" >&2
  exit 1
fi
assert_external_json_diagnostic "$INCOMPATIBLE_OVERRIDE_ERROR" \
  IncompatibleEngineOptions \
  "--wit does not match the external engine package"

INCOMPATIBLE_WORLD_ERROR="$WORK/incompatible external world.jsonl"
if "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
    --wit "$PURE_ENGINE_DIR/surface-wit" \
    --world-name wrong-world \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$WORK/incompatible external world.wasm" \
    "$SOURCE" >/dev/null 2>"$INCOMPATIBLE_WORLD_ERROR"
then
  echo "FAIL: incompatible external engine world succeeded" >&2
  exit 1
fi
assert_external_json_diagnostic "$INCOMPATIBLE_WORLD_ERROR" \
  IncompatibleEngineOptions \
  "--world-name does not match external engine surface provenance"

for generated_stage in \
  feature-target-core \
  feature-target-component \
  feature-provider-core \
  feature-provider-component
do
  for generated_mutation in inplace replace-restore; do
    generated_label="$generated_stage-$generated_mutation"
    GENERATED_RACE_OUTPUT="$WORK/generated-$generated_label.wasm"
    GENERATED_RACE_ERROR="$SCRATCH/generated-$generated_label.jsonl"
    GENERATED_RACE_BARRIER="$BARRIERS/generated-$generated_label"
    printf 'old-generated-output-%s\n' "$generated_label" \
      > "$GENERATED_RACE_OUTPUT"
    generated_environment=()
    case "$generated_stage" in
      feature-provider-*)
        generated_environment+=(FAKE_PROVIDER_WIT=1)
        ;;
    esac
    env \
      STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$GENERATED_RACE_BARRIER" \
      STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE="$generated_stage" \
      "${generated_environment[@]}" \
      "$COMPONENTIZER" \
        --json-diagnostics \
        --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
        --wizer-bin "$TOOLS/fake wizer" \
        --wabt-bin "$TOOLS/fake wabt" \
        --wasm-tools-bin "$TOOLS/fake wasm-tools" \
        --out "$GENERATED_RACE_OUTPUT" \
        "$SOURCE" >/dev/null 2>"$GENERATED_RACE_ERROR" &
    generated_race_pid=$!
    wait_for_marker "$GENERATED_RACE_BARRIER.ready" "$generated_race_pid" \
      "$generated_mutation $generated_stage race"
    generated_transaction="$(find "$WORK" -maxdepth 1 -type d \
      -name ".generated-$generated_label.wasm.starling-componentize-*" \
      -print -quit)"
    test -n "$generated_transaction"
    generated_target="$(find "$generated_transaction/data" -maxdepth 1 \
      -type f -name 'feature-surface-input-*' -print | sort -V | tail -1)"
    test -f "$generated_target"
    if [ "$generated_mutation" = inplace ]; then
      chmod u+w "$generated_target"
      printf 'mutated-generated-%s\n' "$generated_stage" \
        > "$generated_target"
    else
      generated_saved="$SCRATCH/generated-saved-$generated_stage"
      mv "$generated_target" "$generated_saved"
      printf 'mutated-generated-%s\n' "$generated_stage" \
        > "$generated_target"
      rm "$generated_target"
      mv "$generated_saved" "$generated_target"
    fi
    : > "$GENERATED_RACE_BARRIER.release"
    if wait "$generated_race_pid"; then
      echo "FAIL: $generated_mutation $generated_stage race succeeded" >&2
      exit 1
    fi
    python3 - "$GENERATED_RACE_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC4201", diagnostic
assert diagnostic["phase"] == "adapt", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
    test "$(cat "$GENERATED_RACE_OUTPUT")" = \
      "old-generated-output-$generated_label"
    if find "$WORK" -maxdepth 1 -type d \
      -name ".generated-$generated_label.wasm.starling-componentize-*" \
      | grep -q .; then
      echo "FAIL: $generated_label race retained a transaction" >&2
      exit 1
    fi
    rm -f "$GENERATED_RACE_OUTPUT" "$GENERATED_RACE_ERROR" \
      "$GENERATED_RACE_BARRIER.ready" "$GENERATED_RACE_BARRIER.release"
  done
done

for feature_mutation in inplace replace-restore; do
  FEATURE_RACE_OUTPUT="$WORK/feature input $feature_mutation.wasm"
  FEATURE_RACE_ERROR="$SCRATCH/feature-input-$feature_mutation.jsonl"
  FEATURE_RACE_BARRIER="$BARRIERS/feature-input-$feature_mutation"
  printf 'old-feature-output-%s\n' "$feature_mutation" > \
    "$FEATURE_RACE_OUTPUT"
  STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$FEATURE_RACE_BARRIER" \
  STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=feature-target-surface \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$FEATURE_RACE_OUTPUT" \
    "$SOURCE" >/dev/null 2>"$FEATURE_RACE_ERROR" &
  feature_race_pid=$!
  wait_for_marker "$FEATURE_RACE_BARRIER.ready" "$feature_race_pid" \
    "$feature_mutation generated feature input race"
  feature_transaction="$(find "$WORK" -maxdepth 1 -type d \
    -name ".feature input $feature_mutation.wasm.starling-componentize-*" \
    -print -quit)"
  test -n "$feature_transaction"
  feature_target="$feature_transaction/data/feature-surface-input-0"
  test -f "$feature_target"
  if [ "$feature_mutation" = inplace ]; then
    chmod u+w "$feature_target"
    printf 'package raced:surface; world raced {}\n' > "$feature_target"
  else
    feature_saved="$SCRATCH/feature-target-saved.wit"
    mv "$feature_target" "$feature_saved"
    printf 'package raced:surface; world raced {}\n' > "$feature_target"
    rm "$feature_target"
    mv "$feature_saved" "$feature_target"
  fi
  : > "$FEATURE_RACE_BARRIER.release"
  if wait "$feature_race_pid"; then
    echo "FAIL: $feature_mutation generated feature input race succeeded" >&2
    exit 1
  fi
  python3 - "$FEATURE_RACE_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC4201", diagnostic
assert diagnostic["phase"] == "adapt", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
  test "$(cat "$FEATURE_RACE_OUTPUT")" = \
    "old-feature-output-$feature_mutation"
  if find "$WORK" -maxdepth 1 -type d \
    -name ".feature input $feature_mutation.wasm.starling-componentize-*" \
    | grep -q .; then
    echo "FAIL: $feature_mutation feature race retained a transaction" >&2
    exit 1
  fi
  rm -f "$FEATURE_RACE_OUTPUT" "$FEATURE_RACE_ERROR" \
    "$FEATURE_RACE_BARRIER.ready" "$FEATURE_RACE_BARRIER.release"
done

for provider_mutation in inplace replace-restore; do
  PROVIDER_RACE_OUTPUT="$WORK/provider input $provider_mutation.wasm"
  PROVIDER_RACE_ERROR="$SCRATCH/provider-input-$provider_mutation.jsonl"
  PROVIDER_RACE_BARRIER="$BARRIERS/provider-input-$provider_mutation"
  printf 'old-provider-output-%s\n' "$provider_mutation" > \
    "$PROVIDER_RACE_OUTPUT"
  STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$PROVIDER_RACE_BARRIER" \
  STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=feature-provider-wit-rendered \
  FAKE_PROVIDER_WIT=1 \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$PROVIDER_RACE_OUTPUT" \
    "$SOURCE" >/dev/null 2>"$PROVIDER_RACE_ERROR" &
  provider_race_pid=$!
  wait_for_marker "$PROVIDER_RACE_BARRIER.ready" "$provider_race_pid" \
    "$provider_mutation generated provider WIT race"
  provider_transaction="$(find "$WORK" -maxdepth 1 -type d \
    -name ".provider input $provider_mutation.wasm.starling-componentize-*" \
    -print -quit)"
  test -n "$provider_transaction"
  provider_tree="$(find "$provider_transaction/data" -maxdepth 1 -type d \
    -name 'feature-surface-input-*' -print | sort -V | tail -1)"
  test -n "$provider_tree"
  provider_root="$(find "$provider_tree" -maxdepth 1 -type f -name '*.wit' \
    -print -quit)"
  test -f "$provider_root"
  if [ "$provider_mutation" = inplace ]; then
    chmod u+w "$provider_root"
    printf 'package raced:provider; world raced {}\n' > "$provider_root"
  else
    provider_saved="$SCRATCH/provider-root-saved.wit"
    chmod u+w "$provider_tree"
    mv "$provider_root" "$provider_saved"
    printf 'package raced:provider; world raced {}\n' \
      > "$provider_root"
    rm "$provider_root"
    mv "$provider_saved" "$provider_root"
  fi
  : > "$PROVIDER_RACE_BARRIER.release"
  if wait "$provider_race_pid"; then
    echo "FAIL: $provider_mutation generated provider WIT race succeeded" >&2
    exit 1
  fi
  python3 - "$PROVIDER_RACE_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC4201", diagnostic
assert diagnostic["phase"] == "adapt", diagnostic
assert diagnostic["cause"] == "TransactionChanged", diagnostic
PY
  test "$(cat "$PROVIDER_RACE_OUTPUT")" = \
    "old-provider-output-$provider_mutation"
  if find "$WORK" -maxdepth 1 -type d \
    -name ".provider input $provider_mutation.wasm.starling-componentize-*" \
    | grep -q .; then
    echo "FAIL: $provider_mutation provider race retained a transaction" >&2
    exit 1
  fi
  rm -f "$PROVIDER_RACE_OUTPUT" "$PROVIDER_RACE_ERROR" \
    "$PROVIDER_RACE_BARRIER.ready" "$PROVIDER_RACE_BARRIER.release"
done

for partial_index in 0 1; do
  for partial_mutation in inplace replace-restore; do
    partial_label="$partial_index-$partial_mutation"
    PARTIAL_RACE_OUTPUT="$WORK/partial input $partial_label.wasm"
    PARTIAL_RACE_ERROR="$SCRATCH/partial-input-$partial_label.jsonl"
    PARTIAL_RACE_BARRIER="$BARRIERS/partial-input-$partial_label"
    PARTIAL_COMPOSE_COUNT="$SCRATCH/partial-compose-count-$partial_label"
    printf 'old-partial-output-%s\n' "$partial_label" \
      > "$PARTIAL_RACE_OUTPUT"
    FAKE_PROVIDER_WIT=1 \
    FAKE_MULTI_PROVIDER_WIT=1 \
    FAKE_WABT_COMPOSE_COUNT_FILE="$PARTIAL_COMPOSE_COUNT" \
    FAKE_WABT_COMPOSE_BARRIER_CALL="$((partial_index + 2))" \
    FAKE_WABT_COMPOSE_BARRIER="$PARTIAL_RACE_BARRIER" \
    "$COMPONENTIZER" \
      --json-diagnostics \
      --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
      --wizer-bin "$TOOLS/fake wizer" \
      --wabt-bin "$TOOLS/fake wabt" \
      --wasm-tools-bin "$TOOLS/fake wasm-tools" \
      --out "$PARTIAL_RACE_OUTPUT" \
      "$SOURCE" >/dev/null 2>"$PARTIAL_RACE_ERROR" &
    partial_race_pid=$!
    wait_for_marker "$PARTIAL_RACE_BARRIER.ready" "$partial_race_pid" \
      "$partial_mutation partial $partial_index consumer race"
    partial_transaction="$(find "$WORK" -maxdepth 1 -type d \
      -name ".partial input $partial_label.wasm.starling-componentize-*" \
      -print -quit)"
    test -n "$partial_transaction"
    partial_target="$(find "$partial_transaction/data" -maxdepth 1 \
      -type f -name 'feature-surface-input-*' -print | sort -V | tail -1)"
    test -f "$partial_target"
    if [ "$partial_mutation" = inplace ]; then
      chmod u+w "$partial_target"
      printf 'mutated-partial-%s\n' "$partial_index" > "$partial_target"
    else
      partial_saved="$SCRATCH/partial-saved-$partial_label"
      mv "$partial_target" "$partial_saved"
      printf 'mutated-partial-%s\n' "$partial_index" > "$partial_target"
      rm "$partial_target"
      mv "$partial_saved" "$partial_target"
    fi
    : > "$PARTIAL_RACE_BARRIER.release"
    if wait "$partial_race_pid"; then
      echo "FAIL: $partial_mutation partial $partial_index race succeeded" >&2
      exit 1
    fi
    assert_json_diagnostic "$PARTIAL_RACE_ERROR" SMC4201 adapt \
      TransactionChanged ""
    test "$(cat "$PARTIAL_RACE_OUTPUT")" = \
      "old-partial-output-$partial_label"
    if find "$WORK" -maxdepth 1 -type d \
      -name ".partial input $partial_label.wasm.starling-componentize-*" \
      | grep -q .; then
      echo "FAIL: partial $partial_label race retained a transaction" >&2
      exit 1
    fi
    rm -f "$PARTIAL_RACE_OUTPUT" "$PARTIAL_RACE_ERROR" \
      "$PARTIAL_RACE_BARRIER.ready" "$PARTIAL_RACE_BARRIER.release" \
      "$PARTIAL_COMPOSE_COUNT"
  done
done

MISSING_ENGINE_DIR="$WORK/missing provenance engine bundle"
mkdir -p "$MISSING_ENGINE_DIR/feature-wit"
printf '\0asm\1\0\0\0' > "$MISSING_ENGINE_DIR/starling-raw.wasm"
cp "$WORK/features.json" "$MISSING_ENGINE_DIR/features.json"
if JSON_DIAGNOSTICS=1 componentize_external_engine \
    "$MISSING_ENGINE_DIR/starling-raw.wasm" "$WORK/missing provenance.wasm" \
    >"$WORK/missing provenance.out" 2>"$WORK/missing provenance.err"
then
  echo "FAIL: engine without provenance unexpectedly succeeded" >&2
  exit 1
fi
assert_external_json_diagnostic "$WORK/missing provenance.err" \
  MissingEngineProvenance \
  "missing embedded feature/host provenance"

TAMPERED_ENGINE_DIR="$WORK/tampered provenance engine bundle"
cp -a "$PURE_ENGINE_DIR" "$TAMPERED_ENGINE_DIR"
python3 - "$TAMPERED_ENGINE_DIR/starling-raw.wasm" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[15] ^= 1
path.write_bytes(data)
PY
if JSON_DIAGNOSTICS=1 componentize_external_engine \
    "$TAMPERED_ENGINE_DIR/starling-raw.wasm" "$WORK/tampered provenance.wasm" \
    >"$WORK/tampered provenance.out" 2>"$WORK/tampered provenance.err"
then
  echo "FAIL: engine with tampered bytes unexpectedly succeeded" >&2
  exit 1
fi
assert_external_json_diagnostic "$WORK/tampered provenance.err" \
  EngineProvenanceMismatch \
  "provenance digest does not match"

MISMATCH_ENGINE_DIR="$WORK/mismatched provenance engine bundle"
cp -a "$PURE_ENGINE_DIR" "$MISMATCH_ENGINE_DIR"
sed -i 's/"random": false/"random": true/' \
  "$MISMATCH_ENGINE_DIR/features.json"
if JSON_DIAGNOSTICS=1 componentize_external_engine \
    "$MISMATCH_ENGINE_DIR/starling-raw.wasm" "$WORK/mismatched provenance.wasm" \
    >"$WORK/mismatched provenance.out" 2>"$WORK/mismatched provenance.err"
then
  echo "FAIL: mismatched sibling provenance unexpectedly succeeded" >&2
  exit 1
fi
assert_external_json_diagnostic "$WORK/mismatched provenance.err" \
  EngineProvenanceMismatch \
  "does not match sibling features.json"

if FAKE_AMBIGUOUS_WIT=1 JSON_DIAGNOSTICS=1 componentize_external_engine \
    "$ENGINE" "$WORK/ambiguous generated WIT.wasm" \
    >"$WORK/ambiguous WIT.out" 2>"$WORK/ambiguous WIT.jsonl"
then
  echo "FAIL: ambiguous generated root WIT unexpectedly succeeded" >&2
  exit 1
fi
assert_json_diagnostic "$WORK/ambiguous WIT.jsonl" SMC4201 adapt \
  AmbiguousGeneratedWitRoot "generated WIT has multiple root packages"
test ! -e "$WORK/ambiguous generated WIT.wasm"

if FAKE_MISSING_WIT_ROOT=1 JSON_DIAGNOSTICS=1 componentize_external_engine \
    "$ENGINE" "$WORK/missing generated WIT.wasm" \
    >"$WORK/missing WIT.out" 2>"$WORK/missing WIT.jsonl"
then
  echo "FAIL: missing generated root WIT unexpectedly succeeded" >&2
  exit 1
fi
assert_json_diagnostic "$WORK/missing WIT.jsonl" SMC4201 adapt \
  MissingGeneratedWitRoot "generated WIT has no root package"
test ! -e "$WORK/missing generated WIT.wasm"

POSITIONAL_OUTPUT="$WORK/positional native output.wasm"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  "$SOURCE" \
  "$POSITIONAL_OUTPUT"
cmp "$ENGINE" "$POSITIONAL_OUTPUT"

AOT_BUNDLE="$WORK/aot cache bundle"
AOT_OUTPUT="$WORK/aot output component.wasm"
mkdir -p "$AOT_BUNDLE"
python3 - "$AOT_BUNDLE/starling-ics.wevalcache" "$ENGINE" <<'PY'
import hashlib
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("""create table weval_cache(
    module_hash blob not null,
    key blob not null,
    result blob not null,
    created_time integer not null
)""")
db.execute("create index idx on weval_cache(module_hash, key)")
with open(sys.argv[2], "rb") as engine:
    engine_hash = hashlib.sha256(engine.read()).digest()
db.execute("insert into weval_cache values (?, ?, ?, 0)", (engine_hash, b"key", b"result"))
db.commit()
db.close()
PY
"$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$TOOLS/fake weval" \
  --cache "$AOT_BUNDLE/starling-ics.wevalcache" \
  --primer "$SOURCE" \
  --feature-abi 'starling-features-v1;fake=1' \
  --out "$AOT_BUNDLE/starling-ics.wevalcache.manifest"
"$CACHE_TOOL" validate \
  --engine "$ENGINE" \
  --weval "$TOOLS/fake weval" \
  --cache "$AOT_BUNDLE/starling-ics.wevalcache" \
  --manifest "$AOT_BUNDLE/starling-ics.wevalcache.manifest" \
  --feature-abi 'starling-features-v1;fake=1'

expect_seal_failure() {
  local cache="$1" label="$2"
  if "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$TOOLS/fake weval" \
    --cache "$cache" \
    --primer "$SOURCE" \
    --feature-abi 'starling-features-v1;fake=1' \
    --out "$WORK/$label.manifest"
  then
    echo "FAIL: $label cache unexpectedly sealed" >&2
    exit 1
  fi
  test ! -e "$WORK/$label.manifest"
}

MALFORMED_SCHEMA_CACHE="$WORK/malformed schema.sqlite"
DECOY_CACHE="$WORK/decoy digest.sqlite"
python3 - "$MALFORMED_SCHEMA_CACHE" "$DECOY_CACHE" "$ENGINE" <<'PY'
import hashlib
import sqlite3
import sys

with open(sys.argv[3], "rb") as engine:
    engine_hash = hashlib.sha256(engine.read()).digest()

malformed = sqlite3.connect(sys.argv[1])
malformed.execute(
    "create table weval_cache(module_hash blob, key blob, result blob, created_time integer)"
)
malformed.execute(
    "insert into weval_cache values (?, ?, ?, 0)",
    (engine_hash, b"key", b"result"),
)
malformed.commit()
malformed.close()

decoy = sqlite3.connect(sys.argv[2])
decoy.execute("""create table weval_cache(
    module_hash blob not null,
    key blob not null,
    result blob not null,
    created_time integer not null
)""")
decoy.execute("create index idx on weval_cache(module_hash, key)")
decoy.execute(
    "insert into weval_cache values (?, ?, ?, 0)",
    (b"x" * 32, b"key", b"result"),
)
decoy.execute("create table digest_decoy(value blob not null)")
decoy.execute("insert into digest_decoy values (?)", (engine_hash,))
decoy.commit()
decoy.close()
PY
expect_seal_failure "$MALFORMED_SCHEMA_CACHE" malformed-schema
expect_seal_failure "$DECOY_CACHE" no-live-engine-row

EXTRA_INDEX_CACHE="$WORK/extra index.sqlite"
cp "$AOT_BUNDLE/starling-ics.wevalcache" "$EXTRA_INDEX_CACHE"
python3 - "$EXTRA_INDEX_CACHE" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("create index idx_extra on weval_cache(created_time)")
db.commit()
db.close()
PY
expect_seal_failure "$EXTRA_INDEX_CACHE" extra-index

INTEGRITY_CACHE="$WORK/integrity corrupt.sqlite"
cp "$AOT_BUNDLE/starling-ics.wevalcache" "$INTEGRITY_CACHE"
python3 - "$INTEGRITY_CACHE" <<'PY'
import sys
with open(sys.argv[1], "r+b") as cache:
    cache.seek(100)
    byte = cache.read(1)
    cache.seek(100)
    cache.write(bytes([byte[0] ^ 0xff]))
PY
expect_seal_failure "$INTEGRITY_CACHE" integrity-corrupt

RUNTIME_ONLY_OUTPUT="$WORK/runtime only output.wasm"
rm -f "$FAKE_AOT_RUNTIME_ARGS_LOG"
"$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --weval-bin "$TOOLS/fake weval" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --output "$RUNTIME_ONLY_OUTPUT"
cmp "$ENGINE" "$RUNTIME_ONLY_OUTPUT"
test -e "$FAKE_AOT_RUNTIME_ARGS_LOG"
test ! -s "$FAKE_AOT_RUNTIME_ARGS_LOG"
python3 - "$FAKE_AOT_ARGV_LOG" <<'PY'
import sys

args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert args[args.index("--init-func") + 1] == "starling-aot-runtime-initialize"
PY

export EXPECTED_RUST_MIN_STACK=123456
PATH="$TOOLS:$PATH" RUST_MIN_STACK=999 "$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --aot-min-stack-size "$EXPECTED_RUST_MIN_STACK" \
  --weval-bin path-weval \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$AOT_OUTPUT" \
  "$SOURCE"
cmp "$ENGINE" "$AOT_OUTPUT"
grep -Fq -- "\"$SOURCE\"" "$FAKE_AOT_RUNTIME_ARGS_LOG"

LEGACY_PREOPEN="$SCRATCH/legacy preopen"
LEGACY_PREOPEN_OUTPUT="$WORK/legacy preopen output.wasm"
mkdir -p "$LEGACY_PREOPEN"
export EXPECTED_RUST_MIN_STACK=8388608
env PATH="$TOOLS:$PATH" \
  WEVAL_BIN=path-weval WABT=path-wabt WASM_TOOLS_BIN=path-wasm-tools \
  "$COMPONENTIZER" \
  --aot \
  --legacy-wrapper-preopen \
  --preopen-dir "$LEGACY_PREOPEN" \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --out "$LEGACY_PREOPEN_OUTPUT" \
  "$SOURCE"
python3 - "$FAKE_AOT_ARGV_LOG" "$LEGACY_PREOPEN" <<'PY'
import sys
args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
preopens = [args[index + 1] for index, arg in enumerate(args) if arg == "--dir"]
assert preopens == [sys.argv[2]], preopens
PY

DIRECT_CACHE_OUTPUT="$WORK/direct cache output.wasm"
"$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE/starling-ics.wevalcache" \
  --weval-bin "$TOOLS/fake weval" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$DIRECT_CACHE_OUTPUT" \
  "$SOURCE"
cmp "$ENGINE" "$DIRECT_CACHE_OUTPUT"

RACE_ENGINE="$WORK/race engine.wasm"
RACE_WEVAL="$TOOLS/race weval"
RACE_BUNDLE="$WORK/race cache bundle"
RACE_ENGINE_BASELINE="$WORK/race engine baseline.wasm"
RACE_CACHE_BASELINE="$WORK/race cache baseline.sqlite"
RACE_OUTPUT="$WORK/race output component.wasm"
cp "$ENGINE" "$RACE_ENGINE"
cp "$TOOLS/fake weval" "$RACE_WEVAL"
cp -R "$AOT_BUNDLE" "$RACE_BUNDLE"
cp "$RACE_ENGINE" "$RACE_ENGINE_BASELINE"
cp "$RACE_BUNDLE/starling-ics.wevalcache" "$RACE_CACHE_BASELINE"
EXPECT_AOT_SNAPSHOT=1 \
ORIGINAL_AOT_ENGINE="$RACE_ENGINE" \
ORIGINAL_AOT_CACHE="$RACE_BUNDLE/starling-ics.wevalcache" \
ORIGINAL_AOT_WEVAL="$RACE_WEVAL" \
EXPECTED_AOT_ENGINE="$RACE_ENGINE_BASELINE" \
EXPECTED_AOT_CACHE="$RACE_CACHE_BASELINE" \
"$COMPONENTIZER" \
  --aot \
  --engine "$RACE_ENGINE" \
  --aot-cache-dir "$RACE_BUNDLE" \
  --weval-bin "$RACE_WEVAL" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$RACE_OUTPUT" \
  "$SOURCE"
cmp "$RACE_ENGINE_BASELINE" "$RACE_OUTPUT"
test "$(cat "$RACE_ENGINE")" = "replacement engine"
test "$(cat "$RACE_BUNDLE/starling-ics.wevalcache")" = "replacement cache"

AOT_FAILURE_OUTPUT="$WORK/aot failure output.wasm"
printf 'preserved-aot-output\n' > "$AOT_FAILURE_OUTPUT"
if FAKE_AOT_FAIL=1 "$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --weval-bin "$TOOLS/fake weval" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$AOT_FAILURE_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: injected AOT failure unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$AOT_FAILURE_OUTPUT")" = "preserved-aot-output"
if find "$WORK" -maxdepth 1 -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: AOT componentization left private transaction artifacts" >&2
  exit 1
fi

expect_aot_cache_failure() {
  local bundle="$1" engine="$2" weval="$3" label="$4"
  local failure_output="$WORK/$label output.wasm"
  printf 'preserved\n' > "$failure_output"
  if "$COMPONENTIZER" \
    --aot \
    --engine "$engine" \
    --aot-cache-dir "$bundle" \
    --weval-bin "$weval" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$failure_output" \
    "$SOURCE"
  then
    echo "FAIL: $label AOT cache unexpectedly succeeded" >&2
    exit 1
  fi
  test "$(cat "$failure_output")" = "preserved"
}

expect_aot_cache_failure "$WORK/missing bundle" "$ENGINE" "$TOOLS/fake weval" missing

STALE_ENGINE="$WORK/stale engine.wasm"
cp "$ENGINE" "$STALE_ENGINE"
printf 'stale\n' >> "$STALE_ENGINE"
expect_aot_cache_failure "$AOT_BUNDLE" "$STALE_ENGINE" "$TOOLS/fake weval" stale

CORRUPT_BUNDLE="$WORK/corrupt cache bundle"
cp -R "$AOT_BUNDLE" "$CORRUPT_BUNDLE"
printf 'corrupt\n' >> "$CORRUPT_BUNDLE/starling-ics.wevalcache"
expect_aot_cache_failure "$CORRUPT_BUNDLE" "$ENGINE" "$TOOLS/fake weval" corrupt

STALE_WEVAL="$TOOLS/stale weval"
cp "$TOOLS/fake weval" "$STALE_WEVAL"
printf '# stale tool\n' >> "$STALE_WEVAL"
expect_aot_cache_failure "$AOT_BUNDLE" "$ENGINE" "$STALE_WEVAL" stale-tool

INVALID_BUNDLE="$WORK/invalid manifest bundle"
cp -R "$AOT_BUNDLE" "$INVALID_BUNDLE"
printf 'not-a-manifest\n' > "$INVALID_BUNDLE/starling-ics.wevalcache.manifest"
expect_aot_cache_failure "$INVALID_BUNDLE" "$ENGINE" "$TOOLS/fake weval" invalid-manifest
unset EXPECTED_RUST_MIN_STACK

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
ln -s "$TOOLS/fake wizer" "$SYMLINK_INPUT_DIR/wizer link"
ln -s "$TOOLS/fake wabt" "$SYMLINK_INPUT_DIR/wabt link"
ln -s "$TOOLS/fake wasm-tools" "$SYMLINK_INPUT_DIR/wasm-tools link"
"$COMPONENTIZER" \
  --engine "$SYMLINK_INPUT_DIR/engine link.wasm" \
  --preview2-adapter "$ADAPTER" \
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
RACED_BARRIER="$BARRIERS/raced-source-capture"
python3 - "$RACED_SOURCE" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as source:
    source.write("// immutable input race padding\n" * 500000)
    source.write("export const raced = true;\n")
PY
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$RACED_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=source \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/raced source.wasm" \
  "$RACED_SOURCE" >/dev/null 2> "$RACED_ERROR" &
SOURCE_COMPONENTIZER_PID=$!
python3 - "$RACED_SOURCE" "$RACED_ORIGINAL" \
  "$SOURCE_COMPONENTIZER_PID" "$RACED_BARRIER" <<'PY' &
import os, sys, time
source, original, componentizer, barrier = sys.argv[1:]
componentizer = int(componentizer)
deadline = time.monotonic() + 30
while not os.path.exists(barrier + ".ready"):
    if time.monotonic() >= deadline:
        raise SystemExit("timed out waiting for raced-source capture")
    try:
        os.kill(componentizer, 0)
    except ProcessLookupError:
        raise SystemExit("componentizer exited before raced-source transaction")
    time.sleep(0.0001)
os.rename(source, original)
with open(source, "w", encoding="utf-8") as replacement:
    replacement.write("export const replacement = true;\n")
open(barrier + ".release", "w", encoding="utf-8").close()
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

COMPOSE_DIAGNOSTIC="$SCRATCH/component-compose.diagnostic.jsonl"
if FAKE_PROVIDER_WIT=1 FAKE_FAIL_STAGE="component compose" \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$PURE_ENGINE_DIR/starling-raw.wasm" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$WORK/component compose failure.wasm" \
    "$SOURCE" >/dev/null 2>"$COMPOSE_DIAGNOSTIC"
then
  echo "FAIL: injected WABT compose failure unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$COMPOSE_DIAGNOSTIC" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC4201", diagnostic
assert diagnostic["phase"] == "adapt", diagnostic
assert diagnostic["cause"] == "CommandFailed", diagnostic
assert diagnostic["command"] == "feature surface: compose provider", diagnostic
assert diagnostic["exit_code"] == 23, diagnostic
PY

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
    --build-root "$FAKE_BUILD_ROOT" \
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
  --build-root "$FAKE_BUILD_ROOT" \
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
PUBLICATION_SAVED="$SCRATCH/publication-link-original"
PUBLICATION_RESTORED_OUTPUT="$PUBLICATION_A/restored-safe.wasm"
PUBLICATION_RESTORED_METADATA="$PUBLICATION_A/restored-safe.json"
PUBLICATION_RESTORED_DEBUG="$PUBLICATION_A/restored-safe.debug"
PUBLICATION_ATTACKER_OUTPUT="$PUBLICATION_B/restored-safe.wasm"
PUBLICATION_ATTACKER_METADATA="$PUBLICATION_B/restored-safe.json"
PUBLICATION_ATTACKER_DEBUG="$PUBLICATION_B/restored-safe.debug"
PUBLICATION_RESTORED_LOG="$SCRATCH/publication-restored.jsonl"
PUBLICATION_RESTORED_BARRIER="$BARRIERS/publication-restored"
printf 'old-output\n' > "$PUBLICATION_RESTORED_OUTPUT"
printf 'old-metadata\n' > "$PUBLICATION_RESTORED_METADATA"
mkdir "$PUBLICATION_RESTORED_DEBUG" "$PUBLICATION_ATTACKER_DEBUG"
printf 'old-debug\n' > "$PUBLICATION_RESTORED_DEBUG/unrelated.txt"
printf 'attacker-output\n' > "$PUBLICATION_ATTACKER_OUTPUT"
printf 'attacker-metadata\n' > "$PUBLICATION_ATTACKER_METADATA"
printf 'attacker-debug\n' > "$PUBLICATION_ATTACKER_DEBUG/unrelated.txt"
STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_BARRIER="$PUBLICATION_RESTORED_BARRIER" \
STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_STAGE=output-parent \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$PUBLICATION_LINK/restored-safe.json" \
  --debug-dir "$PUBLICATION_LINK/restored-safe.debug" \
  --out "$PUBLICATION_LINK/restored-safe.wasm" \
  "$SOURCE" 2> "$PUBLICATION_RESTORED_LOG" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$PUBLICATION_RESTORED_BARRIER.before_read.ready" \
  "$SNAPSHOT_TEST_PID" "publication selection before read"
mv "$PUBLICATION_LINK" "$PUBLICATION_SAVED"
ln -s "$PUBLICATION_B" "$PUBLICATION_LINK"
: > "$PUBLICATION_RESTORED_BARRIER.before_read.release"
wait_for_marker "$PUBLICATION_RESTORED_BARRIER.after_read.ready" \
  "$SNAPSHOT_TEST_PID" "publication selection after read"
rm "$PUBLICATION_LINK"
mv "$PUBLICATION_SAVED" "$PUBLICATION_LINK"
: > "$PUBLICATION_RESTORED_BARRIER.after_read.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: restored publication substitution was accepted" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
test "$(cat "$PUBLICATION_RESTORED_OUTPUT")" = "old-output"
test "$(cat "$PUBLICATION_RESTORED_METADATA")" = "old-metadata"
test "$(cat "$PUBLICATION_RESTORED_DEBUG/unrelated.txt")" = "old-debug"
test ! -e "$PUBLICATION_RESTORED_DEBUG/commands.txt"
test "$(cat "$PUBLICATION_ATTACKER_OUTPUT")" = "attacker-output"
test "$(cat "$PUBLICATION_ATTACKER_METADATA")" = "attacker-metadata"
test "$(cat "$PUBLICATION_ATTACKER_DEBUG/unrelated.txt")" = "attacker-debug"
test ! -e "$PUBLICATION_ATTACKER_DEBUG/commands.txt"
python3 - "$PUBLICATION_RESTORED_LOG" "$PUBLICATION_RESTORED_OUTPUT" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "PublicationDirectoryChanged", diagnostic
PY

RETARGET_HUMAN_LOG="$SCRATCH/retarget-human.log"
if FAKE_RETARGET_PARENT_LINK="$PUBLICATION_LINK" \
  FAKE_RETARGET_PARENT_TARGET="$PUBLICATION_B" \
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$PUBLICATION_LINK/retarget-safe.wasm" \
    "$SOURCE" 2> "$RETARGET_HUMAN_LOG"
then
  echo "FAIL: unrestored publication retarget succeeded" >&2
  exit 1
fi
test "$(readlink "$PUBLICATION_LINK")" = "$PUBLICATION_B"
test ! -e "$PUBLICATION_A/retarget-safe.wasm"
test ! -e "$PUBLICATION_B/retarget-safe.wasm"
grep -Fq "error[SMC7001] publish:" "$RETARGET_HUMAN_LOG"
grep -Fq "(PublicationDirectoryChanged)" "$RETARGET_HUMAN_LOG"
test "$(cat "$PUBLICATION_A/unrelated")" = "unrelated-a"
test "$(cat "$PUBLICATION_B/unrelated")" = "unrelated-b"

rm "$PUBLICATION_LINK"
ln -s "$PUBLICATION_A" "$PUBLICATION_LINK"
RETARGET_JSON_LOG="$SCRATCH/retarget-json.log"
if FAKE_RETARGET_PARENT_LINK="$PUBLICATION_LINK" \
  FAKE_RETARGET_PARENT_TARGET="$PUBLICATION_B" \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wizer-bin "$TOOLS/fake wizer" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$PUBLICATION_LINK/retarget-json.wasm" \
    "$SOURCE" 2> "$RETARGET_JSON_LOG"
then
  echo "FAIL: unrestored JSON publication retarget succeeded" >&2
  exit 1
fi
test ! -e "$PUBLICATION_A/retarget-json.wasm"
test ! -e "$PUBLICATION_B/retarget-json.wasm"
python3 - "$RETARGET_JSON_LOG" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC7001", diagnostic
assert diagnostic["phase"] == "publish", diagnostic
assert diagnostic["cause"] == "PublicationDirectoryChanged", diagnostic
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
    commit_barrier="$BARRIERS/commit-$commit_slug-barrier"
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
  mutation_barrier="$BARRIERS/mutation-$mutation_artifact-barrier"
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
CONCURRENT_BUNDLE_ENGINE_A_DIR="$SCRATCH/concurrent-engine-a"
CONCURRENT_BUNDLE_ENGINE_B_DIR="$SCRATCH/concurrent-engine-b"
CONCURRENT_BUNDLE_ENGINE_A="$CONCURRENT_BUNDLE_ENGINE_A_DIR/starling-raw.wasm"
CONCURRENT_BUNDLE_ENGINE_B="$CONCURRENT_BUNDLE_ENGINE_B_DIR/starling-raw.wasm"
CONCURRENT_BUNDLE_LOG_A="$SCRATCH/concurrent-bundle-a.jsonl"
CONCURRENT_BUNDLE_LOG_B="$SCRATCH/concurrent-bundle-b.jsonl"
CONCURRENT_BUNDLE_BARRIER_A="$SCRATCH/concurrent-bundle-a-lock"
CONCURRENT_BUNDLE_BARRIER_B="$SCRATCH/concurrent-bundle-b-lock"
for engine_dir in \
  "$CONCURRENT_BUNDLE_ENGINE_A_DIR" "$CONCURRENT_BUNDLE_ENGINE_B_DIR"; do
  mkdir -p "$engine_dir"
  cp "$ADAPTER" "$engine_dir/preview1-adapter.wasm"
  cp -a "$WORK/component-wit" "$WORK/surface-wit" "$WORK/feature-wit" \
    "$engine_dir/"
  cp "$WORK/features.json" "$engine_dir/features.json"
done
printf '\0asm\1\0\0\0\0\6\4seedA' > "$SCRATCH/concurrent-engine-a-base.wasm"
printf '\0asm\1\0\0\0\0\6\4seedB' > "$SCRATCH/concurrent-engine-b-base.wasm"
python3 "$ROOT/tools/embed-engine-provenance.py" \
  "$SCRATCH/concurrent-engine-a-base.wasm" "$CONCURRENT_BUNDLE_ENGINE_A" \
  "$(basename "$EXPECTED_HOST_API")" 11111 exports exports
python3 "$ROOT/tools/embed-engine-provenance.py" \
  "$SCRATCH/concurrent-engine-b-base.wasm" "$CONCURRENT_BUNDLE_ENGINE_B" \
  "$(basename "$EXPECTED_HOST_API")" 11111 exports exports
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

PREOPEN_ROOT="$SCRATCH/preopen caller tree"
PREOPEN_SAVED="$SCRATCH/preopen caller tree saved"
PREOPEN_OUTPUT="$WORK/preopen snapshot.wasm"
PREOPEN_METADATA="$WORK/preopen snapshot.json"
PREOPEN_BARRIER="$BARRIERS/preopen-snapshot"
PREOPEN_LOG="$SCRATCH/preopen-snapshot.log"
mkdir "$PREOPEN_ROOT"
printf 'captured-preopen\n' > "$PREOPEN_ROOT/marker.txt"
FAKE_ASSERT_PREOPEN_SNAPSHOT=1 \
FAKE_PREOPEN_GUEST="$PREOPEN_ROOT" \
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$PREOPEN_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE=wizer \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preopen-dir "$PREOPEN_ROOT" \
  --metadata-out "$PREOPEN_METADATA" \
  --out "$PREOPEN_OUTPUT" \
  "$SOURCE" >/dev/null 2> "$PREOPEN_LOG" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$PREOPEN_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "preopen snapshot substitution"
mv "$PREOPEN_ROOT" "$PREOPEN_SAVED"
mkdir "$PREOPEN_ROOT"
printf 'substituted-preopen\n' > "$PREOPEN_ROOT/marker.txt"
: > "$PREOPEN_BARRIER.release"
wait_for_marker "$PREOPEN_BARRIER.complete" "$SNAPSHOT_TEST_PID" \
  "preopen snapshot completion"
: > "$PREOPEN_BARRIER.verify"
if ! wait "$SNAPSHOT_TEST_PID"; then
  cat "$PREOPEN_LOG" >&2
  cat "$FAKE_WIZER_ARGS_LOG" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
cmp "$ENGINE" "$PREOPEN_OUTPUT"
python3 - "$PREOPEN_METADATA" <<'PY'
import json, re, sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
trees = metadata["provenance"]["inputs"]["preopen_trees"]
assert len(trees) == 1, trees
assert re.fullmatch(r"[0-9a-f]{64}", trees[0]["sha256"]), trees
PY
remove_tree "$PREOPEN_ROOT"
mv "$PREOPEN_SAVED" "$PREOPEN_ROOT"
PREOPEN_FIRST_DIGEST="$(python3 - "$PREOPEN_METADATA" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))
      ["provenance"]["inputs"]["preopen_trees"][0]["sha256"])
PY
)"
printf 'changed-preopen\n' > "$PREOPEN_ROOT/marker.txt"
FAKE_ASSERT_PREOPEN_SNAPSHOT=1 \
FAKE_EXPECT_PREOPEN=changed-preopen \
FAKE_PREOPEN_GUEST="$PREOPEN_ROOT" \
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preopen-dir "$PREOPEN_ROOT" \
  --metadata-out "$PREOPEN_METADATA" \
  --out "$PREOPEN_OUTPUT" \
  "$SOURCE" >/dev/null
PREOPEN_SECOND_DIGEST="$(python3 - "$PREOPEN_METADATA" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))
      ["provenance"]["inputs"]["preopen_trees"][0]["sha256"])
PY
)"
test "$PREOPEN_FIRST_DIGEST" != "$PREOPEN_SECOND_DIGEST"

CACHE="$SCRATCH/cache parent/runtime cache"
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
    --build-root "$FAKE_BUILD_ROOT" \
    --cache-dir "$CACHE" \
    --zig-bin "$zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --preview2-adapter "$ADAPTER" \
    "$@" \
    --out "$output" \
    "$BUILD_SOURCE"
}
build_with_fake_zig() {
  local output="$1"
  shift
  build_with_selected_zig "$TOOLS/fake zig" "$output" "$@"
}

run_retained_cache_selection_race() {
  local kind="$1"
  local root="$SCRATCH/explicit cache $kind selection"
  local link="$root/cache link"
  local saved="$root/original link"
  local original_cache attacker_cache configured_cache
  mkdir "$root"
  if [ "$kind" = symlink ]; then
    original_cache="$root/original cache"
    attacker_cache="$root/attacker cache"
    mkdir "$original_cache" "$attacker_cache"
    ln -s "$original_cache" "$link"
    configured_cache="$link"
  elif [ "$kind" = ancestor ]; then
    local original_parent="$root/original parent"
    local attacker_parent="$root/attacker parent"
    original_cache="$original_parent/cache"
    attacker_cache="$attacker_parent/cache"
    mkdir -p "$original_cache" "$attacker_cache"
    ln -s "$original_parent" "$link"
    configured_cache="$link/cache"
  else
    echo "FAIL: unknown explicit cache race $kind" >&2
    exit 1
  fi
  printf 'attacker-cache\n' > "$attacker_cache/sentinel"
  local barrier="$BARRIERS/explicit-cache-$kind"
  local error="$SCRATCH/explicit-cache-$kind.jsonl"
  local output="$WORK/explicit cache $kind.wasm"
  printf 'preserved-cache-%s-output\n' "$kind" > "$output"
  STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_BARRIER="$barrier" \
  STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_STAGE=cache \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --build-root "$FAKE_BUILD_ROOT" \
    --cache-dir "$configured_cache" \
    --zig-bin "$TOOLS/fake zig" \
  local output="$1" zig_bin="${2:-$TOOLS/fake zig}"
  "$COMPONENTIZER" \
    --build-root "$ROOT" \
    --cache-dir "$CACHE" \
    --zig-bin "$zig_bin" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --preview2-adapter "$ADAPTER" \
    --out "$output" \
    "$BUILD_SOURCE" 2> "$error" &
  SNAPSHOT_TEST_PID=$!
  wait_for_marker "$barrier.before_read.ready" "$SNAPSHOT_TEST_PID" \
    "explicit cache $kind selection before read"
  mv "$link" "$saved"
  if [ "$kind" = symlink ]; then
    ln -s "$attacker_cache" "$link"
  else
    ln -s "$(dirname "$attacker_cache")" "$link"
  fi
  : > "$barrier.before_read.release"
  wait_for_marker "$barrier.after_read.ready" "$SNAPSHOT_TEST_PID" \
    "explicit cache $kind selection after read"
  rm "$link"
  mv "$saved" "$link"
  : > "$barrier.after_read.release"
  if wait "$SNAPSHOT_TEST_PID"; then
    echo "FAIL: restored explicit cache $kind substitution was accepted" >&2
    exit 1
  fi
  SNAPSHOT_TEST_PID=""
  test "$(cat "$output")" = "preserved-cache-$kind-output"
  test -z "$(find "$original_cache" -mindepth 1 -print -quit)"
  test "$(cat "$attacker_cache/sentinel")" = "attacker-cache"
  if find "$attacker_cache" -mindepth 1 ! -name sentinel | grep -q .; then
    echo "FAIL: explicit cache $kind race wrote through attacker path" >&2
    exit 1
  fi
  python3 - "$error" "$output" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "CacheDirectoryChanged", diagnostic
PY
}

run_retained_cache_selection_race symlink
run_retained_cache_selection_race ancestor

run_retained_input_symlink_race() {
  local stage="$1"
  local link_dir="$SCRATCH/$stage retained input"
  local link="$link_dir/input link"
  local saved="$link_dir/original link"
  local attacker="$link_dir/attacker input"
  local marker="$link_dir/attacker-executed"
  local barrier="$BARRIERS/$stage-input-symlink"
  local error="$SCRATCH/$stage-input-symlink.jsonl"
  local output="$WORK/$stage input preserved.wasm"
  local metadata="$WORK/$stage input preserved.json"
  local debug="$WORK/$stage input preserved.debug"
  local original
  case "$stage" in
    engine) original="$ENGINE" ;;
    wizer) original="$TOOLS/fake wizer" ;;
    wasm-tools) original="$TOOLS/fake wasm-tools" ;;
    wabt) original="$TOOLS/fake wabt" ;;
    zig) original="$TOOLS/fake zig" ;;
    *) echo "FAIL: unknown retained input stage $stage" >&2; exit 1 ;;
  esac
  mkdir "$link_dir" "$debug"
  ln -s "$original" "$link"
  if [ "$stage" = engine ]; then
    printf 'substituted-engine\n' > "$attacker"
  else
    cat > "$attacker" <<EOF
#!/usr/bin/env bash
printf 'executed\n' > "$marker"
exit 99
EOF
    chmod +x "$attacker"
  fi
  printf '%s-output\n' "$stage" > "$output"
  printf '%s-metadata\n' "$stage" > "$metadata"
  printf '%s-debug\n' "$stage" > "$debug/unrelated.txt"

  local engine="$ENGINE"
  local wizer="$TOOLS/fake wizer"
  local wasm_tools="$TOOLS/fake wasm-tools"
  local wabt="$TOOLS/fake wabt"
  [ "$stage" = engine ] && engine="$link"
  [ "$stage" = wizer ] && wizer="$link"
  [ "$stage" = wasm-tools ] && wasm_tools="$link"
  [ "$stage" = wabt ] && wabt="$link"
  local command=(
    "$COMPONENTIZER"
    --json-diagnostics
    --wit "$WIT"
    --world-name exports
    --wizer-bin "$wizer"
    --wabt-bin "$wabt"
    --wasm-tools-bin "$wasm_tools"
    --preview2-adapter "$ADAPTER"
    --metadata-out "$metadata"
    --debug-dir "$debug"
    --out "$output"
  )
  if [ "$stage" = zig ]; then
    command+=(
      --build-root "$FAKE_BUILD_ROOT"
      --cache-dir "$WORK/$stage retained input cache"
      --zig-bin "$link"
      "$BUILD_SOURCE"
    )
  else
    command+=(--engine "$engine" "$SOURCE")
  fi

  STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_BARRIER="$barrier" \
  STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_STAGE="$stage" \
    "${command[@]}" 2> "$error" &
  SNAPSHOT_TEST_PID=$!
  wait_for_marker "$barrier.before_read.ready" "$SNAPSHOT_TEST_PID" \
    "$stage retained symlink before read"
  mv "$link" "$saved"
  ln -s "$attacker" "$link"
  : > "$barrier.before_read.release"
  wait_for_marker "$barrier.after_read.ready" "$SNAPSHOT_TEST_PID" \
    "$stage retained symlink after read"
  rm "$link"
  mv "$saved" "$link"
  : > "$barrier.after_read.release"
  if wait "$SNAPSHOT_TEST_PID"; then
    echo "FAIL: restored $stage symlink substitution was accepted" >&2
    exit 1
  fi
  SNAPSHOT_TEST_PID=""
  python3 - "$error" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
  test ! -e "$marker"
  test "$(cat "$output")" = "$stage-output"
  test "$(cat "$metadata")" = "$stage-metadata"
  test "$(cat "$debug/unrelated.txt")" = "$stage-debug"
}

run_retained_input_symlink_race engine
run_retained_input_symlink_race wizer
run_retained_input_symlink_race wasm-tools
run_retained_input_symlink_race wabt
run_retained_input_symlink_race zig

run_retained_directory_selection_race() {
  local stage="$1"
  local root="$SCRATCH/$stage directory selection"
  local link="$root/input link"
  local saved="$root/original link"
  local attacker="$root/attacker"
  local barrier="$BARRIERS/$stage-directory-selection"
  local error="$SCRATCH/$stage-directory-selection.jsonl"
  local output="$WORK/$stage directory selection.wasm"
  local metadata="$WORK/$stage directory selection.json"
  local debug="$WORK/$stage directory selection.debug"
  local source="$SOURCE"
  local initializer_args=()
  local preopen_args=()
  local build_root="$FAKE_BUILD_ROOT"
  local wit="$WIT"
  local target
  mkdir "$root" "$debug"
  case "$stage" in
    source)
      target="$root/original.js"
      printf 'export const originalSource = true;\n' > "$target"
      printf 'export const attackerSource = true;\n' > "$attacker"
      source="$link"
      ;;
    initializer)
      target="$root/original-initializer.js"
      printf 'globalThis.originalInitializer = true;\n' > "$target"
      printf 'globalThis.attackerInitializer = true;\n' > "$attacker"
      initializer_args=(--initializer-script-path "$link")
      ;;
    build-root)
      target="$FAKE_BUILD_ROOT"
      mkdir "$attacker"
      build_root="$link"
      ;;
    preopen)
      target="$root/original-preopen"
      mkdir "$target" "$attacker"
      printf 'original-preopen\n' > "$target/value.txt"
      printf 'attacker-preopen\n' > "$attacker/value.txt"
      preopen_args=(--preopen-dir "$link")
      ;;
    zig-lib)
      target="$FAKE_ZIG_LIB_DIR"
      mkdir "$attacker"
      printf 'attacker-zig-lib\n' > "$attacker/std.zig"
      ;;
    wit)
      target="$WIT"
      mkdir "$attacker"
      cat > "$attacker/world.wit" <<'EOF'
package attacker:componentizer;
world exports {}
EOF
      wit="$link"
      ;;
    *) echo "FAIL: unknown retained directory stage $stage" >&2; exit 1 ;;
  esac
  ln -s "$target" "$link"
  printf 'preserved-%s-output\n' "$stage" > "$output"
  printf 'preserved-%s-metadata\n' "$stage" > "$metadata"
  printf 'preserved-%s-debug\n' "$stage" > "$debug/unrelated.txt"
  local before_wizer=0
  if [ -e "$FAKE_WIZER_ARGS_LOG" ]; then
    before_wizer="$(wc -l < "$FAKE_WIZER_ARGS_LOG")"
  fi

  local command=(
    "$COMPONENTIZER"
    --json-diagnostics
    --wit "$wit"
    --world-name exports
    --wizer-bin "$TOOLS/fake wizer"
    --wabt-bin "$TOOLS/fake wabt"
    --wasm-tools-bin "$TOOLS/fake wasm-tools"
    --preview2-adapter "$ADAPTER"
    --metadata-out "$metadata"
    --debug-dir "$debug"
    --out "$output"
    "${initializer_args[@]}"
    "${preopen_args[@]}"
  )
  if [ "$stage" = build-root ] || [ "$stage" = zig-lib ]; then
    command+=(
      --build-root "$build_root"
      --cache-dir "$CACHE"
      --zig-bin "$TOOLS/fake zig"
      "$source"
    )
  else
    command+=(--engine "$ENGINE" "$source")
  fi
  local environment=(
    env
    "STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_BARRIER=$barrier"
    "STARLING_COMPONENTIZER_TEST_INPUT_SYMLINK_STAGE=$stage"
  )
  if [ "$stage" = zig-lib ]; then
    environment+=("ZIG_LIB_DIR=$link")
  fi
  "${environment[@]}" "${command[@]}" 2> "$error" &
  SNAPSHOT_TEST_PID=$!
  wait_for_marker "$barrier.before_read.ready" "$SNAPSHOT_TEST_PID" \
    "$stage directory selection before read"
  mv "$link" "$saved"
  ln -s "$attacker" "$link"
  : > "$barrier.before_read.release"
  wait_for_marker "$barrier.after_read.ready" "$SNAPSHOT_TEST_PID" \
    "$stage directory selection after read"
  rm "$link"
  mv "$saved" "$link"
  : > "$barrier.after_read.release"
  if wait "$SNAPSHOT_TEST_PID"; then
    echo "FAIL: restored $stage directory selection was accepted" >&2
    exit 1
  fi
  SNAPSHOT_TEST_PID=""
  python3 - "$error" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
  local after_wizer=0
  if [ -e "$FAKE_WIZER_ARGS_LOG" ]; then
    after_wizer="$(wc -l < "$FAKE_WIZER_ARGS_LOG")"
  fi
  test "$before_wizer" -eq "$after_wizer"
  test "$(cat "$output")" = "preserved-$stage-output"
  test "$(cat "$metadata")" = "preserved-$stage-metadata"
  test "$(cat "$debug/unrelated.txt")" = "preserved-$stage-debug"
}

run_retained_directory_selection_race source
run_retained_directory_selection_race initializer
run_retained_directory_selection_race build-root
run_retained_directory_selection_race preopen
run_retained_directory_selection_race zig-lib
run_retained_directory_selection_race wit

SOURCE_ANCESTOR_PARENT="$SCRATCH/source ancestor original"
SOURCE_ANCESTOR_SAVED="$SCRATCH/source ancestor saved"
SOURCE_ANCESTOR_REPLACEMENT="$SCRATCH/source ancestor replacement"
SOURCE_ANCESTOR_DISPLACED="$SCRATCH/source ancestor displaced"
SOURCE_ANCESTOR_FILE="$SOURCE_ANCESTOR_PARENT/main.js"
SOURCE_ANCESTOR_BARRIER="$BARRIERS/source-ancestor-alternation"
SOURCE_ANCESTOR_ERROR="$SCRATCH/source-ancestor-alternation.jsonl"
SOURCE_ANCESTOR_OUTPUT="$WORK/source ancestor preserved.wasm"
SOURCE_ANCESTOR_METADATA="$WORK/source ancestor preserved.json"
SOURCE_ANCESTOR_DEBUG="$WORK/source ancestor preserved.debug"
mkdir "$SOURCE_ANCESTOR_PARENT" "$SOURCE_ANCESTOR_REPLACEMENT" \
  "$SOURCE_ANCESTOR_DEBUG"
printf 'export const originalAncestor = true;\n' > "$SOURCE_ANCESTOR_FILE"
printf 'export const attackerAncestor = true;\n' > \
  "$SOURCE_ANCESTOR_REPLACEMENT/main.js"
printf 'source-ancestor-output\n' > "$SOURCE_ANCESTOR_OUTPUT"
printf 'source-ancestor-metadata\n' > "$SOURCE_ANCESTOR_METADATA"
printf 'source-ancestor-debug\n' > "$SOURCE_ANCESTOR_DEBUG/unrelated.txt"
STARLING_COMPONENTIZER_TEST_ADAPTER_RETAIN_BARRIER="$SOURCE_ANCESTOR_BARRIER" \
STARLING_COMPONENTIZER_TEST_ADAPTER_RETAIN_COMPONENT="$(basename "$SOURCE_ANCESTOR_PARENT")" \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wizer-bin "$TOOLS/fake wizer" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$SOURCE_ANCESTOR_METADATA" \
  --debug-dir "$SOURCE_ANCESTOR_DEBUG" \
  --out "$SOURCE_ANCESTOR_OUTPUT" \
  "$SOURCE_ANCESTOR_FILE" 2> "$SOURCE_ANCESTOR_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SOURCE_ANCESTOR_BARRIER.before_open.ready" \
  "$SNAPSHOT_TEST_PID" "source ancestor baseline"
mv "$SOURCE_ANCESTOR_PARENT" "$SOURCE_ANCESTOR_SAVED"
mv "$SOURCE_ANCESTOR_REPLACEMENT" "$SOURCE_ANCESTOR_PARENT"
: > "$SOURCE_ANCESTOR_BARRIER.before_open.release"
wait_for_marker "$SOURCE_ANCESTOR_BARRIER.after_open.ready" \
  "$SNAPSHOT_TEST_PID" "source retained ancestor"
mv "$SOURCE_ANCESTOR_PARENT" "$SOURCE_ANCESTOR_DISPLACED"
mv "$SOURCE_ANCESTOR_SAVED" "$SOURCE_ANCESTOR_PARENT"
: > "$SOURCE_ANCESTOR_BARRIER.after_open.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: alternating source ancestor was accepted" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$SOURCE_ANCESTOR_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
test "$(cat "$SOURCE_ANCESTOR_OUTPUT")" = "source-ancestor-output"
test "$(cat "$SOURCE_ANCESTOR_METADATA")" = "source-ancestor-metadata"
test "$(cat "$SOURCE_ANCESTOR_DEBUG/unrelated.txt")" = "source-ancestor-debug"

BUILD_ROOT_SNAPSHOT_OUTPUT="$WORK/build root snapshot.wasm"
BUILD_ROOT_SNAPSHOT_METADATA="$WORK/build root snapshot.json"
BUILD_ROOT_SNAPSHOT_METADATA_CHANGED="$WORK/build root snapshot changed.json"
BUILD_ROOT_SNAPSHOT_BARRIER="$BARRIERS/build-root-snapshot"
BUILD_ROOT_SAVED="$SCRATCH/fake native build root saved"
FAKE_ASSERT_BUILD_SNAPSHOT=1 \
FAKE_BUILD_ROOT_GUEST="$FAKE_BUILD_ROOT" \
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$BUILD_ROOT_SNAPSHOT_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE="zig build runtime" \
build_with_fake_zig "$BUILD_ROOT_SNAPSHOT_OUTPUT" \
  --metadata-out "$BUILD_ROOT_SNAPSHOT_METADATA" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$BUILD_ROOT_SNAPSHOT_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "build root snapshot substitution"
mv "$FAKE_BUILD_ROOT" "$BUILD_ROOT_SAVED"
mkdir -p "$FAKE_BUILD_ROOT/runtime" \
  "$FAKE_BUILD_ROOT/tools/componentizer"
printf 'substituted-build-root\n' > "$FAKE_BUILD_ROOT/build.zig"
touch "$FAKE_BUILD_ROOT/build.zig.zon" "$FAKE_BUILD_ROOT/runtime/js.cpp" \
  "$FAKE_BUILD_ROOT/tools/componentizer/main.zig"
: > "$BUILD_ROOT_SNAPSHOT_BARRIER.release"
wait_for_marker "$BUILD_ROOT_SNAPSHOT_BARRIER.complete" "$SNAPSHOT_TEST_PID" \
  "build root snapshot completion"
: > "$BUILD_ROOT_SNAPSHOT_BARRIER.verify"
wait "$SNAPSHOT_TEST_PID"
SNAPSHOT_TEST_PID=""
remove_tree "$FAKE_BUILD_ROOT"
mv "$BUILD_ROOT_SAVED" "$FAKE_BUILD_ROOT"
python3 - "$BUILD_ROOT_SNAPSHOT_METADATA" <<'PY'
import json, re, sys
digest = json.load(open(sys.argv[1], encoding="utf-8")) \
    ["provenance"]["inputs"]["build_root_sha256"]
assert re.fullmatch(r"[0-9a-f]{64}", digest), digest
PY
printf 'changed-build-root\n' > "$FAKE_BUILD_ROOT/build.zig"
build_with_fake_zig "$BUILD_ROOT_SNAPSHOT_OUTPUT" \
  --metadata-out "$BUILD_ROOT_SNAPSHOT_METADATA_CHANGED"
printf 'captured-build-root\n' > "$FAKE_BUILD_ROOT/build.zig"
python3 - "$BUILD_ROOT_SNAPSHOT_METADATA" \
  "$BUILD_ROOT_SNAPSHOT_METADATA_CHANGED" <<'PY'
import json, sys
digests = [
    json.load(open(path, encoding="utf-8"))
    ["provenance"]["inputs"]["build_root_sha256"]
    for path in sys.argv[1:]
]
assert digests[0] != digests[1], digests
PY

SELECTIVE_ROOT="$SCRATCH/selective symlink build root"
SELECTIVE_TARGET="$SELECTIVE_ROOT/deps/spidermonkey-source/js/public/Guarded.h"
SELECTIVE_LINK="$SELECTIVE_ROOT/deps/sm-obj-zig/dist/include/js/Guarded.h"
SELECTIVE_BARRIER="$BARRIERS/selective-target"
SELECTIVE_OUTPUT="$WORK/selective target.wasm"
mkdir -p "$SELECTIVE_ROOT/runtime" \
  "$SELECTIVE_ROOT/tools/componentizer" \
  "$SELECTIVE_ROOT/host-apis/$EXPECTED_HOST_API" \
  "$(dirname "$SELECTIVE_TARGET")" \
  "$(dirname "$SELECTIVE_LINK")"
printf 'captured-build-root\n' > "$SELECTIVE_ROOT/build.zig"
touch "$SELECTIVE_ROOT/build.zig.zon" "$SELECTIVE_ROOT/runtime/js.cpp" \
  "$SELECTIVE_ROOT/tools/componentizer/main.zig"
cat > "$SELECTIVE_ROOT/tools/componentizer/runtime-build-inputs.txt" <<'EOF'
build.zig
build.zig.zon
runtime
tools/componentizer/main.zig
deps/sm-obj-zig/dist/include
EOF
printf 'original-target\n' > "$SELECTIVE_TARGET"
ln -s "$SELECTIVE_TARGET" "$SELECTIVE_LINK"
FAKE_ASSERT_DEREFERENCED_TARGET=original-target \
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$SELECTIVE_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=build-root-targets \
"$COMPONENTIZER" \
  --build-root "$SELECTIVE_ROOT" \
  --cache-dir "$CACHE" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preview2-adapter "$ADAPTER" \
  --out "$SELECTIVE_OUTPUT" \
  "$BUILD_SOURCE" >/dev/null &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SELECTIVE_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "dereferenced build target capture"
mv "$SELECTIVE_TARGET" "$SELECTIVE_TARGET.saved"
printf 'substituted-target\n' > "$SELECTIVE_TARGET"
rm "$SELECTIVE_TARGET"
mv "$SELECTIVE_TARGET.saved" "$SELECTIVE_TARGET"
: > "$SELECTIVE_BARRIER.release"
wait "$SNAPSHOT_TEST_PID"
SNAPSHOT_TEST_PID=""
cmp "$ENGINE" "$SELECTIVE_OUTPUT"

SELECTIVE_LINK_RACE_BARRIER="$BARRIERS/selective-link-read"
SELECTIVE_LINK_RACE_ERROR="$SCRATCH/selective-link-read.jsonl"
SELECTIVE_LINK_RACE_OUTPUT="$WORK/selective link read race.wasm"
SELECTIVE_ATTACKER_TARGET="$SELECTIVE_ROOT/deps/spidermonkey-source/js/public/Attacker.h"
SELECTIVE_LINK_SAVED="$SELECTIVE_LINK.saved"
printf 'attacker-target\n' > "$SELECTIVE_ATTACKER_TARGET"
STARLING_COMPONENTIZER_TEST_SYMLINK_READ_BARRIER="$SELECTIVE_LINK_RACE_BARRIER" \
"$COMPONENTIZER" \
  --json-diagnostics \
  --build-root "$SELECTIVE_ROOT" \
  --cache-dir "$CACHE" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preview2-adapter "$ADAPTER" \
  --out "$SELECTIVE_LINK_RACE_OUTPUT" \
  "$BUILD_SOURCE" 2> "$SELECTIVE_LINK_RACE_ERROR" &
SNAPSHOT_TEST_PID=$!
for link_read in first second; do
  wait_for_marker \
    "$SELECTIVE_LINK_RACE_BARRIER.${link_read}_before.ready" \
    "$SNAPSHOT_TEST_PID" "$link_read symlink read before"
  mv "$SELECTIVE_LINK" "$SELECTIVE_LINK_SAVED"
  ln -s "$SELECTIVE_ATTACKER_TARGET" "$SELECTIVE_LINK"
  : > "$SELECTIVE_LINK_RACE_BARRIER.${link_read}_before.release"
  wait_for_marker \
    "$SELECTIVE_LINK_RACE_BARRIER.${link_read}_after.ready" \
    "$SNAPSHOT_TEST_PID" "$link_read symlink read after"
  rm "$SELECTIVE_LINK"
  mv "$SELECTIVE_LINK_SAVED" "$SELECTIVE_LINK"
  : > "$SELECTIVE_LINK_RACE_BARRIER.${link_read}_after.release"
done
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: restored symlink substitution was accepted" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$SELECTIVE_LINK_RACE_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
test ! -e "$SELECTIVE_LINK_RACE_OUTPUT"

SELECTIVE_MUTATION_BARRIER="$BARRIERS/selective-target-mutation"
SELECTIVE_MUTATION_ERROR="$SCRATCH/selective-target-mutation.jsonl"
SELECTIVE_MUTATION_OUTPUT="$WORK/selective target mutation.wasm"
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$SELECTIVE_MUTATION_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=build-root-targets \
"$COMPONENTIZER" \
  --json-diagnostics \
  --build-root "$SELECTIVE_ROOT" \
  --cache-dir "$CACHE" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preview2-adapter "$ADAPTER" \
  --out "$SELECTIVE_MUTATION_OUTPUT" \
  "$BUILD_SOURCE" 2> "$SELECTIVE_MUTATION_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$SELECTIVE_MUTATION_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "dereferenced build target mutation"
printf 'mutated-target\n' > "$SELECTIVE_TARGET"
: > "$SELECTIVE_MUTATION_BARRIER.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: in-place selective target mutation was captured" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$SELECTIVE_MUTATION_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
test ! -e "$SELECTIVE_MUTATION_OUTPUT"
printf 'original-target\n' > "$SELECTIVE_TARGET"

OUTSIDE_TARGET="$SCRATCH/outside selective target.h"
SELECTIVE_ESCAPE_ERROR="$SCRATCH/selective-escape.jsonl"
printf 'outside-target\n' > "$OUTSIDE_TARGET"
rm "$SELECTIVE_LINK"
ln -s "$OUTSIDE_TARGET" "$SELECTIVE_LINK"
if "$COMPONENTIZER" \
  --json-diagnostics \
  --build-root "$SELECTIVE_ROOT" \
  --cache-dir "$WORK/selective escape cache" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preview2-adapter "$ADAPTER" \
  --out "$WORK/selective escape.wasm" \
  "$BUILD_SOURCE" 2> "$SELECTIVE_ESCAPE_ERROR"
then
  echo "FAIL: escaping selective target was captured" >&2
  exit 1
fi
python3 - "$SELECTIVE_ESCAPE_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "UnsupportedInputEntry", diagnostic
PY

MISSING_GENERATED_ADAPTER_ERROR="$SCRATCH/missing-generated-adapter.jsonl"
if FAKE_OMIT_GENERATED_ADAPTER=1 \
  build_with_fake_zig "$WORK/missing generated adapter.wasm" \
    --json-diagnostics 2> "$MISSING_GENERATED_ADAPTER_ERROR"
then
  echo "FAIL: missing generated adapter was accepted" >&2
  exit 1
fi
test ! -e "$WORK/missing generated adapter.wasm"

EXPLICIT_ADAPTER_LINK="$SCRATCH/explicit adapter symlink.wasm"
ln -s "$ADAPTER" "$EXPLICIT_ADAPTER_LINK"
FAKE_ZIG_PREFIX_LOG="$SCRATCH/explicit-adapter-zig-prefix.log" \
FAKE_ZIG_ENV_LOG="$SCRATCH/explicit-adapter-zig-env.log" \
  "$COMPONENTIZER" \
  --build-root "$FAKE_BUILD_ROOT" \
  --cache-dir "$WORK/explicit adapter symlink cache" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --preview2-adapter "$EXPLICIT_ADAPTER_LINK" \
  --out "$WORK/explicit adapter symlink.wasm" \
  "$BUILD_SOURCE"
test -s "$WORK/explicit adapter symlink.wasm"

run_adapter_ancestor_alternation_test() {
  local flow="$1"
  local parent="$SCRATCH/$flow adapter capture parent"
  local saved="$SCRATCH/$flow adapter capture saved"
  local replacement="$SCRATCH/$flow adapter capture replacement"
  local displaced="$SCRATCH/$flow adapter capture displaced"
  local adapter="$parent/adapter input.wasm"
  local barrier="$BARRIERS/$flow-adapter-retain"
  local error="$SCRATCH/$flow-adapter-retain.jsonl"
  local output="$WORK/$flow adapter retain preserved.wasm"
  local metadata="$WORK/$flow adapter retain preserved.json"
  local debug="$WORK/$flow adapter retain preserved.debug"
  local component
  component="$(basename "$parent")"
  mkdir "$parent" "$replacement" "$debug"
  cp "$ADAPTER" "$adapter"
  printf 'substituted-adapter\n' > "$replacement/adapter input.wasm"
  printf '%s-output\n' "$flow" > "$output"
  printf '%s-metadata\n' "$flow" > "$metadata"
  printf '%s-debug\n' "$flow" > "$debug/unrelated.txt"
  local command=(
    "$COMPONENTIZER"
    --json-diagnostics
    --wit "$WIT"
    --world-name exports
    --wizer-bin "$TOOLS/fake wizer"
    --wabt-bin "$TOOLS/fake wabt"
    --wasm-tools-bin "$TOOLS/fake wasm-tools"
    --preview2-adapter "$adapter"
    --metadata-out "$metadata"
    --debug-dir "$debug"
    --out "$output"
  )
  if [ "$flow" = external ]; then
    command+=(--engine "$ENGINE" "$SOURCE")
  else
    command+=(
      --build-root "$FAKE_BUILD_ROOT"
      --cache-dir "$WORK/$flow adapter retain cache"
      --zig-bin "$TOOLS/fake zig"
      "$BUILD_SOURCE"
    )
  fi
  STARLING_COMPONENTIZER_TEST_ADAPTER_RETAIN_BARRIER="$barrier" \
  STARLING_COMPONENTIZER_TEST_ADAPTER_RETAIN_COMPONENT="$component" \
    "${command[@]}" 2> "$error" &
  SNAPSHOT_TEST_PID=$!
  wait_for_marker "$barrier.before_open.ready" "$SNAPSHOT_TEST_PID" \
    "$flow adapter ancestor baseline"
  mv "$parent" "$saved"
  mv "$replacement" "$parent"
  : > "$barrier.before_open.release"
  wait_for_marker "$barrier.after_open.ready" "$SNAPSHOT_TEST_PID" \
    "$flow adapter retained ancestor"
  mv "$parent" "$displaced"
  mv "$saved" "$parent"
  : > "$barrier.after_open.release"
  if wait "$SNAPSHOT_TEST_PID"; then
    echo "FAIL: $flow alternating adapter ancestor was accepted" >&2
    exit 1
  fi
  SNAPSHOT_TEST_PID=""
  python3 - "$error" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
  test "$(cat "$output")" = "$flow-output"
  test "$(cat "$metadata")" = "$flow-metadata"
  test "$(cat "$debug/unrelated.txt")" = "$flow-debug"
}

run_adapter_ancestor_alternation_test external
run_adapter_ancestor_alternation_test build

FALLBACK_TOOL_DIR="$SCRATCH/fallback adapter tool"
FALLBACK_COMPONENTIZER="$FALLBACK_TOOL_DIR/starling-componentize"
FALLBACK_ADAPTER="$FALLBACK_TOOL_DIR/preview1-adapter.wasm"
FALLBACK_BARRIER="$BARRIERS/fallback-adapter"
FALLBACK_ERROR="$SCRATCH/fallback-adapter.jsonl"
mkdir -p "$FALLBACK_TOOL_DIR"
cp "$COMPONENTIZER" "$FALLBACK_COMPONENTIZER"
cp "$ADAPTER" "$FALLBACK_ADAPTER"
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$FALLBACK_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=adapter \
"$FALLBACK_COMPONENTIZER" \
  --json-diagnostics \
  --build-root "$FAKE_BUILD_ROOT" \
  --cache-dir "$WORK/fallback cache" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/fallback mutation.wasm" \
  "$BUILD_SOURCE" 2> "$FALLBACK_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$FALLBACK_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "fallback adapter capture"
printf 'mutated-fallback-adapter\n' > "$FALLBACK_ADAPTER"
: > "$FALLBACK_BARRIER.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: fallback adapter capture mutation was accepted" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$FALLBACK_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY

FALLBACK_RENAME_BARRIER="$BARRIERS/fallback-adapter-rename"
FALLBACK_RENAME_ERROR="$SCRATCH/fallback-adapter-rename.jsonl"
FALLBACK_RENAME_OUTPUT="$WORK/fallback rename preserved.wasm"
FALLBACK_RENAME_METADATA="$WORK/fallback rename preserved.json"
FALLBACK_RENAME_DEBUG="$WORK/fallback rename preserved.debug"
FALLBACK_ADAPTER_SAVED="$SCRATCH/fallback-adapter-saved.wasm"
cp "$ADAPTER" "$FALLBACK_ADAPTER"
printf 'preserved-fallback-output\n' > "$FALLBACK_RENAME_OUTPUT"
printf 'preserved-fallback-metadata\n' > "$FALLBACK_RENAME_METADATA"
mkdir "$FALLBACK_RENAME_DEBUG"
printf 'preserved-fallback-debug\n' > "$FALLBACK_RENAME_DEBUG/unrelated.txt"
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$FALLBACK_RENAME_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=adapter \
"$FALLBACK_COMPONENTIZER" \
  --json-diagnostics \
  --build-root "$FAKE_BUILD_ROOT" \
  --cache-dir "$WORK/fallback rename cache" \
  --zig-bin "$TOOLS/fake zig" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$FALLBACK_RENAME_METADATA" \
  --debug-dir "$FALLBACK_RENAME_DEBUG" \
  --out "$FALLBACK_RENAME_OUTPUT" \
  "$BUILD_SOURCE" 2> "$FALLBACK_RENAME_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$FALLBACK_RENAME_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "fallback adapter rename-away"
mv "$FALLBACK_ADAPTER" "$FALLBACK_ADAPTER_SAVED"
: > "$FALLBACK_RENAME_BARRIER.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: renamed-away fallback adapter was accepted" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$FALLBACK_RENAME_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
test "$(cat "$FALLBACK_RENAME_OUTPUT")" = "preserved-fallback-output"
test "$(cat "$FALLBACK_RENAME_METADATA")" = "preserved-fallback-metadata"
test "$(cat "$FALLBACK_RENAME_DEBUG/unrelated.txt")" = \
  "preserved-fallback-debug"
mv "$FALLBACK_ADAPTER_SAVED" "$FALLBACK_ADAPTER"

FALLBACK_SYMLINK_CAPTURE_BARRIER="$BARRIERS/fallback-adapter-symlink-capture"
FALLBACK_SYMLINK_SNAPSHOT_BARRIER="$BARRIERS/fallback-adapter-symlink-snapshot"
FALLBACK_SYMLINK_ERROR="$SCRATCH/fallback-adapter-symlink.jsonl"
FALLBACK_SYMLINK_OUTPUT="$WORK/fallback symlink preserved.wasm"
FALLBACK_SYMLINK_METADATA="$WORK/fallback symlink preserved.json"
FALLBACK_SYMLINK_DEBUG="$WORK/fallback symlink preserved.debug"
FALLBACK_SYMLINK_SAVED="$SCRATCH/fallback-adapter-symlink-saved.wasm"
FALLBACK_SYMLINK_MISSING="$SCRATCH/missing substituted adapter.wasm"
cp "$ADAPTER" "$FALLBACK_ADAPTER"
printf 'preserved-symlink-output\n' > "$FALLBACK_SYMLINK_OUTPUT"
printf 'preserved-symlink-metadata\n' > "$FALLBACK_SYMLINK_METADATA"
mkdir "$FALLBACK_SYMLINK_DEBUG"
printf 'preserved-symlink-debug\n' > "$FALLBACK_SYMLINK_DEBUG/unrelated.txt"
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$FALLBACK_SYMLINK_CAPTURE_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=adapter \
STARLING_COMPONENTIZER_TEST_ADAPTER_SNAPSHOT_BARRIER="$FALLBACK_SYMLINK_SNAPSHOT_BARRIER" \
"$FALLBACK_COMPONENTIZER" \
  --json-diagnostics \
  --engine "$ENGINE" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --metadata-out "$FALLBACK_SYMLINK_METADATA" \
  --debug-dir "$FALLBACK_SYMLINK_DEBUG" \
  --out "$FALLBACK_SYMLINK_OUTPUT" \
  "$SOURCE" 2> "$FALLBACK_SYMLINK_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$FALLBACK_SYMLINK_CAPTURE_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "fallback adapter symlink substitution"
mv "$FALLBACK_ADAPTER" "$FALLBACK_SYMLINK_SAVED"
ln -s "$FALLBACK_SYMLINK_MISSING" "$FALLBACK_ADAPTER"
: > "$FALLBACK_SYMLINK_CAPTURE_BARRIER.release"
wait_for_marker "$FALLBACK_SYMLINK_SNAPSHOT_BARRIER.ready" \
  "$SNAPSHOT_TEST_PID" "retained fallback adapter snapshot"
rm "$FALLBACK_ADAPTER"
mv "$FALLBACK_SYMLINK_SAVED" "$FALLBACK_ADAPTER"
: > "$FALLBACK_SYMLINK_SNAPSHOT_BARRIER.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: restored fallback adapter symlink substitution was accepted" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$FALLBACK_SYMLINK_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
test ! -e "$FALLBACK_SYMLINK_MISSING"
test "$(cat "$FALLBACK_SYMLINK_OUTPUT")" = "preserved-symlink-output"
test "$(cat "$FALLBACK_SYMLINK_METADATA")" = "preserved-symlink-metadata"
test "$(cat "$FALLBACK_SYMLINK_DEBUG/unrelated.txt")" = \
  "preserved-symlink-debug"

INVALID_ZIG_OUTPUT="$WORK/invalid Zig version.wasm"
INVALID_ZIG_ERROR="$SCRATCH/invalid-zig-version.jsonl"
if FAKE_ZIG_VERSION=0.17.0-dev.901+invalid \
  build_with_fake_zig "$INVALID_ZIG_OUTPUT" \
    --json-diagnostics 2> "$INVALID_ZIG_ERROR"
then
  echo "FAIL: --zig-bin accepted an unpinned Zig version" >&2
  exit 1
fi
python3 - "$INVALID_ZIG_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "UnsupportedZigVersion", diagnostic
PY
test ! -e "$INVALID_ZIG_OUTPUT"

INVALID_ENV_ZIG_ERROR="$SCRATCH/invalid-env-zig-version.jsonl"
if FAKE_ZIG_VERSION=0.18.0-dev.1+invalid ZIG="$TOOLS/fake zig" \
  "$COMPONENTIZER" \
    --json-diagnostics \
    --build-root "$FAKE_BUILD_ROOT" \
    --cache-dir "$CACHE" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$INVALID_ZIG_OUTPUT" \
    "$BUILD_SOURCE" 2> "$INVALID_ENV_ZIG_ERROR"
then
  echo "FAIL: ZIG accepted an unpinned Zig version" >&2
  exit 1
fi
python3 - "$INVALID_ENV_ZIG_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "UnsupportedZigVersion", diagnostic
PY
test ! -e "$INVALID_ZIG_OUTPUT"

build_with_fake_zig "$BUILD_OUTPUT_1"
build_with_fake_zig "$BUILD_OUTPUT_2"
build_with_env_tools() {
  local output="$1"
  env PATH="$TOOLS:$PATH" \
    ZIG=path-zig WIZER_BIN=path-wizer WABT=path-wabt \
    WASM_TOOLS_BIN=path-wasm-tools \
    "$COMPONENTIZER" \
      --build-root "$ROOT" \
      --cache-dir "$CACHE" \
      --wit "$WIT" \
      --world-name exports \
      --out "$output" \
      "$SOURCE"
}
PATH="$TOOLS:$PATH" build_with_fake_zig "$BUILD_OUTPUT_1" path-zig
build_with_env_tools "$BUILD_OUTPUT_2"
printf '\n// cache invalidation\n' >> "$WIT/world.wit"
build_with_fake_zig "$BUILD_OUTPUT_3"
cp "$WIT/world.wit" "$ENGINE_BUNDLE/component-wit/world.wit"
cp "$WIT/world.wit" "$ENGINE_BUNDLE/surface-wit/world.wit"

METADATA_OUTPUT="$WORK/public metadata.json"
METADATA_REFERENCE="$SCRATCH/public metadata reference.json"
BUILD_DEBUG_DIR="$WORK/build debug bindings"
FAKE_PROVIDER_WIT=1 FAKE_CANDIDATE_WASI_IMPORT=1 \
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
    "preview2_adapter_sha256", "build_root_sha256",
))
assert inputs["preopen_trees"] is None
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
tool_fields = []
for tool in provenance["tools"]:
    tool_fields.append((tool["name"], tool["sha256"]))
    if tool["name"] == "zig":
        tool_fields.append(("zig-lib", tool["lib_tree_sha256"]))
tool_hash = hashlib.sha256()
for name, value in tool_fields:
    tool_hash.update(name.encode())
    tool_hash.update(b"\0")
    tool_hash.update(value.encode())
    tool_hash.update(b"\xff")
assert provenance["tools_sha256"] == tool_hash.hexdigest()
assert sha256.match(metadata["component_sha256"])
runtime_args = open(sys.argv[3], "rb").read()
assert provenance["inputs"]["runtime_arguments_sha256"] == \
    hashlib.sha256(runtime_args).hexdigest()
PY
FAKE_PROVIDER_WIT=1 FAKE_CANDIDATE_WASI_IMPORT=1 \
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
test "${#prefixes[@]}" -eq 18
for prefix in "${prefixes[@]}"; do
  case "$prefix" in
    *".starling-componentize-"*/data/runtime-prefix) ;;
    *)
      echo "FAIL: Zig build escaped its private anchored prefix: $prefix" >&2
      exit 1
      ;;
  esac
done
test "$(printf '%s\n' "${prefixes[@]}" | sort -u | wc -l)" -eq 18
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
while IFS='|' read -r local_cache global_cache; do
  test "$local_cache" = "unset"
  if [ -n "$EXPECTED_ZIG_GLOBAL_CACHE" ]; then
    test "$global_cache" = "$EXPECTED_ZIG_GLOBAL_CACHE"
  else
    test "$global_cache" = "$CACHE/zig-global-cache"
  fi
done < "$FAKE_ZIG_ENV_LOG"
host_api_arg_count="$(
  grep -c -- "-Dhost-api=$EXPECTED_HOST_API" "$FAKE_ZIG_ARGS_LOG"
)"
host_world_arg_count="$(
  grep -c -- '-Dhost-api-world=bindings' "$FAKE_ZIG_ARGS_LOG"
)"
test "$host_api_arg_count" -ge 5
test "$host_world_arg_count" -eq "$host_api_arg_count"
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
    --preview2-adapter "$ADAPTER" \
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
  local race_barrier="$BARRIERS/cache-identity-$race_kind"
  remove_tree "$race_cache" "$race_held" "$race_target"
  FAKE_ZIG_BARRIER="$race_barrier" "$COMPONENTIZER" \
    --json-diagnostics \
    --build-root "$FAKE_BUILD_ROOT" \
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

WIT_TARGET="$SCRATCH/symlinked WIT target"
WIT_TARGET_SAVED="$SCRATCH/symlinked WIT target saved"
WIT_LINK="$SCRATCH/symlinked WIT root"
WIT_SUBSTITUTION_OUTPUT="$WORK/WIT target substitution.wasm"
WIT_SUBSTITUTION_BARRIER="$BARRIERS/WIT-target-substitution"
mkdir "$WIT_TARGET"
cat > "$WIT_TARGET/world.wit" <<'EOF'
package test:componentizer;
world captured {}
EOF
ln -s "$WIT_TARGET" "$WIT_LINK"
WIT_PACKAGE="$SCRATCH/symlinked WIT engine bundle"
mkdir -p "$WIT_PACKAGE/feature-wit"
ln -s "$WIT_TARGET" "$WIT_PACKAGE/component-wit"
ln -s "$WIT_TARGET" "$WIT_PACKAGE/surface-wit"
cp "$ADAPTER" "$WIT_PACKAGE/preview1-adapter.wasm"
cp "$WORK/feature-wit/feature.wit" "$WIT_PACKAGE/feature-wit/"
cat > "$WIT_PACKAGE/features.json" <<EOF
{
  "host-api": "$(basename "$EXPECTED_HOST_API")",
  "component-world": "captured",
  "surface-world": "captured",
  "stdio": true,
  "random": true,
  "clocks": true,
  "http": true,
  "fetch-event": true
}
EOF
python3 "$ROOT/tools/embed-engine-provenance.py" \
  "$ENGINE_BASE" "$WIT_PACKAGE/starling-raw.wasm" \
  "$(basename "$EXPECTED_HOST_API")" 11111 captured captured
FAKE_ASSERT_WIT_SNAPSHOT=1 \
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$WIT_SUBSTITUTION_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE=wizer \
"$COMPONENTIZER" \
  --engine "$WIT_PACKAGE/starling-raw.wasm" \
  --preview2-adapter "$WIT_PACKAGE/preview1-adapter.wasm" \
  --wit "$WIT_LINK" \
  --world-name captured \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WIT_SUBSTITUTION_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2>&1 &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$WIT_SUBSTITUTION_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "symlinked WIT target substitution"
mv "$WIT_TARGET" "$WIT_TARGET_SAVED"
mkdir "$WIT_TARGET"
cat > "$WIT_TARGET/world.wit" <<'EOF'
package test:componentizer;
world substituted {}
EOF
: > "$WIT_SUBSTITUTION_BARRIER.release"
wait_for_marker "$WIT_SUBSTITUTION_BARRIER.complete" "$SNAPSHOT_TEST_PID" \
  "symlinked WIT target completion"
: > "$WIT_SUBSTITUTION_BARRIER.verify"
wait "$SNAPSHOT_TEST_PID"
SNAPSHOT_TEST_PID=""
cmp "$WIT_PACKAGE/starling-raw.wasm" "$WIT_SUBSTITUTION_OUTPUT"
remove_tree "$WIT_TARGET"
mv "$WIT_TARGET_SAVED" "$WIT_TARGET"

WIT_RACE_OUTPUT="$WORK/WIT capture race.wasm"
WIT_RACE_ERROR="$SCRATCH/WIT-capture-race.jsonl"
WIT_RACE_BARRIER="$BARRIERS/WIT-capture-race"
printf 'old-WIT-race-output\n' > "$WIT_RACE_OUTPUT"
STARLING_COMPONENTIZER_TEST_CAPTURE_BARRIER="$WIT_RACE_BARRIER" \
STARLING_COMPONENTIZER_TEST_CAPTURE_STAGE=wit \
"$COMPONENTIZER" \
  --json-diagnostics \
  --engine "$WIT_PACKAGE/starling-raw.wasm" \
  --preview2-adapter "$WIT_PACKAGE/preview1-adapter.wasm" \
  --wit "$WIT_LINK" \
  --world-name captured \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WIT_RACE_OUTPUT" \
  "$SNAPSHOT_SOURCE" >/dev/null 2> "$WIT_RACE_ERROR" &
SNAPSHOT_TEST_PID=$!
wait_for_marker "$WIT_RACE_BARRIER.ready" "$SNAPSHOT_TEST_PID" \
  "symlinked WIT target capture race"
cat > "$WIT_TARGET/world.wit" <<'EOF'
package test:componentizer;
world capture_race_mutation {}
EOF
: > "$WIT_RACE_BARRIER.release"
if wait "$SNAPSHOT_TEST_PID"; then
  echo "FAIL: WIT target capture race reported success" >&2
  exit 1
fi
SNAPSHOT_TEST_PID=""
python3 - "$WIT_RACE_ERROR" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 1, lines
diagnostic = json.loads(lines[0])
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "InputChanged", diagnostic
PY
test "$(cat "$WIT_RACE_OUTPUT")" = "old-WIT-race-output"

for wit_link_kind in escaping dangling; do
  WIT_UNSAFE_ROOT="$SCRATCH/unsafe WIT $wit_link_kind"
  WIT_UNSAFE_ERROR="$SCRATCH/unsafe-WIT-$wit_link_kind.jsonl"
  mkdir "$WIT_UNSAFE_ROOT"
  cat > "$WIT_UNSAFE_ROOT/world.wit" <<'EOF'
package test:componentizer;
world unsafe {}
EOF
  if [ "$wit_link_kind" = escaping ]; then
    ln -s "$ENGINE" "$WIT_UNSAFE_ROOT/escaped.wit"
  else
    ln -s missing.wit "$WIT_UNSAFE_ROOT/dangling.wit"
  fi
  if "$COMPONENTIZER" \
    --json-diagnostics \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT_UNSAFE_ROOT" \
    --world-name unsafe \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$WORK/unsafe WIT $wit_link_kind.wasm" \
    "$SNAPSHOT_SOURCE" >/dev/null 2> "$WIT_UNSAFE_ERROR"
  then
    echo "FAIL: $wit_link_kind WIT symlink was accepted" >&2
    exit 1
  fi
  python3 - "$WIT_UNSAFE_ERROR" <<'PY'
import json, sys
diagnostic = json.load(open(sys.argv[1], encoding="utf-8"))
assert diagnostic["code"] == "SMC1001", diagnostic
assert diagnostic["phase"] == "inputs", diagnostic
assert diagnostic["cause"] == "UnsupportedWitEntry", diagnostic
PY
done

SNAPSHOT_MUTATION_OUTPUT="$WORK/snapshot-mutation.wasm"
SNAPSHOT_MUTATION_ERROR="$SCRATCH/snapshot-mutation.jsonl"
SNAPSHOT_MUTATION_BARRIER="$BARRIERS/snapshot-mutation"
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
SNAPSHOT_UNRESTORED_BARRIER="$BARRIERS/snapshot-unrestored"
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
SNAPSHOT_WIZER_BARRIER="$BARRIERS/snapshot-wizer"
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
SNAPSHOT_WASM_BARRIER="$BARRIERS/snapshot-wasm-tools"
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
SNAPSHOT_WIT_BARRIER="$BARRIERS/snapshot-wit"
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
mv "$snapshot_storage/wit-override" \
  "$snapshot_storage/wit-override.saved"
mv "$snapshot_storage/stripped.wasm" \
  "$SCRATCH/snapshot-wit-saved/stripped.wasm"
mv "$snapshot_storage/embedded.wasm" \
  "$SCRATCH/snapshot-wit-saved/embedded.wasm"
printf '#!/usr/bin/env bash\nexit 97\n' > "$snapshot_storage/wabt"
chmod +x "$snapshot_storage/wabt"
mkdir "$snapshot_storage/wit-override"
printf 'package test:substituted;\nworld substituted {}\n' > \
  "$snapshot_storage/wit-override/world.wit"
printf 'substituted-stripped\n' > "$snapshot_storage/stripped.wasm"
ln -s "$SNAPSHOT_WIT_EXTERNAL" "$snapshot_storage/embedded.wasm"
: > "$SNAPSHOT_WIT_BARRIER.release"
wait_for_marker "$SNAPSHOT_WIT_BARRIER.complete" \
  "$SNAPSHOT_TEST_PID" "WIT snapshot completion"
test "$(cat "$SNAPSHOT_WIT_EXTERNAL")" = "external-output"
rm -f "$snapshot_storage/wabt" "$snapshot_storage/stripped.wasm" \
  "$snapshot_storage/embedded.wasm"
remove_tree "$snapshot_storage/wit-override"
mv "$SCRATCH/snapshot-wit-saved/wabt" "$snapshot_storage/wabt"
mv "$snapshot_storage/wit-override.saved" \
  "$snapshot_storage/wit-override"
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
SNAPSHOT_ZIG_BARRIER="$BARRIERS/snapshot-zig"
SNAPSHOT_ZIG_EXTERNAL="$SCRATCH/snapshot-zig-external"
mkdir "$SNAPSHOT_ZIG_EXTERNAL"
printf 'external-prefix\n' > "$SNAPSHOT_ZIG_EXTERNAL/sentinel"
FAKE_ZIG_BARRIER="$SNAPSHOT_ZIG_BARRIER-child" \
STARLING_COMPONENTIZER_TEST_SPAWN_BARRIER="$SNAPSHOT_ZIG_BARRIER" \
STARLING_COMPONENTIZER_TEST_SPAWN_STAGE="zig build runtime" \
"$COMPONENTIZER" \
  --build-root "$FAKE_BUILD_ROOT" \
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
