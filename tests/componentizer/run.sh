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
if [ "$1 $2" = "component new" ]; then
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
EOF
chmod +x "$TOOLS"/*

export FAKE_RUNTIME_ARGS_LOG="$SCRATCH/runtime args.log"
export FAKE_ENGINE="$ENGINE"
export FAKE_ADAPTER="$ADAPTER"
export FAKE_ZIG_PREFIX_LOG="$SCRATCH/zig prefixes.log"
export FAKE_ZIG_ENV_LOG="$SCRATCH/zig env.log"
export STARLINGMONKEY_CONFIG="--ambient-config-must-not-reach-wizer"

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
if FAKE_FAIL_STAGE="component embed" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: injected component-embed failure unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$OUTPUT")" = "original-output"
if find "$WORK" -maxdepth 1 -name '.output component.wasm.starling-componentize-*' \
  | grep -q .; then
  echo "FAIL: failed componentization left transaction artifacts" >&2
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
test ! -L "$LINK_DEBUG_DIR/commands.txt"
grep -Fq 'fake wizer' "$LINK_DEBUG_DIR/commands.txt"

CACHE="$WORK/runtime cache"
BUILD_OUTPUT_1="$WORK/built output 1.wasm"
BUILD_OUTPUT_2="$WORK/built output 2.wasm"
BUILD_OUTPUT_3="$WORK/built output 3.wasm"
build_with_fake_zig() {
  local output="$1"
  "$COMPONENTIZER" \
    --build-root "$ROOT" \
    --cache-dir "$CACHE" \
    --zig-bin "$TOOLS/fake zig" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$output" \
    "$SOURCE"
}
build_with_fake_zig "$BUILD_OUTPUT_1"
build_with_fake_zig "$BUILD_OUTPUT_2"
printf '\n// cache invalidation\n' >> "$WIT/world.wit"
build_with_fake_zig "$BUILD_OUTPUT_3"
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
test "${#prefixes[@]}" -eq 5
test "${prefixes[0]}" = "${prefixes[1]}"
test "${prefixes[0]}" != "${prefixes[2]}"
test "${prefixes[2]}" = "${prefixes[3]}"
test "${prefixes[2]}" = "${prefixes[4]}"
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
