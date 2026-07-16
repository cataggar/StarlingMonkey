# Native componentizer

`starling-componentize` is a host-native Zig CLI for the current monolithic
StarlingMonkey componentization pipeline. It does not use Node.js and does not
depend on the experimental reusable-engine/thin-shell work.

The CLI performs these stages with structured process arguments (never a shell
command string):

1. Select and cache a WIT-specific `zig build` of `starling-raw.wasm`.
2. Pre-initialize the JavaScript module with Wizer.
3. Strip and embed the selected component world with `wasm-tools`.
2. Pre-initialize the JavaScript module with Wizer, or partially evaluate it
   with the explicitly selected Weval AOT pipeline.
3. Strip and embed the selected component world with WABT.
4. Adapt the reactor into a component.
5. Generate and compose feature-surface providers with pinned WABT so
   disabled/runtime-only
   WASI interfaces do not leak into the caller's world while unmatched
   consumer imports continue to bubble through the composed component.
6. Add standard `language=JavaScript` and
   `processed-by=starling-componentize` producers metadata.
7. Validate the completed candidate with `wasm-tools`.
8. `fsync` and transactionally publish the requested outputs.

Any failure before the durable publication commit leaves existing component
and metadata outputs unchanged and never publishes a partial debug directory.
The output parent is selected without pathname canonicalization: `/`, every
existing ancestor, each no-follow symlink inode and descriptor-bound link
text, and the final directory remain retained. Missing directory components
are created one at a time through the retained parent handle and immediately
reopened no-follow. The resulting anchor is transferred into the transaction,
which creates its temporary directory beside the output through that held
handle.
Backup, publication, rollback, and cleanup stay relative to that handle and
check the complete retained chain and recorded no-follow identities.
Metadata and debug parents are independently descriptor-resolved and must
identify that same retained directory. A substituted output, metadata, or
debug ancestor can therefore fail closed but can never redirect publication
or rollback. Persistent per-destination advisory locks,
opened no-follow beneath the held parent and inherited by no child tool,
serialize overlapping bundles. Immediately before the explicit commit point,
the parent, locks, recovery anchors,
component, metadata, and optional debug directory must retain their exact
identities. A mismatch rolls back only exact owned entries and retains
recoverable transaction state rather than touching a replacement. No error is
reported after commit. Backup cleanup then removes only pre-recorded entries;
if that cleanup cannot finish, publication remains successful and the
transaction is retained for recovery instead of attempting a post-commit
rollback. Optional metadata and debug destinations must use that same parent
so publication and
rollback cannot cross filesystems.

An explicit `--cache-dir` uses the same descriptor-rooted resolver. Missing
cache components and every cache child are created relative to retained
directory handles; native children receive only stable handle paths. Cache
verification checks the retained ancestor/symlink/final chain and each
descriptor-relative child identity, so a symlink or ancestor
replace/resolve/restore race performs no writes through the substituted cache.

## Building

```console
zig build -Doptimize=ReleaseSmall
zig-out/bin/starling-componentize --version
zig build componentizer-test -Doptimize=ReleaseSmall
```

The default install places the CLI beside `wasmtime`, `wasm-tools`, `wabt`,
`preview1-adapter.wasm`, and `starling-raw.wasm`.
`starling-feature-surface` and the selected `feature-wit` closure are installed
beside them and shared with the shell componentizer.
The installed preview1 adapter and feature-provider WIT closure match the
selected host API version, so componentization does not mix interface or
resource identities across WASI releases.
The componentizer test target is the required gate: it runs unit and fake-tool
coverage plus real `wasm-tools`/Wizer relinks for two distinct WIT worlds.

## Weval AOT engine and cache

The AOT engine is a separate SpiderMonkey build. It enables forced portable
baseline interpretation, AOT inline caches, and PBL/Weval integration; a
normal `deps/sm-obj-zig` archive is never relabeled as AOT. Build dependencies
and a directly packaged AOT engine with:

```console
./deps/build-deps.sh --all
zig build -Doptimize=ReleaseSmall -Daot-engine=true
```

