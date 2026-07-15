<div align="center">
  <h1><code>StarlingMonkey</code></h1>

  <p>
    <strong>A SpiderMonkey-based JS runtime on WebAssembly</strong>
  </p>

<strong>A <a href="https://bytecodealliance.org/">Bytecode Alliance</a> project</strong>

  <p>
    <a href="https://github.com/bytecodealliance/StarlingMonkey/actions?query=workflow%3ACI"><img src="https://github.com/bytecodealliance/StarlingMonkey/workflows/CI/badge.svg" alt="build status" /></a>
    <a href="https://bytecodealliance.zulipchat.com/#narrow/stream/459697-StarlingMonkey"><img src="https://img.shields.io/badge/zulip-join_chat-brightgreen.svg" alt="zulip chat" /></a>
  </p>

  <h3>
    <a href="#quick-start">Building</a>
    <span> | </span>
    <a href="ADOPTERS.md">Adopters</a>
    <span> | </span>
    <a href="https://bytecodealliance.github.io/StarlingMonkey">Documentation</a>
    <span> | </span>
    <a href="https://bytecodealliance.zulipchat.com/#narrow/stream/459697-StarlingMonkey">Chat</a>
  </h3>
</div>

StarlingMonkey is a [SpiderMonkey][spidermonkey] based JS runtime optimized for use in [WebAssembly
Components][wasm-component]. StarlingMonkey's core builtins target WASI 0.2.0 to support a Component
Model based event loop and standards-compliant implementations of key web builtins, including the
fetch API, WHATWG Streams, text encoding, and others. To support tailoring for specific use cases,
it's designed to be highly modular, and can be readily extended with custom builtins and host APIs.

StarlingMonkey is used in production for Fastly's JS Compute platform, and Fermyon's Spin JS SDK.
See the [ADOPTERS](ADOPTERS.md) file for more details.

## Documentation

For comprehensive documentation, visit our [Documentation Site][gh-pages].

## Quick Start

### Requirements

