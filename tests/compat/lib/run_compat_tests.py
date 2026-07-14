#!/usr/bin/env python3
"""Phase 0 compatibility harness (cataggar/StarlingMonkey#6).

Node-free by design (see compat_lib.py). Validates that:

  1. manifest.json is well-formed and every fixture/case it declares is
     backed by real files on disk.
  2. Each fixture's WIT actually parses (via the already-pinned `wasm-tools`
     binary) and declares exactly the exported functions the manifest's
     cases/sequences reference, directly on the named world (see
     known_deviations "interface-export-flattening").
  3. Each fixture's component.js statically defines (or, for the two
     negative fixtures, intentionally omits/misdefines) those exports.
  4. The checked-in tests/compat/expected/<fixture>.json files have not
     drifted out of sync with manifest.json.
  5. (Best-effort, skipped without failing if `node` is not on PATH) the
     plain JavaScript in each fixture actually produces the manifest's
     declared bridge_result/result for each case, using a Node.js
     `import()` of component.js with the exact JSON bridge argument style
     (which is Node-optional local self-consistency checking of the
     fixture authoring, not a differential test against ComponentizeJS or
     the actual Zig/WABT dispatch bridge -- see tests/compat/reference/ for
     the latter, and tests/compat/README.md for what this harness does and
     does not verify).

Exit code is non-zero if any non-best-effort check fails.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compat_lib  # noqa: E402
import json_schema_lite  # noqa: E402

PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"


class Reporter:
    def __init__(self) -> None:
        self.counts = {PASS: 0, FAIL: 0, SKIP: 0}
        self.failures: list[str] = []

    def report(self, status: str, label: str, detail: str = "") -> None:
        self.counts[status] += 1
        line = f"{status} {label}"
        if detail and status != PASS:
            line += f" -- {detail}"
        print(line)
        if status == FAIL:
            self.failures.append(label)

    def summary_and_exit(self) -> None:
        print()
        print(
            f"== summary: {self.counts[PASS]} passed, {self.counts[FAIL]} failed, "
            f"{self.counts[SKIP]} skipped =="
        )
        if self.failures:
            print("  failed: " + ", ".join(self.failures))
            sys.exit(1)
        sys.exit(0)


def check_manifest_schema_shape(manifest: dict, reporter: Reporter) -> None:
    """Actually enforces tests/compat/schema/manifest.schema.json against
    manifest.json, using the stdlib-only draft-07-subset validator in
    lib/json_schema_lite.py (see that module's docstring for why this
    doesn't pull in the `jsonschema` PyPI package). Previously,
    manifest.schema.json's `$schema` reference was purely informational --
    nothing checked manifest.json against it."""
    label = "manifest/schema-valid"
    schema_path = compat_lib.COMPAT_DIR / "schema" / "manifest.schema.json"
    try:
        with open(schema_path, encoding="utf-8") as fh:
            schema = json.load(fh)
        json_schema_lite.validate(manifest, schema)
    except json_schema_lite.UnsupportedKeyword as exc:
        reporter.report(FAIL, label, f"schema uses an unsupported keyword: {exc}")
    except json_schema_lite.SchemaValidationError as exc:
        reporter.report(FAIL, label, str(exc))
    else:
        reporter.report(PASS, label)


def check_expected_files_in_sync(manifest: dict, reporter: Reporter) -> None:
    for fixture in manifest["fixtures"]:
        label = f"expected-in-sync/{fixture['id']}"
        expected_path = compat_lib.COMPAT_DIR / fixture["expected_file"]
        if not expected_path.exists():
            reporter.report(FAIL, label, f"missing {expected_path}")
            continue
        want = compat_lib.expected_doc_for_fixture(fixture)
        with open(expected_path, encoding="utf-8") as fh:
            have = json.load(fh)
        if want != have:
            reporter.report(FAIL, label, "checked-in file does not match manifest.json (run lib/regen_expected.py)")
        else:
            reporter.report(PASS, label)


def declared_function_names(fixture: dict) -> set[str]:
    names: set[str] = set()
    for case in fixture.get("cases", []):
        names.add(case["function"])
    for seq in fixture.get("sequences", []):
        names.add(seq["function"])
    return names


def check_wit_and_js(manifest: dict, reporter: Reporter, wasm_tools: str | None) -> None:
    for fixture in manifest["fixtures"]:
        fid = fixture["id"]
        wit_dir = compat_lib.COMPAT_DIR / fixture["wit_dir"]
        js_path = compat_lib.COMPAT_DIR / fixture["dir"] / fixture["js_file"]

        label = f"wit-parses/{fid}"
        if wasm_tools is None:
            reporter.report(SKIP, label, "wasm-tools not found on PATH; set WASM_TOOLS or install it")
            wit_json = None
        else:
            try:
                wit_json = compat_lib.component_wit_json(wasm_tools, wit_dir)
                reporter.report(PASS, label)
            except subprocess.CalledProcessError as exc:
                reporter.report(FAIL, label, exc.stderr.strip().splitlines()[-1] if exc.stderr else str(exc))
                wit_json = None

        if not js_path.exists():
            reporter.report(FAIL, f"js-file-exists/{fid}", f"missing {js_path}")
            continue
        js_source = js_path.read_text(encoding="utf-8")

        if wit_json is not None:
            label = f"wit-exports-match-manifest/{fid}"
            try:
                wit_functions = compat_lib.world_export_functions(wit_json, fixture["world"])
            except ValueError as exc:
                reporter.report(FAIL, label, str(exc))
                wit_functions = {}
            else:
                manifest_functions = declared_function_names(fixture)
                missing_in_wit = manifest_functions - set(wit_functions)
                if fixture.get("negative"):
                    # Negative fixtures intentionally declare a WIT export
                    # (e.g. "phantom") that component.js does not implement;
                    # the manifest case still references it by name, so we
                    # only require the WIT side to declare it, not the JS.
                    if missing_in_wit:
                        reporter.report(FAIL, label, f"WIT world is missing declared export(s): {missing_in_wit}")
                    else:
                        reporter.report(PASS, label)
                else:
                    if missing_in_wit:
                        reporter.report(FAIL, label, f"WIT world is missing declared export(s): {missing_in_wit}")
                    else:
                        reporter.report(PASS, label)

        if fixture.get("negative"):
            for case in fixture.get("cases", []):
                fn = case["function"]
                if fid == "negative-missing-export":
                    label = f"negative-js-omits-export/{fid}/{fn}"
                    if compat_lib.js_defines_function_export(js_source, fn):
                        reporter.report(FAIL, label, f"'{fn}' unexpectedly defined as a function in {fixture['js_file']}")
                    else:
                        reporter.report(PASS, label)
                elif fid == "negative-invalid-export":
                    label = f"negative-js-nonfunction-export/{fid}/{fn}"
                    if compat_lib.js_defines_function_export(js_source, fn):
                        reporter.report(FAIL, label, f"'{fn}' is defined as a function (expected non-function) in {fixture['js_file']}")
                    elif not compat_lib.js_defines_nonfunction_export(js_source, fn):
                        reporter.report(FAIL, label, f"'{fn}' is not exported at all in {fixture['js_file']}")
                    else:
                        reporter.report(PASS, label)
            continue

        for fn in sorted(declared_function_names(fixture)):
            label = f"js-defines-export/{fid}/{fn}"
            if compat_lib.js_defines_function_export(js_source, fn):
                reporter.report(PASS, label)
            else:
                reporter.report(FAIL, label, f"no 'export function {fn}(' found in {fixture['js_file']}")


NODE_ESCAPE_MAP = {"'": "\\'", "\\": "\\\\"}


def node_available() -> str | None:
    return shutil.which("node")


def node_selfcheck_fixture(node: str, fixture: dict, reporter: Reporter) -> None:
    """Best-effort: actually evaluate the fixture's plain JavaScript with a
    system Node.js (if present) and compare against the manifest's declared
    results. This exercises only the JS semantics directly (no WIT, no
    canonical ABI, no ComponentizeJS, no wasm) -- it catches authoring
    mistakes in the fixture/manifest pair, and is skipped (not failed) when
    Node is unavailable, since this repository does not depend on Node."""
    fid = fixture["id"]
    js_path = compat_lib.COMPAT_DIR / fixture["dir"] / fixture["js_file"]

    # `await` unconditionally: a no-op for a plain synchronously-returned
    # value, and required so that a Promise/thenable-returning export
    # (promise-sync roadmap phase; see tests/compat/fixtures/promises) is
    # actually driven to its fulfilled value here too, instead of pushing
    # the Promise object itself (which would not match the manifest's
    # declared fulfilled-value `result`). Fixtures whose promises never
    # settle (tests/compat/fixtures/promises-negative) are always
    # `negative: true` and therefore already excluded from this self-check
    # by main()'s `if fixture.get("negative"): continue`.
    script_lines = [f"const mod = await import({json.dumps(js_path.as_posix())});", "const out = [];"]
    cases = list(fixture.get("cases", []))
    for case in cases:
        args_json = json.dumps(case["args"])
        script_lines.append(
            f"out.push({{id: {json.dumps(case['id'])}, "
            f"value: await mod.{case['function']}(...({args_json}))}});"
        )
    for seq in fixture.get("sequences", []):
        for index, call in enumerate(seq["calls"]):
            args_json = json.dumps(call["args"])
            script_lines.append(
                f"out.push({{id: {json.dumps(seq['id'] + '#' + str(index))}, "
                f"value: await mod.{seq['function']}(...({args_json}))}});"
            )
    script_lines.append("console.log(JSON.stringify(out.map(o => o.value === undefined ? {...o, value: null, __void: true} : o)));")
    script = "\n".join(script_lines)

    try:
        result = subprocess.run(
            [node, "--input-type=module", "-e", script],
            capture_output=True, text=True, timeout=30,
        )
    except Exception as exc:  # pragma: no cover - defensive
        reporter.report(SKIP, f"node-selfcheck/{fid}", f"could not invoke node: {exc}")
        return

    if result.returncode != 0:
        reporter.report(FAIL, f"node-selfcheck/{fid}", result.stderr.strip().splitlines()[-1] if result.stderr else "node exited non-zero")
        return

    # Fixtures are allowed to have observable side effects of their own
    # (e.g. void/component.js calls console.log); only the harness's own
    # final JSON.stringify(...) line, always emitted last, is meaningful.
    stdout_lines = [line for line in result.stdout.splitlines() if line.strip()]
    try:
        observed = json.loads(stdout_lines[-1]) if stdout_lines else []
    except json.JSONDecodeError:
        reporter.report(FAIL, f"node-selfcheck/{fid}", f"could not parse node output: {result.stdout!r}")
        return

    observed_by_id = {o["id"]: o for o in observed}

    ok = True
    mismatches = []
    for case in cases:
        got = observed_by_id.get(case["id"])
        if got is None:
            ok = False
            mismatches.append(f"{case['id']}: no output")
            continue
        if case.get("void"):
            continue
        want = case.get("result", case.get("bridge_result"))
        if got["value"] != want:
            ok = False
            mismatches.append(f"{case['id']}: want {want!r}, got {got['value']!r}")
    for seq in fixture.get("sequences", []):
        for index, call in enumerate(seq["calls"]):
            key = f"{seq['id']}#{index}"
            got = observed_by_id.get(key)
            if got is None or got["value"] != call["result"]:
                ok = False
                mismatches.append(f"{key}: want {call['result']!r}, got {(got or {}).get('value')!r}")

    label = f"node-selfcheck/{fid}"
    if ok:
        reporter.report(PASS, label)
    else:
        reporter.report(FAIL, label, "; ".join(mismatches))


def main() -> None:
    reporter = Reporter()
    manifest = compat_lib.load_manifest()

    check_manifest_schema_shape(manifest, reporter)
    check_expected_files_in_sync(manifest, reporter)

    wasm_tools = compat_lib.find_wasm_tools()
    check_wit_and_js(manifest, reporter, wasm_tools)

    node = node_available()
    if node is None:
        reporter.report(SKIP, "node-selfcheck/*", "node not found on PATH; this repository does not require Node")
    else:
        for fixture in manifest["fixtures"]:
            if fixture.get("negative"):
                continue
            node_selfcheck_fixture(node, fixture, reporter)

    reporter.summary_and_exit()


if __name__ == "__main__":
    main()
