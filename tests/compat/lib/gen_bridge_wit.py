#!/usr/bin/env python3
"""Generate a full WIT closure for a compat fixture, suitable for
`zig build -Dcomponent-wit=... -Dcomponent-world=js-dispatch
-Ddispatch-wit=... -Ddispatch-world=js-exports` (see README.md /
host-apis/wasi-0.2.10/wit/js-dispatch.wit).

Each fixture under tests/compat/fixtures/<id>/wit/world.wit declares its
the exact `package starling:js; interface api { ... } world js-exports {
export api; }` topology used by both ComponentizeJS and StarlingMonkey.
This helper only splices that unmodified package into a copy of the full
WASI-importing closure used by StarlingMonkey's `js-dispatch` world. It does
not flatten, wrap, rename, or otherwise normalize the fixture topology.
"""
import shutil
import sys
from pathlib import Path


def generate(base_wit_dir: Path, fixture_wit_dir: Path, out_dir: Path) -> tuple[Path, Path]:
    """Copy base_wit_dir (the full WASI-importing closure) to out_dir, then
    overwrite its deps/starling-js/package.wit with the exact file from
    fixture_wit_dir/world.wit. Returns (component_wit_dir, dispatch_wit_dir)."""
    if out_dir.exists():
        shutil.rmtree(out_dir)
    shutil.copytree(base_wit_dir, out_dir)
    dispatch_wit_dir = out_dir / "deps" / "starling-js"
    package_wit = dispatch_wit_dir / "package.wit"
    if not package_wit.exists():
        raise FileNotFoundError(f"expected {package_wit} after copying {base_wit_dir}")
    fixture_wit = fixture_wit_dir / "world.wit"
    wit_text = fixture_wit.read_text()
    if "package starling:js;" not in wit_text:
        raise ValueError(f"{fixture_wit} must declare `package starling:js;`")
    if "interface api" not in wit_text or "export api;" not in wit_text:
        raise ValueError(f"{fixture_wit} must export the named `api` interface")
    package_wit.write_text(wit_text)
    return out_dir, dispatch_wit_dir


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: gen_bridge_wit.py <base-wit-dir> <fixture-wit-dir> <out-dir>",
            file=sys.stderr,
        )
        return 2
    base_wit_dir, fixture_wit_dir, out_dir = (Path(a) for a in argv[1:])
    component_wit, dispatch_wit = generate(base_wit_dir, fixture_wit_dir, out_dir)
    print(component_wit)
    print(dispatch_wit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
