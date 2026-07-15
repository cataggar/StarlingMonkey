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
trap 'rm -rf "$stage"' EXIT
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

mv "$stage/starling-raw-weval.wasm" \
  "$stage/starling-ics.wevalcache" \
  "$stage/starling-ics.wevalcache.manifest" \
  "$release_dir/"

echo "Validated AOT release artifacts in $release_dir"
