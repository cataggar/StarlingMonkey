#!/usr/bin/env bash
#
# Build the native dependencies that `zig build` links against, using the Zig
# toolchain (no wasi-sdk):
#   * SpiderMonkey  -> deps/sm-obj-zig/dist/libspidermonkey.a  (libc++ __1)
#   * OpenSSL       -> deps/openssl-zig/libx32/libcrypto.a
#   * Rust bundle   -> target/wasm32-wasip1/release/librust_staticlib.a
#
# Prerequisites: zig 0.17 (with `zig cc`), rustup (channel from rust-toolchain.toml
# + wasm32-wasip1 target), python3, a host clang/clang++, make, curl, git.
#
# Re-running skips steps whose outputs already exist; pass `--force` to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
WRAP="$DEPS/zig-wrappers"
FORCE="${1:-}"

# Versions (kept in sync with cmake/*.cmake).
SM_TAG="FIREFOX_147_0_4_RELEASE_STARLING"
SM_REPO="https://github.com/bytecodealliance/firefox.git"
OPENSSL_VERSION="3.0.17"

command -v zig >/dev/null || { echo "zig not found on PATH"; exit 1; }
command -v cargo >/dev/null || { echo "cargo not found on PATH"; exit 1; }

# ---------------------------------------------------------------------------
# 1. SpiderMonkey (from source, with the Zig toolchain).
# ---------------------------------------------------------------------------
SM_SRC="$DEPS/spidermonkey-source"
SM_OBJ="$DEPS/sm-obj-zig"
SM_LIB="$SM_OBJ/dist/libspidermonkey.a"
if [[ "$FORCE" == "--force" || ! -f "$SM_LIB" ]]; then
  echo ">>> Building SpiderMonkey ($SM_TAG)"
  if [[ ! -d "$SM_SRC/.git" ]]; then
    git clone --depth 1 --branch "$SM_TAG" "$SM_REPO" "$SM_SRC"
  fi
  # Wasi build fixes:
  #  * mozalloc-abort:      skip mozalloc's abort() override (collides with Zig libc)
  #  * fallback-memalign:   declare memalign/valloc for the memory/build fallback
  #  * gc-aligned-alloc:    the GC needs 1 MiB-aligned chunks, but Zig's wasi-libc
  #                         posix_memalign() caps alignment at the page size
  for p in mozalloc-abort-wasi.patch memory-fallback-wasi-memalign.patch gc-wasi-aligned-alloc.patch; do
    git -C "$SM_SRC" apply --check "$DEPS/patches/$p" 2>/dev/null \
      && git -C "$SM_SRC" apply "$DEPS/patches/$p" || true
  done

  MOZCONFIG="$DEPS/mozconfig-zig"
  cat > "$MOZCONFIG" <<EOF
ac_add_options --enable-project=js
ac_add_options --disable-js-shell
ac_add_options --target=wasm32-unknown-wasi
ac_add_options --without-system-zlib
ac_add_options --without-intl-api
ac_add_options --disable-jit
ac_add_options --disable-shared-js
ac_add_options --disable-shared-memory
ac_add_options --disable-tests
ac_add_options --disable-clang-plugin
ac_add_options --enable-jitspew
ac_add_options --enable-optimize=-O2
ac_add_options --enable-js-streams
ac_add_options --enable-portable-baseline-interp
ac_add_options --disable-stdcxx-compat
ac_add_options --disable-debug
ac_add_options --prefix=$SM_OBJ/dist
mk_add_options MOZ_OBJDIR=$SM_OBJ
mk_add_options AUTOCLOBBER=1
EOF

  MOZCONFIG="$MOZCONFIG" MOZBUILD_STATE_PATH="$DEPS/mozbuild-state" LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib}" \
    env CC="$WRAP/zig-cc" CXX="$WRAP/zig-cxx" AR="$WRAP/zig-ar" HOST_CC="${HOST_CC:-clang}" HOST_CXX="${HOST_CXX:-clang++}" \
    python3 "$SM_SRC/mach" --no-interactive build

  # Combine libjs_static.a with the extra objects StarlingMonkey needs (matches
  # SM_OBJ_FILES in cmake/spidermonkey.cmake).
  SM_OBJS=(
    memory/build/Unified_cpp_memory_build0.o
    memory/mozalloc/Unified_cpp_memory_mozalloc0.o
    mfbt/Unified_cpp_mfbt0.o mfbt/Unified_cpp_mfbt1.o
    mozglue/misc/AutoProfilerLabel.o mozglue/misc/ConditionVariable_noop.o
    mozglue/misc/Debug.o mozglue/misc/Decimal.o mozglue/misc/MmapFaultHandler.o
    mozglue/misc/Mutex_noop.o mozglue/misc/Now.o mozglue/misc/Printf.o
    mozglue/misc/SIMD.o mozglue/misc/StackWalk.o mozglue/misc/TimeStamp.o
    mozglue/misc/TimeStamp_posix.o mozglue/misc/Uptime.o
    mozglue/static/lz4.o mozglue/static/lz4frame.o mozglue/static/lz4hc.o
    mozglue/static/xxhash.o third_party/fmt/Unified_cpp_third_party_fmt0.o
  )
  mkdir -p "$SM_OBJ/dist"
  cp "$SM_OBJ/js/src/build/libjs_static.a" "$SM_LIB"
  ( cd "$SM_OBJ" && zig ar -q "$SM_LIB" "${SM_OBJS[@]}" )
  cp -f "$SM_OBJ/js/src/js-confdefs.h" "$SM_OBJ/dist/include/js-confdefs.h"
  echo ">>> SpiderMonkey done: $SM_LIB"
