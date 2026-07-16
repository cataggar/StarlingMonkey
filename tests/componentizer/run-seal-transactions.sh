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
HOOK="$SCRATCH/hook"

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

SEAL_ARGS=(
  seal
  --engine "$ENGINE"
  --weval "$WEVAL"
  --cache "$SOURCE_CACHE"
  --cache-out "$CACHE_OUT"
  --primer "$PRIMER"
  --feature-abi transaction-test
  --out "$MANIFEST_OUT"
)

seal() {
  "$CACHE_TOOL" "${SEAL_ARGS[@]}"
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

FIRST_CACHE_DIR="$SCRATCH/first journal cache"
FIRST_MANIFEST_DIR="$SCRATCH/first journal manifest"
FIRST_CACHE="$FIRST_CACHE_DIR/cache"
FIRST_MANIFEST="$FIRST_MANIFEST_DIR/manifest"
FIRST_HOOK="$SCRATCH/first-journal-hook"
mkdir "$FIRST_CACHE_DIR" "$FIRST_MANIFEST_DIR" "$FIRST_HOOK"
"$CACHE_TOOL" recover --cache "$FIRST_CACHE" --manifest "$FIRST_MANIFEST"
FIRST_JOURNAL="$(
  find "$FIRST_CACHE_DIR" -maxdepth 1 \
    -name '.starling-aot-seal-*.journal' -print -quit
)"
test -n "$FIRST_JOURNAL"
FIRST_BASELINE="$SCRATCH/first-journal-baseline"
FIRST_RECORD="$SCRATCH/first-journal-record"
cp "$FIRST_JOURNAL" "$FIRST_BASELINE"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$FIRST_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=journal-first-transaction-record \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$FIRST_CACHE" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$FIRST_MANIFEST" >"$SCRATCH/first-journal.log" 2>&1 &
first_pid=$!
wait_for_hook "$FIRST_HOOK/journal-first-transaction-record.ready"
cp "$FIRST_JOURNAL" "$FIRST_RECORD"
kill -KILL "$first_pid"
wait "$first_pid" 2>/dev/null || true
test -z "$(find "$FIRST_CACHE_DIR" "$FIRST_MANIFEST_DIR" \
  -name '*.txn' -print -quit)"
python3 - "$CACHE_TOOL" "$FIRST_CACHE" "$FIRST_MANIFEST" \
  "$FIRST_JOURNAL" "$FIRST_BASELINE" "$FIRST_RECORD" <<'PY'
import subprocess
import sys

tool, cache, manifest, journal, baseline_path, record_path = sys.argv[1:]
baseline = open(baseline_path, "rb").read()
record = open(record_path, "rb").read()