`--all` builds both standard and AOT SpiderMonkey variants. An AOT Zig build
defaults `-Dwasm-opt` to false, matching the upstream Weval build; explicitly
enabling wasm-opt or selecting a Debug build is rejected. It installs:

- `starling-raw.wasm`, linked against `deps/sm-obj-zig-aot`;
- `starling-ics.wevalcache`, primed by pinned Weval 0.4.1;
- `starling-ics.wevalcache.manifest`, the integrity and compatibility seal;
- `starling-componentize`, `starling-aot-cache`, and the pinned tools.

For a per-WIT production build, select AOT explicitly:

```console
zig-out/bin/starling-componentize \
  --aot \
  --wit host-apis/wasi-0.2.10/wit/deps/starling-js \
  --world-name js-exports \
  --component-wit host-apis/wasi-0.2.10/wit \
  --component-world-name js-dispatch \
  --out app.wasm \
  app.js
```

The componentizer uses a distinct runtime-cache key for Wizer and AOT and
passes `-Daot-engine=true` to the nested Zig build. The generated cache seal
keys the cache schema, explicit AOT engine ABI, exact engine and Weval binary
SHA-256 digests, resolved feature/build/host ABI, dedicated cache-initializer
ABI, and cache-primer digest. A separate cache SHA-256 protects the SQLite
bytes. Before sealing, the cache is rebuilt in deterministic row order with
`created_time` normalized to zero and fixed SQLite storage settings, so clean
primes of the same inputs produce byte-identical packaged databases. WIT
closures, generated
bindings, host APIs, source/toolchain changes, and linked libraries are bound
by the engine digest; WIT/world and feature selections also remain in the
outer runtime key. Sealing first opens Weval's database read-only, runs `integrity_check`, verifies
the exact table/index shape, and requires a nonempty live row for the exact
engine digest in `weval_cache.module_hash`. The canonical database is checked
the same way before publication, and validation repeats those checks. Bytes in
deleted or unrelated rows cannot bind a cache to an engine.

Sealing retains no-follow handles for every input and the initially resolved
output parents. SQLite parsing, hashing, integrity checks, schema checks, and
live-row checks all consume those same handles. Object identity includes the
filesystem/device, inode, and kind; stable reads check ctime and repeat content
digests, so restored mtimes cannot hide in-place mutation. Publication acquires
the sorted set of cache and manifest destination locks, uses private `0700`
transaction directories, and maintains a checksummed two-slot journal with a
durable clean baseline before its first transaction record. The journal records
both old and new inode/content identities and durably advances around each
cache, manifest, rollback, quarantine, and cleanup namespace operation.
`seal`, `validate`, and the
explicit `starling-aot-cache recover` command recover an interrupted
transaction before doing new work. Recovery either restores both exact old
objects or accepts both exact new objects. Rollback exchanges an object into
quarantine before validating it; an unrelated raced replacement is restored
when safe, never deleted, and keeps the journal/backups recoverable until its
owner resolves the conflict. Every affected output and workspace directory is
synced before committed, rolled-back, cleanup, and clean records.

The lock, journal, and empty private transaction directories use hidden
`.starling-aot-seal-*` names beside the cache. They are persistent control
metadata, not package artifacts. Cache and manifest filenames and bytes remain
unchanged and relocatable.

`--aot-cache-dir` selects a read-only cache bundle containing the two
`starling-ics.wevalcache*` files. It also accepts a direct cache-file path,
with the manifest at `<path>.manifest`, for compatibility with callers that
treat ComponentizeJS's `--aot-cache-dir` as a file option. `--engine --aot`
defaults to a bundle beside the engine. `--weval-bin` must identify the exact
binary in the seal. Missing artifacts, malformed manifests, non-SQLite or
checksum-corrupt caches, and engine/tool/feature mismatches all fail before
initialization or output publication; there is no Wizer fallback.
The validated engine, cache, and manifest are copied into a private per-run
snapshot. The Weval snapshot scope is the selected executable's canonical
containing directory and all descendants (at most 4,096 entries, 32 levels,
and 1 GiB of regular-file data). Descriptor-relative, no-follow traversal
copies stable regular files, directories, and relative symlinks; dangling,
absolute, package-escaping, and special-file layouts are rejected. The
selected basename and internal symlink target are retained, so scripts using
`dirname "$0"`, argv[0]-dispatched tools, and `$ORIGIN` sibling libraries see
their original relative layout. Read and execute permissions are preserved
while write bits are removed.

