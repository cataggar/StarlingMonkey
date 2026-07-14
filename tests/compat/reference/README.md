# Compatibility reference mode (opt-in, requires Node.js + Rust)

This directory runs the Phase 0 fixtures in `tests/compat/fixtures/` through
the **real, pinned** ComponentizeJS release, executing the components it
produces through **Wasmtime** (via `../runtime/invoker`, "compat-invoker" --
a small host on the official `wasmtime` Rust crate) rather than any second
component transpiler, for differential comparison against
`tests/compat/manifest.json`'s `result` / `reference_result` fields.

It exists purely as an *optional cross-check* for anyone updating the
manifest or investigating a suspected deviation between the pinned
ComponentizeJS release and this repository's own Zig/WABT JS-dispatch
bridge (`runtime/js_dispatch.cpp`, `runtime/js_dispatch.zig`).

**This directory, and Node.js/npm in general, is never a normal build or
test dependency of StarlingMonkey.** `tests/compat/run-compat-tests.sh` (the
normal, CI-facing structural harness) does not invoke anything in this
directory and does not require Node to be installed. See
`tests/compat/README.md` for the structural harness and
`tests/compat/runtime/README.md` for the required real-bridge runtime mode.

## Why Wasmtime, not jco

An earlier revision of this script used `@bytecodealliance/jco`'s
`transpile()` to load the componentized `.wasm` as an importable JS module.
That makes *jco* (a separate component-model tool with its own bugs and its
own release cadence) part of the measurement, which risks misattributing a
jco defect to ComponentizeJS -- exactly the failure mode
cataggar/StarlingMonkey#6's code review flagged. This script instead writes
the componentized `.wasm` to `.component-cache/<id>.wasm` and invokes it
directly through `../runtime/invoker`'s Wasmtime-based dynamic Component
Model API, so the only non-ComponentizeJS code in the loop is Wasmtime
itself (the same runtime this repository's own bridge fixtures are invoked
through -- see `../runtime/README.md`).

### Why jco still appears in package-lock.json

`@bytecodealliance/componentize-js` itself depends on `@bytecodealliance/jco`
internally (see its own `package.json`) for its own componentization
process -- this is an implementation detail of what shipping
"componentize-js@0.21.0" *means*, not something this script chooses or
invokes. `package.json` in this directory no longer lists `jco` as its own
`devDependency`, and `run-reference.mjs` never imports it; the transitive
copy in `node_modules`/`package-lock.json` is unavoidable and is exercised
only by `componentize()` itself, not by this script's execution/comparison
step.

## Pinned versions

- `@bytecodealliance/componentize-js` is pinned to the exact version
  requested by the task that produced this harness: `0.21.0`. The manifest
  additionally records the specific upstream commit
  (`12c2b4a25033f65047f8ec5c5fb9e3013bfc4950`) that was used while
  authoring/verifying `manifest.json`'s `reference_result` values; see
  `tests/compat/manifest.json`'s `provenance.componentizejs` for details on
  why that commit and the `0.21.0` npm version are the same released code.
- `package-lock.json` is checked in so a from-scratch `npm install` here
  reproduces the exact dependency tree that was used to verify this
  manifest, without requiring anyone to re-resolve versions.

## Requirements

- Node.js **>= 22.12** (or >= 20.19). The pinned `componentize-js` release
  pulls in `@bytecodealliance/weval`, which has a `@napi-rs/lzma` optional
  native dependency; npm silently skips installing platform-specific
  optional dependencies when the *installing* Node's version does not
  satisfy the declaring package's `engines` range, which otherwise breaks
  at runtime with a "Cannot find native binding" error. A portable Node
  22.x tarball from nodejs.org works fine and needs no system install --
  see "Using a portable Node" below.
- `cargo`/`rustc` (any reasonably recent stable toolchain) to build
  `../runtime/invoker`. `run-reference.mjs` builds it automatically
  (`cargo build --release`) the first time it runs.

### Using a portable Node

If the system default `node` is older than required (e.g. the 20.14 that
may be preinstalled), download a portable build and put it first on `PATH`
for this directory's commands -- no system-wide install or root access
needed:

```sh
cd tests/compat/reference
mkdir -p .node-cache && cd .node-cache
curl -sSL https://nodejs.org/dist/v22.12.0/node-v22.12.0-linux-x64.tar.xz | tar xJ
cd ..
export PATH="$PWD/.node-cache/node-v22.12.0-linux-x64/bin:$PATH"
```

(`.node-cache/` is gitignored.)

## Usage

```sh
cd tests/compat/reference
npm install
node run-reference.mjs
```

This componentizes every non-negative fixture with `componentize-js`,
writes each component to `.component-cache/<id>.wasm`, invokes each
declared case/sequence through Wasmtime (via `../runtime/invoker`), and
compares the observed value against the manifest. For the two negative
fixtures (missing/invalid export), it instead confirms that
`componentize()` itself rejects with the expected message, matching
`expect_error.reference_message_contains` in the manifest -- a
componentize-js build-time behavior with no wasm execution involved.
Output follows the same `PASS`/`FAIL` + summary style as
`tests/run-suite.sh` and `tests/compat/run-compat-tests.sh`.

Re-run this after changing any fixture's WIT/JS or any manifest
`result`/`reference_result`/`expect_error` field, to confirm the manifest
still matches real ComponentizeJS behavior observed through Wasmtime.