def recover(data, label):
    with open(journal, "wb") as output:
        output.write(data)
        output.flush()
    result = subprocess.run(
        [tool, "recover", "--cache", cache, "--manifest", manifest],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise AssertionError(
            f"{label}: {result.stderr.decode(errors='replace')}"
        )

for length in range(len(baseline) + 1):
    recover(baseline[:length], f"baseline byte {length}")

slot = 64 * 1024
assert len(record) > slot
for length in range(slot, len(record) + 1):
    recover(record[:length], f"first transaction byte {length - slot}")
PY
"$CACHE_TOOL" recover --cache "$FIRST_CACHE" --manifest "$FIRST_MANIFEST"
echo "AOT seal first-journal-write interruption matrix passed"

for phase in \
  after-preflight \
  after-weval-hash \
  after-primer-hash \
  after-cache-hash \
  after-manifest-stage \
  journal-prepared \
  before-cache-publish \
  cache-publication-durable \
  after-cache-publish \
  before-manifest-publish \
  manifest-publication-durable \
  after-manifest-publish \
  publication-pair-durable \
  committed
do
  rm -rf "$HOOK"
  HOOK="$SCRATCH/crash-$phase"
  mkdir "$HOOK"
  cache_before="$(stat -c '%d:%i' "$CACHE_OUT")"
  manifest_before="$(stat -c '%d:%i' "$MANIFEST_OUT")"
  STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
  STARLING_AOT_CACHE_TEST_WAIT_AT="$phase" \
    "$CACHE_TOOL" "${SEAL_ARGS[@]}" \
      > "$SCRATCH/crash-$phase.log" 2>&1 &
  seal_pid=$!
  wait_for_hook "$HOOK/$phase.ready"
  kill -KILL "$seal_pid"
  wait "$seal_pid" 2>/dev/null || true
  "$CACHE_TOOL" recover \
    --cache "$CACHE_OUT" \
    --manifest "$MANIFEST_OUT"
  cache_after="$(stat -c '%d:%i' "$CACHE_OUT")"
  manifest_after="$(stat -c '%d:%i' "$MANIFEST_OUT")"
  if { [ "$cache_after" = "$cache_before" ] &&
      [ "$manifest_after" != "$manifest_before" ]; } ||
    { [ "$cache_after" != "$cache_before" ] &&
      [ "$manifest_after" = "$manifest_before" ]; }
  then
    echo "FAIL: $phase recovery produced a mixed generation" >&2
    exit 1
  fi
  validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
  assert_inputs_unchanged
  assert_no_transaction_files
done

for phase in before-cache-rollback cache-rollback-durable after-cache-rollback; do
  rm -rf "$HOOK"
  HOOK="$SCRATCH/crash-$phase"
  mkdir "$HOOK"
  cache_before="$(stat -c '%d:%i' "$CACHE_OUT")"
  manifest_before="$(stat -c '%d:%i' "$MANIFEST_OUT")"
  STARLING_AOT_CACHE_TEST_FAIL=after-cache-publish \
  STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
  STARLING_AOT_CACHE_TEST_WAIT_AT="$phase" \
    "$CACHE_TOOL" "${SEAL_ARGS[@]}" \
      > "$SCRATCH/crash-$phase.log" 2>&1 &
  seal_pid=$!
  wait_for_hook "$HOOK/$phase.ready"
  kill -KILL "$seal_pid"
  wait "$seal_pid" 2>/dev/null || true
  "$CACHE_TOOL" recover \
    --cache "$CACHE_OUT" \
    --manifest "$MANIFEST_OUT"
  test "$(stat -c '%d:%i' "$CACHE_OUT")" = "$cache_before"
  test "$(stat -c '%d:%i' "$MANIFEST_OUT")" = "$manifest_before"
  validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
  assert_inputs_unchanged
  assert_no_transaction_files
done

CLEANUP_CRASH_HOOK="$SCRATCH/cleanup-crash-commit"
mkdir "$CLEANUP_CRASH_HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$CLEANUP_CRASH_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=committed \
  "$CACHE_TOOL" "${SEAL_ARGS[@]}" \
    >"$SCRATCH/cleanup-crash-commit.log" 2>&1 &
cleanup_pid=$!
wait_for_hook "$CLEANUP_CRASH_HOOK/committed.ready"
kill -KILL "$cleanup_pid"
wait "$cleanup_pid" 2>/dev/null || true
rm -rf "$CLEANUP_CRASH_HOOK"
mkdir "$CLEANUP_CRASH_HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$CLEANUP_CRASH_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=workspace-cleanup-durable \
  "$CACHE_TOOL" recover \
    --cache "$CACHE_OUT" \
    --manifest "$MANIFEST_OUT" \
    >"$SCRATCH/cleanup-crash-recovery.log" 2>&1 &
cleanup_pid=$!
wait_for_hook "$CLEANUP_CRASH_HOOK/workspace-cleanup-durable.ready"
kill -KILL "$cleanup_pid"
wait "$cleanup_pid" 2>/dev/null || true
"$CACHE_TOOL" recover \
  --cache "$CACHE_OUT" \
  --manifest "$MANIFEST_OUT"
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
assert_inputs_unchanged
assert_no_transaction_files
echo "AOT seal durable-cleanup process-death recovery passed"

QUARANTINE_CACHE="$OUTPUTS/quarantine cache"
QUARANTINE_MANIFEST="$MANIFESTS/quarantine manifest"
"$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$QUARANTINE_CACHE" \
  --primer "$PRIMER" \
  --feature-abi transaction-test \
  --out "$QUARANTINE_MANIFEST"
QUARANTINE_BASE_INODE="$(stat -c '%d:%i' "$QUARANTINE_CACHE")"
QUARANTINE_HOOK="$SCRATCH/quarantine-race"
mkdir "$QUARANTINE_HOOK"
STARLING_AOT_CACHE_TEST_FAIL=after-cache-publish \
STARLING_AOT_CACHE_TEST_HOOK_DIR="$QUARANTINE_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-cache-rollback-namespace \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$QUARANTINE_CACHE" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$QUARANTINE_MANIFEST" \
    >"$SCRATCH/quarantine-race.log" 2>&1 &
quarantine_pid=$!
wait_for_hook \
  "$QUARANTINE_HOOK/before-cache-rollback-namespace.ready"
mv "$QUARANTINE_CACHE" "$SCRATCH/quarantine-owned-new"
printf 'foreign rollback replacement\n' > "$QUARANTINE_CACHE"
foreign_inode="$(stat -c '%d:%i' "$QUARANTINE_CACHE")"
touch "$QUARANTINE_HOOK/before-cache-rollback-namespace.continue"
if wait "$quarantine_pid"; then
  echo "FAIL: rollback quarantine race unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq TransactionRecoveryRequired "$SCRATCH/quarantine-race.log"
test "$(stat -c '%d:%i' "$QUARANTINE_CACHE")" = "$foreign_inode"
grep -Fq 'foreign rollback replacement' "$QUARANTINE_CACHE"
mv "$QUARANTINE_CACHE" "$SCRATCH/quarantine-foreign-preserved"
mv "$SCRATCH/quarantine-owned-new" "$QUARANTINE_CACHE"
"$CACHE_TOOL" recover \
  --cache "$QUARANTINE_CACHE" \
  --manifest "$QUARANTINE_MANIFEST"
test "$(stat -c '%d:%i' "$QUARANTINE_CACHE")" = "$QUARANTINE_BASE_INODE"
grep -Fq 'foreign rollback replacement' \
  "$SCRATCH/quarantine-foreign-preserved"
validate_pair "$QUARANTINE_CACHE" "$QUARANTINE_MANIFEST"

rm -rf "$QUARANTINE_HOOK"
mkdir "$QUARANTINE_HOOK"
STARLING_AOT_CACHE_TEST_FAIL=after-cache-publish \
STARLING_AOT_CACHE_TEST_HOOK_DIR="$QUARANTINE_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-cache-rollback-namespace,cache-rollback-quarantined \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$QUARANTINE_CACHE" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$QUARANTINE_MANIFEST" \
    >"$SCRATCH/quarantine-crash.log" 2>&1 &
quarantine_pid=$!
wait_for_hook "$QUARANTINE_HOOK/before-cache-rollback-namespace.ready"
mv "$QUARANTINE_CACHE" "$SCRATCH/quarantine-crash-owned-new"
printf 'foreign crash replacement\n' > "$QUARANTINE_CACHE"
touch "$QUARANTINE_HOOK/before-cache-rollback-namespace.continue"
wait_for_hook "$QUARANTINE_HOOK/cache-rollback-quarantined.ready"
kill -KILL "$quarantine_pid"
wait "$quarantine_pid" 2>/dev/null || true
test "$(stat -c '%d:%i' "$QUARANTINE_CACHE")" = "$QUARANTINE_BASE_INODE"
quarantined_foreign="$(
  grep -rl 'foreign crash replacement' "$OUTPUTS" |
    head -1
)"
test -n "$quarantined_foreign"
if "$CACHE_TOOL" recover \
  --cache "$QUARANTINE_CACHE" \
  --manifest "$QUARANTINE_MANIFEST" \
  >"$SCRATCH/quarantine-crash-recover.log" 2>&1
