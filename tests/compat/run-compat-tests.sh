#!/usr/bin/env bash
#
# Run the Phase 0 ComponentizeJS compatibility harness (Node-free).
#
# This checks the tests/compat manifest, fixtures, and checked-in expected
# outputs are internally consistent, and that each fixture's WIT parses via
# the already-pinned `wasm-tools` binary this repository uses elsewhere
# (tests/run-suite.sh, build.zig). It does not require Node, npm, or a full
# StarlingMonkey wasm build, and does not affect the existing e2e/integration
# suite (tests/run-suite.sh) at all.
#
# For an explicitly opt-in mode that runs fixtures through the real pinned
# ComponentizeJS release, see tests/compat/reference/README.md.
#
# Usage: tests/compat/run-compat-tests.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "FAIL compat-harness -- python3 not found on PATH (this repository already requires it for tests/test.sh)"
  exit 1
fi

exec "$PYTHON" "$ROOT/tests/compat/lib/run_compat_tests.py"
