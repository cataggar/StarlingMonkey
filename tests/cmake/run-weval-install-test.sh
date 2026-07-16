#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <WEVAL-enabled-cmake-build-dir>" >&2
  exit 2
fi

BUILD_DIR="$(cd "$1" && pwd)"
WORK="$BUILD_DIR/weval install package test"
INSTALL_ROOT="$WORK/install root"
UNPACK_ROOT="$WORK/unpacked package"
ARCHIVE="$WORK/starling-weval.tar"
SOURCE="$WORK/source with spaces.js"
OUTPUT="$WORK/component from install.wasm"

rm -rf "$WORK"
mkdir -p "$WORK" "$UNPACK_ROOT"
trap 'rm -rf "$WORK"' EXIT

printf 'globalThis.wevalInstallMarker = 42;\n' > "$SOURCE"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_ROOT"
test -s "$INSTALL_ROOT/bin/starling-ics.wevalcache"
"$INSTALL_ROOT/bin/componentize.sh" "$SOURCE" -o "$OUTPUT"
"$INSTALL_ROOT/bin/wasm-tools" validate --features all "$OUTPUT"
"$INSTALL_ROOT/bin/wasmtime" run -S cli -S http "$OUTPUT"

cmake -E chdir "$WORK" cmake -E tar cf "$ARCHIVE" --format=gnutar "install root"
cmake -E chdir "$UNPACK_ROOT" cmake -E tar xf "$ARCHIVE"
PACKAGED_BIN="$UNPACK_ROOT/install root/bin"
test -s "$PACKAGED_BIN/starling-ics.wevalcache"
PACKAGED_OUTPUT="$WORK/component from package.wasm"
"$PACKAGED_BIN/componentize.sh" "$SOURCE" -o "$PACKAGED_OUTPUT"
"$PACKAGED_BIN/wasm-tools" validate --features all "$PACKAGED_OUTPUT"
"$PACKAGED_BIN/wasmtime" run -S cli -S http "$PACKAGED_OUTPUT"

echo "CMake WEVAL clean install, package, and path-space test passed"