then
  echo "FAIL: quarantined recovery discarded a foreign object" >&2
  exit 1
fi
grep -Fq TransactionRecoveryRequired \
  "$SCRATCH/quarantine-crash-recover.log"
grep -Fq 'foreign crash replacement' "$quarantined_foreign"
test -e "$SCRATCH/quarantine-crash-owned-new"

quarantine_old_stage="$quarantined_foreign"
mv "$QUARANTINE_CACHE" "$SCRATCH/quarantine-crash-old"
mv "$quarantine_old_stage" "$QUARANTINE_CACHE"
mv "$SCRATCH/quarantine-crash-old" "$quarantine_old_stage"
mv "$QUARANTINE_CACHE" "$SCRATCH/quarantine-crash-foreign-preserved"
mv "$SCRATCH/quarantine-crash-owned-new" "$QUARANTINE_CACHE"
"$CACHE_TOOL" recover \
  --cache "$QUARANTINE_CACHE" \
  --manifest "$QUARANTINE_MANIFEST"
test "$(stat -c '%d:%i' "$QUARANTINE_CACHE")" = "$QUARANTINE_BASE_INODE"
grep -Fq 'foreign crash replacement' \
  "$SCRATCH/quarantine-crash-foreign-preserved"
validate_pair "$QUARANTINE_CACHE" "$QUARANTINE_MANIFEST"
echo "AOT rollback atomic quarantine race/crash matrix passed"

