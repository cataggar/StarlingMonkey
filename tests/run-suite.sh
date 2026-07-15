#!/usr/bin/env bash
#
# Run the StarlingMonkey e2e and integration test suites against a runtime
# directory (one containing componentize.sh, starling-raw.wasm, the adapter and
# the wasmtime/wasm-tools binaries — e.g. zig-out/bin). Reports a pass/fail
# summary and exits non-zero if any test failed.
#
# Usage: tests/run-suite.sh <runtime-bin-dir>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:?usage: run-suite.sh <runtime-bin-dir>}"
BIN="$(cd "$BIN" && pwd)"

export WASMTIME="$BIN/wasmtime"
export WASM_TOOLS="$BIN/wasm-tools"

E2E=(
  blob eventloop-stall headers runtime-err smoke syntax-err tla-err
  tla-runtime-resolve tla stream-forwarding multi-stream-forwarding
  teed-stream-as-outgoing-body init-script no-init-location init-location
)
INTEGRATION=( blob btoa crypto event fetch performance timers )

pass=0; fail=0; failed=()
case_log="$BIN/.suite-$$.log"
server_log="$BIN/.suite-server-$$.log"

run() { # <label> <test.sh args...>
  local label="$1"; shift
  if timeout 120 bash "$ROOT/tests/test.sh" "$@" >"$case_log" 2>&1; then
    pass=$((pass + 1)); echo "PASS $label"
  else
    fail=$((fail + 1)); failed+=("$label"); echo "FAIL $label"
  fi
}

echo "== e2e =="
for t in "${E2E[@]}"; do run "e2e/$t" "$BIN" "$ROOT/tests/e2e/$t"; done

echo "== integration =="
# The integration suite serves a shared test-server component; componentize it once.
server="$BIN/test-server.wasm"
if PREOPEN_DIR="$ROOT/tests" "$BIN/componentize.sh" "$ROOT/tests/integration/test-server.js" -o "$server" >"$server_log" 2>&1; then
  for t in "${INTEGRATION[@]}"; do run "integration/$t" "$BIN" "$ROOT/tests/integration/$t" "$server" "$t"; done
else
  echo "FAIL integration/test-server (componentize)"; fail=$((fail + 1)); failed+=("integration/test-server")
fi

rm -f "$case_log" "$server_log"
echo
echo "== summary: $pass passed, $fail failed =="
if [ $fail -ne 0 ]; then
  printf '  failed: %s\n' "${failed[*]}"
  exit 1
fi
