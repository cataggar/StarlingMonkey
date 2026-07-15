#!/usr/bin/env python3
import re
import sys


def root_declarations(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    start = next(i for i, line in enumerate(lines) if line == "world root {")
    depth = 0
    result = []
    for line in lines[start:]:
        depth += line.count("{") - line.count("}")
        stripped = line.strip()
        if (
            (stripped.startswith("import ") and not stripped.startswith("import wasi:"))
            or stripped.startswith("export ")
        ):
            result.append(stripped)
        if depth == 0:
            break
    return result


def custom_api(path):
    package = ""
    functions = []
    resources = []
    type_names = set()
    used_names = set()
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if line.startswith("package "):
            package = line.removeprefix("package ").split("@", 1)[0]
        non_wasi = package and not package.startswith("wasi:")
        if not non_wasi:
            continue
        named_custom = not package.startswith("root:")
        if named_custom and ": func" in line:
            functions.append((package, line))
        match = re.match(r"resource ([a-z0-9-]+)", line)
        if named_custom and match:
            resources.append((package, match.group(1)))
        match = re.match(
            r"(?:type|record|variant|enum|flags|resource) ([a-z0-9-]+)", line
        )
        if match:
            type_names.add((package, match.group(1)))
        match = re.search(r"\.\{([^}]+)\};", line) if line.startswith("use ") else None
        if match:
            used_names.update((package, name.strip()) for name in match.group(1).split(","))
    return functions, resources, type_names, used_names


before, after = sys.argv[1:3]
if root_declarations(before) != root_declarations(after):
    raise SystemExit("custom root import/export names or signatures changed")

before_functions, before_resources, before_types, before_used = custom_api(before)
after_functions, after_resources, after_types, _ = custom_api(after)
if before_functions != after_functions or before_resources != after_resources:
    raise SystemExit("custom interface function or resource topology changed")
if not (before_types | before_used) <= after_types:
    raise SystemExit("a custom alias/type name was lost while plugging providers")

before_text = open(before, encoding="utf-8").read()
after_text = open(after, encoding="utf-8").read()
before_wasi = set(re.findall(r"^\s*import (wasi:[^;]+);", before_text, re.MULTILINE))
after_wasi = set(re.findall(r"^\s*import (wasi:[^;]+);", after_text, re.MULTILINE))
if not after_wasi < before_wasi:
    raise SystemExit("expected only a strict subset of WASI imports after surfacing")

print("PASS exact custom import/export signatures preserved; only WASI imports were internalized")
