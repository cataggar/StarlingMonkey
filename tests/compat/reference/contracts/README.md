# ComponentizeJS 0.21 observable-contract probes

This opt-in suite freezes behavior that the ordinary compatibility fixtures
cannot express yet. It runs only against the pinned
`@bytecodealliance/componentize-js@0.21.0` reference and records:

- named-interface export namespaces and their build-time validation;
- direct, aggregate, and nested `option<T>` JavaScript shapes;
- 32-, 33-, 64-, and 65-label flags;
- root-function import mapping;
- exported-resource componentization and WIT surface;
- canonical async-function, `future<T>`, and `stream<T>` acceptance;
- the public API/CLI option surface; and
- Wizer/AOT equivalence for a minimal component.

It is deliberately separate from `tests/compat/manifest.json`: that manifest
drives behavior supported by both implementations, while this suite defines
the target contract for work that is still pending.

## Run

From the repository root, after installing the reference dependencies:

```sh
export PATH="$PWD/tests/compat/reference/.node-cache/node-v22.12.0-linux-x64/bin:$PATH"
node tests/compat/reference/contracts/run.mjs \
  --wasm-tools "$PWD/zig-out/bin/wasm-tools" \
  --weval "$PWD/zig-out/bin/weval"
```

The runner builds the existing Wasmtime compatibility invoker, performs every
probe without network access, validates every successful component, and exits
nonzero if normalized output differs from `expected-0.21.0.json`. Use
`--update` only when intentionally rebasing the pinned reference contract.

The platform-feature import surfaces remain in
`tests/feature-selection/reference/expected/import-surfaces.json`; its
`probe.mjs` now compares them automatically and fails on drift.

## Frozen 0.21 findings

| Area | Observable contract |
| --- | --- |
| Interface exports | A named WIT interface requires a same-named JavaScript namespace object; a flat function fails componentization. |
| Options | Direct and aggregate `none` values lift as `undefined`; nested options use `{ tag: "none" }` and `{ tag: "some", val }`. Both `null` and `undefined` lower to `none`. |
| Flags | 32 labels componentize and execute; 33, 64, and 65 labels are rejected by the reference component construction pipeline. |
| Root imports | A root function maps to an ESM default import whose module specifier is the WIT function name. |
| Resources | Imported and exported resources, constructors, statics, methods, borrows, and drops are accepted and represented in the component surface/import manifest. |
| Async | Promise-returning synchronous exports are supported by the ordinary compatibility suite. Canonical async functions, `future<T>`, and `stream<T>` are rejected by 0.21 and are not release-parity requirements. |
| AOT | The advertised Weval path produces the same WIT surface and result as the ordinary Wizer path for the namespace fixture. |
| API/CLI | AOT, feature disabling, runtime arguments, custom tools, debug bindings, and cache controls are exposed. `aotMinStackSizeBytes` is implemented by the CLI/API runtime but omitted from `types.d.ts`. |