Cache validation hashes the snapshot regular file actually reached by the
selected executable, while execution uses the selected snapshot path. A
content/metadata digest of the complete private package is checked immediately
before and after execution. Thus neither Weval nor its sibling closure is
reopened from the mutable source package after validation, and snapshots are
removed on success or failure.

Executable AOT snapshots are never placed under the output tree. Candidate
roots inside the source package are excluded and every candidate is probed
with an actual private executable before use. If explicit runtime/temp
variables are absent, supported Unix hosts also try the platform default
temporary directory (`/tmp`) before the current directory, so read-only
installations and no-execute output mounts still work.
The required CI gate provisions a real `noexec` tmpfs and fails if it cannot;
local runs explicitly report `SKIP` rather than treating an ordinary
filesystem probe as coverage.

`--aot-min-stack-size` sets Weval's `RUST_MIN_STACK`. The deterministic
default is 8 MiB, and ambient `RUST_MIN_STACK` and `STARLINGMONKEY_CONFIG`
are removed so every snapshot-affecting input is explicit. All subprocess
arguments are structured, including cache, source, output, and preopen paths
containing spaces.

An AOT `componentize.sh` installation delegates to the same native driver.
`WEVAL_CACHE_DIR` and `AOT_MIN_STACK_SIZE` provide shell-entry-point
equivalents for the two controls. `PREOPEN_DIR`, `--output`, positional
output, and output-only runtime componentization retain the legacy wrapper
behavior. CMake rejects `WEVAL=ON` with the Zig AOT build command because its
legacy cache target cannot provide this sealed/validated contract.

Run the focused cache and equivalence coverage with:

```console
zig build componentizer-test -Doptimize=ReleaseSmall
zig build aot-engine-test -Doptimize=ReleaseSmall
```

The first includes shell-sibling, argv[0], real ELF `$ORIGIN`, symlink-selected
executable, immutable-package mutation, noexec output/cwd, missing/stale/corrupt
cache, descriptor/symlink/parent-retarget race, bundle rollback, and concurrent
release-publication coverage. The second builds both real engine variants,
validates both components, primes clean caches in separate directories to
prove byte-for-byte reproducibility, and invokes the same typed JavaScript
exports through Wasmtime to prove Wizer/AOT behavioral equivalence. Its
fixtures and cache/output paths include spaces.

Release packaging must keep the cache and manifest together. The repository's
packaging gate builds through Zig and validates both the engine module and the
sealed SQLite bundle before publication. AOT installation writes every prefix
artifact, including Weval and the sealed bundle, to a build-cache generation;
`starling-aot-cache publish-prefix` copies and validates that complete
generation under the publication lock before atomically exchanging the prefix.
Release packaging uses `publish-bundle` to overlay its three public artifacts
into an equally private complete generation. Both commands use the same
checksummed dual-slot journal and recover abandoned staging, switching,
rollback, and cleanup phases before a new publisher starts. A target-scoped
kernel lock serializes publishers and is automatically released on process
termination; no child process inherits it.
The public package layout remains three ordinary files with the existing
names. Hidden `.starling-aot-publish-*` lock/journal files live beside, rather
than inside, the switched directory:

```console
just builddir=build-aot aot-package release-artifacts
```

For an already assembled bundle, run the same seal validation directly:

```console
build-aot/bin/starling-aot-cache validate \
  --engine release-artifacts/starling-raw-weval.wasm \
  --weval build-aot/bin/weval \
  --cache release-artifacts/starling-ics.wevalcache \
  --manifest release-artifacts/starling-ics.wevalcache.manifest
```

## Per-run WIT worlds

The monolithic runtime needs two related WIT views:

- `--wit` / `--world-name` selects the world used to generate JavaScript
  dispatch bindings.
