#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/tests/feature-selection/.build/matrix failure proof"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

for mode in zig cmake; do
  log="$WORK/$mode.log"
  if STARLING_MATRIX_PROBE_ONLY=1 \
      STARLING_MATRIX_FAIL_VERSION=0.2.2 \
      "$ROOT/tests/feature-selection/run-host-api-matrix.sh" "$mode" true \
      >"$log" 2>&1
  then
    echo "FAIL: $mode matrix swallowed an injected child failure" >&2
    exit 1
  fi
  grep -q 'injected matrix failure at wasi-0.2.2' "$log"
  ! grep -q 'wasi-0.2.3 pure production surface' "$log"
done

echo "host API matrix failure propagation passed"
