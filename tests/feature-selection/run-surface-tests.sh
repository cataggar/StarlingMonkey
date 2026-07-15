#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <starling-feature-surface> <wasm-tools>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$(realpath "$1")"
WASM_TOOLS="$(realpath "$2")"
HERE="$ROOT/tests/feature-selection"
SCRATCH="$HERE/.surface"
EXPECTED="$HERE/reference/expected/import-surfaces.json"
TARGET="$HERE/reference/wit-probe"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/candidate/deps"
trap 'rm -rf "$SCRATCH"' EXIT

cp -R "$ROOT/host-apis/wasi-0.2.10/wit/deps/." "$SCRATCH/candidate/deps/"

"$WASM_TOOLS" component embed \
  "$ROOT/host-apis/wasi-0.2.10/wit" \
  --world bindings --dummy -o "$SCRATCH/base.core.wasm"
"$WASM_TOOLS" component new \
  "$SCRATCH/base.core.wasm" -o "$SCRATCH/base.wasm"
"$WASM_TOOLS" component wit \
  "$SCRATCH/base.wasm" -o "$SCRATCH/base.wit"

{
  echo "package local:feature-candidate;"
  echo "world candidate {"
  sed -n 's/^  import \(wasi:[^;]*\);/  import \1;/p' "$SCRATCH/base.wit"
  echo "  export handler: func() -> u32;"
  echo "}"
} > "$SCRATCH/candidate/world.wit"

"$WASM_TOOLS" component embed \
  "$SCRATCH/candidate" \
  --world candidate --dummy -o "$SCRATCH/candidate.core.wasm"
"$WASM_TOOLS" component new \
  "$SCRATCH/candidate.core.wasm" -o "$SCRATCH/candidate.wasm"

run_case() {
  local name="$1" features="$2"
  local work="$SCRATCH/$name"
  mkdir -p "$work"
  "$HELPER" \
    --wasm-tools "$WASM_TOOLS" \
    --platform-wit "$ROOT/host-apis/wasi-0.2.10/wit" \
    --component "$SCRATCH/candidate.wasm" \
    --output "$work/output.wasm" \
    --work-dir "$work" \
    --target-wit "$TARGET" \
    --target-world probe \
    --features "$features"
  "$WASM_TOOLS" component wit "$work/output.wasm" -o "$work/output.wit"
  python3 - "$EXPECTED" "$name" "$work/output.wit" <<'PY'
import json
import re
import sys

expected_path, case, actual_path = sys.argv[1:]
expected = json.load(open(expected_path, encoding="utf-8"))[case]
text = open(actual_path, encoding="utf-8").read()
actual = {
    "imports": re.findall(r"^\s*import ([^;]+);", text, re.MULTILINE),
    "exports": re.findall(r"^\s*export ([^;]+);", text, re.MULTILINE),
}
for key in ("imports", "exports"):
    if sorted(actual[key]) != sorted(expected[key]):
        raise SystemExit(
            f"{case} {key} mismatch\n"
            f"expected={sorted(expected[key])}\n"
            f"actual={sorted(actual[key])}"
        )
print(f"PASS {case}: exact import/export surface")
PY
}

run_case defaults "1,1,1,1,1"
run_case disable-all "0,0,0,0,0"
run_case disable-http-only "1,1,1,0,1"
run_case disable-fetch-event-only "1,1,1,1,0"
run_case disable-random "1,0,1,1,1"
run_case disable-clocks "1,1,0,1,1"
run_case disable-stdio "0,1,1,1,1"
run_case enable-features-nonempty "1,1,1,1,1"

echo "feature surface oracle tests passed"
