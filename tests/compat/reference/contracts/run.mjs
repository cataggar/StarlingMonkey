#!/usr/bin/env node

import { componentize, version } from "@bytecodealliance/componentize-js";
import { execFile } from "node:child_process";
import { access, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../../../..");
const FIXTURES = join(HERE, "fixtures");
const SCRATCH = join(HERE, ".scratch");
const EXPECTED = join(HERE, "expected-0.21.0.json");
const INVOKER_DIR = join(REPO, "tests/compat/runtime/invoker");
const INVOKER = join(INVOKER_DIR, "target/release/compat-invoker");
const DISABLE_ALL = ["stdio", "random", "clocks", "http", "fetch-event"];

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1) return fallback;
  if (!process.argv[index + 1]) throw new Error(`${name} requires a value`);
  return resolve(process.argv[index + 1]);
}

const wasmTools = option(
  "--wasm-tools",
  process.env.WASM_TOOLS || join(REPO, "zig-out/bin/wasm-tools"),
);
const weval = option(
  "--weval",
  process.env.WEVAL || join(REPO, "zig-out/bin/weval"),
);
const update = process.argv.includes("--update");

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, sorted(value[key])]),
    );
  }
  return value;
}

function normalizeError(error, probe) {
  const message = String(error?.message || error);
  const capturedStderr = String(error?.contractStderr || "");
  let category = "componentize-error";
  if (/does not export an? .* interface as expected by the world/i.test(message)) {
    category = "missing-interface-namespace";
  } else if (
    probe === "async-function" &&
    /not yet implemented/i.test(capturedStderr)
  ) {
    category = "canonical-async-function-unsupported";
  } else if (
    probe === "future" &&
    /internal error: entered unreachable code/i.test(capturedStderr)
  ) {
    category = "canonical-future-unsupported";
  } else if (
    probe === "stream" &&
    /internal error: entered unreachable code/i.test(capturedStderr)
  ) {
    category = "canonical-stream-unsupported";
  } else if (probe === "root-import") {
    category = "root-import-componentization-error";
  } else if (probe === "resources") {
    category = "resource-componentization-error";
  } else if (probe === "aot") {
    category = "aot-componentization-error";
  } else if (probe.startsWith("flags-") && /more than 32 flags/i.test(message)) {
    category = "flags-over-32-unsupported";
  }
  return {
    class: error?.constructor?.name || "Error",
    category,
  };
}

function parseSurface(wit) {
  return {
    imports: [...wit.matchAll(/^\s*import ([^;]+);/gm)].map((match) => match[1]).sort(),
    exports: [...wit.matchAll(/^\s*export ([^;]+);/gm)].map((match) => match[1]).sort(),
  };
}

function resourceDeclarations(wit) {
  const names = [
    "resource counter",
    "constructor(",
    "from-double: static func",
    "increment: func",
    "value: func",
    "borrow-value: func",
    "take-value: func",
    "read: func",
  ];
  return wit
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => names.some((name) => line.includes(name)))
    .sort();
}

function interfaceBody(source, name) {
  const declaration = `interface ${name} {`;
  const start = source.indexOf(declaration);
  if (start === -1) throw new Error(`missing ${declaration}`);
  const open = source.indexOf("{", start);
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    if (source[index] === "{") depth++;
    if (source[index] === "}") {
      depth--;
      if (depth === 0) return source.slice(open + 1, index);
    }
  }
  throw new Error(`unterminated ${declaration}`);
}

async function ensureTools() {
  for (const [name, path] of [["wasm-tools", wasmTools], ["weval", weval]]) {
    await access(path).catch(() => {
      throw new Error(`${name} not found at ${path}`);
    });
  }
  const nodeMajor = Number(process.versions.node.split(".")[0]);
  if (nodeMajor < 22) {
    throw new Error(`Node >=22 is required, found ${process.versions.node}`);
  }
  await execFileAsync("cargo", ["build", "--release", "--quiet"], { cwd: INVOKER_DIR });
}

