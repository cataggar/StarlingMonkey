# world-shell-integration: a real world-independent engine + thin WIT shells

This is the follow-up to `docs/world-shell-spike.md`. That spike proved, with
toy stand-in modules, that `wasm-tools component link` (Shared-Everything
Dynamic Linking) *can* compose an "engine" and a "shell" module built
separately. This document covers integrating that mechanism with the *real*
StarlingMonkey engine (C++ + SpiderMonkey + OpenSSL + Rust, all now PIC) and
the *real* typed/JSON `js_dispatch` bridge, and pins down -- with runnable
probes, not prose -- exactly why the remaining piece (an *initialized*
JS-engine snapshot reusable across worlds) is structurally blocked with the
currently pinned toolchain.

Reproduce everything below with:

```
unset ZIG_LOCAL_CACHE_DIR
export ZIG_GLOBAL_CACHE_DIR=/path/to/.zig-global-cache
ZIG=/path/to/zig-x86_64-linux-0.17.0-dev.902+7255f3e72/zig \
  docs/world-shell-integration/verify/build-and-verify.sh
```

(requires `deps/openssl-zig`, `deps/sm-obj-zig`, and
`target/wasm32-wasip1/release/librust_staticlib.a` to already exist as PIC
artifacts -- see `deps/build-deps.sh` and the `docs/pic-*/verify` scripts).

## Architecture

- **Engine** (`-Dengine-dylib-experiment=true`): the full StarlingMonkey C++
  runtime + SpiderMonkey + OpenSSL + Rust crates, linked as a `wasm32-wasi
  -dynamic -fPIC` dylib with **no** component/dispatch WIT compiled in at
  all. It exports `cabi_realloc` and the three `js_dispatch` bridge
  functions (`starling_js_dispatch`, `starling_js_dispatch_native`,
  `starling_js_dispatch_native_free`); everything else needed by a shell is
  reached transitively once composed.
- **Shell** (`-Dshell-dylib-experiment=true -Ddispatch-wit=... -Ddispatch-world=...`):
  a thin `wasm32-wasi -dynamic -fPIC` dylib containing *only* the
  `wasip3-bindgen`-generated `component_bindings.zig` for one WIT world, plus
  `wit_types.zig` and `runtime/js_dispatch.zig` (the Zig half of the typed
  bridge). It imports the three dispatch functions from `env` and contains
  none of the engine's C++/SpiderMonkey/OpenSSL/Rust code.
- **Composition**: `wasm-tools component embed --world <world> <wit-dir>
  shell.wasm` attaches the WIT world's `component-type` custom section to the
  shell (the engine needs no such section: it exports plain functions, not a
  WIT world), then `wasm-tools component link engine=... shell=... --adapt
  wasi_snapshot_preview1=...` merges both PIC dylibs plus a synthesized
  memory/table owner into one component, resolving the shell's dispatch
  imports against the engine's exports.

## What is proven, with exact evidence

All of the following are exercised by
`docs/world-shell-integration/verify/build-and-verify.sh` (~19s to run
warm-cached end-to-end) and were independently verified during this session:

1. **Gate #1 -- world-independent engine artifact.** The real engine builds
   as a valid `wasm32-wasi -dynamic -fPIC` dylib (`dylink.0` section present,
   `wasm-tools validate` passes), with **no** component/dispatch WIT compiled
   in. This closes the exact blocker the original spike hit (17253 link
   errors from non-PIC OpenSSL/Rust archives); those are now real PIC
   archives (see `docs/pic-rust/`, `deps/verify-openssl-pic.sh`,
   `docs/pic-spidermonkey/`).
   - The engine dylib does **not** naturally export the three dispatch
     bridge functions: in the monolithic build they stay alive because
     `runtime/js_dispatch.zig`'s `extern fn` declarations are real call
     sites; in a standalone engine dylib with no Zig caller in-module,
     wasm-ld's DCE removes them despite default visibility. Fixed via a new
     `STARLING_ENGINE_EXPORT` (`__attribute__((used, visibility("default"))))`)
     macro applied to their declarations in `runtime/js_dispatch.h` -- additive
     and safe for the monolithic build (visibility was already default,
     `used` only prevents DCE).
2. **Gate #3 -- two distinct thin shells, no engine rebuild.** Two shells are
   built from two distinct WIT worlds (`host-apis/wasi-0.2.10/wit/deps/starling-js`,
   the real full `js-exports` world with JSON + typed/BigInt functions; and
   `.../starling-js-v2`, a fixture world with one extra `subtract` function,
   renamed to package `starling:js-v2` this session -- see "Fixes made along
   the way" below). Each shell rebuild + WIT re-embed + recompose against the
   *same* engine artifact takes **~0.26-0.33s warm**, vs. the original
   ~31.2s warm WIT-change baseline recorded in `docs/world-shell-spike.md`
   (**~95-120x faster**). The engine's sha256 is verified byte-identical
   before and after switching worlds.
3. **Gate #4 (partial) -- composition + invocation mechanics.** Both
   `engine + shellA` and `engine + shellB` compose into valid components
   (`wasm-tools validate` passes) whose WIT world correctly reflects the
   shell's own world (confirmed via `wasm-tools component wit`: shell A
   exports `starling:js/api` with `add`/`greet`/`big-add`/... ; shell B
   exports `starling:js-v2/api` with the extra `subtract`). Invoking
   `add(5, 7)` through `wasmtime run --invoke` on the *uninitialized*
   composed component runs the full call chain end-to-end -- WASI is
   satisfied, the shell's export wrapper runs, it calls into the engine's
   `starling_js_dispatch` across the shared linear memory the composition
   synthesized -- and then panics with `"JavaScript export dispatch
   failed"` specifically because no JS module/context was ever
   initialized (`api::Engine::cx()` is null). This is the **expected**
   failure and is itself the proof that the composed wiring (imports,
   exports, shared memory, cross-module calls) is entirely correct; the
   only missing piece is initialization.
