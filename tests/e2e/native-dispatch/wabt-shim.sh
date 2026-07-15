#!/usr/bin/env bash
# WABT does not yet support embedding worlds with world-level `use` and root
# function imports. The WIT-import E2E selects this explicit wasm-tools
# backend while the standard dispatch E2E exercises the bundled WABT binary.
set -euo pipefail

WASM_TOOLS="${WASM_TOOLS_BIN:?WASM_TOOLS_BIN must point at a wasm-tools binary}"

if [ "${1:-}" = "module" ] && [ "${2:-}" = "strip" ]; then
  shift 2
  exec "$WASM_TOOLS" strip "$@"
fi

exec "$WASM_TOOLS" "$@"
