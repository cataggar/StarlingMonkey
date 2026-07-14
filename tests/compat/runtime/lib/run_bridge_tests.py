#!/usr/bin/env python3
"""Runtime bridge compatibility suite for tests/compat (cataggar/StarlingMonkey#6).

Unlike tests/compat/run-compat-tests.sh (Node-free, structural-only; see its
own module docstring in lib/run_compat_tests.py), this module builds the
*actual* StarlingMonkey WIT dispatch reactor (runtime/js_dispatch.cpp +
runtime/js_dispatch.zig) for every fixture declared in manifest.json,
componentizes it with the real Wizer+WABT pipeline (componentize.sh,
cataggar/wabt#331's reactor-export-lift fix), invokes its exports through
Wasmtime (via tests/compat/runtime/invoker, "compat-invoker" -- a small host
built on the official `wasmtime` Rust crate, not a CLI string parser and not
a second component transpiler), and compares observed values/traps against
manifest.json's checked-in expectations. Negative fixtures are built and
invoked the same way, to build-verify the bridge's actual call-time-trap
behavior, not just statically reason about js_dispatch.cpp's source.

This is deliberately NOT part of `zig build test` or `zig build compat-test`
(see build.zig's `compat-bridge-test` step): a full run takes on the order
of 15-20 minutes, since each fixture needs its own from-scratch Zig build of
the reactor (StarlingMonkey + QuickJS/SpiderMonkey + the fixture's generated
WIT closure). See tests/compat/runtime/README.md.

Preflight requirements -- **all fail loudly (FAIL, non-zero exit) rather
than SKIP** if missing, since the entire point of this suite is to replace
a structural-only false positive, not reproduce one under a new name:
  - `$ZIG` (or `zig` on PATH) at exactly the version build.zig.zon requires.
  - `wasm-tools` (to validate componentized output).
  - `cargo`/`rustc` (to build tests/compat/runtime/invoker).
  - A working `wabt` binary with the cataggar/wabt#331 reactor-export-lift
    fix -- built on demand by build-wabt.sh (which itself requires network
    access to clone cataggar/wabt, unless a build is already cached).
  - The prebuilt SpiderMonkey/OpenSSL/Rust-staticlib artifacts this repo's
    build.zig needs (deps/sm-obj-zig, deps/openssl-zig,
    target/wasm32-wasip1/release/librust_staticlib.a) -- see README.md's
    "Building with Zig" section and this directory's README.md.

Usage:
    tests/compat/runtime/run-bridge-tests.sh [fixture-id ...]

With no arguments, runs every fixture in manifest.json. With arguments,
runs only the named fixture(s) (handy while developing this suite itself,
given the per-fixture build cost above).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

RUNTIME_DIR = Path(__file__).resolve().parent.parent
COMPAT_DIR = RUNTIME_DIR.parent
ROOT = COMPAT_DIR.parent.parent
sys.path.insert(0, str(COMPAT_DIR / "lib"))
import compat_lib  # noqa: E402
import gen_bridge_wit  # noqa: E402

PASS, FAIL = "PASS", "FAIL"

CACHE_DIR = RUNTIME_DIR / ".cache"
WIT_CACHE_DIR = CACHE_DIR / "wit"
BUILD_CACHE_DIR = CACHE_DIR / "build"
COMPONENT_CACHE_DIR = CACHE_DIR / "components"

BASE_WIT_DIR = ROOT / "host-apis" / "wasi-0.2.10" / "wit"


class PreflightError(RuntimeError):
    pass


class Reporter:
    def __init__(self) -> None:
        self.counts = {PASS: 0, FAIL: 0}
        self.failures: list[str] = []

    def report(self, status: str, label: str, detail: str = "") -> None:
        self.counts[status] += 1
        line = f"{status} {label}"
        if detail and status != PASS:
            line += f" -- {detail}"
        print(line, flush=True)
        if status == FAIL:
            self.failures.append(label)

    def summary_and_exit(self) -> int:
        print()
        print(f"== bridge-runtime summary: {self.counts[PASS]} passed, {self.counts[FAIL]} failed ==")
        if self.failures:
            print("  failed: " + ", ".join(self.failures))
            return 1
        return 0


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return subprocess.run(cmd, **kwargs)


# ---------------------------------------------------------------------------
# Preflight: every check below must fail loudly, never SKIP.
# ---------------------------------------------------------------------------

# This harness (specifically build-wabt.sh's two local Zig-toolchain-compat
# patches, tests/compat/runtime/wabt-patches/*.patch) is written against one
# exact upstream Zig dev build, not just any toolchain satisfying
# build.zig.zon's looser `minimum_zig_version` ("0.17.0"). Accepting any
# "0.17"-prefixed toolchain here previously let a *different* 0.17.x dev
# build silently pass preflight even though the wabt patches (and their
# `@Int`/`@Enum`-builtin-rename assumptions) are only known to apply to this
# exact commit; a version drift would surface later as a confusing wabt
# build failure instead of a clear preflight error. See build-wabt.sh's own
# header comment for the same pin.
REQUIRED_ZIG_VERSION = "0.17.0-dev.902+7255f3e72"


def find_zig() -> str:
    zig = os.environ.get("ZIG") or shutil.which("zig")
    if not zig:
        raise PreflightError(
            "no Zig toolchain found: set $ZIG to the pinned binary path "
            f"(exactly {REQUIRED_ZIG_VERSION}; see README.md/AGENTS.md) or "
            "put a matching `zig` on PATH."
        )
    if not os.access(zig, os.X_OK):
        raise PreflightError(f"$ZIG ('{zig}') is not executable")
    result = run([zig, "version"])
    if result.returncode != 0:
        raise PreflightError(f"`{zig} version` failed: {result.stderr}")
    version = result.stdout.strip()
    if version != REQUIRED_ZIG_VERSION:
        raise PreflightError(
            f"$ZIG ('{zig}') reports version '{version}', but this harness "
            f"requires exactly '{REQUIRED_ZIG_VERSION}' (not merely a "
            "matching major.minor prefix): tests/compat/runtime/wabt-patches/ "
            "is only known to apply cleanly to that exact upstream Zig dev "
            "build. This suite refuses to silently accept a different "
            "0.17.x toolchain and risk a confusing downstream wabt build "
            "failure instead of a clear preflight error."
        )
    return zig


def find_wasm_tools() -> str:
    tool = os.environ.get("WASM_TOOLS") or shutil.which("wasm-tools")
    if not tool:
        raise PreflightError(
            "`wasm-tools` not found on PATH (and $WASM_TOOLS not set); required "
            "to validate componentized fixture output. This repository already "
            "depends on it elsewhere (tests/run-suite.sh, build.zig smoke-test)."
        )
    return tool


def find_cargo() -> str:
    cargo = shutil.which("cargo")
    if not cargo:
        raise PreflightError(
            "`cargo` not found on PATH; required to build tests/compat/runtime/"
            "invoker (compat-invoker), the Wasmtime-based host used to invoke "
            "componentized fixtures. Install a Rust toolchain (https://rustup.rs)."
        )
    return cargo


def check_prebuilt_artifacts() -> None:
    required = [
        ROOT / "deps" / "sm-obj-zig",
        ROOT / "deps" / "openssl-zig",
        ROOT / "target" / "wasm32-wasip1" / "release" / "librust_staticlib.a",
    ]
    missing = [str(p) for p in required if not p.exists()]
    if missing:
        raise PreflightError(
            "missing prebuilt artifact(s) required by build.zig: " + ", ".join(missing) +
            " (see README.md's build requirements; this environment's setup notes "
            "describe symlinking these in from a sibling checkout)."
        )


def build_wabt(zig: str) -> str:
    env = dict(os.environ)
    env["ZIG"] = zig
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(ROOT / ".zig-global-cache"))
    result = run(["bash", str(RUNTIME_DIR / "build-wabt.sh")], env=env)
    if result.returncode != 0:
        raise PreflightError(f"build-wabt.sh failed:\n{result.stderr}")
    wabt = result.stdout.strip().splitlines()[-1]
    if not wabt or not os.access(wabt, os.X_OK):
        raise PreflightError(f"build-wabt.sh did not produce a usable binary (got: {wabt!r})")
    return wabt


def build_invoker(cargo: str) -> str:
    invoker_dir = RUNTIME_DIR / "invoker"
    result = run([cargo, "build", "--release", "--quiet"], cwd=invoker_dir)
    if result.returncode != 0:
        raise PreflightError(f"building compat-invoker failed:\n{result.stderr}")
    binary = invoker_dir / "target" / "release" / "compat-invoker"
    if not binary.exists():
        raise PreflightError(f"compat-invoker build succeeded but {binary} is missing")
    return str(binary)


# ---------------------------------------------------------------------------
# Per-fixture build + componentize + invoke + compare
# ---------------------------------------------------------------------------

def build_reactor(zig: str, fixture: dict[str, Any]) -> Path:
    fixture_wit_dir = COMPAT_DIR / fixture["wit_dir"]
    gen_out = WIT_CACHE_DIR / fixture["id"]
    component_wit, dispatch_wit = gen_bridge_wit.generate(BASE_WIT_DIR, fixture_wit_dir, gen_out)
    # build.zig's `b.path(...)` requires paths relative to the build root
    # (ROOT), not absolute paths -- see Build.zig's `sub_path is expected to
    # be relative to the build root` panic.
    component_wit_rel = os.path.relpath(component_wit, ROOT)
    dispatch_wit_rel = os.path.relpath(dispatch_wit, ROOT)

    install_prefix = BUILD_CACHE_DIR / fixture["id"]
    env = dict(os.environ)
    env.setdefault("ZIG_GLOBAL_CACHE_DIR", str(ROOT / ".zig-global-cache"))
    env.pop("ZIG_LOCAL_CACHE_DIR", None)
    result = run(
        [
            zig, "build", "-Doptimize=ReleaseSmall",
            f"-Dcomponent-wit={component_wit_rel}",
            "-Dcomponent-world=js-dispatch",
            f"-Ddispatch-wit={dispatch_wit_rel}",
            "-Ddispatch-world=js-exports",
            "-p", str(install_prefix),
        ],
        cwd=ROOT, env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(f"zig build failed for fixture '{fixture['id']}':\n{result.stderr[-4000:]}")
    return install_prefix / "bin"


def componentize(bin_dir: Path, fixture: dict[str, Any], wabt: str) -> Path:
    js_path = COMPAT_DIR / fixture["dir"] / fixture["js_file"]
    out_path = COMPONENT_CACHE_DIR / f"{fixture['id']}.wasm"
    COMPONENT_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["WABT"] = wabt
    result = run(
        ["bash", str(bin_dir / "componentize.sh"), str(js_path), "-o", str(out_path)],
        cwd=bin_dir, env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(f"componentize.sh failed for fixture '{fixture['id']}':\n{result.stderr}")
    return out_path


def validate(wasm_tools: str, component_path: Path) -> None:
    result = run([wasm_tools, "validate", str(component_path)])
    if result.returncode != 0:
        raise RuntimeError(f"wasm-tools validate failed for {component_path}:\n{result.stderr}")


def calls_for_fixture(fixture: dict[str, Any]) -> list[dict[str, Any]]:
    calls = []
    for c in fixture.get("cases", []):
        calls.append({"function": c["function"], "args": c["args"], "_case": c})
    for seq in fixture.get("sequences", []):
        for index, call in enumerate(seq["calls"]):
            calls.append({
                "function": seq["function"],
                "args": call["args"],
                "_case": {"id": f"{seq['id']}#{index}", "result": call["result"]},
            })
    return calls


def invoke(invoker: str, component_path: Path, calls: list[dict[str, Any]]) -> list[dict[str, Any]]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, dir=CACHE_DIR) as fh:
        json.dump([{"function": c["function"], "args": c["args"]} for c in calls], fh)
        calls_path = fh.name
    try:
        result = run([invoker, str(component_path), calls_path])
    finally:
        os.unlink(calls_path)
    if result.returncode != 0:
        raise RuntimeError(f"compat-invoker failed: {result.stderr}\n{result.stdout}")
    return json.loads(result.stdout)


def run_positive_fixture(fixture, zig, wabt, wasm_tools, invoker, reporter) -> None:
    label = f"bridge/{fixture['id']}"
    try:
        bin_dir = build_reactor(zig, fixture)
        component_path = componentize(bin_dir, fixture, wabt)
        validate(wasm_tools, component_path)
        calls = calls_for_fixture(fixture)
        results = invoke(invoker, component_path, calls)
    except RuntimeError as err:
        reporter.report(FAIL, label, str(err)[-2000:])
        return

    mismatches = []
    for call, observed in zip(calls, results):
        c = call["_case"]
        if not observed["ok"]:
            mismatches.append(f"{c['id']}: unexpected trap: {observed['trap']}")
            continue
        if c.get("void"):
            continue
        want = c["bridge_result"] if "bridge_result" in c else c["result"]
        if json.dumps(observed["value"], sort_keys=True) != json.dumps(want, sort_keys=True):
            mismatches.append(f"{c['id']}: want {want!r}, got {observed['value']!r}")
    if mismatches:
        reporter.report(FAIL, label, "; ".join(mismatches))
    else:
        reporter.report(PASS, label)


def run_negative_fixture(fixture, zig, wabt, wasm_tools, invoker, reporter) -> None:
    label = f"bridge/{fixture['id']}"
    try:
        bin_dir = build_reactor(zig, fixture)
        component_path = componentize(bin_dir, fixture, wabt)
        validate(wasm_tools, component_path)
        calls = calls_for_fixture(fixture)
        results = invoke(invoker, component_path, calls)
    except RuntimeError as err:
        reporter.report(FAIL, label, str(err)[-2000:])
        return

    mismatches = []
    for call, observed in zip(calls, results):
        c = call["_case"]
        expect = c.get("expect_error", {})
        needle = expect.get("bridge_message_contains")
        if observed["ok"]:
            mismatches.append(f"{c['id']}: expected a call-time trap, call succeeded with {observed.get('value')!r}")
            continue
        if needle:
            haystack = observed["trap"] + "\n" + observed.get("diagnostics", "")
            if needle not in haystack:
                mismatches.append(f"{c['id']}: trap/diagnostics did not contain {needle!r}; trap={observed['trap']!r} diagnostics={observed.get('diagnostics', '')!r}")
    if mismatches:
        reporter.report(FAIL, label, "; ".join(mismatches))
    else:
        reporter.report(PASS, label)


def main(argv: list[str]) -> int:
    only = set(argv[1:]) or None

    reporter = Reporter()
    try:
        zig = find_zig()
        wasm_tools = find_wasm_tools()
        cargo = find_cargo()
        check_prebuilt_artifacts()
        wabt = build_wabt(zig)
        invoker = build_invoker(cargo)
    except PreflightError as err:
        print(f"FAIL bridge/preflight -- {err}")
        return 1

    print(f"bridge-runtime preflight OK: zig={zig} wasm-tools={wasm_tools} wabt={wabt} invoker={invoker}")
    print()

    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    manifest = compat_lib.load_manifest()
    for fixture in manifest["fixtures"]:
        if only is not None and fixture["id"] not in only:
            continue
        if fixture.get("negative"):
            run_negative_fixture(fixture, zig, wabt, wasm_tools, invoker, reporter)
        else:
            run_positive_fixture(fixture, zig, wabt, wasm_tools, invoker, reporter)

    return reporter.summary_and_exit()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