async function withCapturedStderr(operation) {
  const originalWrite = process.stderr.write;
  let captured = "";
  process.stderr.write = (chunk, encoding, callback) => {
    captured += ArrayBuffer.isView(chunk)
      ? Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength).toString()
      : String(chunk);
    const done = typeof encoding === "function" ? encoding : callback;
    if (done) done();
    return true;
  };
  try {
    return await operation();
  } catch (error) {
    error.contractStderr = captured;
    throw error;
  } finally {
    process.stderr.write = originalWrite;
  }
}

async function inspectComponent(name, component) {
  const wasmPath = join(SCRATCH, `${name}.wasm`);
  await writeFile(wasmPath, component);
  await execFileAsync(wasmTools, ["validate", wasmPath]);
  const { stdout } = await execFileAsync(
    wasmTools,
    ["component", "wit", "--no-docs", wasmPath],
    { maxBuffer: 32 * 1024 * 1024 },
  );
  return { wasmPath, surface: parseSurface(stdout), wit: stdout };
}

async function invoke(wasmPath, calls) {
  const callsPath = `${wasmPath}.calls.json`;
  await writeFile(callsPath, JSON.stringify(calls));
  const { stdout } = await execFileAsync(
    INVOKER,
    [wasmPath, callsPath],
    { maxBuffer: 32 * 1024 * 1024 },
  );
  return JSON.parse(stdout);
}

async function componentizeFixture(dir, source = "component.js", options = {}) {
  return componentize({
    sourcePath: join(FIXTURES, dir, source),
    witPath: join(FIXTURES, dir, "wit"),
    worldName: "probe",
    disableFeatures: DISABLE_ALL,
    ...options,
  });
}

function flagsWit(count) {
  const labels = (count) =>
    Array.from({ length: count }, (_, index) => `    flag-a${String(index).padStart(2, "0")},`).join("\n");
  const observation = count === 32 ? `
  record observation {
    set-count: u32,
    first: bool,
    last: bool,
  }` : "";
  const describe = count === 32
    ? "\n  export describe32: func(value: flags32) -> observation;"
    : "";
  return `package contract:flag-contract-${count}@0.1.0;

world probe {
  flags flags${count} {
${labels(count)}
  }
${observation}
  export echo${count}: func(value: flags${count}) -> flags${count};${describe}
}
`;
}

async function componentizeGenerated(name, wit, sourceDir = "async") {
  const dir = join(SCRATCH, name, "wit");
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, "world.wit"), wit);
  return componentize({
    sourcePath: join(FIXTURES, sourceDir, "component.js"),
    witPath: dir,
    worldName: "probe",
    disableFeatures: DISABLE_ALL,
  });
}

async function capture(name, operation) {
  try {
    return await operation();
  } catch (error) {
    if (process.env.CONTRACT_DEBUG) {
      console.error(`--- ${name} ---\n${error?.stack || error}`);
      if (error?.contractStderr) {
        console.error(`--- ${name} stderr ---\n${error.contractStderr}`);
      }
    }
    return { status: "error", error: normalizeError(error, name) };
  }
}

async function namespaceProbe() {
  const positive = await componentizeFixture("namespace");
  const inspected = await inspectComponent("namespace", positive.component);
  const calls = await invoke(inspected.wasmPath, [
    { function: "ping", args: [41] },
  ]);
  const flat = await capture("namespace-flat", async () => {
    await componentizeFixture("namespace", "flat.js");
    return { status: "ok" };
  });
  return {
    positive: {
      status: "ok",
      surface: inspected.surface,
      calls,
    },
    flat,
  };
}

