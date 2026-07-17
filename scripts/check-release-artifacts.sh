#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <release-directory>" >&2
  exit 2
fi

release_dir="$1"
test -d "$release_dir"
expected=(
  preview1-adapter.wasm
  starling-debug.wasm
  starling-ics.wevalcache
  starling-ics.wevalcache.manifest
  starling-raw-debug.wasm
  starling-raw-weval.wasm
  starling-raw.wasm
  starling.wasm
)
mapfile -t actual < <(
  find "$release_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' |
    LC_ALL=C sort
)

if [ "${actual[*]}" != "${expected[*]}" ]; then
  echo "release directory must contain exactly the eight v0.4 assets" >&2
  printf 'expected: %s\n' "${expected[*]}" >&2
  printf 'actual:   %s\n' "${actual[*]}" >&2
  exit 1
fi

for asset in "${expected[@]}"; do
  if [ ! -f "$release_dir/$asset" ] ||
    [ -L "$release_dir/$asset" ] ||
    [ ! -s "$release_dir/$asset" ]
  then
    echo "release asset must be a nonempty regular file: $asset" >&2
    exit 1
  fi
done

echo "Validated exact eight-asset v0.4 release inventory"