- `--component-wit` / `--component-world-name` selects the complete world
  embedded into the core module. It must include StarlingMonkey's WASI
  imports/exports as well as the user exports.

Feature surfacing is derived from the `--wit` caller/export world, not the
larger component embedding world. The finished candidate is inspected before
runtime-only WASI imports are composed away.

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
are keyed by the componentizer's embedded host API, the two WIT closures,
worlds, feature selection, and build mode. Every nested build receives that
exact `-Dhost-api`; an installed componentizer cannot silently fall back to a
different adapter/provider identity.
are keyed by the pipeline/engine ABI, two WIT closures, worlds, resolved
feature ABI, and build mode.
The CLI still invokes `zig build` on every run so source/toolchain changes
cannot reuse stale output; Zig's own dependency cache makes an unchanged
monolithic relink a fast cache hit. JavaScript source is deliberately excluded
from the runtime key. Per-input and per-runtime advisory locks make concurrent
uses of one cache safe, and the runtime lock remains held until componentization
has finished consuming the cached engine, adapter, and generated bindings.
The effective default or explicit componentizer cache is canonicalized before
source snapshotting and retained through an opened directory handle. Runtime,
lock, and Zig local/global-cache directories are created and checked no-follow
relative to held ancestors. Zig receives private handle-backed paths for the
runtime prefix and both caches; canonical cache paths remain in diagnostics.
The private prefix and its `bin` directory are held independently, while every
consumed runtime artifact is opened no-follow relative to the held `bin`.
Cache `bin` and artifact symlinks are rejected before and after the build, so
root or descendant replacement cannot redirect writes or reads into a
replacement. Only the exact effective-cache
directory identity is excluded if it is nested inside a snapshotted source
tree.
An explicit `ZIG_GLOBAL_CACHE_DIR` is preserved for nested builds; otherwise
the CLI uses `<cache-dir>/zig-global-cache`. `ZIG_LOCAL_CACHE_DIR` is always
removed.

`--engine` accepts only a `starling-raw.wasm` carrying StarlingMonkey's
integrity-bound embedded engine provenance and a matching sibling
`features.json`. The provenance records the host API, complete five-feature
tuple, component world, and surface world and is bound to the core module by a
SHA-256 digest. The componentizer selects the adapter and WIT closures beside
that engine, so pure/mixed engines and older supported WASI versions retain
their exact surface instead of inheriting the componentizer executable's
defaults. Missing, tampered, or mismatched provenance is rejected before
Wizer runs. Build-changing feature/debug options remain incompatible with an
external engine.

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
subprocess text. Capture is bounded per stream; failed commands retain at most
16 KiB of final stderr and include an explicit truncation marker. Human mode
streams ordinary child stdout and stderr while retaining the same bounded
failure tail. Runtime-build output and verbose arguments are bounded, buffered,
and redact transaction snapshot paths before display; canonical build and cache
paths remain visible.
Filesystem paths must be valid UTF-8. Invalid source, initializer, output, WIT,
tool, or traversed tree paths fail during input diagnostics with
`InvalidUtf8Path`, ensuring every public diagnostic path remains a JSON string.
Component, metadata, and debug destination validation is also input preflight
and therefore reports `SMC1001`/`inputs`; the later metadata and debug phase
codes describe generation, not destination parsing. Engine, adapter, WIT,
tool, Zig executable/library, build-root, and preopen capture also remain in
the input phase. Only execution of the retained native build enters
`runtime_build`.

## Imports and provenance metadata

