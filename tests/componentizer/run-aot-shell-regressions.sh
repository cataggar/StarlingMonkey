#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/harness-helpers.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEGACY="$SCRIPT_DIR/run-legacy-aot-targets.sh"
SCRATCH="$ROOT/tests/componentizer/.aot-shell-regressions"
TOOL_DIR="$SCRATCH/selected toolchain's directory"
SENTINEL_ZIG="$TOOL_DIR/zig sentinel"
SENTINEL_ZIG_LOG="$SCRATCH/zig invocations.log"

rm -rf "$SCRATCH"
mkdir -p "$TOOL_DIR"
trap 'rm -rf "$SCRATCH"' EXIT

cat > "$SENTINEL_ZIG" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${EXPECTED_ZIG:?}"
: "${SENTINEL_ZIG_LOG:?}"
test "$0" = "$EXPECTED_ZIG"
{
  printf 'zig'
  printf ' <%q>' "$@"
  printf '\n'
} >> "$SENTINEL_ZIG_LOG"

prefix=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = --prefix ]; then
    j=$((i + 1))
    prefix="${!j}"
  fi
done
if [ -n "$prefix" ]; then
  mkdir -p "$prefix/bin"
  printf '\0asm-sentinel\n' > "$prefix/bin/starling-raw.wasm"
  cat > "$prefix/bin/wasm-tools" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
test "$1 $2 $3" = "validate --features all"
test -s "$4"
TOOL
  cat > "$prefix/bin/componentize.sh" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
out=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    -o|--output)
      j=$((i + 1))
      out="${!j}"
      ;;
  esac
done
test -n "$out"
bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$bin/starling-raw.wasm" "$out"
TOOL
  chmod +x "$prefix/bin/wasm-tools" "$prefix/bin/componentize.sh"
fi
EOF
chmod +x "$SENTINEL_ZIG"
export EXPECTED_ZIG="$SENTINEL_ZIG" SENTINEL_ZIG_LOG

BARE_DIR="$SCRATCH/PATH shadow"
mkdir -p "$BARE_DIR"
ln -s "$SENTINEL_ZIG" "$BARE_DIR/zig-shadow"
PATH="$BARE_DIR:$PATH" "$LEGACY" zig-shadow "$SCRATCH/bare prefix"

EXPLICIT_ZIG="$SCRATCH/explicit path/zig symlink"
mkdir -p "$(dirname "$EXPLICIT_ZIG")"
ln -s "$SENTINEL_ZIG" "$EXPLICIT_ZIG"
"$LEGACY" "$EXPLICIT_ZIG" "$SCRATCH/explicit prefix"

just --justfile "$ROOT/justfile" \
  zig="$SENTINEL_ZIG" \
  mode=weval \
  builddir="$SCRATCH/recursive prefix" \
  test

grep -Fq 'componentizer-test' "$SENTINEL_ZIG_LOG"
grep -Fq 'aot-engine-test' "$SENTINEL_ZIG_LOG"
test "$(wc -l < "$SENTINEL_ZIG_LOG")" -ge 9

echo "AOT shell path resolution and recursive Zig forwarding passed"