4. **Critical initialization problem -- structurally blocked, with three
   independent, exact tool-evidence probes:**
   - `wasmtime wizer <engine>.wasm` &rarr; `Error: imported memories are not
     supported`. Matches `wasmtime wizer --help`'s documented, unconditional
     caveat ("The Wasm module may not import globals, tables, or
     memories"). Every `-dynamic -fPIC` (`-shared`) wasm32-wasi module
     produced by this zig/wasm-ld imports its memory from `env` -- this is
     not a StarlingMonkey-specific quirk.
   - `zig build-lib ... -dynamic -fPIC --export-memory` &rarr; `error:
     exporting memory is incompatible with dynamic linking`. This is the
     key new probe this session: it proves there is **no** flag combination
     with the pinned wasm-ld that produces a `-shared`/`dylink.0`-tagged
     module which *owns* (exports) memory instead of importing it. The
     "libc owns memory, side modules import it" arrangement described in
     the [Shared-Everything Dynamic Linking
     explainer](https://github.com/WebAssembly/component-model/blob/main/design/mvp/examples/SharedEverythingDynamicLinking.md)
     is an idealized illustration; the actual lld/wasm-ld implementation
     unconditionally makes every `-shared` output import memory.
   - `wasm-tools component link engine=<starling-raw.wasm> shell=...` (using
     the existing, already-Wizer-compatible, memory-*owning* monolithic
     build as the "engine") &rarr; `error: failed to encode a component
     from modules: failed to extract linking metadata from engine:
     unsupported export kind for memory: Memory`. `component link` requires
     every input to carry a `dylink.0` section; a plain memory-owning
     module (no `dylink.0`) is rejected outright, so simply swapping in the
     existing Wizer-friendly executable as one of the linked inputs does not
     work either.
   - Composing first and Wizer-ing the resulting *component* afterwards is
     also not viable: `wasmtime wizer <component>.wasm` &rarr; `No exported
     func named 'wizer-initialize' in component` -- Wizer operates only on
     core modules with a plain exported `wizer-initialize` function; a
     Component (even one produced by `component link`) does not expose one
     at the top level.
   - A fourth avenue considered and disproven earlier in this session:
     building the engine *both* as a Wizer-compatible static executable and
     as a PIC dylib from the same (fully shared/cached) compiled object
     files, then grafting the static twin's Wizer snapshot (data segments +
     globals) onto the dylib. `wasm-tools objdump` shows the two final
     *linked* artifacts have materially different code/export layouts
     (static exe: 7 exports / 24159 functions / 1,337,237 bytes data vs. PIC
     dylib: 2711 exports / 32022 functions / 1,528,325 bytes data), because
     wasm-ld's `-shared` mode retains far more code as reachable-from-export
     than the narrow static entry points do. A byte-level graft is not
     safe/valid as-is.

   **Conclusion**: with this exact toolchain (zig 0.17.0-dev.902+7255f3e72's
   bundled lld, `wasm-tools` 1.250.0, `wasmtime` 45.0.0's `wizer`
   subcommand), there is no module shape that is simultaneously (a)
   Wizer-snapshottable (must own/export memory, no imports) and (b) a valid
   `wasm-tools component link` input (must carry `dylink.0`, which this
   `wasm-ld` only emits for memory-*importing* modules). This is a genuine,
   three-way structural incompatibility between the three specified tools,
   not a StarlingMonkey design gap -- see "Smallest next prerequisite" below
   for what would unblock it.

## Fixes made along the way

- **`runtime/js_dispatch.h`**: added `STARLING_ENGINE_EXPORT` and applied it
  to all three dispatch bridge function declarations, so they survive DCE in
  a standalone engine dylib (see gate #1 above). No ABI change.
- **`runtime/js_dispatch.cpp`/`.h`**: added
  `starling_dispatch_result_free(void *ptr)`, an exported wrapper around
  `std::free` for the JSON dispatch path's result buffer. A thin shell has
  no reason to statically link its own copy of wasi-libc just to call
  `free` on a buffer some *other* module's allocator produced -- and doing
  so caused a real, reproducible problem: `wasm-tools component link`
  rejected composing two libc-linked side modules with `error: duplicate
  export name '__wasilibc_find_relpath_alloc' already defined` (wasm-ld's
  `-shared` mode auto-exports every default-visibility symbol pulled in from
  a statically-linked archive, including internal wasi-libc helpers, and
  `component link`'s merge step cannot have the same export name defined
  twice across inputs). The shell no longer links libc at all; the engine's
  copy remains the sole allocator for buffers crossing the dispatch
  boundary.
- **`runtime/js_dispatch.zig`**: switched the bridge's internal scratch
  arenas from `std.heap.c_allocator` to `std.heap.wasm_allocator` (a
  freestanding, libc-independent allocator already in Zig's stdlib), and
  the JSON result free call now goes through `starling_dispatch_result_free`
  instead of a raw `extern fn free`. Purely an internal
  implementation-detail change; the bridge's wire ABI
  (`StarlingJSDispatchResult`, `StarlingJsValue`, function signatures) is
  unchanged.
- **`host-apis/wasi-0.2.10/wit/deps/starling-js-v2/package.wit`**: renamed
  `package starling:js` to `package starling:js-v2`. The original
  world-shell-link spike placed this fixture (identical to `../starling-js`
  plus one extra function) alongside the real world under the same shared
  `wit/deps` tree; keeping an identical package name there broke `zig build
  test`'s native-dispatch e2e suite, which resolves the *whole*
  `host-apis/wasi-0.2.10/wit` tree as one WIT package graph
  (`-Dcomponent-wit=host-apis/wasi-0.2.10/wit`): `error: package starling:js
  is defined in two different locations`. Renaming the fixture's package
  removes the collision while keeping it usable standalone for gate #3 (its
  own `-Ddispatch-wit=.../starling-js-v2` build still works unchanged).
- **`build.zig`**: added the `shell-dylib-experiment` opt-in target (thin
  PIC shell: `component_bindings.zig` + `wit_types.zig` + `js_dispatch.zig`
  only, no `addStarlingSources`/prebuilt archives), and removed a stale
  build.zig.zon comment left over from the cherry-picked spike commit (the
  hash-pinning fix it referred to was already present via the zig17 rebase,
  `41a0e0d`; no hash *values* were touched).

## Test suite status (monolithic default, unchanged behavior)

`zig build test -Doptimize=ReleaseSmall` (matching the prebuilt
`--disable-debug` SpiderMonkey artifact): **19/19 build steps succeeded**,
**22/22 e2e+integration tests passed**, and the native-dispatch E2E suite
(`tests/e2e/native-dispatch/run.sh`, covering full-domain i64/u64 boundaries,
nested records, optional some/none, `list<u64>`, wrong-type traps, and
JSON-path regressions) reported `[native-dispatch e2e] all checks passed`.
This confirms the `js_dispatch.h`/`.cpp`/`.zig` changes above are
behaviorally transparent to the existing monolithic path, which remains the
unconditional default (none of the new build options are enabled unless
explicitly requested).

## Smallest next prerequisite (to unblock gate #2 fully)

Any of the following would remove the structural blockage identified above;
none is available in the currently pinned toolchain:

1. A `wasmtime wizer` mode that accepts a module importing memory/table
   from a **caller-supplied** pre-populated memory/table (i.e., wizer
   snapshots the *shared* memory/table region a side module was given,
   rather than requiring the module to own it). This is the most direct
   fix and matches how the shared-everything model conceptually treats
   memory ownership.
2. A `wasm-ld`/lld wasm32 backend change allowing `-shared --export-memory`
   (i.e., letting one participant in the dynamic-linking graph own memory
   while still emitting `dylink.0` so `wasm-tools component link` accepts
   it) -- this is exactly what the Shared-Everything explainer's `libc.wat`
   example assumes, but the current lld implementation forbids it outright.
3. A `wasm-tools component link` mode that accepts a plain (non-`dylink.0`)
   memory-owning module as the designated memory/table provider for the
   other `dylink.0` side modules, rather than requiring every input to
   carry `dylink.0`.
4. A wholly different persistent-snapshot mechanism that does not go through
   Wizer at all -- e.g., a custom tool that runs the existing monolithic
   Wizer-compatible build, snapshots its post-init memory/globals directly
   (bypassing `wasmtime wizer`), and re-emits them as data segments in a
   freshly-linked PIC engine dylib with matching layout. This was explored
   partially this session (the "build both shapes from shared cached
   objects, then graft" idea) and shown non-trivial because the two link
   modes produce different code/export layouts; a from-scratch
   implementation would need to force *matching* layouts between the static
   and dynamic link outputs (e.g. by explicitly `--export`-listing exactly
   the same symbol set for both, together with `--no-gc-sections` or
   equivalent on both sides) before a segment-level graft could be sound --
   untried and unproven, and likely substantial additional work.

Until one of the above exists, the `-Dengine-dylib-experiment=true` /
`-Dshell-dylib-experiment=true` split path proven here should be treated as
validating everything *except* persistent JS-engine initialization: it is a
correct, fast, and low-risk mechanism for reusing one engine binary across
many WIT worlds once initialization is solved, but on its own it cannot
replace the monolithic Wizer-initialized build for real request-serving use
today.
