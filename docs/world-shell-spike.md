# world-shell-spike: reducing the cost of WIT/world changes

Spike branch: `spike/world-shell-link` (worktree `/work/StarlingMonkey-world-shell`).
Todo id: `world-shell-spike`.

## 1. Diagnosis: what actually gets expensive on a WIT/world change

`build.zig` builds StarlingMonkey as a single Zig module (`link_mod`, ~line 155)
that is simultaneously:
- the root source file for the generated component bindings
  (`component_bindings.zig`, produced by `wasip3-bindgen` from
  `-Dcomponent-wit`/`-Dcomponent-world`/`-Ddispatch-wit`/`-Ddispatch-world`),
- every StarlingMonkey C++ translation unit (`addStarlingSources`), and
- the prebuilt SpiderMonkey/OpenSSL/Rust static archives (`addObjectFile`),

all linked into one `exe` ("starling-raw"), which then unconditionally goes
through a whole-binary `wasm-opt -O3` pass (see the "Post-build: wasm-opt"
section of `build.zig`).

Changing `-Ddispatch-wit`/`-Ddispatch-world` regenerates
`component_bindings.zig`, which changes the module's root source file,
which invalidates the final link step of `exe` -- and `wasm-opt` runs on
every `zig build`, regardless of what changed, because it processes
`exe.getEmittedBin()` unconditionally.

### Where the time actually goes (measured, warm zig-cache)

Reproduction: force a WIT/world change against an already-built tree by
pointing `-Ddispatch-wit` at a fixture with one extra function
(`host-apis/wasi-0.2.10/wit/deps/starling-js-v2/package.wit`, a copy of
`.../starling-js/package.wit` plus a `subtract` function), so
`component_bindings.zig` regenerates but no C++ source or the prebuilt
archives change.

```
unset ZIG_LOCAL_CACHE_DIR
export ZIG_GLOBAL_CACHE_DIR=/work/StarlingMonkey-world-shell/.zig-global-cache
ZIG=/home/g/.local/share/ghr/tools/cataggar/zig/zig-x86_64-linux-0.17.0-dev.902+7255f3e72/zig

$ZIG build -Doptimize=ReleaseSmall \
  -Dcomponent-wit=host-apis/wasi-0.2.10/wit -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=host-apis/wasi-0.2.10/wit/deps/starling-js-v2 -Ddispatch-world=js-exports \
  --summary all
```

Result (warm cache, only the WIT dir differs from a prior build):

```
Build Summary: 18/18 steps succeeded
install success
+- install generated to starling-raw.wasm success
|  +- wasm-opt (starling-raw.wasm) success 27s        <-- 87% of wall time
|     +- compile exe starling-raw ReleaseSmall wasm32-wasi success 3s   <-- relink only
|        +- run exe wasip3-bindgen (component_bindings.zig) success 23ms
...
real  0m31.2s
```

Key finding: **Zig already caches individual C++ translation-unit
compilation independently of the module's root source file.** Changing
`component_bindings.zig` does *not* force any `.cpp` recompilation -- only
the final link (~3s) and `wasm-opt` (~27-32s) re-run. `wasm-opt`'s
whole-module `-O3` pass over the ~11MB linked `starling-raw.wasm` is the
dominant cost (~87-90%), not compilation or even linking. This contradicts
the part of the original task framing that assumed C++ recompilation was
a major cost; it isn't, on this Zig version.

Artifact sizes: `starling-raw.wasm` (pre-opt) ~11MB;
`deps/sm-obj-zig/dist/libspidermonkey.a` (prebuilt SpiderMonkey) ~435MB
(mostly dead-code-eliminated at link time -- SpiderMonkey itself is never
rebuilt by a WIT change, confirming the task's premise that SpiderMonkey
compilation is not the problem; `wasm-opt` on the *linked* output is).

## 2. Safe, zero-risk improvement shipped in this spike

`build.zig` already has a `-Dwasm-opt` boolean option that disables the
`wasm-opt` step entirely. It was not being used for iteration. Using it
for a WIT/world change:

```
$ZIG build -Doptimize=ReleaseSmall -Dwasm-opt=false \
  -Dcomponent-wit=host-apis/wasi-0.2.10/wit -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=host-apis/wasi-0.2.10/wit/deps/starling-js-v2 -Ddispatch-world=js-exports \
  --summary all
```

