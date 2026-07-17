#!/usr/bin/env bash
set -euo pipefail

validate_only=0
if [ "${1:-}" = --validate ]; then
  validate_only=1
  shift
fi
if [ "$#" -lt 8 ]; then
  echo "usage: $0 [--validate] <zig> <archive> <marker> <variant> <tag> <base-archive> <object-root> <object>..." >&2
  exit 2
fi

zig="$1"
archive="$2"
marker="$3"
variant="$4"
tag="$5"
base_archive="$6"
object_root="$7"
shift 7
objects=("$@")
schema=starling-spidermonkey-archive-v1

input_key() {
  {
    printf 'schema=%s\nvariant=%s\ntag=%s\n' "$schema" "$variant" "$tag"
    printf 'base=%s\n' "$(sha256sum "$base_archive" | cut -d ' ' -f 1)"
    for object in "${objects[@]}"; do
      case "$object" in
        "$object_root"/*) relative="${object#"$object_root"/}" ;;
        *)
          echo "object is outside the declared object root: $object" >&2
          return 1
          ;;
      esac
      printf 'object=%s:%s\n' "$relative" \
        "$(sha256sum "$object" | cut -d ' ' -f 1)"
    done
  } | sha256sum | cut -d ' ' -f 1
}

archive_members() {
  "$zig" ar -t "$1"
}

verify_archive() {
  local candidate="$1" members base_members expected_count actual_count
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  members="$(archive_members "$candidate" 2>/dev/null)" || return 1
  base_members="$(archive_members "$base_archive" 2>/dev/null)" || return 1
  expected_count=$((
    $(printf '%s\n' "$base_members" | sed '/^$/d' | wc -l) +
    ${#objects[@]}
  ))
  actual_count="$(printf '%s\n' "$members" | sed '/^$/d' | wc -l)"
  [ "$actual_count" -eq "$expected_count" ] || return 1
  for object in "${objects[@]}"; do
    basename="$(basename "$object")"
    printf '%s\n' "$members" | grep -Fxq "$basename" || return 1
  done
}

expected_marker() {
  local key archive_sha member_count
  key="$(input_key)"
  archive_sha="$(sha256sum "$archive" | cut -d ' ' -f 1)"
  member_count="$(archive_members "$archive" | sed '/^$/d' | wc -l)"
  printf 'schema=%s\ninput_key=%s\narchive_sha256=%s\nmember_count=%s\n' \
    "$schema" "$key" "$archive_sha" "$member_count"
}

validate_pair() {
  local actual expected
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  verify_archive "$archive" || return 1
  actual="$(cat "$marker")" || return 1
  expected="$(expected_marker)" || return 1
  [ "$actual" = "$expected" ]
}

if [ "$validate_only" -eq 1 ]; then
  validate_pair
  exit
fi

mkdir -p "$(dirname "$archive")"
lock="${archive}.lock"
exec 9>>"$lock"
flock -x 9
if [ "${STARLING_SM_ARCHIVE_FORCE:-0}" != 1 ] && validate_pair; then
  exit 0
fi

archive_dir="$(dirname "$archive")"
archive_name="$(basename "$archive")"
marker_name="$(basename "$marker")"
while IFS= read -r stale; do
  rm -f -- "$stale"
done < <(
  find "$archive_dir" -maxdepth 1 -type f \
    \( -name "$archive_name.tmp.*" -o -name "$marker_name.tmp.*" \) \
    -print
)

temporary_archive=""
temporary_marker=""
cleanup() {
  [ -z "$temporary_archive" ] || rm -f -- "$temporary_archive"
  [ -z "$temporary_marker" ] || rm -f -- "$temporary_marker"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

reserve_temporary() {
  local prefix="$1" candidate
  for attempt in $(seq 1 64); do
    candidate="$archive_dir/$prefix.tmp.${BASHPID}.${RANDOM}.$attempt"
    if (set -o noclobber; : >"$candidate") 2>/dev/null; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

test_hook() {
  local phase="$1" hook_dir="${STARLING_SM_ARCHIVE_TEST_HOOK_DIR:-}"
  if [ "${STARLING_SM_ARCHIVE_TEST_FAIL:-}" = "$phase" ]; then
    return 97
  fi
  [ -n "$hook_dir" ] || return 0
  mkdir -p "$hook_dir"
  if [ "${STARLING_SM_ARCHIVE_TEST_WAIT_AT:-}" = "$phase" ]; then
    : >"$hook_dir/$phase.ready"
    while [ ! -e "$hook_dir/$phase.continue" ]; do
      sleep 0.001
    done
  fi
}

temporary_archive="$(reserve_temporary "$archive_name")"
cp "$base_archive" "$temporary_archive"
test_hook archive-created
member_index=0
for object in "${objects[@]}"; do
  "$zig" ar -q "$temporary_archive" "$object"
  member_index=$((member_index + 1))
  test_hook "member-appended-$member_index"
done
"$zig" ar -s "$temporary_archive"
test_hook members-appended
verify_archive "$temporary_archive"
python3 - "$temporary_archive" <<'PY'
import os
import sys

with open(sys.argv[1], "rb") as archive:
    os.fsync(archive.fileno())
PY
mv -f -- "$temporary_archive" "$archive"
temporary_archive=""
python3 - "$archive_dir" <<'PY'
import os
import sys

directory = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
test_hook archive-published

temporary_marker="$(reserve_temporary "$marker_name")"
expected_marker >"$temporary_marker"
python3 - "$temporary_marker" <<'PY'
import os
import sys

with open(sys.argv[1], "rb") as marker:
    os.fsync(marker.fileno())
PY
test_hook before-marker
mv -f -- "$temporary_marker" "$marker"
temporary_marker=""
python3 - "$archive_dir" <<'PY'
import os
import sys

directory = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
validate_pair