async function optionsProbe() {
  const output = await componentizeFixture("options");
  const inspected = await inspectComponent("options", output.component);
  const calls = await invoke(inspected.wasmPath, [
    { function: "direct-shape", args: [null] },
    {
      function: "aggregate-shapes",
      args: [{ direct: null, items: [null, 7] }],
    },
    {
      function: "nested-shape",
      args: [{ $option: "none" }],
    },
    {
      function: "nested-shape",
      args: [{ $option: "some", value: { $option: "none" } }],
    },
    {
      function: "nested-shape",
      args: [{ $option: "some", value: { $option: "some", value: 7 } }],
    },
    { function: "lower-null", args: [] },
    { function: "lower-undefined", args: [] },
  ]);
  return { status: "ok", surface: inspected.surface, calls };
}

async function flagsProbe() {
  const results = {};
  for (const count of [32, 33, 64, 65]) {
    results[count] = await capture(`flags-${count}`, async () => {
      const output = await componentizeGenerated(
        `flags-${count}`,
        flagsWit(count),
        "flags",
      );
      const inspected = await inspectComponent(`flags-${count}`, output.component);
      const calls = count === 32
        ? await invoke(inspected.wasmPath, [
            { function: "echo32", args: [["flag-a31"]] },
            {
              function: "describe32",
              args: [["flag-a00", "flag-a31"]],
            },
          ])
        : [];
      return { status: "ok", surface: inspected.surface, calls };
    });
  }
  return results;
}

async function rootImportProbe() {
  const output = await componentizeFixture("root-import");
  const inspected = await inspectComponent("root-import", output.component);
  return {
    status: "ok",
    apiImports: output.imports,
    surface: inspected.surface,
  };
}

async function resourcesProbe() {
  const exported = await componentizeFixture("resources");
  const exportedInspected = await inspectComponent("resources", exported.component);
  const imported = await componentizeFixture("imported-resources");
  const importedInspected = await inspectComponent(
    "imported-resources",
    imported.component,
  );
  return {
    status: "ok",
    imported: {
      apiImports: imported.imports,
      surface: importedInspected.surface,
      declarations: resourceDeclarations(importedInspected.wit),
    },
    exported: {
      surface: exportedInspected.surface,
      declarations: resourceDeclarations(exportedInspected.wit),
    },
  };
}

async function unsupportedTypeProbe(name, declaration) {
  const wit = `package contract:probe-${name}@0.1.0;

world probe {
  ${declaration}
}
`;
  return capture(name, async () => {
    const output = await withCapturedStderr(() => componentizeGenerated(name, wit));
    const inspected = await inspectComponent(name, output.component);
    return { status: "ok", surface: inspected.surface };
  });
}

async function cliProbe() {
  const cli = join(
    REPO,
    "tests/compat/reference/node_modules/.bin/componentize-js",
  );
  const [{ stdout: versionOutput }, { stdout: help }, types] = await Promise.all([
    execFileAsync(cli, ["--version"]),
    execFileAsync(cli, ["--help"]),
    readFile(
      join(
        REPO,
        "tests/compat/reference/node_modules/@bytecodealliance/componentize-js/types.d.ts",
      ),
      "utf8",
    ),
  ]);
  const moduleExports = Object.keys(
    await import("@bytecodealliance/componentize-js"),
  ).sort();
  const cliOptions = [
    ...help.matchAll(/^\s+(?:-\w,\s+)?(--[a-z0-9-]+)/gm),
  ].map((match) => match[1]).sort();
  const componentizeOptions = interfaceBody(types, "ComponentizeOptions");
  const apiOptions = [
    ...componentizeOptions.matchAll(/^  ([A-Za-z][A-Za-z0-9]*)\??:/gm),
  ].map((match) => match[1]).sort();
  const debugOptions = [
    ...componentizeOptions.matchAll(/^    ([A-Za-z][A-Za-z0-9]*)\??:/gm),
  ].map((match) => match[1]).sort();
  return {
    status: "ok",
    version: versionOutput.trim(),
    moduleExports,
    cliOptions,
    apiOptions,
    debugOptions,
  };
}

