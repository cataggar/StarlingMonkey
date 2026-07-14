# pic-spidermonkey: building `libspidermonkey.a` as PIC and proving it dynamic-links

Branch: `fix/pic-spidermonkey` (worktree `/work/StarlingMonkey-pic-spidermonkey`).
Todo id: `pic-spidermonkey`.

## 1. Background

`docs/world-shell-spike.md` (branch `spike/world-shell-link`) proved that
`wasm-tools component link` (Shared-Everything Dynamic Linking) can compose a
thin WIT "shell" module with an "engine" module, but that applying this to
the *real* StarlingMonkey engine failed: `deps/openssl-zig/libx32/libcrypto.a`,
`target/wasm32-wasip1/release/librust_staticlib.a`, and
`deps/sm-obj-zig/dist/libspidermonkey.a` were all compiled without `-fPIC`
(the archive had been built for a static executable), so `wasm-ld` rejects
their absolute-address relocations (`R_WASM_MEMORY_ADDR_LEB`/`_SLEB`/`_I32`)
when linking a `-dynamic -fPIC` module (see
`docs/world-shell-spike/engine-pic-fail.excerpt.log`).

This todo closes that gap for SpiderMonkey: make
`deps/sm-obj-zig/dist/libspidermonkey.a` build as PIC, and prove -- by
actually linking real JSAPI symbols into a `wasm32-wasi -dynamic -fPIC`
module, composing it with a shell, and running it end-to-end with
`wasmtime`, not just inspecting relocation records -- that the archive can
now participate in that dynamic-linking convention. (`fix/pic-rust` and
`fix/pic-openssl` are the sibling todos for the other two archives.)

## 2. How `libspidermonkey.a` is built

