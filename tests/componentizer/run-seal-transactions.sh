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
SCRATCH="$ROOT/tests/componentizer/.seal-transactions"
INPUTS="$SCRATCH/inputs"
ENGINE="$INPUTS/engine.wasm"
WEVAL="$INPUTS/weval"
SOURCE_CACHE="$INPUTS/source.wevalcache"
PRIMER="$INPUTS/primer.js"
OUTPUTS="$SCRATCH/cache output"
MANIFESTS="$SCRATCH/manifest output"
CACHE_OUT="$OUTPUTS/starling.wevalcache"
MANIFEST_OUT="$MANIFESTS/starling.wevalcache.manifest"

rm -rf "$SCRATCH"
mkdir -p "$INPUTS" "$OUTPUTS" "$MANIFESTS"
trap 'rm -rf "$SCRATCH"' EXIT

printf 'transaction-engine\n' > "$ENGINE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WEVAL"
chmod +x "$WEVAL"
printf 'function transactionPrimer() { return 1; }\n' > "$PRIMER"
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
    (engine_hash, b"transaction-key", b"transaction-result", 23),
)
db.execute("create index idx on weval_cache(module_hash, key)")
db.commit()
db.close()
PY

INPUT_HASHES="$(sha256sum "$ENGINE" "$WEVAL" "$SOURCE_CACHE" "$PRIMER")"

seal() {
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$CACHE_OUT" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$MANIFEST_OUT"
}

validate_pair() {
  "$CACHE_TOOL" validate \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$1" \
    --manifest "$2" \
    --feature-abi transaction-test
}

assert_inputs_unchanged() {
  test "$(sha256sum "$ENGINE" "$WEVAL" "$SOURCE_CACHE" "$PRIMER")" = \
    "$INPUT_HASHES"
}

assert_no_transaction_files() {
  if find "$SCRATCH" -name '.aot-*' -print -quit | grep -q .; then
    echo "FAIL: AOT seal left a transaction artifact" >&2
    find "$SCRATCH" -name '.aot-*' -print >&2
    exit 1
  fi
}

wait_for_hook() {
  local ready="$1"
  for _ in $(seq 1 10000); do
    test -e "$ready" && return
    sleep 0.001
  done
  echo "FAIL: timed out waiting for $ready" >&2
  exit 1
}

seal
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
PAIR_HASHES="$(sha256sum "$CACHE_OUT" "$MANIFEST_OUT")"
PAIR_INODES="$(stat -c '%d:%i' "$CACHE_OUT" "$MANIFEST_OUT")"

for phase in after-weval-hash after-primer-hash after-cache-hash after-manifest-stage; do
  if STARLING_AOT_CACHE_TEST_FAIL="$phase" seal \
      > "$SCRATCH/fail-$phase.log" 2>&1; then
    echo "FAIL: injected $phase failure unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Fq AotCacheTestFailure "$SCRATCH/fail-$phase.log"
  test "$(sha256sum "$CACHE_OUT" "$MANIFEST_OUT")" = "$PAIR_HASHES"
  test "$(stat -c '%d:%i' "$CACHE_OUT" "$MANIFEST_OUT")" = "$PAIR_INODES"
  assert_inputs_unchanged
  assert_no_transaction_files
done

if STARLING_AOT_CACHE_TEST_FAIL=after-first-publish seal \
    > "$SCRATCH/fail-after-first.log" 2>&1; then
  echo "FAIL: injected post-publication failure unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq AotCacheTestFailure "$SCRATCH/fail-after-first.log"
test "$(sha256sum "$CACHE_OUT" "$MANIFEST_OUT")" = "$PAIR_HASHES"
test "$(stat -c '%d:%i' "$CACHE_OUT" "$MANIFEST_OUT")" = "$PAIR_INODES"
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
assert_inputs_unchanged
assert_no_transaction_files

