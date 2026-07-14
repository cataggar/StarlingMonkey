#!/usr/bin/env bash
#
# world-shell-integration verification: builds the real, world-independent
# StarlingMonkey engine as a `-dynamic -fPIC` dylib (no component/dispatch
# WIT baked in), builds two distinct thin per-world Zig shells from two
# different WIT worlds, composes each with the *same* engine artifact via
# `wasm-tools component link` (Shared-Everything Dynamic Linking), validates
# the resulting components, and demonstrates -- with exact tool evidence --
# that changing the WIT/world never touches the engine artifact.
#
# It also re-runs the three negative probes that pin down exactly why the
# "Wizer-initialize the engine, then compose" path is structurally blocked
# with the currently pinned toolchain (see ../README.md for the narrative):
#   1. `wasmtime wizer` refuses a PIC engine dylib (imports memory).
#   2. `wasm-ld`/zig refuses `--export-memory` together with `-shared`.
#   3. `wasm-tools component link` refuses a memory-owning module that lacks
#      a `dylink.0` section, using a small, deterministically generated
#      fixture module (not the huge monolithic build) as the negative input.
#
# Usage (from repo root):
#   unset ZIG_LOCAL_CACHE_DIR
#   export ZIG_GLOBAL_CACHE_DIR=/path/to/.zig-global-cache
#   ZIG=/path/to/zig WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
#     docs/world-shell-integration/verify/build-and-verify.sh
#
# Requires deps/openssl-zig, deps/sm-obj-zig and
# target/wasm32-wasip1/release/librust_staticlib.a to already exist and be
# PIC (see deps/build-deps.sh and the docs/pic-*/verify scripts).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(cd ../../.. && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
WASM_TOOLS="${WASM_TOOLS:-wasm-tools}"
WASMTIME="${WASMTIME:-wasmtime}"
ADAPTER="${ADAPTER:-$ROOT/host-apis/wasi-0.2.0/preview1-adapter-release/wasi_snapshot_preview1.wasm}"

work="$(mktemp -d "$ROOT/.verify-work-XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "== [1/7] Building the world-independent engine dylib (no component/dispatch WIT) =="
"$ZIG" build engine-dylib-experiment -Dengine-dylib-experiment=true -Doptimize=ReleaseSmall \
  --prefix "$work/engine-out" --summary all
ENGINE="$work/engine-out/bin/starling-engine.wasm"
"$WASM_TOOLS" validate "$ENGINE"
"$WASM_TOOLS" print "$ENGINE" > "$work/engine.wat"
grep -q '(@dylink.0' "$work/engine.wat" || { echo "FAIL: engine is not a PIC dylib"; exit 1; }
for sym in starling_js_dispatch starling_dispatch_result_free starling_js_dispatch_native starling_js_dispatch_native_free; do
  grep -q "(export \"$sym\"" "$work/engine.wat" \
    || { echo "FAIL: engine does not export $sym"; exit 1; }
done
echo "OK: engine is a valid PIC dylib exporting all four dispatch bridge functions"
ENGINE_HASH_BEFORE="$(sha256sum "$ENGINE" | cut -d' ' -f1)"

build_and_compose_shell() {
  local wit_dir="$1" world="$2" out_prefix="$3" label="$4"
  "$ZIG" build shell-dylib-experiment -Dshell-dylib-experiment=true -Doptimize=ReleaseSmall \
    -Ddispatch-wit="$wit_dir" -Ddispatch-world="$world" \
    --prefix "$out_prefix" --summary all
  "$WASM_TOOLS" component embed --world "$world" -o "$out_prefix/shell-embedded.wasm" \
    "$wit_dir" "$out_prefix/bin/starling-shell.wasm"
  "$WASM_TOOLS" component link \
    engine="$ENGINE" shell="$out_prefix/shell-embedded.wasm" \
    --adapt wasi_snapshot_preview1="$ADAPTER" \
    -o "$out_prefix/composed.wasm"
  "$WASM_TOOLS" validate "$out_prefix/composed.wasm"
  echo "OK: $label composed and validated"
}

echo
echo "== [2/7] Building + composing thin shell A (host-apis/wasi-0.2.10/wit/deps/starling-js) =="
time build_and_compose_shell \
  host-apis/wasi-0.2.10/wit/deps/starling-js js-exports "$work/shellA" "shell A"

echo
echo "== [3/7] Building + composing thin shell B (.../starling-js-v2, a distinct world) =="
time build_and_compose_shell \
  host-apis/wasi-0.2.10/wit/deps/starling-js-v2 js-exports "$work/shellB" "shell B"

