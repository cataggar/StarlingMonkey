#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <cmake-runtime-dir> <wasm-tools> <oracle-case>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="$(realpath "$1")"
WASM_TOOLS="$(realpath "$2")"
ORACLE_CASE="$3"
WORK="$RUNTIME/cmake surface test"
COMPONENT="$WORK/default component.wasm"
WIT="$WORK/default component.wit"

rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

"$RUNTIME/componentize.sh" \
  "$ROOT/tests/feature-selection/reference/component.js" \
  -o "$COMPONENT"
"$WASM_TOOLS" validate --features all "$COMPONENT"
"$WASM_TOOLS" component wit "$COMPONENT" -o "$WIT"
if [ -n "$ORACLE_CASE" ]; then
  python3 "$ROOT/tests/feature-selection/check-production-surface.py" \
    "$ROOT/tests/feature-selection/reference/expected/import-surfaces.json" \
    "$ORACLE_CASE" \
    "wasi:cli/run@0.2.10,wasi:http/incoming-handler@0.2.10" \
    "$WIT"
fi