function assertUpdateable(observed) {
  const failures = [];
  const requireStatus = (label, value, status, category) => {
    if (value?.status !== status) {
      failures.push(`${label} must be ${status}`);
    } else if (category && value?.error?.category !== category) {
      failures.push(`${label} must be ${category}`);
    }
  };
  if (observed.componentizejsVersion !== "0.21.0") {
    failures.push("componentizejsVersion must be exactly 0.21.0");
  }
  requireStatus("namespace positive", observed.namespace.positive, "ok");
  requireStatus(
    "namespace flat",
    observed.namespace.flat,
    "error",
    "missing-interface-namespace",
  );
  requireStatus("options", observed.options, "ok");
  requireStatus("flags 32", observed.flags[32], "ok");
  for (const count of [33, 64, 65]) {
    requireStatus(
      `flags ${count}`,
      observed.flags[count],
      "error",
      "flags-over-32-unsupported",
    );
  }
  requireStatus("root import", observed.rootImport, "ok");
  requireStatus("resources", observed.resources, "ok");
  requireStatus(
    "async function",
    observed.asyncFunction,
    "error",
    "canonical-async-function-unsupported",
  );
  requireStatus(
    "future",
    observed.future,
    "error",
    "canonical-future-unsupported",
  );
  requireStatus(
    "stream",
    observed.stream,
    "error",
    "canonical-stream-unsupported",
  );
  requireStatus("CLI", observed.cli, "ok");
  requireStatus("AOT", observed.aot, "ok");
  if (failures.length) {
    throw new Error(`refusing to update contract:\n- ${failures.join("\n- ")}`);
  }
}

async function aotProbe() {
  return capture("aot", async () => {
    const output = await componentizeFixture("namespace", "component.js", {
      enableAot: true,
      wevalBin: weval,
      aotMinStackSizeBytes: 64 * 1024 * 1024,
    });
    const inspected = await inspectComponent("namespace-aot", output.component);
    const calls = await invoke(inspected.wasmPath, [
      { function: "ping", args: [41] },
    ]);
    return { status: "ok", surface: inspected.surface, calls };
  });
}

async function main() {
  await ensureTools();
  await rm(SCRATCH, { recursive: true, force: true });
  await mkdir(SCRATCH, { recursive: true });
  try {
    const observed = {
      contractVersion: 1,
      componentizejsVersion: version,
      tools: {
        node: process.versions.node,
        wasmTools: (await execFileAsync(wasmTools, ["--version"])).stdout.trim(),
        weval: (await execFileAsync(weval, ["--version"])).stdout.trim(),
      },
      namespace: await namespaceProbe(),
      options: await optionsProbe(),
      flags: await flagsProbe(),
      rootImport: await capture("root-import", rootImportProbe),
      resources: await capture("resources", resourcesProbe),
      asyncFunction: await unsupportedTypeProbe(
        "async-function",
        "export make: async func() -> u32;",
      ),
      future: await unsupportedTypeProbe(
        "future",
        "export make: func() -> future<u32>;",
      ),
      stream: await unsupportedTypeProbe(
        "stream",
        "export make: func() -> stream<u32>;",
      ),
      cli: await cliProbe(),
      aot: await aotProbe(),
    };
    const normalized = sorted(observed);
    if (update) {
      assertUpdateable(normalized);
      await writeFile(EXPECTED, JSON.stringify(normalized, null, 2) + "\n");
      console.log(`updated ${relative(REPO, EXPECTED)}`);
      return;
    }
    const expected = sorted(JSON.parse(await readFile(EXPECTED, "utf8")));
    if (JSON.stringify(normalized) !== JSON.stringify(expected)) {
      await writeFile(
        join(SCRATCH, "actual-0.21.0.json"),
        JSON.stringify(normalized, null, 2) + "\n",
      );
      console.error("FAIL ComponentizeJS 0.21 contract drifted");
      console.error(`actual: ${relative(REPO, join(SCRATCH, "actual-0.21.0.json"))}`);
      process.exitCode = 1;
      return;
    }
    console.log("PASS ComponentizeJS 0.21 observable contract");
  } finally {
    if (!process.exitCode) {
      await rm(SCRATCH, { recursive: true, force: true });
    }
  }
}

await main();
