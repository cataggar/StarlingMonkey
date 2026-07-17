#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ] && [ "$#" -ne 6 ]; then
  echo "usage: $0 <cmake-runtime-dir> <wasm-tools> [<oracle-file> <oracle-case> <host-api-version> <expected-exports>]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="$(realpath "$1")"
WASM_TOOLS="$(realpath "$2")"
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
if [ "$#" -eq 6 ]; then
  ORACLE_FILE="$3"
  ORACLE_CASE="$4"
  HOST_API_VERSION="$5"
  EXPECTED_EXPORTS="$6"
  python3 "$ROOT/tests/feature-selection/check-production-surface.py" \
    --host-api-version "$HOST_API_VERSION" \
    "$ORACLE_FILE" \
    "$ORACLE_CASE" \
    "$EXPECTED_EXPORTS" \
    "$WIT"
fi
