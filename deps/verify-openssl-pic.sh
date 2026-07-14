#!/usr/bin/env bash
#
# Verify that deps/openssl-zig/libx32/{libcrypto,libssl}.a are actually
# usable in a wasm32-wasi `-dynamic -fPIC` dylib -- i.e. that every object
# in them was compiled with -fPIC and therefore carries no absolute-address
# relocations (R_WASM_MEMORY_ADDR_SLEB/LEB) that wasm-ld would reject when
# linking a PIC dynamic library (see the "engine-dylib-experiment" blocker
# in docs/world-shell-spike.md).
#
# A string grep for "-fPIC" in build logs is not sufficient (it doesn't
# prove the compiled *objects* are actually relocatable, and doesn't cover
# objects pulled from prebuilt/cached archives). This script instead
# *exercises the linker*: it extracts every object out of both archives
# (`zig ar x`, not `--whole-archive`, so nothing can be skipped for being
# "unreferenced") and links them all, with --no-gc-sections so wasm-ld
# cannot discard any section before validating its relocations, into a
# real `zig build-lib -target wasm32-wasi -dynamic -fPIC` dylib. If any
# object still contains a forbidden absolute relocation, wasm-ld fails
# with "recompile with -fPIC" and this script exits non-zero.
#
# Usage:
#   ZIG=/path/to/zig deps/verify-openssl-pic.sh
#
# Prerequisites: deps/openssl-zig/libx32/{libcrypto,libssl}.a already built
# (run deps/build-deps.sh first), zig 0.17 on PATH or $ZIG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
ZIG="${ZIG:-zig}"
SSL_LIBDIR="$DEPS/openssl-zig/libx32"

command -v "$ZIG" >/dev/null || { echo "zig not found: $ZIG"; exit 1; }
for lib in libcrypto.a libssl.a; do
  [[ -f "$SSL_LIBDIR/$lib" ]] || {
    echo "Missing $SSL_LIBDIR/$lib -- run deps/build-deps.sh first"
    exit 1
  }
done

WORK="$DEPS/.pic-verify-work"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Extract every object from both archives. Using `ar x` (rather than letting
# the linker pull from the .a lazily by symbol reference) guarantees every
# object's relocations get processed below, not just the ones some trivial
# root file happens to reference.
n_objs=0
for lib in libcrypto.a libssl.a; do
  ( cd "$WORK" && "$ZIG" ar x "$SSL_LIBDIR/$lib" )
  n=$("$ZIG" ar t "$SSL_LIBDIR/$lib" | wc -l)
  n_objs=$((n_objs + n))
done
echo ">>> Extracted $n_objs objects from libcrypto.a + libssl.a"

# Trivial Zig root module: it exists only so `zig build-lib` has a root
# source file; it deliberately references nothing from OpenSSL, because
# --no-gc-sections below is what forces every extracted object's sections
# (and therefore relocations) to be kept and validated, regardless of
# whether anything actually calls into them.
cat > "$WORK/root.zig" <<'EOF'
export fn pic_verify_entry() void {}
EOF

echo ">>> Linking all objects into a wasm32-wasi -dynamic -fPIC dylib (exercises wasm-ld's relocation checks)"
( cd "$WORK"
  "$ZIG" build-lib -target wasm32-wasi -dynamic -fPIC -OReleaseSmall --no-gc-sections \
    root.zig ./*.o -lc -femit-bin=engine.wasm )

[[ -s "$WORK/engine.wasm" ]] || { echo "FAIL: linker did not produce engine.wasm"; exit 1; }

echo ">>> PASS: all $n_objs objects from libcrypto.a + libssl.a linked cleanly into a PIC wasm32-wasi dylib"
echo "    (no 'recompile with -fPIC' / absolute-relocation errors from wasm-ld)"
