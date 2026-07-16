#!/usr/bin/env python3

import json
import re
import sys


args = sys.argv[1:]
host_api_version = "0.2.10"
if args[:1] == ["--host-api-version"]:
    host_api_version = args[1]
    args = args[2:]

expected_path, case, expected_exports_text, *surfaces = args
expected = json.load(open(expected_path, encoding="utf-8"))[case]
expected_exports = expected_exports_text.split(",") if expected_exports_text else []
expected_imports = [
    re.sub(r"@0\.2\.10$", f"@{host_api_version}", item)
    for item in expected["imports"]
]
baseline = None

for surface in surfaces:
    text = open(surface, encoding="utf-8").read()
    actual = {
        "imports": sorted(re.findall(r"^\s*import ([^;]+);", text, re.MULTILINE)),
        "exports": sorted(re.findall(r"^\s*export ([^;]+);", text, re.MULTILINE)),
    }
    wanted = {
        "imports": sorted(expected_imports),
        "exports": sorted(expected_exports),
    }
    if actual != wanted:
        raise SystemExit(
            f"{surface}: {case} surface mismatch\n"
            f"expected={wanted}\n"
            f"actual={actual}"
        )
    if baseline is not None and actual != baseline:
        raise SystemExit(f"{surface}: production componentizers disagree")
    baseline = actual

print(f"PASS {case}: exact production import/export surface")