else
  echo ">>> SpiderMonkey up to date"
fi

# ---------------------------------------------------------------------------
# 2. OpenSSL (libcrypto.a for wasm32-wasi).
# ---------------------------------------------------------------------------
SSL_SRC="$DEPS/openssl-src"
SSL_INSTALL="$DEPS/openssl-zig"
if [[ "$FORCE" == "--force" || ! -f "$SSL_INSTALL/libx32/libcrypto.a" ]]; then
  echo ">>> Building OpenSSL $OPENSSL_VERSION"
  if [[ ! -d "$SSL_SRC" ]]; then
    curl -sL -o "$DEPS/openssl-$OPENSSL_VERSION.tar.gz" \
      "https://openssl.org/source/old/3.0/openssl-$OPENSSL_VERSION.tar.gz"
    mkdir -p "$SSL_SRC"
    tar xzf "$DEPS/openssl-$OPENSSL_VERSION.tar.gz" -C "$SSL_SRC" --strip-components=1
    ( cd "$SSL_SRC" && patch -p1 < "$DEPS/patches/getuid.patch" && patch -p1 < "$DEPS/patches/rand.patch" )
  fi
  ( cd "$SSL_SRC"
    # -fPIC: passed through Configure as a bare compiler flag, it lands in
    # both $useradd{CFLAGS} and $useradd{CXXFLAGS} (see Configure's generic
    # "-something" arg handling), so it reaches every libcrypto object file's
    # compile command. -no-asm means every crypto primitive is compiled from
    # C (no perlasm-generated .S files, so there is no separate
    # assembly/ASFLAGS step to keep in sync) -- this is what makes a single
    # -fPIC flag here sufficient to cover "compile and assembly-equivalent
    # steps" consistently. Without it, libcrypto.a's objects contain
    # absolute-address relocations (R_WASM_MEMORY_ADDR_SLEB/LEB) that
    # wasm-ld rejects when the archive is later pulled into a
    # `-dynamic -fPIC` wasm32-wasi dylib (see deps/verify-openssl-pic.sh).
    CC="$WRAP/zig-cc" AR="$WRAP/zig-ar" RANLIB="$WRAP/zig-ranlib" \
      ./Configure linux-x32 --prefix="$SSL_INSTALL" --openssldir="$SSL_INSTALL" \
        -static -fPIC -no-sock -no-asm -no-ui-console -no-egd -no-afalgeng -no-tests \
        -no-stdio -no-threads no-dso -DHAVE_FORK=0 -DNO_SYSLOG -DNO_CHMOD \
        -DOPENSSL_NO_SECURE_MEMORY --with-rand-seed=getrandom
    make -j"$(nproc)"
    make install_sw )
  echo ">>> OpenSSL done: $SSL_INSTALL/libx32/libcrypto.a"
else
  echo ">>> OpenSSL up to date"
fi

# ---------------------------------------------------------------------------
# 3. Rust crate bundle (single wasm32-wasip1 staticlib).
# ---------------------------------------------------------------------------
RUST_LIB="$ROOT/target/wasm32-wasip1/release/librust_staticlib.a"
if [[ "$FORCE" == "--force" || ! -f "$RUST_LIB" ]]; then
  echo ">>> Building Rust crate bundle"
  BD="$DEPS/rust-staticlib-build"
  rm -rf "$BD" && mkdir -p "$BD/.cargo"
  # Build every unit (the bundle crate and all its path/registry
  # dependencies) as position-independent code, so the resulting
  # librust_staticlib.a can later be linked into a wasm32-wasi PIC dylib
  # (e.g. `wasm-ld -shared`/`zig build-lib -dynamic -fPIC`) instead of only
  # a plain static executable. Scoped via a tracked config.toml (not
  # RUSTFLAGS or the user's ambient ~/.cargo/config.toml) so it is
  # reproducible and target-specific.
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
  echo ">>> Rust bundle done: $RUST_LIB"
else
  echo ">>> Rust bundle up to date"
fi

echo
echo "All dependencies built. Now run: zig build -Doptimize=ReleaseSmall"
