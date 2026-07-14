#!/usr/bin/env node
// Opt-in reference-mode runner for tests/compat (cataggar/StarlingMonkey#6,
// Phase 0). Not part of the normal build or test suite -- see README.md in
// this directory for setup and requirements (Node >= 22.12, `npm install`
// run manually here first, plus `cargo`/`rustc` for the compat-invoker
// helper described below).
//
// For every non-negative fixture declared in ../manifest.json, this script:
//   1. componentizes fixtures/<id>/component.js against fixtures/<id>/wit
//      using the pinned @bytecodealliance/componentize-js release,
//   2. writes the produced component to .component-cache/<id>.wasm and
//      invokes it with ../runtime/invoker (compat-invoker), a small Rust
//      host built on the official `wasmtime` crate, which instantiates the
//      component once and calls each declared case/sequence against that
//      single instance via the component model's dynamic API (Wasmtime's
//      canonical-ABI value marshalling, not a hand-rolled CLI string
//      parser and not another component transpiler). This keeps the
//      *execution* half of the comparison attributable to Wasmtime + the
//      real componentize-js output, per cataggar/StarlingMonkey#6's
//      requirement that defects observed here be attributable to
//      ComponentizeJS itself rather than to a second adapter's own bugs.
//   3. compares the observed value against manifest.json's result field,
//      reporting PASS/FAIL the same way run-compat-tests.sh does.
//
// For negative fixtures (missing/invalid export), this script instead
// confirms that componentize() itself rejects with the manifest's declared
// reference_class/reference_message_contains -- a componentize-js build-time
// behavior with no wasm execution involved.
//
// Usage (from this directory, after `npm install`):
//   node run-reference.mjs

import { componentize } from "@bytecodealliance/componentize-js";
import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const HERE = dirname(fileURLToPath(import.meta.url));
const COMPAT_DIR = join(HERE, "..");
const CACHE_DIR = join(HERE, ".component-cache");
const INVOKER_DIR = join(COMPAT_DIR, "runtime", "invoker");
const INVOKER_BIN = join(INVOKER_DIR, "target", "release", "compat-invoker");

const manifest = JSON.parse(await readFile(join(COMPAT_DIR, "manifest.json"), "utf8"));

let pass = 0, fail = 0;
const failures = [];

function report(status, label, detail) {
  if (status === "PASS") pass++;
  else { fail++; failures.push(label); }
  console.log(detail ? `${status} ${label} -- ${detail}` : `${status} ${label}`);
}

async function ensureInvokerBuilt() {
  try {
    await execFileAsync("cargo", ["--version"]);
  } catch {
    throw new Error(
      "`cargo` not found on PATH -- required to build tests/compat/runtime/invoker " +
      "(compat-invoker), which this script uses to run componentize-js output through " +
      "Wasmtime. Install a Rust toolchain (https://rustup.rs) to run the reference mode."
    );
  }
  console.log("building compat-invoker (cargo build --release)...");
  await execFileAsync("cargo", ["build", "--release", "--quiet"], { cwd: INVOKER_DIR });
}

async function componentizeFixture(fixture) {
  const sourcePath = join(COMPAT_DIR, fixture.dir, fixture.js_file);
  const witPath = join(COMPAT_DIR, fixture.wit_dir);
  const { component } = await componentize({
    sourcePath,
    witPath,
    worldName: fixture.world,
  });
  return component;
}

function callsFor(fixture) {
  const calls = [];
  for (const c of fixture.cases ?? []) {
    calls.push({ function: c.function, args: c.args, __case: c });
  }
  for (const seq of fixture.sequences ?? []) {
    for (const [index, call] of seq.calls.entries()) {
      calls.push({
        function: seq.function,
        args: call.args,
        __case: { id: `${seq.id}#${index}`, void: false, result: call.result },
      });
    }
  }
  return calls;
}

async function invoke(wasmPath, calls) {
  const callsPath = `${wasmPath}.calls.json`;
  await writeFile(callsPath, JSON.stringify(calls.map(({ function: fn, args }) => ({ function: fn, args }))));
  const { stdout } = await execFileAsync(INVOKER_BIN, [wasmPath, callsPath], { maxBuffer: 64 * 1024 * 1024 });
  return JSON.parse(stdout);
}

