#!/usr/bin/env python3
"""Regenerate the checked-in tests/compat/expected/<fixture>.json files from
manifest.json. manifest.json remains the single source of truth for case
data; the expected/ files are a denormalized, checked-in projection of it so
that other tooling (or a human) can inspect expected observable outputs for
one fixture without parsing the full manifest. Run this after editing
manifest.json's fixtures/cases, then re-run run-compat-tests.sh to confirm
they are in sync.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compat_lib  # noqa: E402


def main() -> None:
    manifest = compat_lib.load_manifest()
    for fixture in manifest["fixtures"]:
        doc = compat_lib.expected_doc_for_fixture(fixture)
        expected_path = compat_lib.COMPAT_DIR / fixture["expected_file"]
        expected_path.parent.mkdir(parents=True, exist_ok=True)
        with open(expected_path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print(f"wrote {expected_path.relative_to(compat_lib.COMPAT_DIR)}")


if __name__ == "__main__":
    main()
