#!/usr/bin/env bash
# world-shell-spike proof of concept.
#
# Demonstrates that `wasm-tools component link` (the WebAssembly
# "shared-everything dynamic linking" proposal) can compose two
# *independently built and independently cacheable* PIC wasm32-wasi
# dynamic libraries -- an "engine" and a thin "shell" -- while correctly
# sharing ONE linear memory, for both:
#   1) a plain scalar call (engine.zig / shell.zig), and
#   2) a raw pointer+length call (engine2.zig / shell2.zig), which matches
#      the shape of StarlingMonkey's real `starling_js_dispatch` ABI
#      (runtime/js_dispatch.h): dispatch(name_ptr, name_len, args_ptr,
#      args_len, *result).
#
# Both demos are built, linked into a component, and actually *executed*
# with wasmtime; the printed values are checked against expected results.
#
# Requirements: the pinned zig toolchain, `wasm-tools` (>=1.230, needs
# `component link`/`component embed`), and `wasmtime`.
#
# Usage (from repo root, after `zig build` once so deps are fetched):
#   ZIG=/path/to/zig WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
#     docs/world-shell-spike/poc/build-and-run.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ZIG="${ZIG:-zig}"
WASM_TOOLS="${WASM_TOOLS:-wasm-tools}"
WASMTIME="${WASMTIME:-wasmtime}"
# The wasi-preview1 adapter shipped with StarlingMonkey; `component link`
# needs it to satisfy WASI-preview1 imports pulled in by Zig's wasm-wasi
# start-up code, even for these trivial reactors.
ADAPTER="${ADAPTER:-../../../host-apis/wasi-0.2.0/preview1-adapter-release/wasi_snapshot_preview1.wasm}"

work="$(mktemp -d ./.poc-work-XXXXXX)"
trap 'rm -rf "$work"' EXIT

echo "== [1/2] scalar-call demo (engine.zig / shell.zig) =="
"$ZIG" build-lib engine.zig -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
  -femit-bin="$work/engine.wasm"
"$ZIG" build-lib shell.zig -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
  -femit-bin="$work/shell.wasm"
"$WASM_TOOLS" component embed --world demo -o "$work/shell-embedded.wasm" wit/ "$work/shell.wasm"
"$WASM_TOOLS" component link \
  engine="$work/engine.wasm" shell="$work/shell-embedded.wasm" \
  --adapt wasi_snapshot_preview1="$ADAPTER" \
  -o "$work/linked.component.wasm"
out=$("$WASMTIME" run --invoke 'shell-call(5, 7)' "$work/linked.component.wasm")
echo "shell-call(5, 7) = $out (expected 113 = 5+7+101, proves engine's internal counter state was reached across the module boundary)"
[ "$out" = "113" ] || { echo "FAIL: expected 113"; exit 1; }

echo
echo "== [2/2] pointer-passing demo (engine2.zig / shell2.zig), matches js_dispatch ABI shape =="
"$ZIG" build-lib engine2.zig -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
  -femit-bin="$work/engine2.wasm"
"$ZIG" build-lib shell2.zig -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
  -femit-bin="$work/shell2.wasm"
"$WASM_TOOLS" component embed --world demo2 -o "$work/shell2-embedded.wasm" wit2dir/ "$work/shell2.wasm"
"$WASM_TOOLS" component link \
  engine="$work/engine2.wasm" shell="$work/shell2-embedded.wasm" \
  --adapt wasi_snapshot_preview1="$ADAPTER" \
  -o "$work/linked2.component.wasm"
out=$("$WASMTIME" run --invoke 'shell-echo()' "$work/linked2.component.wasm")
echo "shell-echo() = $out (expected 72 = ASCII 'H', proves a raw pointer into shell's memory was dereferenced correctly by engine code across the module boundary, and the returned pointer -- into engine's OWN static buffer -- was dereferenced correctly by the caller)"
[ "$out" = "72" ] || { echo "FAIL: expected 72"; exit 1; }

echo
echo "PASS: both demos linked and executed correctly."
