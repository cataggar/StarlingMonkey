#!/usr/bin/env node
// Opt-in reference-mode runner for tests/compat (cataggar/StarlingMonkey#6,
// Phase 0). Not part of the normal build or test suite -- see README.md in
// this directory for setup and requirements (Node >= 22.12, `npm install`
// run manually here first).
//
// For every non-negative fixture declared in ../manifest.json, this script:
//   1. componentizes fixtures/<id>/component.js against fixtures/<id>/wit
//      using the pinned @bytecodealliance/componentize-js release,
//   2. transpiles the resulting component with jco so it can be imported
//      directly as a plain JS module (avoiding any CLI string-argument
//      ambiguity -- see manifest.json provenance notes on the u32 CLI
//      quirk that was ruled out this way),
//   3. calls each declared case/sequence and compares the observed value
//      against manifest.json's reference_result (falling back to result)
//      field, reporting PASS/FAIL/SKIP the same way run-compat-tests.sh
//      does.
//
// For negative fixtures (missing/invalid export), this script instead
// confirms that componentize() itself rejects with the manifest's declared
// reference_class/reference_message_contains.
//
// Usage (from this directory, after `npm install`):
//   node run-reference.mjs

import { componentize } from "@bytecodealliance/componentize-js";
import { transpile } from "@bytecodealliance/jco";
import { readFile, rm } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const COMPAT_DIR = join(HERE, "..");

const manifest = JSON.parse(await readFile(join(COMPAT_DIR, "manifest.json"), "utf8"));

let pass = 0, fail = 0, skip = 0;
const failures = [];

function report(status, label, detail) {
  if (status === "PASS") pass++;
  else if (status === "SKIP") skip++;
  else { fail++; failures.push(label); }
  console.log(detail ? `${status} ${label} -- ${detail}` : `${status} ${label}`);
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

async function loadTranspiled(component, name) {
  const workdir = join(HERE, ".jco-out", name);
  await rm(workdir, { recursive: true, force: true });
  const { mkdir, writeFile } = await import("node:fs/promises");
  await mkdir(workdir, { recursive: true });
  const { files } = await transpile(component, { name, noTypescript: true });
  let entry;
  for (const [relPath, contents] of Object.entries(files)) {
    const full = join(workdir, relPath);
    await mkdir(dirname(full), { recursive: true });
    await writeFile(full, contents);
    if (relPath === `${name}.js`) entry = full;
  }
  return await import(pathToFileURL(entry).href);
}

for (const fixture of manifest.fixtures) {
  if (fixture.negative) {
    const label = `reference/${fixture.id}`;
    try {
      await componentizeFixture(fixture);
      report("FAIL", label, "componentize() unexpectedly succeeded for a negative fixture");
    } catch (err) {
      const expectClasses = (fixture.cases ?? []).map((c) => c.expect_error?.reference_message_contains).filter(Boolean);
      const message = String(err && err.message || err);
      const matched = expectClasses.some((needle) => message.includes(needle));
      if (matched) report("PASS", label);
      else report("FAIL", label, `error message did not match any expected substring; got: ${message}`);
    }
    continue;
  }

  const label = `reference/${fixture.id}`;
  let mod;
  try {
    const component = await componentizeFixture(fixture);
    mod = await loadTranspiled(component, fixture.id);
  } catch (err) {
    report("FAIL", label, `componentize/transpile failed: ${err && err.message || err}`);
    continue;
  }

  const mismatches = [];
  for (const c of fixture.cases ?? []) {
    let got;
    try {
      got = await mod[c.function](...c.args);
    } catch (err) {
      mismatches.push(`${c.id}: threw ${err && err.message || err}`);
      continue;
    }
    if (c.void) continue;
    const want = "reference_result" in c ? c.reference_result : c.result;
    const normalizedGot = got === undefined ? null : got;
    if (JSON.stringify(normalizedGot) !== JSON.stringify(want)) {
      mismatches.push(`${c.id}: want ${JSON.stringify(want)}, got ${JSON.stringify(normalizedGot)}`);
    }
  }
  for (const seq of fixture.sequences ?? []) {
    for (const [index, call] of seq.calls.entries()) {
      let got;
      try {
        got = await mod[seq.function](...call.args);
      } catch (err) {
        mismatches.push(`${seq.id}#${index}: threw ${err && err.message || err}`);
        continue;
      }
      if (JSON.stringify(got) !== JSON.stringify(call.result)) {
        mismatches.push(`${seq.id}#${index}: want ${JSON.stringify(call.result)}, got ${JSON.stringify(got)}`);
      }
    }
  }

  if (mismatches.length === 0) report("PASS", label);
  else report("FAIL", label, mismatches.join("; "));
}

console.log();
console.log(`== reference summary: ${pass} passed, ${fail} failed, ${skip} skipped ==`);
if (failures.length) {
  console.log("  failed: " + failures.join(", "));
  process.exit(1);
}
