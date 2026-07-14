#!/usr/bin/env node
// Standalone, opt-in reproduction of manifest.json's known_deviations
// "componentizejs-s64-negative-value-defect" (cataggar/StarlingMonkey#6,
// sync-value-parity). Not part of any normal test run and not wired into
// run-reference.mjs's PASS/FAIL counting: a trap here poisons the shared
// Wasmtime component instance for every later call made against the same
// instance (see main.rs's single Store/instance reused across all calls in
// one invocation), which would otherwise cascade-fail every subsequent
// case in a normal fixture batch. Kept as an isolated, minimal, one-call-
// per-instance probe instead.
//
// Usage (from tests/compat/reference, after `npm install`; requires
// Node >= 22.12/20.19, see ../README.md "Using a portable Node"):
//   node known-defects/s64-negative-value/reproduce.mjs
//
// Expected output: id-s64(5) and neg-s64(0) succeed; id-s64(-5) and
// neg-s64(5) (i.e. returning -5) both trap with a bare wasm `unreachable`
// and a guest-stderr "Redirecting call to abort() to mozalloc_abort"
// diagnostic, reproducing the defect against the exact pinned
// @bytecodealliance/componentize-js@0.21.0 (commit
// 12c2b4a25033f65047f8ec5c5fb9e3013bfc4950) release this repository's
// compat harness pins.
import { componentize } from "@bytecodealliance/componentize-js";
import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const INVOKER_BIN = join(HERE, "..", "..", "..", "runtime", "invoker", "target", "release", "compat-invoker");
const CACHE_DIR = join(HERE, ".cache");

const { component } = await componentize({
  sourcePath: join(HERE, "component.js"),
  witPath: join(HERE, "wit"),
  worldName: "js-exports",
});
await mkdir(CACHE_DIR, { recursive: true });
const wasmPath = join(CACHE_DIR, "probe.wasm");
await writeFile(wasmPath, component);

// One call per invocation (i.e. one fresh component instance per call, via
// a fresh compat-invoker process each time): a trap must not affect the
// other calls below, so each is run as an entirely separate process.
async function tryCall(fn, args) {
  const callsPath = join(CACHE_DIR, "probe.calls.json");
  await writeFile(callsPath, JSON.stringify([{ function: fn, args }]));
  try {
    const { stdout } = await execFileAsync(INVOKER_BIN, [wasmPath, callsPath]);
    console.log(`${fn}(${JSON.stringify(args)}) => ${stdout.trim()}`);
  } catch (err) {
    console.log(`${fn}(${JSON.stringify(args)}) => TRAP: ${(err.stderr || err.message).trim()}`);
  }
}

await tryCall("id-s64", [5]);
await tryCall("id-s64", [-5]);
await tryCall("neg-s64", [0]);
await tryCall("neg-s64", [5]);
await tryCall("id-s64", [1000000000000000]);
