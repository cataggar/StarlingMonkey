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

mkdir -p "$PREFIX/unrelated/nested"
printf 'shared prefix bytes\n' > "$PREFIX/unrelated/nested/preserved.txt"
unrelated_inode="$(stat -c '%d:%i' \
  "$PREFIX/unrelated/nested/preserved.txt")"
unrelated_hash="$(sha256sum "$PREFIX/unrelated/nested/preserved.txt")"

assert_unrelated() {
  test "$(stat -c '%d:%i' \
    "$PREFIX/unrelated/nested/preserved.txt")" = "$unrelated_inode"
  test "$(sha256sum "$PREFIX/unrelated/nested/preserved.txt")" = \
    "$unrelated_hash"
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

kill_process_tree() {
  local root_pid="$1"
  mapfile -t process_tree < <(python3 - "$root_pid" <<'PY'
import subprocess
import sys

root = int(sys.argv[1])
children = {}
for line in subprocess.check_output(
    ["ps", "-eo", "pid=,ppid="], text=True
).splitlines():
    pid, parent = map(int, line.split())
    children.setdefault(parent, []).append(pid)

def descendants(pid):
    for child in children.get(pid, []):
        yield from descendants(child)
        yield child

print(*descendants(root), root, sep="\n")
PY
)
  for pid in "${process_tree[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

test -x "$PREFIX/bin/starling-aot-cache"
baseline_inode="$(stat -c '%d:%i' "$PREFIX")"
test -f "$PREFIX/.starling-aot-engine/owner"
test -f "$PREFIX/.starling-aot-engine/ownership.manifest"
test -L "$PREFIX/bin/starling-raw.wasm"

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
  assert_unrelated
  "$PREFIX/bin/starling-aot-cache" recover-bundle --target "$PREFIX"
  test "$(stat -c '%d:%i' "$PREFIX")" = "$baseline_inode"
  assert_unrelated
done

kill_hook="$SCRATCH/sigkill"
mkdir "$kill_hook"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$kill_hook" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-prefix-switch \
  build_prefix >"$SCRATCH/sigkill.log" 2>&1 &
kill_pid=$!
wait_for_hook "$kill_hook/after-prefix-switch.ready"
kill_process_tree "$kill_pid"
wait "$kill_pid" 2>/dev/null || true
"$PREFIX/bin/starling-aot-cache" recover-bundle --target "$PREFIX"
assert_unrelated
test "$(stat -c '%d:%i' "$PREFIX")" = "$baseline_inode"

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
  --weval "$PREFIX/.starling-aot-engine/current/weval-package/weval" \
  --cache "$PREFIX/bin/starling-ics.wevalcache" \
  --manifest "$PREFIX/bin/starling-ics.wevalcache.manifest"
test -x "$PREFIX/bin/starling-componentize"
test -x "$PREFIX/bin/componentize.sh"
test -x "$PREFIX/bin/weval"
test -s "$PREFIX/bin/preview1-adapter.wasm"
test -s "$PREFIX/bin/features.json"
assert_unrelated
test "$(stat -c '%d:%i' "$PREFIX")" = "$baseline_inode"

echo "Actual shared-prefix upgrade/failure/SIGKILL/concurrency matrix passed"
