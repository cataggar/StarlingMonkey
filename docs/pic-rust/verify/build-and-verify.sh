#!/usr/bin/env bash
#
# pic-rust verification: proves that target/wasm32-wasip1/release/librust_staticlib.a
# -- rebuilt with `-C relocation-model=pic` for every crate in the bundle via
# deps/build-deps.sh -- can be linked (not merely inspected for relocation
# metadata) into a wasm32-wasi `-dynamic -fPIC` module, composed with an
# independently built "shell" via `wasm-tools component link` (the same
# Shared-Everything Dynamic Linking mechanism used in
# docs/world-shell-spike.md), and actually executed end-to-end with
# wasmtime.
#
# Steps:
#   1. Build librust_staticlib.a from scratch via deps/build-deps.sh's Rust
#      step (PIC, see runtime/crates/staticlib-template/cargo-config.toml.in).
#   2. Link engine.zig + librust_staticlib.a into one wasm32-wasi -dynamic
#      -fPIC "engine" module (engine.zig calls real, exported symbols from
#      three different bundled crates: rust-hooks, rust-multipart,
#      rust-url). This is the step that would fail with the exact
#      "recompile with -fPIC" errors from
#      docs/world-shell-spike/engine-pic-fail.excerpt.log if the archive
#      were not PIC.
#   3. Build a thin "shell" module + WIT world, embed and `component link`
#      it against the engine module.
#   4. Run the resulting component with wasmtime and check the returned
#      value, proving the composed call chain (shell -> engine ->
#      rust-hooks/rust-multipart/rust-url, across a shared linear memory)
#      executes correctly.
#
# Usage (from repo root):
#   unset ZIG_LOCAL_CACHE_DIR
#   export ZIG_GLOBAL_CACHE_DIR=/path/to/.zig-global-cache
#   ZIG=/path/to/zig WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
#     docs/pic-rust/verify/build-and-verify.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(cd ../../.. && pwd)"

ZIG="${ZIG:-zig}"
WASM_TOOLS="${WASM_TOOLS:-wasm-tools}"
WASMTIME="${WASMTIME:-wasmtime}"
ADAPTER="${ADAPTER:-$ROOT/host-apis/wasi-0.2.0/preview1-adapter-release/wasi_snapshot_preview1.wasm}"
RUST_LIB="${RUST_LIB:-$ROOT/target/wasm32-wasip1/release/librust_staticlib.a}"

if [[ "${SKIP_RUST_BUILD:-}" != "1" ]]; then
  echo "== [1/4] Building librust_staticlib.a from scratch (PIC) via deps/build-deps.sh's Rust step =="
  BD="$ROOT/deps/rust-staticlib-build"
  rm -rf "$BD" "$RUST_LIB"
  mkdir -p "$BD/.cargo"
  cp "$ROOT/runtime/crates/staticlib-template/cargo-config.toml.in" "$BD/.cargo/config.toml"
  cp "$ROOT/runtime/crates/staticlib-template/Cargo.toml.in" "$BD/Cargo.toml"
  cat >> "$BD/Cargo.toml" <<EOF
rust-encoding = { path = "$ROOT/crates/rust-encoding", features = [] }
rust-hooks = { path = "$ROOT/crates/rust-hooks", features = [] }
rust-url = { path = "$ROOT/crates/rust-url", features = [] }
multipart = { path = "$ROOT/crates/rust-multipart", features = ["capi", "simd"] }
EOF
  cp "$ROOT/runtime/crates/staticlib-template/rust-staticlib.rs.in" "$BD/rust-staticlib.rs"
  cat >> "$BD/rust-staticlib.rs" <<EOF
pub use rust_encoding;
pub use rust_hooks;
pub use rust_url;
pub use multipart;
EOF
  cp "$ROOT/runtime/crates/staticlib-template/Cargo.lock" "$BD/Cargo.lock"
  ( cd "$BD" && CARGO_TARGET_DIR="$ROOT/target" cargo build --release --target wasm32-wasip1 )
else
  echo "== [1/4] Skipping Rust build (SKIP_RUST_BUILD=1); using existing $RUST_LIB =="
fi
[[ -f "$RUST_LIB" ]] || { echo "missing $RUST_LIB"; exit 1; }

work="$(mktemp -d ./.verify-work-XXXXXX)"
trap 'rm -rf "$work"' EXIT

echo
echo "== [2/4] Linking engine.zig + librust_staticlib.a into one wasm32-wasi -dynamic -fPIC module =="
echo "   (this is the step that fails with R_WASM_MEMORY_ADDR_* 'recompile with -fPIC' errors"
echo "    -- see ../../world-shell-spike/engine-pic-fail.excerpt.log -- if the archive isn't PIC)"
"$ZIG" build-lib engine.zig "$RUST_LIB" \
  -target wasm32-wasi -dynamic -fPIC -OReleaseSmall -lc \
  -femit-bin="$work/rust-engine.wasm"

echo
echo "== Verifying the linked module is valid wasm and a real PIC dylib (has a dylink.0 section) =="
"$WASM_TOOLS" validate "$work/rust-engine.wasm"
# (write to a file rather than piping into grep -q: with `set -o pipefail`,
# grep -q's early exit after the first match sends SIGPIPE to the
# upstream `wasm-tools print`, which would otherwise be misreported as a
# pipeline failure)
"$WASM_TOOLS" print "$work/rust-engine.wasm" > "$work/rust-engine.wat"
grep -q '(@dylink.0' "$work/rust-engine.wat" \
  || { echo "FAIL: no dylink.0 section -- not a PIC dylib"; exit 1; }
echo "OK: valid wasm32-wasi PIC dylib with a dylink.0 section"

echo
echo "== [3/4] Building thin shell.wasm, embedding + composing with the engine module =="
"$ZIG" build-lib shell.zig -target wasm32-wasi -dynamic -fPIC -OReleaseSmall \
  -femit-bin="$work/shell.wasm"
"$WASM_TOOLS" component embed --world demo -o "$work/shell-embedded.wasm" wit/ "$work/shell.wasm"
"$WASM_TOOLS" component link \
  engine="$work/rust-engine.wasm" shell="$work/shell-embedded.wasm" \
  --adapt wasi_snapshot_preview1="$ADAPTER" \
  -o "$work/linked.component.wasm"

echo
echo "== [4/4] Running the composed component with wasmtime =="
out=$("$WASMTIME" run --invoke 'shell-call(5, 7)' "$work/linked.component.wasm")
echo "shell-call(5, 7) = $out"
echo "(expected 112 = 5 + 7 + 100: +100 is only added by engine_verify in engine.zig"
echo " after install_rust_hooks() [rust-hooks], multipart_parser_new/_free() [rust-multipart]"
echo " and new_jsurl/free_jsurl() [rust-url] all round-tripped successfully through the"
echo " PIC-linked archive across the engine/shell module boundary)"
[ "$out" = "112" ] || { echo "FAIL: expected 112, got $out"; exit 1; }

echo
echo "PASS: librust_staticlib.a is PIC and links + runs as a wasm32-wasi dynamic library."
