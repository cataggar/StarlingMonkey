#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <non-WEVAL-cmake-build-dir>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$(cd "$1" && pwd)"
WORK="$BUILD_DIR/componentizer install package test"
INSTALL_ROOT="$WORK/install root"
UNPACK_ROOT="$WORK/unpacked package"
REJECTED_BUILD="$WORK/rejected WEVAL build"
ARCHIVE="$WORK/starling-componentizer.tar"
SOURCE="$WORK/source with spaces.js"
OUTPUT="$WORK/component from install.wasm"

rm -rf "$WORK"
mkdir -p "$WORK" "$UNPACK_ROOT"
trap 'rm -rf "$WORK"' EXIT

if cmake -S "$ROOT" -B "$REJECTED_BUILD" -DWEVAL=ON \
    >"$WORK/weval.out" 2>"$WORK/weval.err"
then
  echo "CMake WEVAL=ON unexpectedly configured successfully" >&2
  exit 1
fi
grep -q 'CMake WEVAL builds are no longer supported' \
  "$WORK/weval.out" "$WORK/weval.err"
if find "$REJECTED_BUILD" -type f \
    \( -name 'starling*.wasm' -o -name '*.wevalcache' \
       -o -name '*.wevalcache.manifest' \) -print -quit |
    grep -q .
then
  echo "rejected CMake WEVAL configuration created a release artifact" >&2
  exit 1
fi

printf 'globalThis.installMarker = 42;\n' > "$SOURCE"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_ROOT"
for required in \
  starling-raw.wasm preview1-adapter.wasm features.json componentize.sh \
  starling-feature-surface wasm-tools wasmtime wabt
do
  test -s "$INSTALL_ROOT/bin/$required"
done
test -d "$INSTALL_ROOT/bin/component-wit"
test -d "$INSTALL_ROOT/bin/surface-wit"
test -d "$INSTALL_ROOT/bin/feature-wit"
! compgen -G "$INSTALL_ROOT/bin/*.wevalcache" >/dev/null
! compgen -G "$INSTALL_ROOT/bin/*.wevalcache.manifest" >/dev/null
test ! -e "$INSTALL_ROOT/bin/starling-raw-external.wasm"

"$INSTALL_ROOT/bin/componentize.sh" "$SOURCE" -o "$OUTPUT"
"$INSTALL_ROOT/bin/wasm-tools" validate --features all "$OUTPUT"
"$INSTALL_ROOT/bin/wasmtime" run -S cli -S http "$OUTPUT"
"$ROOT/tests/runtime-eval/run.sh" "$INSTALL_ROOT/bin"

cmake -E chdir "$WORK" cmake -E tar cf "$ARCHIVE" --format=gnutar \
  "install root"
cmake -E chdir "$UNPACK_ROOT" cmake -E tar xf "$ARCHIVE"
PACKAGED_BIN="$UNPACK_ROOT/install root/bin"
test -s "$PACKAGED_BIN/starling-raw.wasm"
test -s "$PACKAGED_BIN/features.json"
! compgen -G "$PACKAGED_BIN/*.wevalcache" >/dev/null
! compgen -G "$PACKAGED_BIN/*.wevalcache.manifest" >/dev/null
test ! -e "$PACKAGED_BIN/starling-raw-external.wasm"
PACKAGED_OUTPUT="$WORK/component from package.wasm"
"$PACKAGED_BIN/componentize.sh" "$SOURCE" -o "$PACKAGED_OUTPUT"
"$PACKAGED_BIN/wasm-tools" validate --features all "$PACKAGED_OUTPUT"
"$PACKAGED_BIN/wasmtime" run -S cli -S http "$PACKAGED_OUTPUT"
"$ROOT/tests/runtime-eval/run.sh" "$PACKAGED_BIN"

echo "clean non-WEVAL CMake install, package, and path-space test passed"
