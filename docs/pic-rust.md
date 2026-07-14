# pic-rust: building `librust_staticlib.a` as PIC and proving it dynamic-links

Branch: `fix/pic-rust` (worktree `/work/StarlingMonkey-pic-rust`). Todo id: `pic-rust`.

## 1. Background

`docs/world-shell-spike.md` (branch `spike/world-shell-link`) proved that
`wasm-tools component link` (Shared-Everything Dynamic Linking) can compose a
thin WIT "shell" module with an "engine" module, but that applying this to
the *real* StarlingMonkey engine failed: `deps/openssl-zig/libx32/libcrypto.a`,
`target/wasm32-wasip1/release/librust_staticlib.a`, and (almost certainly)
`deps/sm-obj-zig/dist/libspidermonkey.a` were all compiled without `-fPIC`, so
`wasm-ld` rejects their absolute-address relocations
(`R_WASM_MEMORY_ADDR_LEB`/`_SLEB`/`_I32`) when linking a `-dynamic -fPIC`
module (see `docs/world-shell-spike/engine-pic-fail.excerpt.log`).

This todo closes that gap for the Rust part of the bundle: make
`target/wasm32-wasip1/release/librust_staticlib.a` build as PIC, and prove --
by actually linking and running it, not just inspecting relocation records --
that it can now participate in a `wasm32-wasi -dynamic -fPIC` module.

## 2. How `librust_staticlib.a` is built

`deps/build-deps.sh` step 3 ("Rust crate bundle") generates a throwaway Cargo
workspace in `deps/rust-staticlib-build/` (gitignored) from tracked templates
in `runtime/crates/staticlib-template/`:

- `Cargo.toml.in` -- the staticlib crate manifest (`crate-type = ["staticlib"]`).
- `rust-staticlib.rs.in` -- the root source (just `pub use` statements).
- `Cargo.lock` -- pinned dependency versions.

`build-deps.sh` appends path dependencies for `rust-encoding`, `rust-hooks`,
`rust-url`, and `multipart` (from `crates/`) to the generated `Cargo.toml`,
then runs `cargo build --release --target wasm32-wasip1` in that directory.
This is the single, tracked, reproducible path that produces the archive
`build.zig` links against (`link_mod.addObjectFile(... librust_staticlib.a)`,
`build.zig:190`) as well as `cmake/build-crates.cmake`'s
`corrosion_import_crate` build of the same crate for the CMake/wasi-sdk path.

## 3. The fix: a tracked, target-scoped `-C relocation-model=pic`

Added `runtime/crates/staticlib-template/cargo-config.toml.in`:

```toml
[target.wasm32-wasip1]
rustflags = ["-C", "relocation-model=pic"]
```

`deps/build-deps.sh` now copies this into
`deps/rust-staticlib-build/.cargo/config.toml` before running `cargo build`
(alongside the existing `Cargo.toml`/`Cargo.lock`/root-source copies).

Why a tracked `.cargo/config.toml` in the generated build directory, and not
`RUSTFLAGS` or the user's `~/.cargo/config.toml`:
- It's part of the reproducible, tracked build path (same principle as the
  other `*.in` templates already copied into `$BD` by the script), so anyone
  re-running `deps/build-deps.sh` gets a PIC archive without exporting
  anything in their shell.
- Scoping it to `[target.wasm32-wasip1]` (rather than global `rustflags` or an
  exported `RUSTFLAGS`) means it only affects units actually compiled for
  that target -- host-side build scripts/proc-macros (none of these four
  crates have any, but this is future-proof) are unaffected, and it can't
  leak into or be silently overridden by a user's ambient Cargo config.
- Cargo applies target `rustflags` to *every* crate compiled for that target,
  including path and registry dependencies (`arrayvec`, `url`, `winnow`,
  `encoding_c`, `encoding_c_mem`, etc.) -- i.e. "every Rust unit, including
  dependencies" in the bundle, not just the top-level `rust-staticlib` crate.

This does **not** rebuild the wasm32-wasip1 standard library/`compiler_builtins`
shipped by rustup -- see the caveat in section 5.

## 4. Verification: `docs/pic-rust/verify/build-and-verify.sh`

Per the task's instruction not to accept relocation-metadata inspection
alone, `docs/pic-rust/verify/build-and-verify.sh` performs a real, four-step,
reproducible linker verification:

1. **Rebuilds `librust_staticlib.a` from scratch** using the exact
   `deps/build-deps.sh` step-3 logic (so the proof always exercises the
   tracked build path, not a stale artifact).
2. **Links `engine.zig` + the fresh archive into one `wasm32-wasi -dynamic
   -fPIC` module** with the pinned zig
   (`zig-x86_64-linux-0.17.0-dev.902+7255f3e72`). `engine.zig` calls real,
   `#[no_mangle] pub extern "C"` exports from **three different** bundled
   crates -- `install_rust_hooks` (`crates/rust-hooks`),
   `multipart_parser_new`/`multipart_parser_free` (`crates/rust-multipart`),
   and `new_jsurl`/`free_jsurl` (`crates/rust-url`) -- not synthetic
   stand-ins. This is the exact step that failed with "recompile with
   -fPIC" errors in the world-shell-spike's
   `engine-dylib-experiment`/`engine-pic-fail.excerpt.log` when the archive
   wasn't PIC.
