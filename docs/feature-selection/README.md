# Platform feature selection and pure components

StarlingMonkey exposes ComponentizeJS 0.21-compatible controls for `stdio`,
`random`, `clocks`, `http`, and `fetch-event`. All five are enabled by
default.

## Build options

Each feature has a typed boolean:

```sh
zig build -Dfeature-stdio=false
zig build -Dfeature-random=false
zig build -Dfeature-clocks=false
zig build -Dfeature-http=false
zig build -Dfeature-fetch-event=false
```

The ComponentizeJS-style list forms are also accepted:

```sh
zig build -Ddisable-features=http,fetch-event
zig build -Dfeature-random=false -Denable-features=random
```

Pure mode disables all five:

```sh
zig build -Doptimize=ReleaseSmall \
  -Dfeature-stdio=false -Dfeature-random=false \
  -Dfeature-clocks=false -Dfeature-http=false \
  -Dfeature-fetch-event=false
```

The resolved values are installed as `bin/features.json`.

Unknown feature names and a feature present in both lists are build-time
errors. StarlingMonkey intentionally rejects these configurations even though
ComponentizeJS 0.21 silently accepts them.

## Exact component surfaces

After preview1 adaptation, `starling-feature-surface` resolves the selected WIT
world, generates dummy provider components for imports that must be internal,
and composes those providers into the candidate. Providers are generated from
the installed `feature-wit` closure, so resource identities and interface
versions come from the same WIT definitions as the runtime. Dependencies
between provider interfaces are composed in order rather than leaked back out
as residual imports.

For a caller world without explicit WASI imports, the frozen ComponentizeJS
0.21 surfaces are:

| Selection | Removed from the default feature closure |
|---|---|
| `stdio=false` | stdin, stdout, all terminal interfaces, and filesystem adapter residuals; stderr remains |
| `random=false` | `wasi:random/random` |
| `clocks=false` | monotonic clock; wall clock remains |
| `http=false` | outgoing handler; HTTP types remain while fetch-event is enabled |
| `fetch-event=false` | no import change |
| `http=false`, `fetch-event=false` | outgoing handler and HTTP types |
| only `fetch-event` enabled | HTTP types plus their `wasi:io/error`, `poll`, and `streams` resource identities |
| all disabled | every `wasi:*` import |

The executable oracle is
`tests/feature-selection/reference/expected/import-surfaces.json`.
The runtime matrix and native componentizer E2E tests compare complete sorted
import and export lists from real production components against that file.
The native E2E runs `starling-componentize`, installed `componentize.sh`, and
the external-engine path for all ten supported feature selections.

User-declared non-feature imports remain external. Runtime-only filesystem,
socket, environment, and exit imports are internalized when they are not part
of a specialized caller world. The componentizers explicitly mark Wizer
outputs as snapshotted; an output-only `componentize.sh -o starling.wasm`
instead preserves external CLI arguments/environment for runtime evaluation.
A legacy build without `-Dcomponent-wit` keeps
its fixed export world; consequently its historical
`wasi:http/incoming-handler` export remains, even in pure mode, while pure mode
still has zero WASI imports. Export topology for a caller-supplied world is
controlled by that world and matches the oracle.

## Disabled behavior

Surface removal does not silently route disabled operations to the host:

- `stdio`: preview1 writes are successful no-ops.
- `random`: `crypto.getRandomValues` uses a deterministic splitmix64 stream.
- `clocks`: timer registration throws a catchable `FeatureDisabled`
  `TypeError`, including internal users such as `AbortSignal.timeout`;
  scheduler immediate stream tasks use a distinct internal handle and no
  longer retain the monotonic-clock import.
- `http`: outgoing requests fail through the existing catchable fetch error
  path without calling the outgoing handler.
- `fetch-event`: `addEventListener("fetch", ...)` throws a catchable
  `FeatureDisabled` `TypeError`.

Provider functions are trap stubs and are only a final structural backstop.
The feature-specific C/C++ paths stop disabled operations before a provider is
called. In pure mode no host diagnostic stream exists, so an unexpected
provider call is necessarily trap-only.

## Componentizers and packaging

Both production paths apply the same provider policy:

- installed `componentize.sh`;
- native `starling-componentize`.

The build installs `starling-feature-surface` and `feature-wit` beside the
runtime, adapter, WABT, and wasm-tools. The shell pipeline invokes the helper
after component creation. The native pipeline calls the same Zig module
directly and records generated provider WIT/components in `--debug-bindings`
output.

The selected preview1 adapter remains unchanged. Internal preview1 stubs remove
feature syscalls before adaptation; generated preview2 provider adapters remove
the remaining component-level closure after snapshotting. Default builds with
no caller WIT and all features enabled are copied through unchanged.

`fetch-event` depends on incoming HTTP types, which in turn share
identity-bearing `wasi:io` resources. Those dependencies remain external as a
closure even when stdio, clocks, and outgoing HTTP are disabled; value aliases
such as monotonic `duration` can still be internalized.

Legacy `CMake WEVAL=ON` is rejected before configuration can create build or
release artifacts. Sealed AOT engines and their cache/manifest pair are built
only by the dedicated Zig AOT path. Non-AOT CMake installations remain
relocatable componentizer packages and never contain an unsealed Weval cache.

## Tests

Fast tests:

```sh
zig build feature-selection-test -Doptimize=ReleaseSmall
```

This runs:

- 16 build-option positive/negative cases;
- 8 C/C++ default-macro cases;
- exact frozen surface checks for defaults, every oracle disable case,
  fetch-event dependency minima, and pure mode.

Full runtime tests:

```sh
zig build feature-selection-runtime-test -Doptimize=ReleaseSmall
```

The required all-host production gate runs both build systems (WASI
0.2.0/0.2.2/0.2.3/0.2.10) plus the custom-host fixture:

```sh
zig build host-api-production-matrix-test -Doptimize=ReleaseSmall
```

The two halves can be selected as
`host-api-zig-production-matrix-test` and
`host-api-cmake-production-matrix-test`.

For CMake custom host APIs, set `HOST_API_WORLD` when the root world is not
`bindings`. The built-in WASI exact-surface oracle is skipped explicitly for
custom APIs while the production component is still validated. A custom exact
oracle requires all four cache variables:
`CUSTOM_FEATURE_SURFACE_ORACLE`, `CUSTOM_FEATURE_SURFACE_CASE`,
`CUSTOM_HOST_API_VERSION`, and
`CUSTOM_FEATURE_SURFACE_EXPECTED_EXPORTS`.

For Zig custom host APIs, `-Dhost-api-world` is embedded in
`starling-componentize`, forwarded to its nested runtime builds, and included
in their cache identity and engine provenance.

The runtime matrix builds all ten production combinations, componentizes
real JavaScript, validates resulting components, checks exact disabled
interface absence (including zero-import pure mode), and exercises
representative enabled and disabled behavior through Wasmtime.

The opt-in reference probe under `tests/feature-selection/reference/` still
runs the real pinned ComponentizeJS package and fails if its checked-in surface
oracle drifts. Node.js is never used by production or normal tests.
