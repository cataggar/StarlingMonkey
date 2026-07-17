#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <zig>" >&2
  exit 2
fi

ZIG="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/require-zig-version.sh" "$ZIG"
ASSEMBLER="$ROOT/deps/assemble-spidermonkey-archive.sh"
SCRATCH="$ROOT/deps/.spidermonkey-archive-test"
OBJECT_ROOT="$SCRATCH/objects"
BASE="$OBJECT_ROOT/js/src/build/libjs_static.a"
OBJECT_A="$OBJECT_ROOT/memory/build/required-a.o"
OBJECT_B="$OBJECT_ROOT/mozglue/misc/required-b.o"
ARCHIVE="$SCRATCH/dist/libspidermonkey.a"
MARKER="$ARCHIVE.complete"

rm -rf "$SCRATCH"
mkdir -p "$(dirname "$BASE")" "$(dirname "$OBJECT_A")" \
  "$(dirname "$OBJECT_B")" "$(dirname "$ARCHIVE")"
trap 'rm -rf "$SCRATCH"' EXIT

printf 'base-member\n' > "$SCRATCH/base-member.o"
"$ZIG" ar rcs "$BASE" "$SCRATCH/base-member.o"
printf 'required-a-v1\n' > "$OBJECT_A"
printf 'required-b-v1\n' > "$OBJECT_B"

assemble() {
  bash "$ASSEMBLER" "$ZIG" "$ARCHIVE" "$MARKER" test TEST_TAG \
    "$BASE" "$OBJECT_ROOT" "$OBJECT_A" "$OBJECT_B"
}

validate() {
  bash "$ASSEMBLER" --validate "$ZIG" "$ARCHIVE" "$MARKER" test \
    TEST_TAG "$BASE" "$OBJECT_ROOT" "$OBJECT_A" "$OBJECT_B"
}

wait_for_hook() {
  local ready="$1"
  for _ in $(seq 1 10000); do
    [ -e "$ready" ] && return
    sleep 0.001
  done
  echo "FAIL: timed out waiting for $ready" >&2
  exit 1
}

assert_no_temporary_archives() {
  test -z "$(
    find "$(dirname "$ARCHIVE")" -maxdepth 1 -type f \
      \( -name 'libspidermonkey.a.tmp.*' \
        -o -name 'libspidermonkey.a.complete.tmp.*' \) \
      -print -quit
  )"
}

assemble
validate
for phase in archive-created member-appended-1 members-appended \
  archive-published before-marker
do
  printf '\n%s\n' "$phase" >> "$OBJECT_B"
  if STARLING_SM_ARCHIVE_TEST_FAIL="$phase" assemble \
    >"$SCRATCH/failure-$phase.log" 2>&1
  then
    echo "FAIL: $phase archive interruption unexpectedly succeeded" >&2
    exit 1
  fi
  if validate 2>/dev/null; then
    echo "FAIL: $phase left a new input validated by an old pair" >&2
    exit 1
  fi
  assert_no_temporary_archives
  assemble
  validate
done

printf 'stale marker\n' > "$MARKER"
if validate 2>/dev/null; then
  echo "FAIL: stale archive marker was accepted" >&2
  exit 1
fi
assemble
validate

printf 'corrupt archive\n' > "$ARCHIVE"
if validate 2>/dev/null; then
  echo "FAIL: corrupt archive was accepted" >&2
  exit 1
fi
assemble
validate

KILL_HOOK="$SCRATCH/kill-hook"
mkdir "$KILL_HOOK"
printf '\nkill-rebuild\n' >> "$OBJECT_A"
STARLING_SM_ARCHIVE_TEST_HOOK_DIR="$KILL_HOOK" \
STARLING_SM_ARCHIVE_TEST_WAIT_AT=member-appended-1 \
  bash "$ASSEMBLER" "$ZIG" "$ARCHIVE" "$MARKER" test TEST_TAG \
    "$BASE" "$OBJECT_ROOT" "$OBJECT_A" "$OBJECT_B" \
    >"$SCRATCH/kill.log" 2>&1 &
kill_pid=$!
wait_for_hook "$KILL_HOOK/member-appended-1.ready"
kill -KILL "$kill_pid"
wait "$kill_pid" 2>/dev/null || true
assemble
validate
assert_no_temporary_archives

HOOK_A="$SCRATCH/concurrent-a"
HOOK_B="$SCRATCH/concurrent-b"
mkdir "$HOOK_A" "$HOOK_B"
printf '\nconcurrent-rebuild\n' >> "$OBJECT_A"
STARLING_SM_ARCHIVE_TEST_HOOK_DIR="$HOOK_A" \
STARLING_SM_ARCHIVE_TEST_WAIT_AT=members-appended \
  assemble >"$SCRATCH/concurrent-a.log" 2>&1 &
pid_a=$!
wait_for_hook "$HOOK_A/members-appended.ready"
STARLING_SM_ARCHIVE_TEST_FAIL=archive-created \
  assemble >"$SCRATCH/concurrent-b.log" 2>&1 &
pid_b=$!
sleep 0.05
kill -0 "$pid_b"
touch "$HOOK_A/members-appended.continue"
wait "$pid_a"
wait "$pid_b"
validate
assert_no_temporary_archives

test "$("$ZIG" ar -t "$ARCHIVE" | wc -l)" -eq 3
echo "Atomic SpiderMonkey archive interruption/concurrency matrix passed"
