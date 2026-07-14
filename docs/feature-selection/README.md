# feature-selection: ComponentizeJS-compatible platform feature defaults/disabling

Branch: `feat/feature-selection` (worktree `/work/StarlingMonkey-feature-selection`).
Todo id: `feature-selection`. Roadmap: cataggar/StarlingMonkey#6 Phase 6.

## 1. Goal

Provide ComponentizeJS 0.21.0-compatible platform feature defaults and
disabling behavior for **stdio**, **random**, **clocks**, **http**, and
**fetch-event**, via typed Zig build options (not environment-variable
hacks), so that:

- Defaults match ComponentizeJS 0.21.0 (all five features enabled).
- Disabling a feature prunes or stubs its WASI imports so `wasm-tools
  component wit`/metadata reflects the selected surface where architecturally
  possible.
- A **pure-component mode** (all five disabled) emits the smallest viable
  import surface achievable given this repository's WASI closure and
  prebuilt preview1-adapter, and fails deterministically -- never silently --
  if user JavaScript requests disabled host functionality.
- Incompatible/unknown feature selections produce a deterministic build-time
  error, never a silent fallback.
- The production componentizer (`componentize.sh`) remains entirely
  Node-free; Node is only ever used, opt-in, to cross-check against the real
  pinned ComponentizeJS release (`tests/feature-selection/reference/`).

This document is the authoritative behavior matrix and deviation list;
inline comments throughout the changed source point back here.

## 2. CLI / build usage

Five typed boolean options, all defaulting to `true` (matches
ComponentizeJS's "all features enabled by default"):

```sh
zig build -Dfeature-stdio=false
zig build -Dfeature-random=false
zig build -Dfeature-clocks=false
zig build -Dfeature-http=false
zig build -Dfeature-fetch-event=false
```

Any combination may be given together, e.g. pure-component mode:

```sh
zig build \
  -Dfeature-stdio=false -Dfeature-random=false -Dfeature-clocks=false \
  -Dfeature-http=false -Dfeature-fetch-event=false
```

For ComponentizeJS-CLI ergonomics, two comma-separated-list options are also
accepted and are layered on top of the typed booleans (a name in both lists
is a **conflict**, see below):

```sh
zig build -Ddisable-features=http,fetch-event
zig build -Denable-features=random          # re-enable a typed-disabled feature
```

The resolved selection is written to `zig-out/bin/features.json` (or
`<prefix>/bin/features.json`) as a small JSON manifest, e.g.:

```json
{
  "stdio": true,
  "random": true,
  "clocks": true,
  "http": false,
  "fetch-event": true
}
```

### Diagnostics (deterministic, never a silent fallback)

```sh
$ zig build -Ddisable-features=bogus-name
error: -Ddisable-features: unknown feature 'bogus-name' (known features: stdio, random, clocks, http, fetch-event)
panic: unknown feature name
[...]
$ echo $?
1

$ zig build -Ddisable-features=http -Denable-features=http
error: feature 'http' appears in both -Ddisable-features and -Denable-features
panic: conflicting feature selection
[...]
$ echo $?
1
```

Both checks run during Zig's build-graph configuration (before any
compilation), so they fail in well under a second even for a `--help`
invocation -- see `tests/feature-selection/run-build-option-tests.sh`.

## 3. Behavior matrix

Each row: feature, ComponentizeJS 0.21.0 reference default/behavior when
disabled (empirically verified against the pinned npm release --
`tests/feature-selection/reference/`), and this repository's behavior.

