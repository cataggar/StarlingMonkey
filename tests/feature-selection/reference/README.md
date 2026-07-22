# Feature-selection reference mode (opt-in, requires Node.js)

This directory runs a trivial component through the real, pinned
`@bytecodealliance/componentize-js` **0.21.0** release's actual
`disableFeatures`/`enableFeatures` `componentize()` options, and records the
resulting WASI import/export surface (via `wasm-tools component wit`) for
differential comparison against
[`expected/import-surfaces.json`](expected/import-surfaces.json).

It exists purely as an *optional cross-check* for anyone investigating a
suspected deviation between the pinned ComponentizeJS release and this
repository's own feature-selection implementation (`build.zig`'s "Platform
feature selection" section, `runtime/feature_stubs.c`, and the
`STARLING_FEATURE_*`-gated C++ call sites -- see
[`docs/feature-selection/README.md`](../../../docs/feature-selection/README.md)).

**This directory, and Node.js/npm in general, is never a normal build or
test dependency of StarlingMonkey.** Neither `tests/feature-selection/run-build-option-tests.sh`
nor `tests/feature-selection/run-runtime-tests.sh` (the two scripts wired into
`zig build test`/`zig build feature-selection-runtime-test`) invoke anything
in this directory, and neither requires Node to be installed. The production
componentizer (`componentize.sh`) remains Node-free.

## What this checks

`probe.mjs` componentizes [`component.js`](component.js) against
[`wit-probe/world.wit`](wit-probe/world.wit) (a minimal `export handler: func()
-> u32;` world, deliberately not StarlingMonkey's own WIT world, since the
point is to observe ComponentizeJS's *own* WASI-closure behavior in
isolation) for each of the following `componentize()` option combinations,
matching the feature names/CSV semantics this repository's own
`-Ddisable-features`/`-Denable-features` build options accept:

- `defaults` -- no options (ComponentizeJS's default, all-enabled, surface).
- `disable-all` -- `disableFeatures: ["random","stdio","clocks","http","fetch-event"]`.
- `disable-http-only`, `disable-fetch-event-only`, `disable-random`,
  `disable-clocks`, `disable-stdio` -- one feature disabled at a time.
- `enable-features-nonempty` -- a redundant `enableFeatures: ["random"]` with
  no corresponding disable (must be a no-op, not an error).
- `unknown-feature` -- `disableFeatures: ["bogus-feature"]` (an unknown name).
- `enable-and-disable-same` -- the same feature in both lists.

The last two are the key **deviation probes**: this repository's `build.zig`
`@panic`s deterministically for both (see `run-build-option-tests.sh`'s
`unknown-feature-in-disable-list`/`conflicting-same-feature-disable-and-enable`
cases), whereas ComponentizeJS 0.21.0 silently accepts both and proceeds
using only the recognized/non-conflicting entries -- confirmed by this probe
succeeding (not throwing) for both. This is an intentional,
stricter-than-reference diagnostic; see
`docs/feature-selection/README.md`.

## Running

```sh
cd tests/feature-selection/reference
npm install
node probe.mjs /path/to/wasm-tools   # defaults to `wasm-tools` on PATH
```

This writes `actual-import-surfaces.json` (gitignored scratch output) next
to this README, compares it with `expected/import-surfaces.json`, and exits
nonzero on drift (e.g. after a ComponentizeJS version bump). The checked-in
`expected/import-surfaces.json` was captured against the pinned `0.21.0`
release and is believed stable, since it reflects the (fixed, pinned) npm
release's own WASI-closure construction, not anything about StarlingMonkey.

## Pinned versions

- `@bytecodealliance/componentize-js` is pinned to `0.21.0`, the same
  version pinned by `tests/compat/reference/package.json` (see that
  directory's README for the exact upstream commit/provenance notes; both
  reference directories intentionally pin the identical release so a single
  `npm install` result can be reused between them if desired, e.g. by
  symlinking `node_modules`).
- `package-lock.json` is checked in so a from-scratch `npm install` here
  reproduces the exact dependency tree used to produce
  `expected/import-surfaces.json`.

## Requirements

Same as `tests/compat/reference/README.md`: Node.js >= 22.12 (or >= 20.19);
see that file's "Using a portable Node" section if the system Node is older.