for phase in before-cache-rollback after-cache-rollback committed; do
  rm -rf "$HOOK"
  HOOK="$SCRATCH/replacement-$phase"
  mkdir "$HOOK"
  if [ "$phase" = committed ]; then
    STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
    STARLING_AOT_CACHE_TEST_WAIT_AT="$phase" \
      "$CACHE_TOOL" "${SEAL_ARGS[@]}" \
        > "$SCRATCH/replacement-$phase.log" 2>&1 &
  else
    STARLING_AOT_CACHE_TEST_FAIL=after-cache-publish \
    STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
    STARLING_AOT_CACHE_TEST_WAIT_AT="$phase" \
      "$CACHE_TOOL" "${SEAL_ARGS[@]}" \
        > "$SCRATCH/replacement-$phase.log" 2>&1 &
  fi
  seal_pid=$!
  wait_for_hook "$HOOK/$phase.ready"
  mv "$CACHE_OUT" "$SCRATCH/replacement-owned-$phase"
  printf 'external replacement at %s\n' "$phase" > "$CACHE_OUT"
  replacement_inode="$(stat -c '%d:%i' "$CACHE_OUT")"
  touch "$HOOK/$phase.continue"
  if wait "$seal_pid"; then
    echo "FAIL: replacement at $phase unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Fq TransactionRecoveryRequired \
    "$SCRATCH/replacement-$phase.log"
  test "$(stat -c '%d:%i' "$CACHE_OUT")" = "$replacement_inode"
  grep -Fq "external replacement at $phase" "$CACHE_OUT"
  rm "$CACHE_OUT"
  mv "$SCRATCH/replacement-owned-$phase" "$CACHE_OUT"
  "$CACHE_TOOL" recover \
    --cache "$CACHE_OUT" \
    --manifest "$MANIFEST_OUT"
  validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
  assert_inputs_unchanged
  assert_no_transaction_files
done

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

LEGACY_JOURNAL="$OUTPUTS/.aot-transaction-abandoned"
printf 'state=prepared\n' > "$LEGACY_JOURNAL"
if validate_pair "$CACHE_OUT" "$MANIFEST_OUT" \
    > "$SCRATCH/legacy-journal.log" 2>&1; then
  echo "FAIL: validation ignored an unrecoverable legacy journal" >&2
  exit 1
fi
grep -Fq InvalidRecoveryJournal "$SCRATCH/legacy-journal.log"
rm "$LEGACY_JOURNAL"
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"

rm -rf "$HOOK"
HOOK="$SCRATCH/validation-race"
mkdir "$HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=validation-opened \
  "$CACHE_TOOL" validate \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$CACHE_OUT" \
    --manifest "$MANIFEST_OUT" \
    --feature-abi transaction-test \
    > "$SCRATCH/validation-race.log" 2>&1 &
