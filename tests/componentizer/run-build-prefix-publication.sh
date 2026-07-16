#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <zig> <published-prefix>" >&2
  exit 2
fi

ZIG="$1"
PREFIX="$(realpath "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
SCRATCH="$ROOT/tests/componentizer/.build-prefix-publication"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

build_prefix() {
  "$ZIG" build \
    --prefix "$PREFIX" \
    -Doptimize=ReleaseSmall \
    -Daot-engine=true
}

prefix_hash() {
  find "$PREFIX" -type f -print0 |
    sort -z |
    xargs -0 sha256sum |
    sha256sum
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

test -x "$PREFIX/bin/starling-aot-cache"
baseline_inode="$(stat -c '%d:%i' "$PREFIX")"
baseline_hash="$(prefix_hash)"

for phase in \
  prefix-files-durable \
  prefix-validated \
  prefix-prepared \
  before-prefix-switch \
  after-prefix-switch
do
  if STARLING_AOT_CACHE_TEST_FAIL="$phase" build_prefix \
    >"$SCRATCH/failure-$phase.log" 2>&1
  then
    echo "FAIL: build-prefix $phase injection unexpectedly succeeded" >&2
    exit 1
  fi
  grep -Fq AotCacheTestFailure "$SCRATCH/failure-$phase.log"
  test "$(stat -c '%d:%i' "$PREFIX")" = "$baseline_inode"
  test "$(prefix_hash)" = "$baseline_hash"
  "$PREFIX/bin/starling-aot-cache" recover-bundle --target "$PREFIX"
  test "$(stat -c '%d:%i' "$PREFIX")" = "$baseline_inode"
  test "$(prefix_hash)" = "$baseline_hash"
done

hook_a="$SCRATCH/concurrent-A"
hook_b="$SCRATCH/concurrent-B"
mkdir "$hook_a" "$hook_b"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$hook_a" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-prefix-switch \
  build_prefix >"$SCRATCH/concurrent-A.log" 2>&1 &
pid_a=$!
wait_for_hook "$hook_a/before-prefix-switch.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$hook_b" \
STARLING_AOT_CACHE_TEST_WAIT_AT=prefix-prepared \
STARLING_AOT_CACHE_TEST_NOTIFY_AT=prefix-lock-attempt \
  build_prefix >"$SCRATCH/concurrent-B.log" 2>&1 &
pid_b=$!
wait_for_hook "$hook_b/prefix-lock-attempt.ready"
test ! -e "$hook_b/prefix-prepared.ready"
touch "$hook_a/before-prefix-switch.continue"
wait "$pid_a"
wait_for_hook "$hook_b/prefix-prepared.ready"
touch "$hook_b/prefix-prepared.continue"
wait "$pid_b"

"$PREFIX/bin/starling-aot-cache" validate \
  --engine "$PREFIX/bin/starling-raw.wasm" \
  --weval "$PREFIX/bin/weval" \
  --cache "$PREFIX/bin/starling-ics.wevalcache" \
  --manifest "$PREFIX/bin/starling-ics.wevalcache.manifest"
test -x "$PREFIX/bin/starling-componentize"
test -x "$PREFIX/bin/componentize.sh"
test -x "$PREFIX/bin/weval"
test -s "$PREFIX/bin/preview1-adapter.wasm"
test -s "$PREFIX/bin/features.json"

echo "Actual Zig build-prefix failure/concurrency matrix passed"