MISSING_CACHE="$OUTPUTS/missing rollback cache"
MISSING_MANIFEST="$MANIFESTS/missing rollback manifest"
if STARLING_AOT_CACHE_TEST_FAIL=after-first-publish \
    "$CACHE_TOOL" seal \
      --engine "$ENGINE" \
      --weval "$WEVAL" \
      --cache "$SOURCE_CACHE" \
      --cache-out "$MISSING_CACHE" \
      --primer "$PRIMER" \
      --feature-abi transaction-test \
      --out "$MISSING_MANIFEST" \
      > "$SCRATCH/fail-missing-after-first.log" 2>&1; then
  echo "FAIL: missing-destination rollback unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq AotCacheTestFailure "$SCRATCH/fail-missing-after-first.log"
test ! -e "$MISSING_CACHE"
test ! -e "$MISSING_MANIFEST"
assert_inputs_unchanged
assert_no_transaction_files

HOOK="$SCRATCH/hook-manifest-race"
mkdir "$HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
  seal > "$SCRATCH/manifest-race.log" 2>&1 &
seal_pid=$!
wait_for_hook "$HOOK/after-preflight.ready"
mv "$MANIFEST_OUT" "$SCRATCH/original-manifest"
ln -s "$ENGINE" "$MANIFEST_OUT"
touch "$HOOK/after-preflight.continue"
if wait "$seal_pid"; then
  echo "FAIL: raced manifest symlink unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq SealPathRace "$SCRATCH/manifest-race.log"
test -L "$MANIFEST_OUT"
test "$(readlink "$MANIFEST_OUT")" = "$ENGINE"
test "$(sha256sum "$CACHE_OUT")" = "$(printf '%s\n' "$PAIR_HASHES" | head -1)"
assert_inputs_unchanged
assert_no_transaction_files
rm "$MANIFEST_OUT"
mv "$SCRATCH/original-manifest" "$MANIFEST_OUT"

rm -rf "$HOOK"
mkdir "$HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-first-publish \
  seal > "$SCRATCH/second-publication-race.log" 2>&1 &
seal_pid=$!
wait_for_hook "$HOOK/after-first-publish.ready"
mv "$MANIFEST_OUT" "$SCRATCH/raced-original-manifest"
ln -s "$ENGINE" "$MANIFEST_OUT"
touch "$HOOK/after-first-publish.continue"
if wait "$seal_pid"; then
  echo "FAIL: raced second publication unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq SealPathRace "$SCRATCH/second-publication-race.log"
test "$(stat -c '%d:%i' "$CACHE_OUT")" = "$(printf '%s\n' "$PAIR_INODES" | head -1)"
test -L "$MANIFEST_OUT"
test "$(readlink "$MANIFEST_OUT")" = "$ENGINE"
test "$(sha256sum "$SCRATCH/raced-original-manifest")" = \
  "$(printf '%s\n' "$PAIR_HASHES" | tail -1 | sed "s|  $MANIFEST_OUT\$|  $SCRATCH/raced-original-manifest|")"
assert_inputs_unchanged
assert_no_transaction_files
rm "$MANIFEST_OUT"
mv "$SCRATCH/raced-original-manifest" "$MANIFEST_OUT"
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"

ORIGINAL_PARENT="$SCRATCH/original parent"
RETARGET_PARENT="$SCRATCH/retarget parent"
PARENT_LINK="$SCRATCH/output parent link"
mkdir "$ORIGINAL_PARENT" "$RETARGET_PARENT"
ln -s "$ORIGINAL_PARENT" "$PARENT_LINK"
LINK_CACHE="$PARENT_LINK/cache"
LINK_MANIFEST="$ORIGINAL_PARENT/manifest"
rm -rf "$HOOK"
mkdir "$HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$LINK_CACHE" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$LINK_MANIFEST" \
    > "$SCRATCH/parent-race.log" 2>&1 &
seal_pid=$!
wait_for_hook "$HOOK/after-preflight.ready"
ln -sfn "$RETARGET_PARENT" "$PARENT_LINK"
touch "$HOOK/after-preflight.continue"
wait "$seal_pid"
test -f "$ORIGINAL_PARENT/cache"
test -f "$ORIGINAL_PARENT/manifest"
test ! -e "$RETARGET_PARENT/cache"
test ! -e "$RETARGET_PARENT/manifest"
validate_pair "$ORIGINAL_PARENT/cache" "$ORIGINAL_PARENT/manifest"
assert_inputs_unchanged
assert_no_transaction_files

echo "AOT seal descriptor race and rollback matrix passed"
