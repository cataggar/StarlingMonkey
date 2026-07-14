# ComponentizeJS compatibility harness (Phase 0)

This directory implements Phase 0 of
[cataggar/StarlingMonkey#6](https://github.com/cataggar/StarlingMonkey/issues/6):
a data-driven manifest describing where StarlingMonkey's WIT/JavaScript
bridge (`runtime/js_dispatch.cpp` + `runtime/js_dispatch.zig`, driven by
`host-apis/wasi-0.2.10/wit/js-dispatch.wit`) agrees or diverges from the
pinned `@bytecodealliance/componentize-js@0.21.0` release, plus a Node-free
test harness and original WIT/JavaScript fixtures that exercise the
currently supported surface: booleans, numeric primitives (within the
current bridge's exact limits -- see `known_deviations` below), strings,
lists, records, options, void returns, many-argument calls, repeated calls
against persistent module state, and two negative cases (a WIT export the
JS module never defines, and one it defines as a non-function).

Everything here is scoped to what the *current* bridge actually supports.
Enums, flags, variants, results, resources, imports, and Promise-returning
exports are out of scope for Phase 0 (see the issue's Phase 1-9 roadmap)
but the manifest schema and harness are intentionally structured so that
adding them later means appending `feature_matrix`/`fixtures` entries, not
redesigning anything.

## Layout

```
tests/compat/
  manifest.json           # single source of truth: provenance, known
                          # deviations, feature matrix, per-fixture cases
  schema/manifest.schema.json  # draft-07-subset JSON Schema for manifest.json,
                          # actually enforced by run-compat-tests.sh via
                          # lib/json_schema_lite.py (stdlib-only validator)
  fixtures/<id>/wit/world.wit  # original WIT per fixture (see "Provenance")
  fixtures/<id>/component.js   # original JS per fixture
  fixtures/package.json        # {"type": "module"}, only for the optional
                               # Node self-check described below
  expected/<id>.json      # checked-in, denormalized projection of each
                          # fixture's manifest.json cases, so expected
                          # observable outputs are reviewable and diffable
                          # without parsing the whole manifest
  lib/                    # Python 3 standard-library-only harness code
  run-compat-tests.sh     # structural entry point (Node-free, fast)
  runtime/                 # REQUIRED runtime-compatibility mode: builds the
                          # real StarlingMonkey WIT dispatch reactor, uses
                          # Wizer+WABT to componentize, and invokes through
                          # Wasmtime; see runtime/README.md
  reference/              # explicitly opt-in ComponentizeJS reference mode
                          # (requires Node.js >= 22.12); see reference/README.md
```

## Two harness modes: structural (fast) vs runtime (real bridge)

This directory has two genuinely different verification modes; naming and
build wiring keep them distinct on purpose (cataggar/StarlingMonkey#6 code
review found an earlier revision blurred this, reporting a "76/76" pass
that never actually built or ran the Zig/WABT bridge):

- **`run-compat-tests.sh` (structural, Node-free, fast, part of `zig build
  test` via `zig build compat-test`)**: validates that `manifest.json`,
  its schema, its fixtures, and its checked-in `expected/` projections are
  internally consistent, plus a best-effort plain-JS self-check. It never
  builds StarlingMonkey, never runs Zig/WABT/Wasmtime, and does not
  validate anything about ComponentizeJS. See "What this harness does not
  verify" below.
- **`runtime/run-bridge-tests.sh` (real bridge, required/full mode, `zig
  build compat-bridge-test`, *not* part of the default `test`/`compat-test`
  targets because a full run takes ~15-20 minutes)**: builds the actual
  `runtime/js_dispatch.cpp`/`runtime/js_dispatch.zig` reactor for every
  fixture, componentizes with the real Wizer+WABT pipeline
  (`componentize.sh`, using a `wabt` build containing
  cataggar/wabt#331's reactor-export-lift fix), invokes every export
  through Wasmtime (via `runtime/invoker`, a small host on the official
  `wasmtime` Rust crate), and compares against `manifest.json`. Missing
  tools (`wasm-tools`, a Rust toolchain for `cargo`) or prebuilt build
  artifacts make it **fail**, not skip -- see `runtime/README.md`.

## Running the (Node-free) harness

```sh
tests/compat/run-compat-tests.sh
```

This requires only `python3` (already a documented StarlingMonkey build
requirement) and, best-effort, the already-pinned `wasm-tools` binary this
repository uses elsewhere (`tests/run-suite.sh`, `build.zig`); it does not
require Node, npm, or a full StarlingMonkey wasm build, and it does not
modify or depend on the existing e2e/integration suite
(`tests/run-suite.sh`) at all. It checks:

1. `manifest.json` actually validates against `schema/manifest.schema.json`
   (draft-07 subset; see `lib/json_schema_lite.py`), not just a hardcoded
   top-level-keys check.
2. Every `expected/<id>.json` file matches what `manifest.json` currently
   declares for that fixture (catches manual edits that drift out of sync;
   regenerate with `python3 tests/compat/lib/regen_expected.py`).
3. Every fixture's `wit/world.wit` actually parses (via `wasm-tools
   component wit --json`) and its world exports exactly the function names
   the manifest's cases/sequences reference.
4. Every non-negative fixture's `component.js` statically defines each of
   those exports as a function; the two negative fixtures are checked for
   the opposite (a declared WIT export that `component.js` never defines,
   or defines as a non-function), matching their `negative: true` intent.
5. **Best-effort only, skipped without failing if `node` is not on
   `PATH`:** each fixture's plain JavaScript is evaluated directly with a
   system Node.js and compared against the manifest's declared results.
   This exercises only JS semantics (no WIT, no canonical ABI, no
   ComponentizeJS, no wasm) -- it is a self-consistency check on fixture
   authoring, not a substitute for either the real bridge or the reference
   mode below. StarlingMonkey does not depend on Node for anything else;
   this step degrades to `SKIP` cleanly on a machine without it.

None of the above requires building the StarlingMonkey wasm runtime itself
(no `deps/spidermonkey-source` build), which is why this harness can run
quickly in ordinary CI alongside (but independent of) `zig build test`.

## What this (structural) harness does *not* verify

The Node-free steps above validate structure and (best-effort) plain JS
semantics; they do not execute the actual Zig/WABT JSON dispatch bridge
(`runtime/js_dispatch.cpp`) against a real StarlingMonkey wasm build, and
they do not execute the fixtures through real ComponentizeJS. That gap is
closed by the two modes below, which this same directory now also
provides:

- **`runtime/run-bridge-tests.sh`** builds and runs the real Zig/WABT
  bridge for every fixture (see the "Two harness modes" section above and
  `runtime/README.md`).
- **`reference/run-reference.mjs`** runs every fixture through the real,
  pinned ComponentizeJS release, executed via Wasmtime (see "Opt-in
  reference mode" below and `reference/README.md`).

Neither of the two runtime-executing modes above is part of
`run-compat-tests.sh`/`zig build compat-test`; they are separate,
explicitly-invoked steps (see build.zig's `compat-bridge-test` step for the
bridge side). Where a `manifest.json` case still carries a
`static-reasoning` confidence rather than a build- or reference-verified
one, that reflects a specific case not yet exercised by either mode (for
example a deviation only discovered by code reading), not a structural
limitation of this repository's tooling.

## Opt-in reference mode

`reference/` runs every fixture through the real, pinned
`@bytecodealliance/componentize-js@0.21.0`, executes the produced component
through Wasmtime (via `runtime/invoker`, not a second component transpiler),
and compares against `manifest.json`'s `result`/`reference_result` fields.
It requires Node.js >= 22.12 and a Rust toolchain (`cargo`), is never
invoked by the normal build/test flow, and must be run manually via one
deterministic command: `cd reference && npm install && node
run-reference.mjs`. See `reference/README.md`.

## Known deviations

See `manifest.json`'s `bridge.known_deviations` for the full list with
evidence and confidence levels. Summary, as of this manifest:

- **Interface export flattening**: the bridge always looks up a flat
  top-level function by name; ComponentizeJS requires a JS namespace object
  export when the WIT world exports a named `interface`. All Phase 0
  fixtures declare exports directly on the `world` to sidestep this (a
  single JS source is valid input to both pipelines).
- **`u32` values >= 2^31**: do not round-trip correctly through the pinned
  ComponentizeJS reference (reference-verified); the bridge is expected,
  by static reasoning about its JSON-based dispatch, to be unaffected,
  but this has not been build-verified. See the `numeric-primitives`
  fixture's `echou32-max` case.
- **`option::none` representation**: arrives as JS `undefined` under
  ComponentizeJS but as JS `null` under the bridge's JSON round-trip
  (bridge behavior reasoned from `std.json` null serialization, not
  build-verified). All Phase 0 fixtures use the portable `value == null`
  idiom and always return `null` for `none`, so one JS source works under
  both.
- **Missing/invalid export detection timing**: ComponentizeJS detects a
  missing or non-function WIT export at componentization (build) time
  (reference-verified); the bridge only detects this lazily, at call time
  (reasoned from `js_dispatch.cpp`'s `JS_GetProperty`/`JS::IsCallable`
  check, not build-verified). See the two `negative-*` fixtures.

## Provenance

Every fixture's WIT and JavaScript was authored independently from
publicly documented, observable behavior (the WebAssembly Component Model
canonical ABI conventions, and ComponentizeJS's own public README/EXAMPLE
docs) plus hands-on verification against the pinned release performed while
building this manifest -- not copied from ComponentizeJS's source tree.
See `manifest.json`'s `provenance.componentizejs.value_shape_baseline_source`
and each fixture file's header comment.
