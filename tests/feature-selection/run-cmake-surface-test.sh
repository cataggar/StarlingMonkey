#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <cmake-runtime-dir> <wasm-tools> <oracle-case> <host-api-version>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="$(realpath "$1")"
WASM_TOOLS="$(realpath "$2")"
ORACLE_CASE="$3"
HOST_API_VERSION="$4"
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
    --host-api-version "$HOST_API_VERSION" \
    "$ROOT/tests/feature-selection/reference/expected/import-surfaces.json" \
    "$ORACLE_CASE" \
    "wasi:cli/run@$HOST_API_VERSION,wasi:http/incoming-handler@$HOST_API_VERSION" \
    "$WIT"
fi
