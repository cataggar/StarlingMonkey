#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <inventory-checker>" >&2
  exit 2
fi

CHECKER="$(realpath "$1")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.release-inventory"
RELEASE="$SCRATCH/release"
rm -rf "$SCRATCH"
mkdir -p "$RELEASE"
trap 'rm -rf "$SCRATCH"' EXIT

assets=(
  preview1-adapter.wasm
  starling-debug.wasm
  starling-ics.wevalcache
  starling-ics.wevalcache.manifest
  starling-raw-debug.wasm
  starling-raw-weval.wasm
  starling-raw.wasm
  starling.wasm
)
for asset in "${assets[@]}"; do
  printf 'fixture %s\n' "$asset" > "$RELEASE/$asset"
done

"$CHECKER" "$RELEASE"

printf 'unsealed external engine\n' \
  > "$RELEASE/starling-raw-weval-external.wasm"
if "$CHECKER" "$RELEASE" >/dev/null 2>&1; then
  echo "FAIL: external AOT engine was accepted as a release asset" >&2
  exit 1
fi
rm "$RELEASE/starling-raw-weval-external.wasm"

rm "$RELEASE/starling-ics.wevalcache.manifest"
if "$CHECKER" "$RELEASE" >/dev/null 2>&1; then
  echo "FAIL: incomplete AOT trio was accepted" >&2
  exit 1
fi

echo "Release artifact inventory rejection matrix passed"