validator_pid=$!
wait_for_hook "$HOOK/validation-opened.ready"
mv "$CACHE_OUT" "$SCRATCH/validation-open-cache"
mv "$MANIFEST_OUT" "$SCRATCH/validation-open-manifest"
printf 'replacement cache\n' > "$CACHE_OUT"
printf 'replacement manifest\n' > "$MANIFEST_OUT"
touch "$HOOK/validation-opened.continue"
wait "$validator_pid"
grep -Fq 'Validated AOT cache' "$SCRATCH/validation-race.log"
rm "$CACHE_OUT" "$MANIFEST_OUT"
mv "$SCRATCH/validation-open-cache" "$CACHE_OUT"
mv "$SCRATCH/validation-open-manifest" "$MANIFEST_OUT"
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
grep -Fq TransactionRecoveryRequired \
  "$SCRATCH/second-publication-race.log"
test -L "$MANIFEST_OUT"
test "$(readlink "$MANIFEST_OUT")" = "$ENGINE"
test "$(sha256sum "$SCRATCH/raced-original-manifest")" = \
  "$(printf '%s\n' "$PAIR_HASHES" | tail -1 | sed "s|  $MANIFEST_OUT\$|  $SCRATCH/raced-original-manifest|")"
assert_inputs_unchanged
rm "$MANIFEST_OUT"
mv "$SCRATCH/raced-original-manifest" "$MANIFEST_OUT"
"$CACHE_TOOL" recover \
  --cache "$CACHE_OUT" \
  --manifest "$MANIFEST_OUT"
test "$(stat -c '%d:%i' "$CACHE_OUT")" = \
  "$(printf '%s\n' "$PAIR_INODES" | head -1)"
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
assert_no_transaction_files

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
STARLING_AOT_CACHE_TEST_WAIT_AT=after-cache-parent-anchor \
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
wait_for_hook "$HOOK/after-cache-parent-anchor.ready"
ln -sfn "$RETARGET_PARENT" "$PARENT_LINK"
touch "$HOOK/after-cache-parent-anchor.continue"
wait "$seal_pid"
test -f "$ORIGINAL_PARENT/cache"
test -f "$ORIGINAL_PARENT/manifest"
test ! -e "$RETARGET_PARENT/cache"
test ! -e "$RETARGET_PARENT/manifest"
validate_pair "$ORIGINAL_PARENT/cache" "$ORIGINAL_PARENT/manifest"
assert_inputs_unchanged
assert_no_transaction_files

REPLACED_CACHE="$OUTPUTS/input replacement cache"
REPLACED_MANIFEST="$MANIFESTS/input replacement manifest"
rm -rf "$HOOK"
HOOK="$SCRATCH/input-path-race"
mkdir "$HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$REPLACED_CACHE" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$REPLACED_MANIFEST" \
    > "$SCRATCH/input-path-race.log" 2>&1 &
seal_pid=$!
wait_for_hook "$HOOK/after-preflight.ready"
for input in "$ENGINE" "$WEVAL" "$SOURCE_CACHE" "$PRIMER"; do
  mv "$input" "$input.opened"
  printf 'raced replacement\n' > "$input"
done
touch "$HOOK/after-preflight.continue"
if wait "$seal_pid"; then
  echo "FAIL: replaced input paths unexpectedly passed stable sealing" >&2
  exit 1
fi
grep -Fq SealPathRace "$SCRATCH/input-path-race.log"
for input in "$ENGINE" "$WEVAL" "$SOURCE_CACHE" "$PRIMER"; do
  rm "$input"
  mv "$input.opened" "$input"
done
"$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$WEVAL" \
  --cache "$SOURCE_CACHE" \
  --cache-out "$REPLACED_CACHE" \
  --primer "$PRIMER" \
  --feature-abi transaction-test \
  --out "$REPLACED_MANIFEST"
validate_pair "$REPLACED_CACHE" "$REPLACED_MANIFEST"
assert_inputs_unchanged
assert_no_transaction_files

