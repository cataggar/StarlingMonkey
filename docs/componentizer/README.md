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
5. Add standard `language=JavaScript` and
   `processed-by=starling-componentize` producers metadata.
6. Validate the completed candidate with `wasm-tools`.
7. `fsync` and transactionally publish the requested outputs.

Any failure leaves existing component and metadata outputs unchanged and never
publishes a partial debug directory. The temporary transaction directory is
created beside the output; optional metadata and debug destinations must use
that same parent so publication and rollback cannot cross filesystems.

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
that override. Public imports metadata for a WIT-selected run requires the
generated bindings retained by the native runtime build, so `--metadata-out`
with both `--engine` and `--wit` is rejected rather than reporting an
incomplete imports list.

## Diagnostics

Human errors use stable codes and name the failing pipeline phase, for example:

```text
error[SMC4101] embed: wabt component embed did not complete successfully (CommandFailed)
```

Codes are assigned by phase: `SMC0001` arguments, `SMC1001` inputs,
`SMC2001` runtime build, `SMC3001` initialization/export preflight,
`SMC4001` strip, `SMC4101` embed, `SMC4201` adapt, `SMC4301` metadata,
`SMC5001` validation, `SMC6001` debug preparation, and `SMC7001`
publication. Messages include a phase-specific recovery hint and captured tool
details where available.

Pass `--diagnostic-format json` (or `--json-diagnostics`) for deterministic
JSON Lines on stderr. Each object uses schema
`starling-componentize-diagnostic/v1` and contains `severity`, `code`, `phase`,
`message`, `cause`, `detail`, and `hint`, plus typed `command`, `exit_code`,
and `signal` process fields; a successful run emits `SMC0000`. Child output is
captured in this mode, so the diagnostic stream is not mixed with ad hoc
subprocess text.

## Imports and provenance metadata

`--metadata-out <file>` writes `starling-componentize-metadata/v1` JSON next
to the component. Its `imports` array uses ComponentizeJS 0.21's public
`[[specifier, binding], ...]` convention, including default-import records for
world-level functions. The typed `bindings` array adds function arity,
canonical dispatch keys, resource classes, and constructor/method/static
operations without requiring consumers to parse runtime TSV or stderr.
`imports_complete` distinguishes a verified empty list from debug metadata
produced with an external engine whose generated bindings are unavailable.
External engines also report `features` and `features_sha256` as `null`:
feature-selection options are rejected for those engines, so their actual
compiled feature state cannot be asserted authoritatively.

The `provenance` object records the selected dispatch and component worlds,
content hashes of both complete WIT layouts, the resolved feature booleans,
SHA-256 hashes of every invoked tool (including nested runtime-build tools
such as `wasip3-bindgen` and `wasm-opt`), source/initializer/runtime-argument
hashes, engine/adapter hashes, and the exact published component hash.
Canonical aggregate hashes cover worlds, features, and tools. It contains no
timestamps, random transaction names, or host paths, so its provenance fields
are deterministic even if an underlying snapshot tool emits byte-distinct
components. Files, WIT trees, and executables are copied to immutable
per-run snapshots before use; hashes are computed while creating those
snapshots, and every child executes or consumes the corresponding snapshot.
The component itself also receives standard WebAssembly producers metadata
compatible with `wasm-tools metadata show`.

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

`--debug-bindings` explicitly requests runtime arguments, generated bindings
(when the CLI builds the runtime), imports/provenance JSON, a path-sanitized
command log, and each pipeline intermediate in `<output>.debug`. `--debug-dir`
chooses another directory and also enables the dump. The destination cannot
contain an input or output. Routine reruns transactionally replace only the
known generated files while preserving unrelated files, symlinks, and
directory trees; a directory at a generated filename is rejected rather than
removed recursively. The complete merged directory is published only after
validation, with rollback on any publication failure.

The CLI advertises the frozen ComponentizeJS 0.21 AOT option names but rejects
them explicitly. Weval execution and cache controls belong to the separate
`aot-engine` milestone; silently falling back to Wizer would be incorrect.