```
Build Summary: 17/17 steps succeeded
install success
+- install generated to starling-raw.wasm success
|  +- compile exe starling-raw ReleaseSmall wasm32-wasi success 3s
...
real  0m3.58s
```

**~8.7x faster (31.2s -> 3.58s)** for a WIT/world iteration, using an
existing, already-tested flag -- no `build.zig` restructuring required for
this part. It does **not** fully satisfy the acceptance gate (the final
`exe` is still *relinked*, just cheaply, and this build's `wasm-opt`-free
`.wasm` is not representative of the shipped artifact), so this is
documented as the safe fallback improvement, not the gate itself. Default
build/test behavior (`wasm-opt=true` unless explicitly disabled) is
completely unchanged.

## 3. Proposed architecture: engine/shell split via `wasm-tools component link`

The task's proposed direction -- a reusable, WIT-independent "engine" plus
a thin, WIT-specific "shell", composed rather than relinked -- maps onto
the WebAssembly **Shared-Everything Dynamic Linking** proposal, implemented
today by `wasm-tools component link` (available in the system `wasm-tools`
1.250.0, via `component link`/`component embed` subcommands) plus Zig's
`-dynamic -fPIC` wasm32-wasi backend (which emits `dylink.0`-tagged PIC
dylibs -- confirmed working, with a "not yet stable" warning from LLD but
functionally correct output).

StarlingMonkey's real "world-independent core boundary" already exists:
`runtime/js_dispatch.{h,cpp,zig}` expose a single, generically-typed
function

```
starling_js_dispatch(name_ptr, name_len, args_json_ptr, args_json_len, *result) -> u32
```

WIT-generated bindings (`component_bindings.zig`, per world) merely
translate typed calls into this generic, string-dispatched call. Everything
the engine needs to expose to any world is already funneled through this
one function -- so an engine/shell split does not require an ABI rewrite.

### Proof of concept (executable, not just described)

`docs/world-shell-spike/poc/build-and-run.sh` builds and *runs* two
end-to-end demos with the exact same tool (`wasm-tools component link`)
and linking mode (`zig build-lib -dynamic -fPIC`) that would be used for
the real engine/shell split:

1. **Scalar call + engine-side persistent state**: `engine.zig` exports
   `engine_add`/`engine_counter` with an internal `counter` global;
   `shell.zig` (embedded with a WIT world via `wasm-tools component embed`)
   calls `engine_add` and is composed with `wasm-tools component link`.
   Running `wasmtime run --invoke 'shell-call(5, 7)'` on the linked
   component returns `113` (`5 + 7 + 101`, where `counter` started at 100
   and was incremented once inside `engine_add`) -- proving the shell
   correctly observed the engine's persistent internal state through a
   properly relocated shared memory, despite the two modules being built
   and linked **completely independently**.

2. **Raw pointer+length call** (matching the real `starling_js_dispatch`
   ABI shape): `engine2.zig` exports `engine_echo_upper(ptr, len,
   *out_len) -> [*]const u8`, reading bytes from a caller-supplied pointer
   and returning a pointer into its **own** static buffer; `shell2.zig`
   calls it with a pointer into its **own** local buffer. Running
   `wasmtime run --invoke 'shell-echo()'` returns `72` (ASCII `'H'`),
   proving cross-module raw-pointer dereferencing works correctly in both
   directions (shell's memory read by engine; engine's memory read by
   shell) through the shared linear memory that `component link` sets up.

Run it:
```
cd docs/world-shell-spike/poc
ZIG=/home/g/.local/share/ghr/tools/cataggar/zig/zig-x86_64-linux-0.17.0-dev.902+7255f3e72/zig \
WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
./build-and-run.sh
```
Output ends with `PASS: both demos linked and executed correctly.`

This conclusively demonstrates that `wasm-tools component link` provides
the shared-memory/call-boundary needed for an engine/shell split, for both
plain scalar calls and the raw-pointer ABI shape StarlingMonkey actually
uses. **The composition mechanism itself is not the blocker.**

### An intermediate, naively-tried approach that does NOT work

