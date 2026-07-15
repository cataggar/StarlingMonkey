#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <zig-prefix> <release-directory>" >&2
  exit 2
fi

prefix="$(realpath "$1")"
mkdir -p "$2"
release_dir="$(realpath "$2")"
bin="$prefix/bin"
stage="$release_dir/.aot-package-$BASHPID"
previous="$stage/previous"
publication_started=0
publication_complete=0
lock_acquired=0
artifacts=(
  starling-raw-weval.wasm
  starling-ics.wevalcache
  starling-ics.wevalcache.manifest
)

run_without_publication_lock() {
  "$@" {lock_fd}>&-
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$publication_started" -eq 1 ] &&
    [ "$publication_complete" -eq 0 ]; then
    for artifact in "${artifacts[@]}"; do
      if [ "$lock_acquired" -eq 1 ]; then
        run_without_publication_lock rm -f "$release_dir/$artifact"
      else
        rm -f "$release_dir/$artifact"
      fi
      if [ -e "$previous/$artifact" ]; then
        if [ "$lock_acquired" -eq 1 ]; then
          run_without_publication_lock \
            mv "$previous/$artifact" "$release_dir/$artifact"
        else
          mv "$previous/$artifact" "$release_dir/$artifact"
        fi
      fi
    done
  fi
  if [ "$lock_acquired" -eq 1 ]; then
    run_without_publication_lock rm -rf "$stage"
  else
    rm -rf "$stage"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage"

for artifact in \
  starling-raw.wasm \
  starling-ics.wevalcache \
  starling-ics.wevalcache.manifest \
  starling-aot-cache \
  wasm-tools \
  weval
do
  test -s "$bin/$artifact"
done

cp "$bin/starling-raw.wasm" "$stage/starling-raw-weval.wasm"
cp "$bin/starling-ics.wevalcache" "$stage/starling-ics.wevalcache"
cp "$bin/starling-ics.wevalcache.manifest" \
  "$stage/starling-ics.wevalcache.manifest"

"$bin/wasm-tools" validate --features all "$stage/starling-raw-weval.wasm"
"$bin/starling-aot-cache" validate \
  --engine "$stage/starling-raw-weval.wasm" \
  --weval "$bin/weval" \
  --cache "$stage/starling-ics.wevalcache" \
  --manifest "$stage/starling-ics.wevalcache.manifest"

command -v flock >/dev/null
exec {lock_fd}> "$release_dir/.starling-aot-release.lock"
flock -x "$lock_fd"
lock_acquired=1

run_without_publication_lock mkdir "$previous"
for artifact in "${artifacts[@]}"; do
  if [ -e "$release_dir/$artifact" ]; then
    run_without_publication_lock \
      cp -p "$release_dir/$artifact" "$previous/$artifact"
  fi
done
publication_started=1
for artifact in "${artifacts[@]}"; do
  run_without_publication_lock \
    mv "$stage/$artifact" "$release_dir/$artifact"
done

run_without_publication_lock "$bin/wasm-tools" validate --features all \
  "$release_dir/starling-raw-weval.wasm"
run_without_publication_lock "$bin/starling-aot-cache" validate \
  --engine "$release_dir/starling-raw-weval.wasm" \
  --weval "$bin/weval" \
  --cache "$release_dir/starling-ics.wevalcache" \
  --manifest "$release_dir/starling-ics.wevalcache.manifest"
publication_complete=1

echo "Validated AOT release artifacts in $release_dir"