ENGINE_HASH_AFTER="$(sha256sum "$ENGINE" | cut -d' ' -f1)"
[[ "$ENGINE_HASH_BEFORE" == "$ENGINE_HASH_AFTER" ]] \
  || { echo "FAIL: engine artifact changed across WIT/world switch"; exit 1; }
echo "OK: engine.wasm byte-identical (sha256 $ENGINE_HASH_AFTER) across both distinct worlds"

echo
echo "== [4/7] Invoking the composed (uninitialized) component through wasmtime =="
echo "   (expected: reaches starling_js_dispatch -> resolve_export_function -> panics because"
echo "    no JS module/context has been initialized -- this proves the composed call chain"
echo "    engine<->shell is wired correctly end-to-end; only JS-engine initialization is missing)"
if "$WASMTIME" run -S http=y -S cli=y --invoke 'add(5, 7)' "$work/shellA/composed.wasm" \
     > "$work/invoke.log" 2>&1; then
  echo "UNEXPECTED: invoke succeeded without initialization"; cat "$work/invoke.log"; exit 1
fi
grep -q "JavaScript export dispatch failed" "$work/invoke.log" \
  || { echo "FAIL: did not observe the expected uninitialized-engine panic"; cat "$work/invoke.log"; exit 1; }
echo "OK: composed component runs end-to-end up to the (expected) uninitialized-engine panic"

echo
echo "== [5/7] Negative probe: wasmtime wizer rejects the PIC engine dylib =="
if "$WASMTIME" wizer "$ENGINE" -o "$work/wizer-out.wasm" > "$work/wizer.log" 2>&1; then
  echo "UNEXPECTED: wizer succeeded on a PIC dylib"; cat "$work/wizer.log"; exit 1
fi
grep -qi "imported memories are not supported" "$work/wizer.log" \
  || { echo "FAIL: expected wizer's documented import-memory rejection"; cat "$work/wizer.log"; exit 1; }
echo "OK: $(grep -i 'error' "$work/wizer.log" | head -1)"

echo
echo "== [6/7] Negative probe: -shared + --export-memory is rejected by the linker =="
cat > "$work/probe.zig" <<'EOF'
export fn probe(x: i32) i32 {
    return x + 1;
}
EOF
if "$ZIG" build-lib "$work/probe.zig" -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
     --export-memory -femit-bin="$work/probe.wasm" > "$work/probe.log" 2>&1; then
  echo "UNEXPECTED: --export-memory succeeded together with -dynamic -fPIC"; cat "$work/probe.log"; exit 1
fi
grep -qi "exporting memory is incompatible with dynamic linking" "$work/probe.log" \
  || { echo "FAIL: expected the dynamic-linking/export-memory conflict"; cat "$work/probe.log"; exit 1; }
echo "OK: $(grep -i 'error' "$work/probe.log" | head -1)"

echo
echo "== [7/7] Negative probe: component link rejects a memory-owning, non-dylink.0 module =="
cat > "$work/memory-owner.zig" <<'EOF'
export fn probe(x: i32) i32 {
    return x + 1;
}
pub fn main() void {}
EOF
"$ZIG" build-exe "$work/memory-owner.zig" -target wasm32-wasi -OReleaseSmall \
  -femit-bin="$work/memory-owner.wasm" > "$work/memory-owner-build.log" 2>&1
"$WASM_TOOLS" print "$work/memory-owner.wasm" > "$work/memory-owner.wat"
grep -q '(@dylink.0' "$work/memory-owner.wat" \
  && { echo "FAIL: fixture unexpectedly carries a dylink.0 section"; exit 1; }
grep -q '(export "memory"' "$work/memory-owner.wat" \
  || { echo "FAIL: fixture does not own/export memory"; exit 1; }
if "$WASM_TOOLS" component link \
     engine="$work/memory-owner.wasm" shell="$work/shellA/shell-embedded.wasm" \
     --adapt wasi_snapshot_preview1="$ADAPTER" \
     -o "$work/composed-bad.wasm" > "$work/component-link-reject.log" 2>&1; then
  echo "UNEXPECTED: component link succeeded with a memory-owning, non-dylink.0 input"
  cat "$work/component-link-reject.log"; exit 1
fi
grep -qi "unsupported export kind for memory" "$work/component-link-reject.log" \
  || { echo "FAIL: expected the dylink.0-less memory-owning-module rejection"; cat "$work/component-link-reject.log"; exit 1; }
echo "OK: $(grep -i 'unsupported export kind for memory' "$work/component-link-reject.log" | sed 's/^ *//')"

echo
echo "All checks passed. See docs/world-shell-integration/README.md for the full write-up,"
echo "including why these three results together mean Wizer-then-compose is structurally"
echo "blocked with this exact toolchain, and what the smallest unblocking change would be."