| Feature | Default | Reference (disabled) | This repo (disabled) |
|---|---|---|---|
| `stdio` | enabled | `wasi:cli/stdin`+`stdout`+terminal-* removed; `cli/stderr` **kept** | `terminal-*` (5 imports) removed; `wasi:cli/stdin`\|`stdout`\|`stderr` **all kept** (adapter-level residual, see deviation D1) |
| `random` | enabled | `wasi:random/random` removed entirely | `wasi:random/random` removed entirely (matches); `crypto.getRandomValues` returns a deterministic splitmix64 PRNG stream instead of throwing |
| `clocks` | enabled | `wasi:clocks/monotonic-clock` removed; `wasi:clocks/wall-clock` **kept** | **neither** clock import removed (see deviation D2); `setTimeout`/`setInterval` throw a catchable `FeatureDisabled` `TypeError` instead |
| `http` | enabled | `wasi:http/outgoing-handler` removed; `wasi:http/types` **kept** | `wasi:http/outgoing-handler` removed; `wasi:http/types` **kept** (matches); `fetch()` rejects with a catchable error instead of trapping |
| `fetch-event` | enabled | no import-surface change (only export-surface differs, not probed here) | no import-surface change (matches); `addEventListener('fetch', ...)` throws a catchable `FeatureDisabled` `TypeError` synchronously |
| `http` + `fetch-event` both disabled | -- | not applicable (ComponentizeJS's world is caller-defined; ours is fixed) | `wasi:http/outgoing-handler` removed; `wasi:http/types` import and `wasi:http/incoming-handler` export **both kept** (see deviation D3) |
| all five disabled ("pure mode") | -- | `disableFeatures: [...]` on a world with no HTTP/fetch surface at all -> **zero** imports | `terminal-*`, `wasi:random/random`, `wasi:http/outgoing-handler` removed; `wasi:cli/stdin`\|`stdout`\|`stderr`, `wasi:clocks/monotonic-clock`\|`wall-clock`, `wasi:http/types`, filesystem/sockets/environment/exit/io imports **all remain** (see deviation D4) |
| unknown feature name | -- | **silently ignored** (does not throw) | `@panic`s deterministically at build-configure time (see deviation D5) |
| same feature in both enable+disable lists | -- | **silently accepted** (last-specified or otherwise non-conflicting behavior; does not throw) | `@panic`s deterministically at build-configure time (see deviation D5) |

See `tests/feature-selection/reference/expected/import-surfaces.json` for
the exact, machine-checked reference import lists this table is derived
from, and `tests/feature-selection/run-runtime-tests.sh` for the exact,
machine-checked assertions against this repository's own output.

## 4. Known deviations

**D1 -- stdio residual adapter imports.** The prebuilt
`preview1-adapter.wasm` (a wasi-sdk artifact, out of this phase's scope to
modify) unconditionally imports `wasi:cli/stdin`/`stdout`/`stderr`
regardless of whether the core module still calls the preview1
`fd_write`/`fd_fdstat_get` syscalls. Disabling `stdio` therefore only
eliminates the 5 `terminal-*` imports (confirmed empirically); the three
`wasi:cli/std*` imports are an unavoidable, structural residual. (The
ComponentizeJS reference achieves a *better* partial result here --
dropping `stdin`/`stdout` too, while keeping `stderr` -- because its
Rust-based embedding controls its own preview1-adapter linkage
differently; this is a genuine, currently-unclosed gap, not an oversight.)

**D2 -- `clocks` keeps both clock imports.**
`MonotonicClock::subscribe()`/`unsubscribe()` (`host-apis/wasi-0.2.0/host_api.cpp`)
are deliberately left **ungated** even when `clocks` is disabled, because
the async task scheduler's `AsyncTask::select()` (same file) uses
`subscribe_duration(0)` internally for immediate-vs-blocking task fairness
across *all* async code (fetch, streams, timers) -- gating it would break
unrelated functionality, not just user-facing timers. Only
`MonotonicClock::now()`/`resolution()` and the preview1
`clock_time_get`/`clock_res_get` syscalls are gated (fixed-constant /
trapping stubs in `runtime/feature_stubs.c`). Since the scheduler always
needs monotonic-clock subscription, and the preview1-adapter's own
initialization needs wall-clock regardless of whether the core module still
calls `clock_time_get`, **neither** `wasi:clocks/monotonic-clock` nor
`wasi:clocks/wall-clock` is removed from the import surface when `clocks`
is disabled -- only the *user-facing* behavior (`setTimeout`/`setInterval`)
changes (a deterministic, catchable `FeatureDisabled` `TypeError`, verified
via `tests/feature-selection/run-runtime-tests.sh`'s `clocks-disabled`
case). This is the reference's own disable-clocks behavior for
`wasi:clocks/wall-clock` (kept) but a deviation for `monotonic-clock`
(reference drops it; we keep it, for the reason above).

**D3 -- `http`+`fetch-event` both disabled still expose `wasi:http/types`
and the `wasi:http/incoming-handler` export.** These are baked into a
fixed, prebuilt component-type descriptor
(`bindings_component_type.o`/equivalent) shared by every StarlingMonkey
build, generated by a separate toolchain step outside this phase's scope
(owned by the sibling `wit-imports`/`world-shell-integration` roadmap
agents -- see this task's "Avoid overlap" instruction: "do not redesign
typed JS dispatch or custom WIT import generation"). This repository's C++
gating (`NS_DEF(builtins::web::fetch)`/`NS_DEF(builtins::web::fetch::fetch_event)`
exclusion in `build.zig` when both features are disabled) successfully
removes `wasi:http/outgoing-handler` and all fetch/Request/Response/Headers/
FetchEvent JS bindings, but cannot change the component's fixed WIT world
shape. The pre-existing `MOZ_RELEASE_ASSERT(REQUEST_HANDLER)` guard in
`host_api.cpp`'s `exports_wasi_http_incoming_handler` (unmodified,
pre-existing code) already makes any incoming HTTP request deterministically
fail (`wasmtime serve` reports HTTP 500 with "guest never invoked
`response-outparam::set`") if no handler was registered -- verified in
`tests/feature-selection/run-runtime-tests.sh`.

**D4 -- pure mode is not zero-import.** With all five features disabled,
this repository's import surface loses every *prunable* import
(`terminal-*`, `wasi:random/random`, `wasi:http/outgoing-handler`) but
retains `wasi:cli/stdin`\|`stdout`\|`stderr` (D1), both clock imports (D2),
`wasi:http/types` (D3), and structural imports this phase was not asked to
gate (`wasi:filesystem/*`, `wasi:sockets/*`, `wasi:cli/environment`,
`wasi:cli/exit`, `wasi:io/*`) -- these are part of StarlingMonkey's baseline
WASI 0.2.10 closure regardless of feature selection. ComponentizeJS's own
"disable all features" probe reaches **zero** imports only because its
probed world exports nothing but a trivial `handler: func() -> u32` (no
filesystem/sockets/environment usage at all) -- see
`tests/feature-selection/reference/expected/import-surfaces.json`'s
`disable-all` case. This is an architectural difference in scope (a fixed,
comprehensive WASI-0.2.10-closure runtime vs. a bundler that only links in
what the JS/WIT world actually needs), not a bug in this phase's pruning
logic; a true zero-import StarlingMonkey pure mode would require
demand-driven linking of the whole WASI closure, well beyond this phase's
scope (build options + import pruning/stubbing + diagnostics only, per this
task's boundaries).

**D5 -- stricter-than-reference build-time diagnostics.** ComponentizeJS
0.21.0 silently ignores unknown feature names in
`disableFeatures`/`enableFeatures`, and silently accepts (without error) the
same feature name appearing in both lists -- confirmed by
`tests/feature-selection/reference/probe.mjs`'s `unknown-feature` and
`enable-and-disable-same` cases both succeeding (not throwing). This
repository intentionally deviates by `@panic`ing deterministically at build
time for both (see `build.zig`'s `parseFeatureList`/`resolveFeatures`),
per this task's explicit requirement: "Do not silently fall back." A
misconfigured build fails loudly and immediately rather than silently
building a component with an unintended feature surface.

**D6 -- pre-existing, unrelated bug discovered during this work (not
fixed).** `builtins/web/performance.cpp`'s `Performance::timeOrigin` (a
`std::optional<std::chrono::steady_clock::time_point>`) is declared but
never assigned anywhere in the codebase. Any call to `performance.now()` or
the `timeOrigin` getter crashes via `bad_optional_access` -> an `unreachable`
wasm trap, **on the completely unmodified default build**, independent of
any `clocks` feature-selection setting. This is out of scope for this task
(not caused by, or tightly coupled to, this phase's changes) and is
intentionally left unfixed; `performance.now()` must be avoided when testing
`clocks`-disabled behavior (use `setTimeout`/`Date.now()` instead, as this
phase's fixtures and tests do).

## 5. Implementation summary

- `build.zig` ("Platform feature selection" section): `FeatureName` enum,
  `Features` struct, `parseFeatureList`/`resolveFeatures` (typed
  `-Dfeature-*` booleans plus `-Ddisable-features`/`-Denable-features` CSV
  lists, deterministic `@panic` diagnostics), `-DSTARLING_FEATURE_*=0/1`
  macro threading into both C++ and C compile flags, conditional
  `builtins_incl` generation (excludes the `fetch`/`fetch_event` builtin
  namespaces entirely when both `http` and `fetch-event` are disabled), and
  the `features.json` manifest artifact.
- `runtime/feature_stubs.c` (new): preview1-level C symbol-override stubs
  (`fd_write`, `fd_fdstat_get`, `clock_time_get`, `clock_res_get`,
  `random_get`), each `#if !STARLING_FEATURE_*`-gated. Providing a strong C
  definition for the exact symbol name Zig's bundled wasi-libc declares as
  an `extern` import trampoline (in its auto-generated
  `__wasilibc_real.c`) causes `wasm-ld` to resolve the call internally
  instead of creating a wasm import -- the toolchain handles all
  function-index assignment safely, with no manual WAT/binary patching.
- `host-apis/wasi-0.2.0/host_api.cpp`: gated `Random::get_bytes`/`get_u32`,
  `MonotonicClock::now`/`resolution` (see D2 for why
  `subscribe`/`unsubscribe` stay ungated), `HttpOutgoingRequest::send`
  (returns a generic internal error instead of ever calling
  `wasi_http_outgoing_handler_handle`, letting `wasm-ld` drop the import).
- `include/errors.h`: added `Errors::FeatureDisabled` (a `TypeError`
  matching JS's own exception conventions, catchable via normal
  `try`/`catch`).
- `builtins/web/timers.cpp`: `setTimeout`/`setInterval` throw
  `FeatureDisabled` when `clocks` is disabled.
- `builtins/web/event/global-event-target.cpp`: `addEventListener('fetch',
  ...)` throws `FeatureDisabled` when `fetch-event` is disabled (this check
  lives in the always-compiled `event` builtin, so it remains present even
  when the whole `fetch`/`fetch_event` builtin namespace is excluded by the
  `http`+`fetch-event`-both-disabled case).
- `builtins/web/fetch/fetch_event.cpp`: `install()` skips
  `FetchEvent`/`HttpIncomingRequest::set_handler` registration when
  `fetch-event` is disabled.

## 6. Tests

- `tests/feature-selection/run-build-option-tests.sh` -- fast (~3s),
  Node-free, part of `zig build test` (via the new `feature-selection-test`
  step). Exercises `build.zig`'s option-parsing/validation logic via `zig
  build --help` (which runs the full `build()` function, including all
  `-Dfeature-*` parsing and `@panic` diagnostics, without compiling
  anything). 16 cases: positive (single/combined typed options, CSV
  disable/enable lists, redundant/non-conflicting combinations) and
  negative (unknown feature name in either list, conflicting
  enable+disable of the same feature).
- `tests/feature-selection/run-runtime-tests.sh` -- full, real-build
  component-level tests. NOT part of `zig build test` (each of the 8
  combinations requires a full StarlingMonkey build; wired as the separate
  `feature-selection-runtime-test` step, matching the `compat-bridge-test`
  precedent). For each combination (`defaults`, `stdio-disabled`,
  `random-disabled`, `clocks-disabled`, `http-disabled`,
  `fetch-event-disabled`, `http-and-fetch-event-disabled`, `all-disabled`):
  builds with the corresponding `-Dfeature-*` flags, checks
  `features.json`, componentizes `tests/feature-selection/fixtures/probe.js`,
  asserts the import/export surface via `wasm-tools component wit`
  (including the documented residuals/deviations above), and invokes the
  component via `wasmtime serve -S common --addr 0.0.0.0:0` + curl (the
  same pattern as `tests/test.sh`) to assert on representative
  enabled/disabled runtime behavior.
- `tests/feature-selection/reference/` -- opt-in, Node-required,
  never invoked by the above two scripts or by `componentize.sh`. Runs the
  real pinned ComponentizeJS 0.21.0 `componentize()` API with the same
  `disableFeatures`/`enableFeatures` options against a minimal WIT world,
  for differential comparison against
  `tests/feature-selection/reference/expected/import-surfaces.json` (the
  source of the "Reference" column in the behavior matrix above).

Run everything:

```sh
export ZIG_GLOBAL_CACHE_DIR=/work/StarlingMonkey-feature-selection/.zig-global-cache
zig build test                                          # includes feature-selection-test
zig build feature-selection-runtime-test                 # slow, full builds
```
