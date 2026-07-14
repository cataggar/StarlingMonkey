# Compatibility reference mode (opt-in, requires Node.js)

This directory runs the Phase 0 fixtures in `tests/compat/fixtures/` through
the **real, pinned** ComponentizeJS release, for differential comparison
against `tests/compat/manifest.json`'s `reference_result` / `result` fields.

It exists purely as an *optional cross-check* for anyone updating the
manifest or investigating a suspected deviation between the pinned
ComponentizeJS release and this repository's own Zig/WABT JS-dispatch
bridge (`runtime/js_dispatch.cpp`, `runtime/js_dispatch.zig`).

**This directory, and Node.js/npm in general, is never a normal build or
test dependency of StarlingMonkey.** `tests/compat/run-compat-tests.sh` (the
normal, CI-facing compatibility harness) does not invoke anything in this
directory and does not require Node to be installed. See
`tests/compat/README.md` for the Node-free harness.

## Pinned versions

- `@bytecodealliance/componentize-js` is pinned to the exact version
  requested by the task that produced this harness: `0.21.0`. The manifest
  additionally records the specific upstream commit
  (`12c2b4a25033f65047f8ec5c5fb9e3013bfc4950`) that was used while
  authoring/verifying `manifest.json`'s `reference_result` values; see
  `tests/compat/manifest.json`'s `provenance.componentizejs` for details on
  why that commit and the `0.21.0` npm version are the same released code.
- `@bytecodealliance/jco` is pinned to `1.25.2` for reference-run
  reproducibility (transpiling the componentized `.wasm` so it can be
  `import()`-ed and called directly, bypassing all CLI string-argument
  ambiguity). Its exact version is not otherwise significant to Phase 0.
- `package-lock.json` is checked in so a from-scratch `npm install` here
  reproduces the exact dependency tree that was used to verify this
  manifest, without requiring anyone to re-resolve versions.

## Requirements

- Node.js **>= 22.12** (or >= 20.19). The pinned `componentize-js` release
  pulls in `@bytecodealliance/weval`, which has a `@napi-rs/lzma` optional
  native dependency; npm silently skips installing platform-specific
  optional dependencies when the *installing* Node's version does not
  satisfy the declaring package's `engines` range, which otherwise breaks
  at runtime with a "Cannot find native binding" error. Older Node (e.g. the
  20.14 that may be the default `node` on a given machine) can *run* jco's
  transpiled output fine, it just cannot successfully *install* this
  directory's dependencies.

## Usage

```sh
cd tests/compat/reference
npm install
node run-reference.mjs
```

This componentizes and transpiles every non-negative fixture, calls each
declared case/sequence, and compares the observed value against the
manifest. For the two negative fixtures (missing/invalid export), it
instead confirms that `componentize()` itself rejects with the expected
message, matching `expect_error.reference_message_contains` in the
manifest. Output follows the same `PASS`/`FAIL`/`SKIP` + summary style as
`tests/run-suite.sh` and `tests/compat/run-compat-tests.sh`.

Re-run this after changing any fixture's WIT/JS or any manifest
`reference_result`/`expect_error` field, to confirm the manifest still
matches real ComponentizeJS behavior.