`--metadata-out <file>` writes componentizer-owned
`starling-componentize-metadata/v2` JSON next to the component; debug import
output remains `starling-componentize-imports/v1`. Schema meanings and
required fields are stable within each version. Its `imports` array uses
ComponentizeJS 0.21's public
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
hashes, engine/adapter hashes, and the exact published component hash. The
optional `build_root_sha256` and ordered `preopen_trees` fields record
domain-separated digests of the exact directory snapshots visible to native
Zig and Wizer. Their order follows the CLI preopen order; they do not expose
host paths.
The
`zig` tool record carries both the executable `sha256` and a domain-separated
`lib_tree_sha256` over the complete snapshotted Zig library tree; both fields
participate unambiguously in `tools_sha256`. Other tool records set
`lib_tree_sha256` to `null`.
Native components also expose `zig-sha256` and `zig-lib-sha256` entries in
their standard WebAssembly `processed-by` producers section, beside the
`starling-componentize` version.
`source_sha256` and `initializer_sha256` remain hashes of the exact entry
files. The `source_tree` and optional `initializer_tree` records add the
normalized relative entry path and a domain-separated digest of every staged
directory, regular file, file byte, and symlink target. An initializer record
states whether it shares the source tree, including nested overlap, so one
snapshot is not ambiguously represented as two independent inputs.
Canonical aggregate hashes cover worlds, features, and tools. It contains no
timestamps, random transaction names, or host paths, so its provenance fields
are deterministic even if an underlying snapshot tool emits byte-distinct
components. Files, complete JavaScript source-directory trees, WIT trees, and
executables are copied to immutable per-run snapshots in controlled transaction
storage before use; hashes are computed while creating those snapshots.
Source and initializer files, their selected source-tree roots, WIT roots,
native build roots, Wizer preopens, and Zig library roots use the same
descriptor-rooted resolver as executable inputs. The resolver retains `/`,
every no-follow ancestor, each symlink inode and its descriptor-bound link
text, and the selected file or directory before any content becomes a
baseline. Tree copying starts from that exact retained directory handle rather
than reopening a canonical pathname. Restored root or ancestor substitution,
including alternating namespace states between selection and copying, fails
with `InputChanged` during `inputs`.

