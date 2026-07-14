#!/usr/bin/env bash
# `componentize.sh` (rendered from componentize.sh.in) shells out to a
# `wabt` CLI binary for the final `module strip` / `component embed` /
# `component new` steps whenever a `-Dcomponent-world` is configured. The
# only `wabt` CLI builds available in this environment are either too old
# (predates the reactor preview1 adapter fix) or hit an unrelated
# `canonical option 'memory' is required` bug in their `component new`
# adapter-splicing logic -- neither is a StarlingMonkey/js_dispatch bug, and
# both are out of scope to fix here (the former is an environment/tooling
# version mismatch; the latter would require patching a separate `wabt`
# fleet worktree we're not permitted to touch for this task).
#
# `wasm-tools` (the reference component-model implementation, itself
# Node-free, already vendored into zig-out/bin by build.zig) implements the
# same three operations correctly. This shim translates the `wabt`-style
# subcommand spelling `module strip` to `wasm-tools strip` (the one place
# the two CLIs' subcommand names differ) and otherwise passes arguments
# through unchanged, so it works as a drop-in `WABT=` override for
# componentize.sh without modifying componentize.sh.in, the bindgen
# generator, or any other fleet worktree.
set -euo pipefail

WASM_TOOLS="${WASM_TOOLS_BIN:?WASM_TOOLS_BIN must point at a wasm-tools binary}"

if [ "${1:-}" = "module" ] && [ "${2:-}" = "strip" ]; then
  shift 2
  exec "$WASM_TOOLS" strip "$@"
fi

exec "$WASM_TOOLS" "$@"
