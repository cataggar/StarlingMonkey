#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <starling-aot-cache>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/harness-helpers.sh"
CACHE_TOOL="$(resolve_executable "$1")"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.seal-aliases"
WORK="$SCRATCH/work with spaces"
ENGINE="$WORK/engine.wasm"
WEVAL="$WORK/weval tool"
SOURCE_CACHE="$WORK/source.wevalcache"
PRIMER="$WORK/primer.js"

rm -rf "$SCRATCH"
mkdir -p "$WORK"
trap 'rm -rf "$SCRATCH"' EXIT

printf 'seal-alias-engine\n' > "$ENGINE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WEVAL"
chmod +x "$WEVAL"
printf 'function sealAliasPrimer() {}\n' > "$PRIMER"
python3 - "$SOURCE_CACHE" "$ENGINE" <<'PY'
import hashlib
import sqlite3
import sys

with open(sys.argv[2], "rb") as engine:
    engine_hash = hashlib.sha256(engine.read()).digest()
db = sqlite3.connect(sys.argv[1])
db.execute("""create table weval_cache(
    module_hash blob not null,
    key blob not null,
    result blob not null,
    created_time integer not null
)""")
db.execute(
    "insert into weval_cache values (?, ?, ?, ?)",
    (engine_hash, b"alias-key", b"alias-result", 17),
)
db.execute("create index idx on weval_cache(module_hash, key)")
db.commit()
db.close()
PY

INPUT_HASHES="$(sha256sum "$ENGINE" "$WEVAL" "$SOURCE_CACHE" "$PRIMER")"

assert_inputs_unchanged() {
  test "$(sha256sum "$ENGINE" "$WEVAL" "$SOURCE_CACHE" "$PRIMER")" = \
    "$INPUT_HASHES"
  if find "$WORK" -maxdepth 2 -name '*.canonical-*' -print -quit | grep -q .; then
    echo "FAIL: rejected seal left a canonicalization artifact" >&2
    exit 1
  fi
}

expect_collision() {
  local label="$1"
  shift
  if "$@" > "$SCRATCH/$label.log" 2>&1; then
    echo "FAIL: $label seal collision unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Fq 'AOT cache seal path collision:' "$SCRATCH/$label.log"
  assert_inputs_unchanged
}

SHARED_OUTPUT="$WORK/shared output"
printf 'preserved-shared-output\n' > "$SHARED_OUTPUT"
expect_collision same-outputs \
  "$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$SHARED_OUTPUT" \
  --primer "$PRIMER" \
  --feature-abi seal-alias-test \
  --out "$SHARED_OUTPUT"
test "$(cat "$SHARED_OUTPUT")" = preserved-shared-output

SYMLINK_MANIFEST="$WORK/symlink manifest"
SYMLINK_CACHE="$WORK/symlink canonical cache"
ln -s "$ENGINE" "$SYMLINK_MANIFEST"
expect_collision symlink \
  "$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$SYMLINK_CACHE" \
  --primer "$PRIMER" \
  --feature-abi seal-alias-test \
  --out "$SYMLINK_MANIFEST"
test -L "$SYMLINK_MANIFEST"
test "$(readlink "$SYMLINK_MANIFEST")" = "$ENGINE"
test ! -e "$SYMLINK_CACHE"

DANGLING_TARGET="$WORK/not-yet-existing output"
DANGLING_LINK="$WORK/dangling output symlink"
ln -s "$DANGLING_TARGET" "$DANGLING_LINK"
expect_collision dangling-symlink \
  "$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$DANGLING_TARGET" \
  --primer "$PRIMER" \
  --feature-abi seal-alias-test \
  --out "$DANGLING_LINK"
test -L "$DANGLING_LINK"
test "$(readlink "$DANGLING_LINK")" = "$DANGLING_TARGET"
test ! -e "$DANGLING_TARGET"

HARDLINK_MANIFEST="$WORK/hardlink manifest"
HARDLINK_CACHE="$WORK/hardlink canonical cache"
ln "$PRIMER" "$HARDLINK_MANIFEST"
PRIMER_INODE="$(stat -c '%d:%i' "$PRIMER")"
expect_collision hardlink \
  "$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$HARDLINK_CACHE" \
  --primer "$PRIMER" \
  --feature-abi seal-alias-test \
  --out "$HARDLINK_MANIFEST"
test "$(stat -c '%d:%i' "$HARDLINK_MANIFEST")" = "$PRIMER_INODE"
test ! -e "$HARDLINK_CACHE"

mkdir -p "$WORK/normalized/nested"
printf 'preserved-normalized-output\n' > "$WORK/normalized/cache"
expect_collision normalized-relative \
  bash -c '
    cd "$1"
    exec "$2" seal \
      --engine engine.wasm \
      --weval "weval tool" \
      --cache source.wevalcache \
      --cache-out normalized/cache \
      --primer primer.js \
      --feature-abi seal-alias-test \
      --out normalized/nested/../cache
  ' bash "$WORK" "$CACHE_TOOL"
test "$(cat "$WORK/normalized/cache")" = preserved-normalized-output

SAFE_CACHE="$WORK/safe canonical cache"
SAFE_MANIFEST="$WORK/safe manifest"
"$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$SAFE_CACHE" \
  --primer "$PRIMER" \
  --feature-abi seal-alias-test \
  --out "$SAFE_MANIFEST"
"$CACHE_TOOL" validate \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SAFE_CACHE" \
  --manifest "$SAFE_MANIFEST" \
  --feature-abi seal-alias-test
assert_inputs_unchanged

IN_PLACE_CACHE="$WORK/in-place cache"
IN_PLACE_MANIFEST="$WORK/in-place manifest"
cp "$SOURCE_CACHE" "$IN_PLACE_CACHE"
"$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$IN_PLACE_CACHE" \
  --primer "$PRIMER" \
  --feature-abi seal-alias-test \
  --out "$IN_PLACE_MANIFEST"
"$CACHE_TOOL" validate \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$IN_PLACE_CACHE" \
  --manifest "$IN_PLACE_MANIFEST" \
  --feature-abi seal-alias-test
cmp "$SAFE_CACHE" "$IN_PLACE_CACHE"

echo "AOT seal alias rejection matrix passed"
