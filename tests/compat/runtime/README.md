# Runtime bridge compatibility mode (required/full, no Node)

This directory builds the **actual** StarlingMonkey WIT dispatch reactor
(`runtime/js_dispatch.cpp` + `runtime/js_dispatch.zig`, driven by
`host-apis/wasi-0.2.10/wit/js-dispatch.wit`) for every fixture in
`../manifest.json`, componentizes it with the real Wizer+WABT pipeline
(`componentize.sh`), invokes its exports through Wasmtime, and compares
observed values/traps against the manifest's checked-in expectations. This
is what actually differentiates this mode from `../run-compat-tests.sh`
(structural-only; see `../README.md`'s "Two harness modes" section) --
cataggar/StarlingMonkey#6's code review found that an earlier revision of
this compatibility harness never did this, and reported a passing result
regardless.

## What it does, per fixture

1. **Generate a full WIT closure** (`../lib/gen_bridge_wit.py`): each
   fixture's `wit/world.wit` declares its exports directly on the world
   (see manifest.json's `interface-export-flattening` known deviation).
   This script rewrites that into `interface api { ... } world js-exports {
   export api; }` and splices it into a copy of
   `host-apis/wasi-0.2.10/wit` (the full WASI 0.2.10 closure StarlingMonkey's
   `js-dispatch` world already imports and exports `starling:js/api` from),
   without modifying the original fixture files.
2. **Build the reactor**: `zig build -Doptimize=ReleaseSmall
   -Dcomponent-wit=<generated> -Dcomponent-world=js-dispatch
   -Ddispatch-wit=<generated>/deps/starling-js -Ddispatch-world=js-exports
   -p <cache>`, producing `starling-raw.wasm` plus `componentize.sh` and
   the tools it needs.
3. **Componentize**: run the installed `componentize.sh` against the
   fixture's `component.js`, using a `wabt` binary built by
   `build-wabt.sh` (see below).
4. **Validate**: `wasm-tools validate` on the componentized output.
5. **Invoke**: run every declared case/sequence through `invoker`
   (`compat-invoker`), instantiating the component once per fixture and
   calling each export in the manifest's declared order (required for the
   `repeated-calls` fixture's module-level state to be observable the way
   a real embedder would see it).
6. **Compare**: observed JSON values against `result`/`bridge_result`; for
   negative fixtures, confirm a call-time wasm trap whose message contains
   `expect_error.bridge_message_contains`.

## Why a wabt build step (`build-wabt.sh`)

The reactor-shaped core module StarlingMonkey's build produces needs
`wabt component new`'s reactor-export-lifting fix
(cataggar/wabt#331, commit `9bb32091fbf7598921cfa364a814015ac4918777` on
`cataggar/wabt`'s `main`). At the time this harness was written, that
commit postdates the latest published `cataggar/wabt` release, so no
prebuilt binary contains it -- `build-wabt.sh` clones the pinned commit,
applies two small local patches (`wabt-patches/*.patch`, needed only to
build wabt's Zig source under this repository's specific pinned Zig
toolchain, which removed the generic `@Type` builtin -- see comments in the
patches and in `build-wabt.sh`), and builds it, caching the result in
`.wabt-cache/` (gitignored) so subsequent runs are instant. Without this
fix, componentizing fails outright with `error: splicing adapters:
UnsupportedAdapterShape`.

## Why a separate Rust tool (`invoker/`, "compat-invoker")

`wasmtime run --invoke '<fn>(<args>)'` only supports one invocation per
process (each CLI invocation reinstantiates the component from its
Wizer-frozen initial state), which cannot exercise the `repeated-calls`
fixture's module-level state persisting across separate dispatches within
one instance. `invoker/` is a small Rust binary on the official `wasmtime`
crate's dynamic Component Model API
(`wasmtime::component::{Component, Linker, Val, Type}`) that instantiates
a component once and calls a JSON-declared sequence of exports against
that single instance, printing a JSON array of `{"ok": true, "value": ...}`
or `{"ok": false, "trap": "..."}` results (a `post_return` failure after an
otherwise-successful call is reported as its own distinct
`{"ok": false, "trap": "post_return failed: ...", "post_return_failed":
true}` record -- see `invoker/src/main.rs`'s `call_and_finalize` -- so it
can never be misreported as a PASS). It is also used, unmodified, by
`../reference/run-reference.mjs` to invoke ComponentizeJS's output, so both
"sides" of the compatibility comparison run through the same Wasmtime
execution path.

### Wasmtime version: exact `42.0.1` match, via a scoped Rust 1.91 toolchain

This repository itself pins Wasmtime `v42.0.1` (`cmake/wasmtime.cmake`,
`build.zig.zon`); `invoker/Cargo.toml` now pins the exact same `=42.0.1`
for all three of `wasmtime`/`wasmtime-wasi`/`wasmtime-wasi-http`, matching
it precisely (see `invoker/Cargo.lock`).

The published `wasmtime` 42.0.1 crate declares `rust-version = "1.91.0"`
and `edition = "2024"` in its own `Cargo.toml`, newer than this
repository's root `rust-toolchain.toml` (`channel = "1.88.0"`, pinned for
producing this repository's production `wasm32-wasip1` artifacts). That
version gap is **not** a blocker for `invoker/`, because compat-invoker is
a standalone host-side test tool: it produces no `wasm32-wasip1` output,
is never linked into or shipped as part of StarlingMonkey itself, and only
ever runs on the *host* as a test harness helper. It therefore carries its
own nested `invoker/rust-toolchain.toml`, pinning exact Rust `1.91.0`
(`profile = "minimal"`, host-only -- no `wasm32-wasip1` target is declared
or needed here) -- independently of, and without changing, the repository
root's `rust-toolchain.toml`.

rustup resolves the *nearest* `rust-toolchain.toml` by walking up from the
current working directory, so this works automatically as long as `cargo`
is invoked with a `cwd` inside `invoker/` (or a path under it) rather than
depending on the *caller's* cwd. Both call sites that build/run
`compat-invoker` already do this: `lib/run_bridge_tests.py`'s
`build_invoker()` runs `cargo build --release --quiet` with
`cwd=RUNTIME_DIR / "invoker"` (an absolute path derived from
`Path(__file__).resolve()`, not the caller's shell cwd), and
`../reference/run-reference.mjs` runs the same command with
`{ cwd: INVOKER_DIR }` (an absolute path derived from
`fileURLToPath(import.meta.url)`). A one-off manual
`cd tests/compat/runtime/invoker && cargo build --release` (or `cargo
test`) also picks up the scoped toolchain the same way.

Verify the scoped toolchain and the exact Wasmtime pin independently:

```sh
cd tests/compat/runtime/invoker
rustc --version   # rustc 1.91.0 (...), not the repository root's 1.88.0
cargo metadata --format-version 1 | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); \
    print([p["version"] for p in d["packages"] if p["name"]=="wasmtime"])'
  # ["42.0.1"]
```

Adapting `invoker/src/main.rs` from Wasmtime 27 to 42 required a handful
of API updates (see the file's own comments at each call site for
details): `wasmtime_wasi::pipe`/`add_to_linker_sync` moved under a new
`p2` module; `WasiView` now returns a single `WasiCtxView` bundling the
context and resource table instead of separate `ctx()`/`table()` methods;
`Instance::get_export` now returns `(ComponentItem, ComponentExportIndex)`
instead of a bare index; `Func::params`/`Func::results` were replaced by
`Func::ty(&store).params()/.results()`; `wasmtime::Error` no longer
implements `std::error::Error` (so `anyhow::Context::context` needs an
explicit `.map_err(anyhow::Error::from)` first, with the `wasmtime` crate's
own `"anyhow"` feature enabled for that conversion); and, most
significantly, `Func::call` now runs the canonical ABI's mandatory
`post-return` cleanup as an inseparable last step of the same call --
`Func::post_return` is a deprecated no-op kept only for source
compatibility. See "Keeping post_return failure handling under Wasmtime
42" below for what that means for this harness's post-return-trap
handling and its unit tests.

This match was validated with real 11/11 bridge (`run-bridge-tests.sh`)
and 11/11 reference (`../reference/run-reference.mjs`) runs against
Wasmtime `42.0.1` under the scoped Rust `1.91.0` toolchain; see this
directory's git history for the exact commands and output.

#### Keeping post_return failure handling under Wasmtime 42

Wasmtime 42's `Func::call` folding post-return into the call itself
actually strengthens the invariant `call_and_finalize` exists to
guarantee: a post-return trap can no longer be silently swallowed as a
false `ok:true` PASS *by construction*, for every caller of the `wasmtime`
crate, not just this one, since `call` itself now returns `Err`
unconditionally in that case. What Wasmtime's public API no longer
exposes is *which* phase of a single failing `call` actually trapped
(`results` are already lifted from the callee's return values before the
post-return step runs internally). `call_and_finalize` recovers that
distinction by comparing `results`' `Debug` representation before and
after the call (`wasmtime::component::Val` has no `PartialEq` impl):
`Func::call`'s own docs state the caller-supplied initial values are
ignored and always overwritten on success, so if a trapping call
nonetheless left `results` changed away from their placeholders, the call
body must have completed (writing real results) before post-return then
failed -- reported as the same distinct `{"ok": false, "trap":
"post_return failed: ...", "post_return_failed": true}` record as before.
The two `invoker/src/main.rs` unit tests exercising this
(`post_return_trap_is_reported_as_failure_not_false_pass`,
`successful_post_return_still_reports_call_value`) are unchanged in intent
and both pass under Rust 1.91/Wasmtime 42.0.1.

## Requirements (all fail loudly if missing -- see `lib/run_bridge_tests.py`)

- The exact pinned Zig toolchain (`$ZIG`; see the top-level `README.md` and
  `AGENTS.md`/`CLAUDE.md` for the required version) able to build this
  repository (i.e. the prebuilt SpiderMonkey/OpenSSL/Rust-staticlib
  artifacts `build.zig` needs must already be present -- `deps/sm-obj-zig`,
  `deps/openssl-zig`, `target/wasm32-wasip1/release/librust_staticlib.a`).
- `wasm-tools` on `PATH` (or `$WASM_TOOLS`).
- `cargo`/`rustc` on `PATH` to build `invoker/`: any `rustup`-managed
  installation is sufficient, since `invoker/rust-toolchain.toml` pins its
  own exact Rust `1.91.0` (installed via `rustup toolchain install
  1.91.0` if not already present) independently of whatever toolchain is
  otherwise active for the rest of this repository.
- Network access (or an already-populated `.wabt-cache/` and Zig package
  cache) the first time `build-wabt.sh` runs, to clone `cataggar/wabt`.


## Usage

```sh
ZIG=/path/to/pinned/zig tests/compat/runtime/run-bridge-tests.sh
# or, while developing this suite itself, just a subset:
ZIG=/path/to/pinned/zig tests/compat/runtime/run-bridge-tests.sh booleans repeated-calls
```

A full run builds all 11 fixtures from scratch (~90s each with a warm Zig
global package cache), so it is wired into `build.zig` as its own
`compat-bridge-test` step, distinct from and *not* a dependency of `zig
build test`/`zig build compat-test` -- see the top-level `README.md`.

## Layout

```
runtime/
  run-bridge-tests.sh     # entry point
  build-wabt.sh            # builds/caches a wabt binary with #331's fix
  wabt-patches/*.patch     # local Zig-toolchain-compat patches for wabt
  lib/run_bridge_tests.py  # orchestration (preflight, build, run, compare)
  invoker/                 # compat-invoker: Wasmtime-based Rust host
  .wabt-cache/, .cache/    # gitignored build caches
```
