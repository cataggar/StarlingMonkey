#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <zig> <zig-prefix>" >&2
  exit 2
fi

ZIG="$(realpath "$1")"
PREFIX="$(realpath "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JUSTFILE="$ROOT/justfile"

rm -f "$PREFIX/bin/starling-raw.wasm"
just --justfile "$JUSTFILE" zig="$ZIG" mode=weval builddir="$PREFIX" \
  build starling-raw.wasm
test -s "$PREFIX/bin/starling-raw.wasm"
"$PREFIX/bin/wasm-tools" validate --features all \
  "$PREFIX/bin/starling-raw.wasm"

rm -f "$PREFIX/starling.wasm"
just --justfile "$JUSTFILE" zig="$ZIG" mode=weval builddir="$PREFIX" \
  build starling
test -s "$PREFIX/starling.wasm"
"$PREFIX/bin/wasm-tools" validate --features all "$PREFIX/starling.wasm"

echo "Legacy AOT starling-raw.wasm and starling targets passed"
