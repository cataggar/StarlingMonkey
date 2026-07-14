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

### Wasmtime version: pinned to `27`, not this repository's `42.0.1` (known, proven blocker)

This repository itself pins Wasmtime `v42.0.1` (`cmake/wasmtime.cmake`,
`build.zig.zon`). `invoker/Cargo.toml` was attempted at an exact `=42.0.1`
pin for all three of `wasmtime`/`wasmtime-wasi`/`wasmtime-wasi-http` to
match, but that upgrade is **blocked**, not merely deferred: the published
`wasmtime` 42.0.1 crate declares `rust-version = "1.91.0"` and
`edition = "2024"` in its own `Cargo.toml`, while this repository's
`rust-toolchain.toml` pins `channel = "1.88.0"`. `cargo build` under that
pinned toolchain fails outright (not a warning) with:

```
error: rustc 1.88.0 is not supported by the following packages:
  wasmtime@42.0.1 requires rustc 1.91.0
  cranelift-assembler-x64@0.129.2 requires rustc 1.91.0
  ... (35+ more wasmtime/cranelift/pulley/wiggle crates, all requiring 1.91.0)
```

`cargo update -p cranelift-codegen --precise <older>` cannot route around
this either: `wasmtime-internal-cranelift@42.0.1` requires
`cranelift-codegen = "^0.129.1"`, and every published `0.129.x` release
already requires rustc 1.91.0 -- there is no older, rustc-1.88-compatible
release satisfying that exact range. This is a hard upstream MSRV
requirement of the pinned `42.0.1` release itself, not a resolvable
dependency conflict.

`invoker/Cargo.toml` therefore remains pinned to Wasmtime `27` (the
version already validated by this harness's real 11/11 bridge and
reference runs) until either this repository's Rust toolchain is bumped to
>= 1.91.0 (a repository-wide change out of scope here) or a future
Wasmtime release restores compatibility with an older rustc. This is
recorded here deliberately, rather than silently keeping the old pin with
no explanation.

## Requirements (all fail loudly if missing -- see `lib/run_bridge_tests.py`)

- The exact pinned Zig toolchain (`$ZIG`; see the top-level `README.md` and
  `AGENTS.md`/`CLAUDE.md` for the required version) able to build this
  repository (i.e. the prebuilt SpiderMonkey/OpenSSL/Rust-staticlib
  artifacts `build.zig` needs must already be present -- `deps/sm-obj-zig`,
  `deps/openssl-zig`, `target/wasm32-wasip1/release/librust_staticlib.a`).
- `wasm-tools` on `PATH` (or `$WASM_TOOLS`).
- `cargo`/`rustc` (any reasonably recent stable toolchain) to build
  `invoker/`.
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