Before landing on `component link`, `wasm-merge` (binaryen) was tried to
literally concatenate two independently-linked WASI reactor executables.
It fails: each reactor defines its own private `memory`/`table` and its
own `__stack_pointer` global, so merging either collides on export names
(`--skip-export-conflicts` produces an invalid multi-memory/multi-table
module) or, once each side is rebuilt to import a shared memory/table,
still collides on `__stack_pointer` (each stack independently assumes it
owns the full address space). Plain executables are not relocatable;
`wasm-merge` has no relocation/base-offset logic. This is the failure mode
the task anticipated as a possible blocker for the naive approach -- it
*is* real for `wasm-merge`, but is fully solved by using proper PIC dylibs
+ `wasm-tools component link` instead, which does the necessary relocation.

## 4. The actual blocker for applying this to the real engine

Applying the proven split to the real StarlingMonkey build requires
linking `deps/sm-obj-zig/dist/libspidermonkey.a` (prebuilt SpiderMonkey),
`deps/openssl-zig/libx32/libcrypto.a` (prebuilt OpenSSL), and
`target/wasm32-wasip1/release/librust_staticlib.a` (prebuilt Rust crate
bundle) into a PIC (`-fPIC -dynamic`) "engine" module instead of a plain
static executable.

`build.zig` has an opt-in `engine-dylib-experiment` step
(`zig build engine-dylib-experiment -Dengine-dylib-experiment=true`) that
attempts exactly this: it builds all of StarlingMonkey's own C++ sources
(which link fine as PIC -- `-fPIC` is already part of their compile flags)
plus the three prebuilt archives into one `-dynamic -fPIC` Zig library. It
fails:

```
error: wasm-ld: .../libcrypto.a(libcrypto-lib-bn_lib.o): relocation
  R_WASM_MEMORY_ADDR_SLEB cannot be used against symbol `.L.str`;
  recompile with -fPIC
...
error: 17253 compilation errors
```

(excerpt in `docs/world-shell-spike/engine-pic-fail.excerpt.log`; 14471
errors from `libcrypto.a`, 2783 from `librust_staticlib.a` -- wasm-ld's
error accumulation appears to stop before it would reach
`libspidermonkey.a`, so that archive's own PIC-compatibility is not
separately confirmed by this run, but it is built by the same
non-PIC-by-default SpiderMonkey/Zig toolchain family and has no reason to
be PIC-compatible either).