await mkdir(CACHE_DIR, { recursive: true });
await ensureInvokerBuilt();

for (const fixture of manifest.fixtures) {
  const label = `reference/${fixture.id}`;

  if (fixture.negative) {
    // Two distinct kinds of "negative" exist across this manifest:
    //   - componentization-time (negative-missing-export, negative-invalid-export):
    //     componentize() itself must reject.
    //   - call-time (promises-rejected, promises-deadlock): the pinned
    //     ComponentizeJS release can synchronously drive a Promise-returning
    //     export to completion, so componentization succeeds; the
    //     rejection/no-progress case must instead surface once the built
    //     component is actually invoked (mirroring tests/compat/runtime/
    //     lib/run_bridge_tests.py's run_negative_fixture). Try
    //     componentizing first and only fall back to call-time trap
    //     comparison if that unexpectedly succeeds, so a componentization-
    //     time regression in the first kind is still caught as before.
    let component;
    try {
      component = await componentizeFixture(fixture);
    } catch (err) {
      const expectClasses = (fixture.cases ?? [])
        .map((c) => c.expect_error?.reference_message_contains)
        .filter(Boolean);
      const message = String((err && err.message) || err);
      const matched = expectClasses.some((needle) => message.includes(needle));
      if (matched) report("PASS", label);
      else report("FAIL", label, `error message did not match any expected substring; got: ${message}`);
      continue;
    }

    const wasmPath = join(CACHE_DIR, `${fixture.id}.wasm`);
    await writeFile(wasmPath, component);
    const calls = callsFor(fixture);
    let results;
    try {
      results = await invoke(wasmPath, calls);
    } catch (err) {
      report("FAIL", label, `compat-invoker failed: ${(err && err.message) || err}`);
      continue;
    }
    const mismatches = [];
    for (const [i, call] of calls.entries()) {
      const c = call.__case;
      const observed = results[i];
      const needle = c.expect_error?.reference_message_contains;
      if (observed.ok) {
        mismatches.push(`${c.id}: expected a call-time trap, call succeeded with ${JSON.stringify(observed.value)}`);
        continue;
      }
      if (needle) {
        const haystack = `${observed.trap}\n${observed.diagnostics ?? ""}`;
        if (!haystack.includes(needle)) {
          mismatches.push(`${c.id}: trap/diagnostics did not contain ${JSON.stringify(needle)}; trap=${JSON.stringify(observed.trap)} diagnostics=${JSON.stringify(observed.diagnostics)}`);
        }
      }
    }
    if (mismatches.length === 0) report("PASS", label);
    else report("FAIL", label, mismatches.join("; "));
    continue;
  }

  let wasmPath;
  try {
    const component = await componentizeFixture(fixture);
    wasmPath = join(CACHE_DIR, `${fixture.id}.wasm`);
    await writeFile(wasmPath, component);
  } catch (err) {
    report("FAIL", label, `componentize failed: ${(err && err.message) || err}`);
    continue;
  }

  const calls = callsFor(fixture);
  let results;
  try {
    results = await invoke(wasmPath, calls);
  } catch (err) {
    report("FAIL", label, `compat-invoker failed: ${(err && err.message) || err}`);
    continue;
  }

  const mismatches = [];
  for (const [i, call] of calls.entries()) {
    const c = call.__case;
    const observed = results[i];
    if (!observed.ok) {
      mismatches.push(`${c.id}: trapped: ${observed.trap}`);
      continue;
    }
    if (c.void) continue;
    const want = "reference_result" in c ? c.reference_result : c.result;
    if (JSON.stringify(observed.value) !== JSON.stringify(want)) {
      mismatches.push(`${c.id}: want ${JSON.stringify(want)}, got ${JSON.stringify(observed.value)}`);
    }
  }

  if (mismatches.length === 0) report("PASS", label);
  else report("FAIL", label, mismatches.join("; "));
}

console.log();
console.log(`== reference summary: ${pass} passed, ${fail} failed ==`);
if (failures.length) {
  console.log("  failed: " + failures.join(", "));
  process.exit(1);
}