`deps/build-deps.sh` step 1 ("SpiderMonkey") builds SpiderMonkey's `js`
engine from the `FIREFOX_147_0_4_RELEASE_STARLING` tag
(`bytecodealliance/firefox`) using the pinned Zig toolchain as the C/C++
compiler (`deps/zig-wrappers/zig-cc`/`zig-cxx`/`zig-ar`, thin wrappers around
`zig cc`/`zig c++`/`zig ar`), driven through Mozilla's own build system
(`mach --no-interactive build`) with a generated `mozconfig` targeting
`wasm32-unknown-wasi`. Three tracked WASI patches
(`deps/patches/mozalloc-abort-wasi.patch`,
`memory-fallback-wasi-memalign.patch`, `gc-wasi-aligned-alloc.patch`) adapt a
few WASI-incompatible bits (mozalloc's `abort()` override, `memalign`
declarations, GC chunk alignment). After the build, the script copies
`js/src/build/libjs_static.a` to `dist/libspidermonkey.a` and appends a
fixed list of extra `mozglue`/`mfbt`/`third_party` object files with `zig ar
-q` (matching `SM_OBJ_FILES` in `cmake/spidermonkey.cmake`, the CMake/
wasi-sdk build's equivalent step) -- this combined archive is what
`build.zig` links against.

## 3. The fix: `-fPIC` is already emitted, now verified and guarded

Unlike the Rust bundle (`fix/pic-rust`, which needed an explicit
`-C relocation-model=pic` added because Cargo does not enable PIC for this
target by default), Mozilla's own configure system already adds `-fPIC` to
every C/C++/assembler compile for this target with **zero mozconfig/source
changes required**:

```
# deps/spidermonkey-source/build/moz.configure/flags.configure
check_and_add_asm_flag(
    "-fPIC", when=building_with_gnu_compatible_cc & ~target_is_windows
)
check_and_add_flag("-fPIC", when=building_with_gnu_compatible_cc & ~target_is_windows)
```

`building_with_gnu_compatible_cc` is true for `zig cc`/`zig c++` (clang-based),
and the target is not Windows, so this fires unconditionally for the
wasm32-wasi build -- confirmed directly in a from-scratch build's
`config.log`:

```
checking whether the C compiler supports -fPIC... yes
checking whether the C++ compiler supports -fPIC... yes
```

Because this is silent, automatic, and easy to regress (e.g. a
`zig-wrappers` change that stops looking "gnu-compatible" to moz.configure's
probe, or an unrelated compiler-probe failure), `deps/build-deps.sh` now
**asserts** it right after `mach build` finishes, at the tracked
source-of-truth layer, rather than only discovering a non-PIC archive later
at `wasm-tools component link` time:

```bash
for probe in "checking whether the C compiler supports -fPIC" \
             "checking whether the C++ compiler supports -fPIC"; do
  grep -A1 -F "$probe" "$SM_OBJ/config.log" | grep -q "^INFO: yes$" || {
    echo "ERROR: SpiderMonkey configure did not confirm -fPIC support ..." >&2
    exit 1
  }
done
```

The identical guard is duplicated in
`docs/pic-spidermonkey/verify/build-and-verify.sh`'s own from-scratch build
step (step 1), so the verification script fails loudly and immediately, in
the same way, if it is ever run against a toolchain/config where the
auto-detection stops firing.

## 4. Verification: `docs/pic-spidermonkey/verify/build-and-verify.sh`

Per the task's instruction not to accept relocation-metadata inspection
alone, `docs/pic-spidermonkey/verify/build-and-verify.sh` performs a real,
five-step, reproducible linker verification:

1. **Rebuilds `libspidermonkey.a` from scratch** using the exact
   `deps/build-deps.sh` step-1 logic (clone/patch/mozconfig/`mach build`/
   archive assembly), including the `-fPIC` guard above, so the proof always
   exercises the tracked build path, not a stale artifact. (`SKIP_SM_BUILD=1`
   reuses an already-built archive for fast iteration; the acceptance run
   for this todo used the full from-scratch path.)
2. **Compiles `probe.cpp`** (real JSAPI calls: `JS_Init`, `JS_NewContext`,
   `js::UseInternalJobQueues`, `JS::InitSelfHostedCode`,
   `JS_NewGlobalObject`, `JS::Evaluate`, `JS_DestroyContext`, `JS_ShutDown`
   -- the same sequence `runtime/engine.cpp`'s `init_js()`/
   `create_content_global()` use) and links it together with the fresh
   archive into one `wasm32-wasi -dynamic -fPIC` "engine" module
   (`--export=engine_verify --export=__wasm_call_ctors`). This is the exact
   step that fails with "recompile with -fPIC" errors (see
   `docs/world-shell-spike/engine-pic-fail.excerpt.log`) if the archive
   isn't PIC.
3. **Builds a thin, independent "shell" module** + WIT world
   (`docs/pic-spidermonkey/verify/wit/world.wit`), composes it with the
   engine module via `wasm-tools component embed`/`component link`
   (the adapter is `host-apis/wasi-0.2.0/preview1-adapter-release/
   wasi_snapshot_preview1.wasm`, already tracked in this repo).
4. **Runs the resulting component with `wasmtime run --invoke`.** The call
   chain `shell-call(5, 7)` -> `engine_verify(5, 7)` ->
   `JS_Init`/`JS_NewContext`/`JS_NewGlobalObject`/`JS::Evaluate("(5 + 7)")`/
   `JS_DestroyContext`/`JS_ShutDown` returns `112` (`5 + 7 + 100`; `+100` is
   only added if the parser, bytecode emitter, interpreter and GC all
   round-tripped correctly), proving the composed, PIC-linked archive is not
   just link-clean but functionally correct across the shared-memory module
   boundary.
5. **Inspects the final linked `sm-engine.wasm`** for the concrete,
   load-bearing markers of the Shared-Everything Dynamic Linking convention:
   it imports `env.__memory_base`/`env.__table_base` and several hundred
   `GOT.mem`/`GOT.func` entries -- i.e. archive-derived code/data symbols are
   genuinely routed through runtime-relocated indirection cells, not merely
   "happen to contain no absolute addresses". (An earlier version of this
   step instead grepped every archive member's own pre-link relocation
   records for "absolute-looking" forms; that was removed because it
   produces false positives even on `probe.cpp`'s own known-good `-fPIC`
   compile -- individual `.o` files legitimately mix relocation forms that
   get resolved when objects are combined, regardless of whether the final
   linked module ends up PIC, so metadata/grep at that granularity cannot
   reliably distinguish PIC from non-PIC archives. The real link (steps 2-4)
   plus the final module's own dylink.0/GOT structure (step 5) are the
   trustworthy signal.)

### Reproducing

```
cd /work/StarlingMonkey-pic-spidermonkey
unset ZIG_LOCAL_CACHE_DIR
export ZIG_GLOBAL_CACHE_DIR=/work/StarlingMonkey-pic-spidermonkey/.zig-global-cache
ZIG=/home/g/.local/share/ghr/tools/cataggar/zig/zig-x86_64-linux-0.17.0-dev.902+7255f3e72/zig

ZIG="$ZIG" WASM_TOOLS=wasm-tools WASMTIME=wasmtime \
  docs/pic-spidermonkey/verify/build-and-verify.sh
```

Output ends with:
```
shell-call(5, 7) = 112
...
sm-engine.wasm imports env.__memory_base/env.__table_base and 346 GOT.mem/GOT.func entries
PASS: libspidermonkey.a is PIC and links + runs as a wasm32-wasi dynamic library.
```

(Pass `SKIP_SM_BUILD=1` to reuse an already-built
`deps/sm-obj-zig/dist/libspidermonkey.a` instead of rebuilding it from
scratch, once you've run `deps/build-deps.sh`/the script once without it.)

## 5. Ordinary static build path preserved

- `deps/build-deps.sh`'s only functional change is the new `-fPIC`
  assertion after `mach build` (section 3); the mozconfig, patches, archive
  assembly, and every other build step are unchanged, and `build.zig`/
  `cmake/spidermonkey.cmake` are untouched -- they just reference the
  resulting archive path by name, and PIC object code is a strict superset
  of what a plain, non-relocatable static link needs (`wasm-ld` resolves the
  PIC-style relative relocations to absolute addresses when producing a
  normal executable).
- `deps/sm-obj-zig/`, `deps/mozbuild-state/`, `deps/mozconfig-zig`,
  `deps/openssl-zig/`, `deps/openssl-src/`, `target/` are already gitignored
  (`.gitignore`); no generated build products are committed by this change.

## 6. Caveats / out-of-scope items

- **`libspidermonkey.a` alone has a small set of external dependencies**
  normally supplied by `target/wasm32-wasip1/release/librust_staticlib.a` in
  the real StarlingMonkey build: `install_rust_hooks` and 13
  `encoding_mem_*`/`encoding_*_valid_up_to` functions used by
  `mfbt/Utf8.h`/`js::MozCrash` (confirmed via `llvm-objdump -t`). Rebuilding
  the Rust bundle is `fix/pic-rust`'s scope, not this todo's; `probe.cpp`
  provides narrow stub definitions with the real declared signatures
  (`third_party/rust/encoding_c_mem/include/encoding_rs_mem.h`,
  `crates/rust-hooks/src/lib.rs`) purely so this SpiderMonkey-only
  verification link can complete standalone. None of them are exercised by
  `engine_verify`'s `"(a + b)"` evaluation.
- **A wasi-libc `PAGESIZE`/PIC interaction bug, independent of
  `libspidermonkey.a`.** The pinned Zig toolchain's bundled wasi-libc defines
  `PAGESIZE` (used by `sysconf(_SC_PAGESIZE)`, `getpagesize()`, and
  transitively `js::gc::InitMemorySubsystem()`/`SystemPageSize()`) as
  `(unsigned long)&__wasm_first_page_end`
  (`lib/libc/include/wasm-wasi-musl/__macro_PAGESIZE.h`, for
  `__clang_major__ >= 22`). That identity only holds in a non-relocatable
  *main* module, where segment 0 legitimately starts at absolute address 0.
  In a `-fPIC`/`-dynamic` *side* module, every data symbol's address is
  `__memory_base + offset`, so `&__wasm_first_page_end` evaluates to some
  large, meaningless address instead of `65536` -- confirmed independent of
  SpiderMonkey by reproducing the exact same wrong value with a minimal,
  SpiderMonkey-free `-dynamic -fPIC` module that only calls
  `sysconf(_SC_PAGESIZE)`. Without a workaround this causes
  `js::gc::MapAlignedPages`'s `MOZ_RELEASE_ASSERT(length % pageSize == 0)`
  (`gc/Memory.cpp:565`) to trap during `JSRuntime`/`GCRuntime`/`Nursery`
  init. `probe.cpp` works around this narrowly and reversibly with strong
  `sysconf`/`getpagesize` symbol definitions (probe.o links before libc, so
  libc's own `sysconf.o` is never pulled in) -- this is a toolchain/libc
  finding documented here for visibility, not a change to any tracked
  toolchain source, and is scoped entirely to the verification harness. Any
  real embedder linking `libspidermonkey.a` as a genuine wasm32-wasi PIC
  dylib will need the same accommodation (or an upstream wasi-libc fix)
  until this is fixed at the toolchain level.
- **`JS::InitSelfHostedCode(cx)` and `js::UseInternalJobQueues(cx)` must be
  called once per context, before the first `JS_NewGlobalObject` call**
  (documented in `js/Initialization.h`). This is a general SpiderMonkey API
  requirement, not a PIC-specific one -- confirmed by reproducing the same
  crash in a fully static, non-PIC, non-dynamic direct link of `probe.cpp` +
  `libspidermonkey.a` before these calls were added, matching what
  `runtime/engine.cpp`'s real `init_js()` already does.
- **`zig build-lib -dynamic` does not auto-export `extern "C"` C++
  functions or `__wasm_call_ctors`** -- both need explicit `--export=`
  flags for `wasm-tools component link`'s synthesized init function to find
  and call them (in the order: `__wasm_apply_data_relocs`, engine ctors,
  shell ctors -- confirmed via `wasm-tools print`ing the composed `$__init`
  core module).

## 7. Acceptance gate status: met

| Requirement | Status |
|---|---|
| Read `deps/spidermonkey-source/AGENTS.md`/`CLAUDE.md`; inspect `deps/mozconfig-zig`, `deps/build-deps.sh`, moz configure flags, compiler wrappers before editing | Done -- section 2-3. |
| Add PIC at the tracked source-of-truth layer, not generated objdir files | Done -- `-fPIC` was already emitted by `build/moz.configure/flags.configure` with zero mozconfig changes; `deps/build-deps.sh` now asserts this loudly (section 3), guarding against silent regression. |
| Build the archive from scratch in this worktree; don't reuse the known non-PIC archive as evidence | Done -- `docs/pic-spidermonkey/verify/build-and-verify.sh` step 1 rebuilds from a clean `deps/sm-obj-zig/` via the exact `deps/build-deps.sh` step-1 logic. |
| Use the pinned zig, `ZIG_GLOBAL_CACHE_DIR`, unset `ZIG_LOCAL_CACHE_DIR`, keep objdirs/caches on `/work` | Done -- all `zig`/`zig cc`/`zig c++`/`zig ar` invocations (both the mozbuild wrappers and the verify script's own `zig build-lib` calls) resolve to the pinned 0.17.0-dev.902+7255f3e72 binary; `deps/sm-obj-zig`, `.zig-global-cache/` all live under `/work/StarlingMonkey-pic-spidermonkey`. |
| Reproducible linker verification, real SpiderMonkey symbols, `wasm32-wasi -dynamic -fPIC`, no forbidden absolute relocations, not metadata-only; prefer a whole-engine/PIC probe | Done -- section 4; a real link + `dylink.0`/GOT-import check + full `wasm-tools component link` + `wasmtime run` execution of real `JS_Init`/`JS_NewContext`/`JS_NewGlobalObject`/`JS::Evaluate`/`JS_DestroyContext`/`JS_ShutDown` calls. |
| Preserve ordinary static build path; no committed generated build products | Done -- section 5; `git status` shows only tracked source/doc files added/changed. |