The runtime's build is managed by [cmake][cmake], which also takes care of downloading the build
dependencies. To properly manage the Rust toolchain, the build script expects
[rustup](https://rustup.rs/) to be installed in the system.

### Usage

With sufficiently new versions of `cmake` and `rustup` installed, the build process is as follows:

1. Clone the repo

```console
git clone https://github.com/bytecodealliance/StarlingMonkey
cd StarlingMonkey
```

2. Run the configuration script

For a release configuration, run

```console
cmake -S . -B cmake-build-release -DCMAKE_BUILD_TYPE=Release
```

For a debug configuration, run

```console
cmake -S . -B cmake-build-debug -DCMAKE_BUILD_TYPE=Debug
```

3. Build the runtime

The build system provides two targets for the runtime: `starling-raw.wasm` and `starling.wasm`. The former is a raw WebAssembly core module that can be used to build a WebAssembly Component, while the latter is the final componentized runtime that can be used directly with a WebAssembly Component-aware runtime like [wasmtime](https://wasmtime.dev/).

A key difference is that `starling.wasm` can only be used for runtime-evaluation of JavaScript code,
while `starling-raw.wasm` can be used to build a WebAssembly Component that is specialized for a specific
JavaScript application, and as a result has much faster startup times.

## Building with Zig (experimental)

An alternative build uses [Zig](https://ziglang.org/) 0.17 as the C/C++ toolchain
(`zig cc`/`zig c++` targeting `wasm32-wasi`) instead of wasi-sdk, driven by
`build.zig` rather than CMake. This is experimental and currently Linux/x86_64 only.

Requirements: `zig` 0.17, `rustup` (the toolchain in `rust-toolchain.toml` plus the
`wasm32-wasip1` target), `python3`, a host `clang`/`clang++`, `make`, `curl`, `git`.

```console
# 1. Build the native dependencies (SpiderMonkey from source, OpenSSL, Rust crates)
#    with the Zig toolchain. This clones and compiles SpiderMonkey, so it takes a while.
./deps/build-deps.sh

# 2. Build starling-raw.wasm (+ componentize.sh, adapter and tools in zig-out/bin)
zig build -Doptimize=ReleaseSmall

# 3. Optionally, componentize + validate a smoke test
zig build smoke-test
```

The runtime can then be componentized and served just like the CMake build:

```console
zig-out/bin/componentize.sh path/to/index.js -o index.wasm
zig-out/bin/wasmtime serve -S cli --dir . index.wasm
```

The Zig build also installs `starling-componentize`, a host-native, Node-free
CLI that drives the monolithic Zig/Wizer/WABT pipeline without shell command
construction. It supports per-run WIT/world selection, content-addressed
cached relinking, feature and tool overrides, runtime arguments, debug
intermediates, and atomic output replacement:

```console
zig-out/bin/starling-componentize \
  --wit host-apis/wasi-0.2.10/wit/deps/starling-js \
  --world-name js-exports \
  --component-wit host-apis/wasi-0.2.10/wit \
  --component-world-name js-dispatch \
  --out app.wasm \
  app.js
```

See [`docs/componentizer/README.md`](docs/componentizer/README.md) for the
topology contract, cache behavior, tool precedence, and debug outputs.

To expose synchronous WIT exports implemented by same-named JavaScript module
exports, configure the WIT package and world at build time. The generated Zig
bindings dispatch typed arguments and results through StarlingMonkey, and the
installed `componentize.sh` uses `cataggar/wabt` to embed and wrap that world:

```console
zig build -Doptimize=ReleaseSmall \
  -Dcomponent-wit=host-apis/wasi-0.2.10/wit \
  -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=host-apis/wasi-0.2.10/wit/deps/starling-js \
  -Ddispatch-world=js-exports

zig-out/bin/componentize.sh app.js -o app.wasm
zig-out/bin/wasmtime run -S http --invoke 'add(2, 3)' app.wasm
```

SpiderMonkey's garbage-collected heap has a 1 GiB ceiling by default. This is
only a limit; it does not reserve or commit 1 GiB when the context is created.
Constrained hosts can lower it while componentizing:

```console
zig-out/bin/componentize.sh --js-heap-limit-mib 256 app.js -o app.wasm
```

Runtime-evaluated components can set the same option through their WASI
arguments or `STARLINGMONKEY_CONFIG`. Values must be whole MiB in the range
1–4095.

The JavaScript bridge supports synchronous WIT exports covering every value
shape ComponentizeJS itself supports except resources, streams, and futures:
JSON-representable primitives, exact-precision s64/u64 (as JS `BigInt`, via a
native, non-JSON dispatch path), f32/f64, strings, `char`, `list<u8>` (a
JS `Uint8Array`, kept distinct from a generic `list<T>`), records, options,
tuples, enums, flags, variants, and `result<T, E>` (both nested and as an
export's own top-level return type: the JS implementation returns the `ok`
payload directly and signals `err` by throwing it, matching ComponentizeJS's
own calling convention). A JS implementation may also return a Promise or
thenable: it is pumped to completion using the engine's own job/task queues,
and its fulfilled value is lowered exactly like a directly-returned value. A
rejected Promise is a deterministic call-time trap for a non-result export;
for a top-level `result<T, E>` export, a rejection is instead treated exactly
like a synchronous throw (`Err(reason)` if the reason's JS shape matches `E`,
a trap otherwise) -- and, either way, a Promise that never settles at all
(no progress possible on the job/task queues) always traps deterministically
rather than hanging, never silently becoming `Err(...)`.

See `tests/compat/README.md` for a data-driven manifest and two Node-free test
harness modes tracking this bridge's compatibility with a pinned ComponentizeJS
release (`tests/compat/manifest.json`), including known deviations between
the two and original WIT/JavaScript fixtures for the surface described above:
a fast structural mode, and a slower runtime mode that builds and exercises
the real Zig/WABT bridge and (optionally) the pinned ComponentizeJS reference
itself through Wasmtime.

Notes:
- SpiderMonkey must be built from source with Zig because the upstream prebuilt
  artifacts use a libc++ ABI incompatible with Zig's.
- Three small SpiderMonkey patches (`deps/patches/`) bridge differences between
  Zig's and wasi-sdk's wasi-libc: skipping mozalloc's `abort()` override,
  declaring `memalign`/`valloc` for the memory fallback, and — most importantly —
  giving the GC properly 1 MiB-aligned chunks (Zig's `posix_memalign` caps
  alignment at the 64 KiB page size, which would otherwise corrupt the GC heap).

Run the test suite against the Zig build with:

```console
zig build test
```

This runs the e2e and integration suites (`tests/run-suite.sh`) against the
runtime in `zig-out/bin`, plus the Node-free, structural-only ComponentizeJS
compatibility harness (`tests/compat/run-compat-tests.sh`; see
`tests/compat/README.md`). Run the structural compatibility harness alone,
without needing the wasm build above, with:

```console
zig build compat-test
```

The structural harness above only checks the compatibility manifest,
fixtures, and expected-output files for self-consistency; it does not build
or execute anything through the real Zig/WABT bridge or ComponentizeJS. For
that, run the separate, required/full runtime bridge suite — which builds
the actual WIT dispatch reactor for every fixture, componentizes it with the
real Wizer+WABT pipeline, and invokes it through Wasmtime — with:

```console
zig build compat-bridge-test
```

This is not part of `zig build test`/`compat-test` because a full run takes
on the order of 15-20 minutes and requires a Rust toolchain and `wasm-tools`
in addition to the wasm build's own prerequisites; see
`tests/compat/runtime/README.md` for exact requirements. The opt-in
ComponentizeJS reference mode (`tests/compat/reference/`) is a separate,
Node-only, one-command script not wired into either Zig build step; see
`tests/compat/reference/README.md`.

### WIT interface imports

JavaScript modules can also `import` WIT interfaces and synchronously call
host-provided component imports, through generated reverse canonical-ABI
wrappers -- matching ComponentizeJS 0.21.0 observable behavior. Pass
`--js-imports` (already wired in for `-Dcomponent-wit`/`-Ddispatch-wit`
builds) and any interface the dispatch world *imports* becomes a StarlingMonkey
builtin ES module, keyed by its versioned WIT identifier (e.g.
`import { add } from "test:wit-imports/host@1.2.3";`) — with no user-written
glue required. Arguments and results are converted with the same strict typed
lifting/lowering helpers used for exports (`runtime/js_dispatch.zig`/`.cpp`):
exact s64/u64 BigInt, strings, records, options, lists, and nested values.
Host traps propagate back through the wasm export call as JS exceptions, and
a component instantiated against a linker that doesn't implement a required
import fails deterministically at instantiation time with an actionable
diagnostic (this is enforced by the host, e.g. Wasmtime, not silently
skipped). Root-level function imports are also generated as default ES module
imports and use the same typed bridge. Imported resources are exposed as
provider-qualified JavaScript classes with constructors, prototype methods,
statics, own/borrow parameters and results, atomic ownership transfer, and
deferred canonical drops. Canonical async imports remain unsupported; the WABT
bindgen fork used by this build (`cataggar/wabt`, see `build.zig.zon`'s
`.wasip3` dependency) rejects them with a build-time diagnostic rather than
silently omitting them.

See `tests/e2e/wit-imports/` for the full fixture (a custom
`test:wit-imports/host@1.2.3` interface implemented by a Wasmtime host, and
`test:wit-imports/api@1.2.3` exported back to it) and run its E2E suite,
which builds the fixture, componentizes it, and drives every export/import
call (including repeated calls, exact BigInt arithmetic, nested records,
resource classes and misuse diagnostics, host-trap propagation, and the
missing-import diagnostic) through a
purpose-built Wasmtime 42 host, with:

```console
zig build wit-imports-e2e-test
```

Like `compat-bridge-test`, this is not part of `zig build test` because it
requires a Rust toolchain and takes several minutes; see
`tests/e2e/wit-imports/run.sh` for the exact steps it automates.


## Using StarlingMonkey with dynamically loaded JS code

The following command will build the `starling.wasm` runtime module in the `cmake-build-release`
directory:

```console
# Use cmake-build-debug for the debug build
cmake --build cmake-build-release -t starling --parallel $(nproc)
```

The resulting runtime can be used to load and evaluate JS code dynamically:

```console
wasmtime -S http cmake-build-release/starling.wasm -e "console.log('hello world')"
# or, to load a file:
wasmtime -S http --dir . starling.wasm index.js
```


## Creating a specialized runtime for your JS code

To create a specialized version of the runtime, first build a raw, unspecialized core wasm version of StarlingMonkey:

```console
# Use cmake-build-debug for the debug build
cmake --build cmake-build-release -t starling-raw.wasm --parallel $(nproc)
```

Then, the `starling-raw.wasm` module can be turned into a component specialized for your code with the following command:

```console
cd cmake-build-release
./componentize.sh index.js -o index.wasm
```

This mode currently only supports the creation of HTTP server components, which means that the `index.js` file must register a `fetch` event handler. For example, your `index.js` could contain the following code:

```javascript
addEventListener('fetch', event => {
  event.respondWith(new Response('Hello, world!'));
});
```

Componentizing this code like above allows running it like this:

```console
wasmtime serve -S cli --dir . index.wasm
```

[cmake]: https://cmake.org/
[gh-pages]: https://bytecodealliance.github.io/StarlingMonkey/
[spidermonkey]: https://spidermonkey.dev/
[wasm-component]: https://component-model.bytecodealliance.org/
