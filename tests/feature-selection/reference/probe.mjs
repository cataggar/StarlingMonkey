// Opt-in reference probe (cataggar/StarlingMonkey#6 Phase 6): runs a trivial
// component through the real, pinned `@bytecodealliance/componentize-js`
// 0.21.0 release with its actual `disableFeatures`/`enableFeatures`
// `componentize()` options, and dumps each resulting component's WASI
// import/export surface (via the same `wasm-tools` binary this repository
// uses elsewhere) so it can be diffed against
// tests/feature-selection/reference/expected/import-surfaces.json.
//
// This is the ComponentizeJS-side half of the comparison documented in
// docs/feature-selection/README.md's "Reference comparison" section; the
// StarlingMonkey-side half is tests/feature-selection/run-runtime-tests.sh.
//
// Never a normal build or test dependency -- see README.md. Requires
// Node >= 22.12 and a `npm install` in this directory first.
//
// Usage: node probe.mjs [path-to-wasm-tools]

import { componentize } from "@bytecodealliance/componentize-js";
import { execFileSync } from "node:child_process";
import { readFile, writeFile, mkdir, rm } from "node:fs/promises";
import path from "node:path";

const HERE = new URL(".", import.meta.url).pathname;
const wasmTools = process.argv[2] || "wasm-tools";

// The exact ComponentizeJS-0.21.0-compatible feature names this repository's
// own build.zig -Ddisable-features/-Denable-features CSV lists accept (see
// docs/feature-selection/README.md "Behavior matrix").
const CASES = {
  "defaults": {},
  "disable-all": { disableFeatures: ["random", "stdio", "clocks", "http", "fetch-event"] },
  "disable-http-only": { disableFeatures: ["http"] },
  "disable-fetch-event-only": { disableFeatures: ["fetch-event"] },
  "disable-random": { disableFeatures: ["random"] },
  "disable-clocks": { disableFeatures: ["clocks"] },
  "disable-stdio": { disableFeatures: ["stdio"] },
  "enable-features-nonempty": { enableFeatures: ["random"] },
  // Deviation probes (see docs/feature-selection/README.md "Known
  // deviations"): ComponentizeJS 0.21.0 does *not* reject these, unlike this
  // repository's build.zig, which @panics deterministically for both.
  "unknown-feature": { disableFeatures: ["bogus-feature"] },
  "enable-and-disable-same": { disableFeatures: ["random"], enableFeatures: ["random"] },
};

function parseWit(text) {
  const imports = [...text.matchAll(/^\s*import ([^;]+);/gm)].map((m) => m[1]);
  const exports = [...text.matchAll(/^\s*export ([^;]+);/gm)].map((m) => m[1]);
  return { imports, exports };
}

function comparable(results) {
  return Object.fromEntries(Object.entries(results).map(([name, result]) => {
    if (!result.ok) {
      return [name, { error: result.error }];
    }
    return [name, {
      imports: [...result.imports].sort(),
      exports: [...result.exports].sort(),
    }];
  }));
}

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, sorted(value[key])]),
    );
  }
  return value;
}

async function main() {
  const results = {};
  const scratch = path.join(HERE, ".scratch");
  await mkdir(scratch, { recursive: true });
  try {
    for (const [name, opts] of Object.entries(CASES)) {
      try {
        const { component } = await componentize({
          sourcePath: `${HERE}component.js`,
          witPath: `${HERE}wit-probe`,
          worldName: "probe",
          ...opts,
        });
        const wasmPath = path.join(scratch, `${name}.wasm`);
        await writeFile(wasmPath, component);
        const wit = execFileSync(wasmTools, ["component", "wit", wasmPath], { encoding: "utf8" });
        results[name] = { ok: true, ...parseWit(wit) };
        console.log(`PASS ${name}: size=${component.length}`);
      } catch (err) {
        results[name] = { ok: false, error: (err && err.message) || String(err) };
        console.log(`ERR  ${name}: ${(err && err.message) || err}`);
      }
    }
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
  await writeFile(`${HERE}actual-import-surfaces.json`, JSON.stringify(results, null, 2) + "\n");
  const expected = JSON.parse(await readFile(`${HERE}expected/import-surfaces.json`, "utf8"));
  const actualComparable = comparable(results);
  const expectedComparable = Object.fromEntries(
    Object.entries(expected).map(([name, result]) => [name, {
      imports: [...result.imports].sort(),
      exports: [...result.exports].sort(),
    }]),
  );
  if (JSON.stringify(sorted(actualComparable)) !== JSON.stringify(sorted(expectedComparable))) {
    console.error(`\nFAIL feature surfaces differ from expected/import-surfaces.json`);
    console.error(`Wrote ${HERE}actual-import-surfaces.json for inspection`);
    process.exitCode = 1;
    return;
  }
  console.log(`\nPASS all feature surfaces match expected/import-surfaces.json`);
}

await main();
