#!/usr/bin/env python3
import re
import shlex
import sys
from pathlib import Path


if len(sys.argv) != 3:
    raise SystemExit("usage: check-just-recipes.py <workflow> <justfile>")

workflow = Path(sys.argv[1])
justfile = Path(sys.argv[2])
recipes = {
    match.group(1)
    for line in justfile.read_text(encoding="utf-8").splitlines()
    if (match := re.match(r"^([A-Za-z][A-Za-z0-9_-]*)(?:\s|:)", line))
    and ":" in line
}
referenced = set()
for line in workflow.read_text(encoding="utf-8").splitlines():
    command = line.strip()
    if not command.startswith("just "):
        continue
    for token in shlex.split(command)[1:]:
        if token.startswith("-") or "=" in token:
            continue
        referenced.add(token)
        break

missing = sorted(referenced - recipes)
if missing:
    raise SystemExit(
        f"{workflow}: missing justfile recipes: {', '.join(missing)}"
    )
print(f"{workflow}: verified recipes: {', '.join(sorted(referenced))}")
