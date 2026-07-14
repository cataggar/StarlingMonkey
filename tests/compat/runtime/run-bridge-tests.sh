#!/usr/bin/env bash
#
# Run the Phase 0 ComponentizeJS compatibility harness's *runtime* mode:
# builds the real StarlingMonkey WIT dispatch reactor for each
# tests/compat/manifest.json fixture, componentizes it with Wizer+WABT,
# invokes its exports through Wasmtime, and compares against checked-in
# expectations. See tests/compat/runtime/lib/run_bridge_tests.py's module
# docstring for exactly what is (and is not) verified, and
# tests/compat/runtime/README.md for setup/requirements.
#
# Unlike tests/compat/run-compat-tests.sh, every required tool/artifact
# check here fails loudly rather than skipping -- there is no fallback
# "best effort" mode for this script, by design (see cataggar/StarlingMonkey#6
# code review: a harness that can silently skip its own real verification
# and still report success is the exact bug this script exists to fix).
#
# Usage:
#   tests/compat/runtime/run-bridge-tests.sh [fixture-id ...]
#
# Required environment:
#   ZIG                    Path to the pinned Zig toolchain binary.
#   ZIG_GLOBAL_CACHE_DIR   (optional) defaults to <repo>/.zig-global-cache
#
# Optional environment:
#   WASM_TOOLS             Path to a wasm-tools binary (defaults to PATH).
#   WABT_CACHE_DIR          Where build-wabt.sh caches its build (defaults
#                          to tests/compat/runtime/.wabt-cache).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "FAIL bridge/preflight -- python3 not found on PATH"
  exit 1
fi

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

exec "$PYTHON" "$HERE/lib/run_bridge_tests.py" "$@"
