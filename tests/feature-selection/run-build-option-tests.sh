#!/usr/bin/env bash
#
# Fast, Node-free unit/negative tests for the feature-selection build options
# (cataggar/StarlingMonkey#6 Phase 6; see build.zig's "Platform feature
# selection" section and docs/feature-selection/README.md).
#
# This exercises build.zig's option-parsing/validation logic
# (parseFeatureList/resolveFeatures) *without* compiling any C++/wasm, by
# invoking `zig build --help`: Zig always runs the full build.zig `build()`
# function (including all `-Dfeature-*`/`-Ddisable-features`/
# `-Denable-features` parsing and the deterministic `@panic`s on unknown
# feature names / enable-vs-disable conflicts) before it lists steps, so
# `--help` triggers the exact same validation as a real build while taking
# well under a second and never touching the compiler. This is why this
# script is wired into `zig build test` (fast tier) while the full
# build-and-componentize-and-invoke checks live in the separate, slow
# `feature-selection-runtime-test` step (run-runtime-tests.sh) instead.
#
# Usage: tests/feature-selection/run-build-option-tests.sh
#
# Required environment:
#   ZIG                    Path to the pinned Zig toolchain binary.
#   ZIG_GLOBAL_CACHE_DIR   (optional) defaults to <repo>/.zig-global-cache

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ZIG="${ZIG:-zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

fail=0
pass_count=0
fail_count=0

# run_case NAME EXPECT_EXIT [expect_stderr_substring] -- ARGS...
run_case() {
  local name="$1" expect_exit="$2" expect_substr="$3"
  shift 3
  local out
  out="$("$ZIG" build --help "$@" 2>&1)"
  local exit_code=$?
  local ok=1
  if [ "$exit_code" != "$expect_exit" ]; then
    ok=0
    echo "FAIL $name -- expected exit $expect_exit, got $exit_code"
  fi
  if [ -n "$expect_substr" ] && ! grep -qF -- "$expect_substr" <<<"$out"; then
    ok=0
    echo "FAIL $name -- expected output to contain: $expect_substr"
    echo "--- actual output ---"
    echo "$out"
    echo "---------------------"
  fi
  if [ "$ok" = 1 ]; then
    echo "PASS $name"
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    fail=1
  fi
}

cd "$ROOT"

# --- Positive cases: valid option combinations must not panic ---

run_case "defaults-no-flags" 0 "" \
  ;

run_case "single-typed-option-stdio-false" 0 "" \
  -Dfeature-stdio=false

run_case "single-typed-option-random-false" 0 "" \
  -Dfeature-random=false

run_case "single-typed-option-clocks-false" 0 "" \
  -Dfeature-clocks=false

run_case "single-typed-option-http-false" 0 "" \
  -Dfeature-http=false

run_case "single-typed-option-fetch-event-false" 0 "" \
  -Dfeature-fetch-event=false

run_case "all-typed-options-false-pure-mode" 0 "" \
  -Dfeature-stdio=false -Dfeature-random=false -Dfeature-clocks=false \
  -Dfeature-http=false -Dfeature-fetch-event=false

run_case "csv-disable-single" 0 "" \
  -Ddisable-features=http

run_case "csv-disable-multiple" 0 "" \
  -Ddisable-features=http,fetch-event,random

run_case "csv-enable-overrides-typed-default-false" 0 "" \
  -Dfeature-http=false -Denable-features=http

run_case "csv-disable-and-enable-different-features" 0 "" \
  -Ddisable-features=http -Denable-features=random

# --- Negative cases: must fail deterministically (no silent fallback) ---

run_case "unknown-feature-in-disable-list" 1 \
  "unknown feature 'bogus-name'" \
  -Ddisable-features=bogus-name

run_case "unknown-feature-in-enable-list" 1 \
  "unknown feature 'not-a-feature'" \
  -Denable-features=not-a-feature

run_case "unknown-feature-among-valid-ones" 1 \
  "unknown feature 'nope'" \
  -Ddisable-features=http,nope,random

run_case "conflicting-same-feature-disable-and-enable" 1 \
  "feature 'http' appears in both -Ddisable-features and -Denable-features" \
  -Ddisable-features=http -Denable-features=http

run_case "conflicting-multiple-overlap" 1 \
  "appears in both -Ddisable-features and -Denable-features" \
  -Ddisable-features=random,clocks -Denable-features=clocks

echo ""
echo "feature-selection build-option tests: $pass_count passed, $fail_count failed"

if [ "$fail" != 0 ]; then
  exit 1
fi
exit 0