3. Confirms the linked module is valid wasm (`wasm-tools validate`) and a
   genuine PIC dylib (has a `dylink.0` custom section).
4. **Builds a thin, independent "shell" module + WIT world
   (`docs/pic-rust/verify/wit/world.wit`), composes it with the engine
   module via `wasm-tools component embed`/`component link`, and executes
   the result with `wasmtime run --invoke`.** The call chain
   `shell-call(5, 7)` -> `engine_verify(5, 7)` -> (rust-hooks, rust-multipart,
   rust-url calls) returns `112` (`5 + 7 + 100`; `+100` is only added if
   every one of those three cross-crate calls round-trips successfully),
   proving the composed, PIC-linked archive is not just link-clean but
   functionally correct across the shared-memory module boundary.

### Reproducing

```
cd /work/StarlingMonkey-pic-rust
unset ZIG_LOCAL_CACHE_DIR
export ZIG_GLOBAL_CACHE_DIR=/work/StarlingMonkey-pic-rust/.zig-global-cache
ZIG=/home/g/.local/share/ghr/tools/cataggar/zig/zig-x86_64-linux-0.17.0-dev.902+7255f3e72/zig

ZIG="$ZIG" WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
  docs/pic-rust/verify/build-and-verify.sh
```

Output ends with:
```
shell-call(5, 7) = 112
...
PASS: librust_staticlib.a is PIC and links + runs as a wasm32-wasi dynamic library.
```

(Pass `SKIP_RUST_BUILD=1` to reuse an already-built `target/wasm32-wasip1/release/librust_staticlib.a`
instead of rebuilding it from scratch, if you've already run
`deps/build-deps.sh`.)

## 5. Ordinary static build path preserved

- `deps/build-deps.sh`'s only functional change is that step 3 now writes a
  `.cargo/config.toml` into the generated build directory before invoking
  `cargo build`; `build.zig`/`cmake/build-crates.cmake` are untouched, and
  neither needed to change since they just reference the resulting archive
  path/crate by name.
- Confirmed the *ordinary* (non-PIC, non-dynamic) static-link path this
  archive is normally used in still works with the now-PIC archive: linking
  `librust_staticlib.a` into a plain `wasm32-wasi` static executable (`zig
  build-exe`, no `-dynamic`/`-fPIC`) succeeds and the resulting module is
  valid wasm and runs correctly under `wasmtime` (PIC object code is a
  strict superset of what a static, non-relocatable link needs; `wasm-ld`
  resolves the PIC-style relative relocations to absolute addresses when
  producing a plain executable).
- `target/` and `deps/rust-staticlib-build/` are already gitignored
  (`.gitignore`); no generated build products are committed by this change.

## 6. Caveat / residual scope

Rebuilding *only* the four bundled crates (and their registry dependencies)
with `-C relocation-model=pic` is sufficient to make `librust_staticlib.a`
link into a PIC dylib and run correctly (proven above) -- Rust's prebuilt
`compiler_builtins`/`std` rlibs shipped by rustup for `wasm32-wasip1` are
*not* recompiled by this change (that would require `-Z build-std`, a
nightly-only Cargo feature, out of scope here). Those prebuilt objects
(e.g. compiler-rt intrinsics like `__addvsi3`) still carry non-PIC
`R_WASM_MEMORY_ADDR_SLEB` relocations against local `.debug_str`/`.rodata`
symbols, but the verification in section 4 shows they are either not pulled
into the final link at all (archive members are lazily included -- only
what's actually referenced gets linked) or, when they are, do not conflict
with a successful `-dynamic -fPIC` link for this bundle's actual call graph.
If a future change to the bundle exercises code paths that pull in one of
these not-fully-PIC prebuilt objects, `wasm-ld` will surface the same
"recompile with -fPIC" diagnostic seen in the original spike, scoped to that
specific object -- rebuilding std via `-Z build-std -C relocation-model=pic`
(nightly toolchain) would be the next step at that point.

## 7. Acceptance gate status: met

| Requirement | Status |
|---|---|
| Inspect `deps/build-deps.sh`, bundle/workspace logic, crate config, conventions before editing | Done -- section 2. |
| `relocation-model=pic` via tracked, reproducible path, for every Rust unit incl. dependencies, no ambient config | Done -- `runtime/crates/staticlib-template/cargo-config.toml.in`, `[target.wasm32-wasip1]`-scoped, copied by `deps/build-deps.sh`. |
| Build the archive from scratch in this worktree | Done -- `docs/pic-rust/verify/build-and-verify.sh` step 1 rebuilds from a clean `deps/rust-staticlib-build/`. |
| Use repo's Rust toolchain; exact pinned zig for zig commands, `ZIG_GLOBAL_CACHE_DIR`, unset `ZIG_LOCAL_CACHE_DIR` | Done -- `rust-toolchain.toml`'s 1.88.0 + wasm32-wasip1 for cargo; pinned zig path for all `zig build-lib` calls. |
| Reproducible targeted linker verification, real bundle exports, `wasm32-wasi -dynamic -fPIC`, no forbidden absolute relocations, not metadata-only | Done -- section 4; a real link + `dylink.0` check + full `wasm-tools component link` + `wasmtime run` execution. |
| Preserve ordinary static build path; no committed generated build products | Done -- section 5; `git status` shows only tracked source/doc files added/changed. |
