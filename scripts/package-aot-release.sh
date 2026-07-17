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
weval="$bin/weval"
if [ -x "$prefix/weval-package/weval" ]; then
  weval="$prefix/weval-package/weval"
elif [ -x "$prefix/.starling-aot-engine/current/weval-package/weval" ]; then
  weval="$prefix/.starling-aot-engine/current/weval-package/weval"
fi

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
  --weval "$weval" \
  --cache "$bin/starling-ics.wevalcache" \
  --manifest "$bin/starling-ics.wevalcache.manifest"

"$bin/starling-aot-cache" publish-bundle \
  --target "$release_dir" \
  --engine "$bin/starling-raw.wasm" \
  --engine-name starling-raw-weval.wasm \
  --weval "$weval" \
  --cache "$bin/starling-ics.wevalcache" \
  --manifest "$bin/starling-ics.wevalcache.manifest"

generation="$(sed -n 's/^key=//p' \
  "$bin/starling-ics.wevalcache.manifest")"
test -n "$generation"
echo "Published validated AOT release generation $generation in $release_dir"
