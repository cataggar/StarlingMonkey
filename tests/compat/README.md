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
  schema/manifest.schema.json  # informational JSON Schema for manifest.json
  fixtures/<id>/wit/world.wit  # original WIT per fixture (see "Provenance")
  fixtures/<id>/component.js   # original JS per fixture
  fixtures/package.json        # {"type": "module"}, only for the optional
                               # Node self-check described below
  expected/<id>.json      # checked-in, denormalized projection of each
                          # fixture's manifest.json cases, so expected
                          # observable outputs are reviewable and diffable
                          # without parsing the whole manifest
  lib/                    # Python 3 standard-library-only harness code
  run-compat-tests.sh     # entry point (Node-free)
  reference/              # explicitly opt-in ComponentizeJS reference mode
                          # (requires Node.js >= 22.12); see reference/README.md
```

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

1. `manifest.json` has the expected top-level shape.
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

## What this harness does *not* verify

The Node-free steps above validate structure and (best-effort) plain JS
semantics; they do not execute the actual Zig/WABT JSON dispatch bridge
(`runtime/js_dispatch.cpp`) against a real StarlingMonkey wasm build, and
they do not execute the fixtures through real ComponentizeJS. Several
`manifest.json` entries are therefore annotated `static-reasoning` (inferred
from reading the bridge's C++/Zig source, not build-verified) rather than
`reference-verified` (actually observed against the pinned ComponentizeJS
release) or `source-verified`. See `manifest.json`'s `provenance` and each
case's `confidence` field. The opt-in reference mode in `reference/` closes
part of this gap for the ComponentizeJS side; closing it for the bridge
side requires a full wasm build environment, which this session's
environment could not provide (no prebuilt `libspidermonkey.a` for
wasm32-wasi was available), and is left as follow-up work.

## Opt-in reference mode

`reference/` runs every fixture through the real, pinned
`@bytecodealliance/componentize-js@0.21.0` and compares against
`manifest.json`'s `reference_result` fields. It requires Node.js >= 22.12,
is never invoked by the normal build/test flow, and must be run manually.
See `reference/README.md`.

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
building this manifest -- not copied from ComponentizeJS's or jco's source
trees. See `manifest.json`'s `provenance.componentizejs.value_shape_baseline_source`
and each fixture file's header comment.