MUTATION_HOOK="$SCRATCH/in-place-mutation"
MUTATION_CACHE="$OUTPUTS/in-place mutation cache"
MUTATION_MANIFEST="$MANIFESTS/in-place mutation manifest"
MUTATION_ENGINE_BACKUP="$SCRATCH/in-place-engine-backup"
cp -p "$ENGINE" "$MUTATION_ENGINE_BACKUP"
mkdir "$MUTATION_HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$MUTATION_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-engine-hash \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$MUTATION_CACHE" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$MUTATION_MANIFEST" \
    >"$SCRATCH/in-place-mutation.log" 2>&1 &
mutation_pid=$!
wait_for_hook "$MUTATION_HOOK/after-engine-hash.ready"
python3 - "$ENGINE" <<'PY'
import os
import sys

path = sys.argv[1]
stat = os.stat(path)
with open(path, "r+b") as handle:
    original = handle.read()
    changed = bytearray(original)
    changed[0] ^= 1
    handle.seek(0)
    handle.write(changed)
    handle.flush()
    os.fsync(handle.fileno())
os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
PY
touch "$MUTATION_HOOK/after-engine-hash.continue"
if wait "$mutation_pid"; then
  echo "FAIL: same-size in-place mutation with restored mtime succeeded" >&2
  exit 1
fi
cp -p "$MUTATION_ENGINE_BACKUP" "$ENGINE"
grep -Fq SealPathRace "$SCRATCH/in-place-mutation.log"
test ! -e "$MUTATION_CACHE"
test ! -e "$MUTATION_MANIFEST"

rm -rf "$MUTATION_HOOK"
mkdir "$MUTATION_HOOK"
MUTATION_CACHE_BACKUP="$SCRATCH/in-place-cache-backup"
cp -p "$CACHE_OUT" "$MUTATION_CACHE_BACKUP"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$MUTATION_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=validation-opened \
  "$CACHE_TOOL" validate \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$CACHE_OUT" \
    --manifest "$MANIFEST_OUT" \
    --feature-abi transaction-test \
    >"$SCRATCH/validation-in-place-mutation.log" 2>&1 &
mutation_pid=$!
wait_for_hook "$MUTATION_HOOK/validation-opened.ready"
python3 - "$CACHE_OUT" <<'PY'
import os
import sys

path = sys.argv[1]
stat = os.stat(path)
with open(path, "r+b") as handle:
    original = handle.read(1)
    handle.seek(0)
    handle.write(bytes([original[0] ^ 1]))
    handle.flush()
    os.fsync(handle.fileno())
os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
PY
touch "$MUTATION_HOOK/validation-opened.continue"
if wait "$mutation_pid"; then
  echo "FAIL: validation accepted restored-mtime in-place mutation" >&2
  exit 1
fi
cp -p "$MUTATION_CACHE_BACKUP" "$CACHE_OUT"
grep -Eq 'CorruptCache|InvalidCacheFormat|SealPathRace' \
  "$SCRATCH/validation-in-place-mutation.log"
validate_pair "$CACHE_OUT" "$MANIFEST_OUT"
assert_inputs_unchanged
assert_no_transaction_files

OVERLAP="$SCRATCH/overlapping destinations"
mkdir "$OVERLAP"
OVERLAP_X="$OVERLAP/x"
OVERLAP_Y="$OVERLAP/y"
OVERLAP_Z="$OVERLAP/z"
OVERLAP_HOOK_A="$SCRATCH/overlap-A"
OVERLAP_HOOK_B="$SCRATCH/overlap-B"
mkdir "$OVERLAP_HOOK_A" "$OVERLAP_HOOK_B"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$OVERLAP_HOOK_A" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$OVERLAP_X" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$OVERLAP_Y" >"$SCRATCH/overlap-A.log" 2>&1 &
overlap_pid_a=$!
wait_for_hook "$OVERLAP_HOOK_A/after-preflight.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$OVERLAP_HOOK_B" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
STARLING_AOT_CACHE_TEST_NOTIFY_AT=before-destination-locks \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$OVERLAP_X" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$OVERLAP_Z" >"$SCRATCH/overlap-B.log" 2>&1 &
overlap_pid_b=$!
wait_for_hook "$OVERLAP_HOOK_B/before-destination-locks.ready"
test ! -e "$OVERLAP_HOOK_B/after-preflight.ready"
touch "$OVERLAP_HOOK_A/after-preflight.continue"
wait "$overlap_pid_a"
wait_for_hook "$OVERLAP_HOOK_B/after-preflight.ready"
touch "$OVERLAP_HOOK_B/after-preflight.continue"
wait "$overlap_pid_b"
validate_pair "$OVERLAP_X" "$OVERLAP_Y"
validate_pair "$OVERLAP_X" "$OVERLAP_Z"