WIT roots are copied descriptor-relative to an immutable intermediate snapshot
while both the retained path chain and complete original tree manifest are
checked. Internal symlinks, escaping, absolute, dangling, or non-regular WIT
entries are rejected. Native builds run with a retained build-root snapshot as
their working directory. The versioned
`tools/componentizer/runtime-build-inputs.txt` inventory limits that snapshot
to the exact runtime-build closure; roots without the inventory are captured
in full, excluding only identity-checked transaction/cache entries. Wizer
preopens are complete descriptor-rooted snapshots mapped to their original
guest paths. Zig version execution occurs only after its executable and
selected library tree have both been retained and snapshotted.
Every selected inventory root has a manifest guard. File symlinks in that
closure are resolved before copying: the root, every target ancestor, and the
target file are opened no-follow and retained, and the target bytes are
independently manifest-guarded. A selected link's direct target is thereby
promoted into the captured closure; targets outside the canonical build root
or reached through another link are rejected. The snapshot reads the retained
file handle. On Linux, both link-text reads use the same retained
`O_PATH|O_NOFOLLOW` symlink descriptor; hosts without an equivalent retained
no-follow symlink handle reject dereferenced build symlinks,
so a replace/restore race cannot inject target bytes even when the target lies
outside the listed subtree (as with generated SpiderMonkey include links).
Escaping or multiply symlinked targets fail closed.
External engines, adapters (explicit, executable-sibling fallback, or retained
build-root), Wizer/Wasmtime, wasm-tools, WABT, and Zig use one input-file
capture primitive during `inputs`. It records each no-follow root, ancestor,
symlink, and file identity while retaining that exact handle chain, binds link
text to the retained no-follow symlink inode, rejects any mismatch before
reading, copies only from the retained file, and verifies the same baseline
afterward. It never independently re-resolves the pathname for a second
baseline. Linux therefore supports safely retained symlinked executables and
adapters; hosts without an equivalent no-follow symlink descriptor reject
them. Restored link or ancestor substitution and alternating namespace states
cannot redirect any child-consumed snapshot. Nested Zig receives the retained
adapter snapshot through `-Dpreview1-adapter`; a missing or byte-different
installed adapter is rejected instead of triggering a post-build fallback.
Once capture begins, disappearance or canonical-identity failure is normalized
to `InputChanged` in the `inputs` phase.
On
Linux, no-follow file and directory handles remain open and children receive
intentional `/proc/self/fd` paths for executables, preopens, engines, WIT, and
pre-created output files. Supported BSD-family hosts use inherited `/dev/fd`
handles; hosts without a retained-handle path fail closed. Handles are
identity-checked immediately around each spawn; publication and cache lock
descriptors remain close-on-exec. Thus a snapshot name can be replaced and
restored without the substituted bytes ever being executed, consumed, or
written. Namespace substitutions that are restored may complete. An
unrestored identity or manifest change, in-place mutation of a retained
object, or monitor overflow fails the active phase with `TransactionChanged`
and publishes nothing. Existing component, metadata, and debug outputs are
restored by identity-checked rollback. This retains
relative sibling and nested-module visibility even for read-only source trees.
Source-tree traversal order, permissions, timestamps, and absolute root
location do not affect tree hashes. Relative symlinks that remain within the
staged tree are preserved and hashed by target; absolute or escaping symlinks
are rejected so a child cannot consume mutable files outside its snapshot.
The current transaction directory and, when nested, the exact effective cache
directory are excluded after no-follow identity verification. Component,
metadata, publication-lock, and generated debug entries are excluded only by
their exact normalized path and current no-follow identity (or exact name while
not yet created). Their parent directories and unrelated debug contents remain
hashed and staged, so modules beside or inside destination directories keep
working. Unrelated names that resemble transaction, output, or cache names
remain ordinary hashed and staged source entries.
Root ctime relaxation is permitted only after Linux inotify positively
observes a root rename. Hosts without that observation compare strict identity
and manifests and fail closed; transaction-owned publication moves remain
explicitly identity-checked before and after rename.
Source and initializer snapshots are mapped to their original logical paths for
Wizer, and the runtime-argument hash covers the exact stable byte stream
supplied to Wizer.
Native bindgen registers every nested `.wit` file as a content-hashed build
input for both relative and absolute WIT roots, in sorted order. Rewriting a WIT
file at the same path therefore invalidates bindgen without relying on a
directory timestamp; spaces and checkout-root relocation do not affect the
generated bindings.
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
For runtime builds, a valid `ZIG_LIB_DIR` takes precedence; standard archive
and installed layouts are resolved next, with stable `zig env` execution as a
fallback. The executable and complete library tree are copied together into
transaction storage, and the build runs only that executable with
`ZIG_LIB_DIR` fixed to the immutable copy. This
supports archive layouts, installed `bin/zig` plus `lib/zig` layouts, symlinked
executables, and paths containing spaces without consulting the original
installation after snapshot validation.
Every top-level and nested build requires exactly Zig
`0.17.0-dev.902+7255f3e72`; `--zig-bin` and `ZIG` overrides are queried from
their retained executable and rejected during input preflight when the version
differs. The broader `build.zig.zon` minimum remains only a package parser
floor.
`--allow-wasi`/`--inherit-env`/`--wasm-bulk-memory` options. Executable
overrides may be absolute paths, relative paths containing a separator, or
bare names resolved through `PATH`. Wizer is resolved only for a non-AOT run
that actually initializes JavaScript; AOT and non-AOT output-only runs ignore
ambient Wizer settings. The AOT runtime-only initializer snapshots no engine,
but resets libc environment state and finalizes the monotonic-clock offset so
runtime `STARLINGMONKEY_CONFIG` and `-e` arguments are observed after resume.

`--debug-bindings` explicitly requests runtime arguments, generated bindings
(when the CLI builds the runtime), imports/provenance JSON, a path-sanitized
command log, and each pipeline intermediate in `<output>.debug`. `--debug-dir`
chooses another directory and also enables the dump. The destination cannot
contain an input or output. Routine reruns transactionally replace only the
known generated files while preserving unrelated files, symlinks, and
directory trees; a directory at a generated filename is rejected rather than
removed recursively. Before publication, the complete old debug directory is
retained as the rollback anchor while unrelated entries are identity-checked
and copied into the staged merge. The complete merged directory is published
only after validation, with rollback on any publication failure.

The AOT option names match the frozen ComponentizeJS 0.21 CLI surface, while
cache sealing and deterministic failure behavior are stricter.
