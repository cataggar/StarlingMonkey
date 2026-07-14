"""Shared helpers for the Phase 0 compatibility harness (tests/compat).

Node-free by design: only the Python 3 standard library plus the already
pinned `wasm-tools` binary (used elsewhere by this repository's build, e.g.
build.zig's smoke-test and tests/run-suite.sh) are required. Node is only
used by the explicitly opt-in reference mode in tests/compat/reference/.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

COMPAT_DIR = Path(__file__).resolve().parent.parent
MANIFEST_PATH = COMPAT_DIR / "manifest.json"


def load_manifest() -> dict[str, Any]:
    with open(MANIFEST_PATH, encoding="utf-8") as fh:
        return json.load(fh)


def expected_doc_for_fixture(fixture: dict[str, Any]) -> dict[str, Any]:
    """Re-derive the checked-in expected/<fixture>.json content from a
    manifest fixture entry. Used both to (re)generate the checked-in files
    and to verify they have not drifted out of sync with manifest.json."""
    doc: dict[str, Any] = {
        "fixture": fixture["id"],
        "world": fixture["world"],
        "wit_dir": fixture["wit_dir"],
        "js_file": fixture["js_file"],
    }
    if "cases" in fixture:
        cases_out = []
        for case in fixture["cases"]:
            entry = {"id": case["id"], "function": case["function"], "args": case["args"]}
            for key in (
                "result", "bridge_result", "reference_result", "void", "confidence",
                "notes", "bridge_none_representation", "reference_none_representation",
                "expect_error",
            ):
                if key in case:
                    entry[key] = case[key]
            cases_out.append(entry)
        doc["cases"] = cases_out
    if "sequences" in fixture:
        doc["sequences"] = fixture["sequences"]
    if "negative" in fixture:
        doc["negative"] = fixture["negative"]
    return doc


def find_wasm_tools() -> str | None:
    return os.environ.get("WASM_TOOLS") or shutil.which("wasm-tools")


def component_wit_json(wasm_tools: str, wit_dir: Path) -> dict[str, Any]:
    result = subprocess.run(
        [wasm_tools, "component", "wit", str(wit_dir), "--json"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def world_export_functions(wit_json: dict[str, Any], world_name: str) -> dict[str, dict[str, Any]]:
    """Return {function_name: function_json} for functions exported directly
    on the given world (Phase 0 fixtures declare exports directly on the
    world; see manifest.json known_deviations "interface-export-flattening")."""
    worlds = {w["name"]: w for w in wit_json.get("worlds", [])}
    world = worlds.get(world_name)
    if world is None:
        raise ValueError(f"world '{world_name}' not found (have: {sorted(worlds)})")
    functions: dict[str, dict[str, Any]] = {}
    for name, export in world.get("exports", {}).items():
        if "function" in export:
            functions[name] = export["function"]
    return functions


_EXPORT_FUNCTION_RE_TEMPLATE = r"export\s+function\s+{name}\s*\("
_EXPORT_NONFUNCTION_RE_TEMPLATE = r"export\s+(?:const|let|var)\s+{name}\b"


def js_defines_function_export(js_source: str, name: str) -> bool:
    return re.search(_EXPORT_FUNCTION_RE_TEMPLATE.format(name=re.escape(name)), js_source) is not None


def js_defines_nonfunction_export(js_source: str, name: str) -> bool:
    return re.search(_EXPORT_NONFUNCTION_RE_TEMPLATE.format(name=re.escape(name)), js_source) is not None
