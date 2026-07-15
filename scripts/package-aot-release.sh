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

"$bin/wasm-tools" validate --features all "$bin/starling-raw.wasm"
"$bin/starling-aot-cache" validate \
  --engine "$bin/starling-raw.wasm" \
  --weval "$bin/weval" \
  --cache "$bin/starling-ics.wevalcache" \
  --manifest "$bin/starling-ics.wevalcache.manifest"

"$bin/starling-aot-cache" publish-bundle \
  --target "$release_dir" \
  --engine "$bin/starling-raw.wasm" \
  --engine-name starling-raw-weval.wasm \
  --weval "$bin/weval" \
  --cache "$bin/starling-ics.wevalcache" \
  --manifest "$bin/starling-ics.wevalcache.manifest"

"$bin/wasm-tools" validate --features all \
  "$release_dir/starling-raw-weval.wasm"
"$bin/starling-aot-cache" validate \
  --engine "$release_dir/starling-raw-weval.wasm" \
  --weval "$bin/weval" \
  --cache "$release_dir/starling-ics.wevalcache" \
  --manifest "$release_dir/starling-ics.wevalcache.manifest"

echo "Validated AOT release artifacts in $release_dir"