**This is the concrete, structural blocker**: `libcrypto.a` and
`librust_staticlib.a` (and almost certainly `libspidermonkey.a`) were
compiled as ordinary static-executable objects, without `-fPIC`, so they
contain absolute-address relocations (`R_WASM_MEMORY_ADDR_SLEB/LEB`) that
`wasm-ld` correctly refuses to place into a relocatable PIC dylib. Fixing
this requires **rebuilding SpiderMonkey, OpenSSL, and the Rust crate with
`-fPIC`** (a multi-hour SpiderMonkey rebuild at minimum, likely also
requiring upstream build-flag changes in `deps/sm-obj-zig`, out of scope
for this spike per the task's own framing that "SpiderMonkey is already a
prebuilt archive"). Given that constraint, the full engine/shell
composition gate cannot be realized in this spike without also rebuilding
the prebuilt dependencies.

## 5. Acceptance gate status: **not fully met -- marking `world-shell-spike` blocked**

| Gate requirement | Status |
|---|---|
| Changing `--wit`/`--world` must not recompile/relink/re-`wasm-opt` the full engine | **Not met for the real engine** (blocked on non-PIC prebuilt archives, see #4). Proven achievable in isolation with a full working PIC-dylib-composition proof (`docs/world-shell-spike/poc`). |
| Measure cold/warm timings/artifacts, reproducible commands | **Met** -- see #1 (baseline: 31.2s, wasm-opt 27s dominant) and #2 (`-Dwasm-opt=false`: 3.58s, 8.7x faster) with exact commands. |
| Existing default build/test behavior must remain intact | **Met** -- `zig build -Doptimize=ReleaseSmall --summary all` (14/14 steps) and `zig build smoke-test` (17/17 steps) both still succeed unmodified; the engine/shell split and the fast-iteration flag are both opt-in (`-Dengine-dylib-experiment`, `-Dwasm-opt=false`) and do not change default behavior. |
| Design must support a future installed native componentizer with arbitrary WIT/world inputs | **Met at the design level** -- the proof shows `wasm-tools component embed --world <name> <wit-dir> <shell.wasm>` followed by `wasm-tools component link engine=... shell=...` composes correctly for arbitrary WIT worlds without touching the engine, which is exactly the shape a future native componentizer would drive. |

Per the task's own instructions, since full composition cannot yet be
realized for the actual engine (blocked on non-PIC prebuilt dependencies,
not on the composition mechanism), the **largest safe latency improvement**
implemented and proven is `-Dwasm-opt=false` for WIT/world iteration
(8.7x faster warm-cache builds), and the todo is being marked `blocked`
rather than `done`, with this document plus the executable proof-of-concept
as the delivered evidence.

## 6. What would be needed to close the gap

1. Rebuild `deps/sm-obj-zig` (SpiderMonkey), `deps/openssl-zig` (OpenSSL),
   and the Rust crate (`crates/`) targeting wasm32-wasi with `-fPIC`
   (`-relocation-model=pic` equivalents for their respective toolchains).
2. Re-run `zig build engine-dylib-experiment -Dengine-dylib-experiment=true`
   -- if it now succeeds, wire a real (non-experimental) `engine`/`shell`
   split into `build.zig`: an `engine` PIC dylib target independent of any
   `-Dcomponent-wit`/`-Ddispatch-wit` option, and a `shell` PIC dylib
   target containing only `component_bindings.zig` + `js_dispatch.zig` +
   `wit_types.zig`, composed via `wasm-tools component embed` +
   `component link` as a new install path.
3. Re-measure the WIT-change cost on that path; `wasm-opt` would then only
   need to process the small shell dylib (or the engine's wasm-opt output
   could be cached/reused across all worlds), which is the actual target
   speedup this spike set out to prove.

## 7. Reproducing everything in this document

```
cd /work/StarlingMonkey-world-shell
unset ZIG_LOCAL_CACHE_DIR
export ZIG_GLOBAL_CACHE_DIR=/work/StarlingMonkey-world-shell/.zig-global-cache
ZIG=/home/g/.local/share/ghr/tools/cataggar/zig/zig-x86_64-linux-0.17.0-dev.902+7255f3e72/zig

# Default build/test still intact:
$ZIG build -Doptimize=ReleaseSmall --summary all
$ZIG build smoke-test

# Baseline WIT-change cost (dominated by wasm-opt):
$ZIG build -Doptimize=ReleaseSmall \
  -Dcomponent-wit=host-apis/wasi-0.2.10/wit -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=host-apis/wasi-0.2.10/wit/deps/starling-js-v2 -Ddispatch-world=js-exports \
  --summary all

# Safe 8.7x-faster WIT iteration (existing -Dwasm-opt flag):
$ZIG build -Doptimize=ReleaseSmall -Dwasm-opt=false \
  -Dcomponent-wit=host-apis/wasi-0.2.10/wit -Dcomponent-world=js-dispatch \
  -Ddispatch-wit=host-apis/wasi-0.2.10/wit/deps/starling-js-v2 -Ddispatch-world=js-exports \
  --summary all

# Reproduce the exact PIC-linking blocker on the real engine:
$ZIG build engine-dylib-experiment -Dengine-dylib-experiment=true --summary all

# Executable proof that component-link composition itself works:
cd docs/world-shell-spike/poc
ZIG=$ZIG WASM_TOOLS=wasm-tools WASMTIME=wasmtime ./build-and-run.sh
```

## 8. Unrelated prerequisite fixes made in this worktree

Building at all in a fresh worktree/global-cache required two unrelated
fixes, orthogonal to the WIT/world spike itself but necessary to run any
measurement:
- `build.zig.zon`: four dependency hashes (binaryen, wasm-tools, weval,
  wasmtime) no longer matched what their GitHub release URLs currently
  serve (confirmed via repeated `curl`+`sha256sum` and `zig fetch`
  checks -- genuine upstream content drift, not flakiness). Updated to
  the current correct hashes.
- `build.zig`: four hardcoded nested archive-extraction paths (e.g.
  `wasm-tools-1.235.0-x86_64-linux/wasm-tools`) no longer matched the
  current (flat) extracted archive layout; updated to flat paths.