REVERSE_X="$OVERLAP/reverse-x"
REVERSE_Y="$OVERLAP/reverse-y"
REVERSE_Z="$OVERLAP/reverse-z"
rm -rf "$OVERLAP_HOOK_A" "$OVERLAP_HOOK_B"
mkdir "$OVERLAP_HOOK_A" "$OVERLAP_HOOK_B"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$OVERLAP_HOOK_A" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$REVERSE_X" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$REVERSE_Y" >"$SCRATCH/reverse-A.log" 2>&1 &
overlap_pid_a=$!
wait_for_hook "$OVERLAP_HOOK_A/after-preflight.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$OVERLAP_HOOK_B" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
STARLING_AOT_CACHE_TEST_NOTIFY_AT=before-destination-locks \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$REVERSE_Z" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$REVERSE_X" >"$SCRATCH/reverse-B.log" 2>&1 &
overlap_pid_b=$!
wait_for_hook "$OVERLAP_HOOK_B/before-destination-locks.ready"
test ! -e "$OVERLAP_HOOK_B/after-preflight.ready"
touch "$OVERLAP_HOOK_A/after-preflight.continue"
wait "$overlap_pid_a"
wait_for_hook "$OVERLAP_HOOK_B/after-preflight.ready"
touch "$OVERLAP_HOOK_B/after-preflight.continue"
wait "$overlap_pid_b"
validate_pair "$REVERSE_Z" "$REVERSE_X"

RECOVERY_HOOK="$SCRATCH/recovery-lock"
RECOVERY_SEAL_HOOK="$SCRATCH/recovery-overlap"
RECOVERY_MANIFEST="$OVERLAP/recovery-manifest"
mkdir "$RECOVERY_HOOK" "$RECOVERY_SEAL_HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$RECOVERY_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=recovery-locked \
  "$CACHE_TOOL" recover \
    --cache "$OVERLAP_X" \
    --manifest "$OVERLAP_Y" >"$SCRATCH/recovery-lock.log" 2>&1 &
recovery_pid=$!
wait_for_hook "$RECOVERY_HOOK/recovery-locked.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$RECOVERY_SEAL_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-preflight \
STARLING_AOT_CACHE_TEST_NOTIFY_AT=before-destination-locks \
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$WEVAL" \
    --cache "$SOURCE_CACHE" \
    --cache-out "$OVERLAP_X" \
    --primer "$PRIMER" \
    --feature-abi transaction-test \
    --out "$RECOVERY_MANIFEST" \
    >"$SCRATCH/recovery-overlap.log" 2>&1 &
overlap_pid_b=$!
wait_for_hook "$RECOVERY_SEAL_HOOK/before-destination-locks.ready"
test ! -e "$RECOVERY_SEAL_HOOK/after-preflight.ready"
touch "$RECOVERY_HOOK/recovery-locked.continue"
wait "$recovery_pid"
wait_for_hook "$RECOVERY_SEAL_HOOK/after-preflight.ready"
touch "$RECOVERY_SEAL_HOOK/after-preflight.continue"
wait "$overlap_pid_b"
validate_pair "$OVERLAP_X" "$RECOVERY_MANIFEST"

assert_inputs_unchanged
assert_no_transaction_files
echo "AOT seal shared-destination lock ordering passed"
echo "AOT seal descriptor race and rollback matrix passed"
