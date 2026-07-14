# tests/e2e/wit-imports/wit/deps/

These 7 `wasi-*-0.2.10` subdirectories are plain **copies** (not symlinks) of
the shared `host-apis/wasi-0.2.10/wit/deps/wasi-*-0.2.10` packages.

They must be real copies rather than symlinks because `zig build install`'s
`InstallDir` step does not follow symlinked subdirectories when populating
`<prefix>/bin/component-wit` (confirmed empirically: symlinked WASI dep
directories here were silently omitted from the installed `component-wit`
tree, causing `wabt component embed` to fail with `package 'wasi:cli@0.2.10'
not found`). A real copy is the only reliable option; the WASI 0.2.10
surface here is static/versioned and not expected to change.

`test-wit-imports/` is this fixture's own custom package (`test:wit-imports`)
and is not shared with anything else -- see `package.wit` in that directory
for the imported `host` and exported `api` interfaces this E2E test
exercises.

Do not edit the `wasi-*` copies directly; if the shared WASI 0.2.10 WIT
surface is ever updated, re-copy from `host-apis/wasi-0.2.10/wit/deps/`.
