#!/usr/bin/env bash
# WABT does not yet support embedding worlds with world-level `use` and root
# function imports. These E2Es select wasm-tools for embedding while routing
# feature-surface composition through the pinned WABT binary.
set -euo pipefail

if [ "${1:-}" = "component" ] && [ "${2:-}" = "compose" ]; then
  exec "${WABT_COMPOSE_BIN:?WABT_COMPOSE_BIN must point at the pinned WABT binary}" "$@"
fi

WASM_TOOLS="${WASM_TOOLS_BIN:?WASM_TOOLS_BIN must point at a wasm-tools binary}"

if [ "${1:-}" = "module" ] && [ "${2:-}" = "strip" ]; then
  shift 2
  exec "$WASM_TOOLS" strip "$@"
fi

exec "$WASM_TOOLS" "$@"
