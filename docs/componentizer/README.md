# Native componentizer

`starling-componentize` is a host-native Zig CLI for the current monolithic
StarlingMonkey componentization pipeline. It does not use Node.js and does not
depend on the experimental reusable-engine/thin-shell work.

The CLI performs these stages with structured process arguments (never a shell
command string):

1. Select and cache a WIT-specific `zig build` of `starling-raw.wasm`.
2. Pre-initialize the JavaScript module with Wizer.
3. Strip and embed the selected component world with WABT.
4. Adapt the reactor into a component.
5. Validate the candidate with `wasm-tools`.
6. `fsync` and atomically rename the candidate over the requested output.

Any failure before the final rename leaves an existing output unchanged. The
temporary transaction directory is created beside the output so publication
cannot cross filesystems.

## Building

```console
zig build -Doptimize=ReleaseSmall
zig-out/bin/starling-componentize --version
zig build componentizer-test -Doptimize=ReleaseSmall
```

The default install places the CLI beside `wasmtime`, `wasm-tools`,
`wabt`, `preview1-adapter.wasm`, and `starling-raw.wasm`. The bundled WABT
contains the reactor adapter and typed-export fixes required by this pipeline.
The componentizer test target is the required gate: it runs unit and fake-tool
coverage plus real WABT/Wizer relinks for two distinct WIT worlds.

## Per-run WIT worlds

The monolithic runtime needs two related WIT views:

- `--wit` / `--world-name` selects the world used to generate JavaScript
  dispatch bindings.
- `--component-wit` / `--component-world-name` selects the complete world
  embedded into the core module. It must include StarlingMonkey's WASI
  imports/exports as well as the user exports.

They may point to the same directory/world only when that world already
contains the complete component closure. For the repository's standard
`starling:js/api` bridge:

```console
zig-out/bin/starling-componentize \
  --wit host-apis/wasi-0.2.10/wit/deps/starling-js \
  --world-name js-exports \
  --component-wit host-apis/wasi-0.2.10/wit \
  --component-world-name js-dispatch \
  --out app.wasm \
  app.js
```

WIT files are content-hashed and staged under the build root. Runtime prefixes
are keyed by the two WIT closures, worlds, feature selection, and build mode.
The CLI still invokes `zig build` on every run so source/toolchain changes
cannot reuse stale output; Zig's own dependency cache makes an unchanged
monolithic relink a fast cache hit. JavaScript source is deliberately excluded
from the runtime key. Per-input and per-runtime advisory locks make concurrent
uses of one cache safe, and the runtime lock remains held until componentization
has finished consuming the cached engine, adapter, and generated bindings.

Use `--engine` only with a `starling-raw.wasm` already built for the exact WIT
and feature selection. Build-changing feature/debug options are rejected with
that override.

## Runtime and tool options

`--runtime-args` accepts the existing raw StarlingMonkey configuration string.
Prefer repeatable `--runtime-arg` for a single argument, because the CLI safely
quotes representable values without shell parsing. The runtime's existing
string parser cannot represent empty values, quotes, control whitespace, or a
quoted value ending in a backslash; the CLI rejects those values instead of
silently changing them. Existing convenience flags are also available:
initializer script, path-prefix stripping, legacy-script mode, WPT mode,
initial location, and the JavaScript heap limit.

The componentization subprocess removes an ambient `STARLINGMONKEY_CONFIG`;
all snapshot-affecting runtime configuration must be supplied explicitly to
the CLI. Other environment variables remain available to the initialized
module, matching the existing pipeline.

Tool precedence is command-line override, environment override, executable
sibling, then `PATH`. The principal overrides are `--zig-bin`,
`--wasmtime-bin`/`--wizer-bin`, `--wabt-bin`, `--wasm-tools-bin`, and
`--preview2-adapter`. `--wasmtime-bin` selects Wasmtime's `wizer` subcommand;
`--wizer-bin` selects a standalone Wizer and uses its native
`--allow-wasi`/`--inherit-env`/`--wasm-bulk-memory` options.

`--debug-bindings` preserves runtime arguments, generated bindings (when the
CLI builds the runtime), and each pipeline intermediate in `<output>.debug`.
`--debug-dir` chooses another directory. Debug files are replaced by name but
the CLI never recursively deletes a user-provided directory. A debug directory
that contains the requested component output is rejected so debug publication
cannot violate output atomicity.

The CLI advertises the frozen ComponentizeJS 0.21 AOT option names but rejects
them explicitly. Weval execution and cache controls belong to the separate
`aot-engine` milestone; silently falling back to Wizer would be incorrect.
