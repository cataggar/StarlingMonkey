#!/usr/bin/env bash
#
# Fast, Node-free preprocessor/compile regression tests for
# include/feature-defaults.h (cataggar/StarlingMonkey#6 Phase 6 review
# follow-up: "critical feature-selection review finding" -- CMake and any
# non-Zig compiler path did not define STARLING_FEATURE_*, so undefined
# macros silently evaluated to 0 and compiled every gated feature as
# *disabled*).
#
# include/feature-defaults.h fixes that by `#define`-ing each
# `STARLING_FEATURE_*` macro to `1` only when it isn't already defined.
# This script proves the resulting contract directly at the preprocessor/
# compiler level, independent of build.zig and independent of any
# particular build system's include-path plumbing:
#
#   1. No explicit -D flags at all  => every macro defaults to 1 (matches
#      Zig's own default: see build.zig's `Features` struct, all fields
#      default `true`).
#   2. Explicit `-DSTARLING_FEATURE_X=0`  => X stays 0 (the header's
#      `#ifndef` guard must not clobber an explicit definition).
#   3. Mixed explicit/implicit  => each macro is independent; explicitly
#      set ones keep their value, unset ones still default to 1.
#   4. Explicit `-DSTARLING_FEATURE_X=1` (matching Zig's enabled default,
#      or CMake's `-Werror`) compiles with zero warnings -- i.e. the
#      header never triggers a macro-redefinition warning, so Zig's
#      `-D...=0/1` (or any other build system's explicit define) stays
#      authoritative as required.
#
# Both a plain-C probe (feature_stubs.c is a plain C source) and a C++
# probe (the other four gated sources are C++) are compiled, using the
# pinned Zig toolchain's bundled clang (`zig cc` / `zig c++`) so this has
# no dependency on a host compiler, wasi-sdk, or network access, and stays
# fast enough for `zig build test`.
#
# Usage: tests/feature-selection/run-macro-default-tests.sh
#
# Required environment:
#   ZIG   Path to the pinned Zig toolchain binary.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ZIG="${ZIG:-zig}"

SCRATCH="$HERE/.build/macro-probes"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

fail=0
pass_count=0
fail_count=0

ALL_MACROS=(STARLING_FEATURE_STDIO STARLING_FEATURE_RANDOM STARLING_FEATURE_CLOCKS
            STARLING_FEATURE_HTTP STARLING_FEATURE_FETCH_EVENT)

# write_probe LANG_EXT -- writes a probe source that #include's the real
# header and #error's out (breaking the build) if any macro doesn't have
# its expected value, per pair of "MACRO=expected" args.
write_probe() {
  local ext="$1"
  shift
  local src="$SCRATCH/probe.$ext"
  {
    echo '#include "feature-defaults.h"'
    for pair in "$@"; do
      local macro="${pair%%=*}"
      local expected="${pair#*=}"
      echo "#if ${macro} != ${expected}"
      echo "#error \"${macro} expected to be ${expected}\""
      echo "#endif"
    done
    if [ "$ext" = "c" ]; then
      echo 'int main(void) { return 0; }'
    else
      echo 'int main() { return 0; }'
    fi
  } > "$src"
  echo "$src"
}

# run_case NAME EXT -- DEFINE_FLAGS... -- MACRO=expected...
run_case() {
  local name="$1" ext="$2"
  shift 2
  local defines=()
  while [ "$1" != "--" ]; do
    defines+=("$1")
    shift
  done
  shift # consume "--"

  local src
  src="$(write_probe "$ext" "$@")"
  local obj="$SCRATCH/${name}.${ext}.o"
  local compiler=cc
  local std=c17
  if [ "$ext" = "cpp" ]; then
    compiler=c++
    std=c++20
  fi
  local out
  out="$("$ZIG" "$compiler" -std=$std -I"$ROOT/include" -Wall -Wextra -Werror \
        "${defines[@]}" -c "$src" -o "$obj" 2>&1)"
  local exit_code=$?

  if [ "$exit_code" = 0 ] && [ -z "$out" ]; then
    echo "PASS $name ($ext)"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL $name ($ext) -- expected clean compile (exit 0, no output)"
    echo "--- actual output (exit $exit_code) ---"
    echo "$out"
    echo "-----------------------------------------"
    fail_count=$((fail_count + 1))
    fail=1
  fi
}

cd "$ROOT"

for ext in c cpp; do
  # --- 1. No explicit macros: every one of the five must default to 1 ---
  run_case "no-explicit-defines-all-default-to-1" "$ext" \
    -- \
    STARLING_FEATURE_STDIO=1 STARLING_FEATURE_RANDOM=1 STARLING_FEATURE_CLOCKS=1 \
    STARLING_FEATURE_HTTP=1 STARLING_FEATURE_FETCH_EVENT=1

  # --- 2. Explicit 0 for every macro: all must stay 0, none silently
  #        reverting to the header's default ---
  run_case "explicit-zero-all-features-stay-disabled" "$ext" \
    -DSTARLING_FEATURE_STDIO=0 -DSTARLING_FEATURE_RANDOM=0 -DSTARLING_FEATURE_CLOCKS=0 \
    -DSTARLING_FEATURE_HTTP=0 -DSTARLING_FEATURE_FETCH_EVENT=0 \
    -- \
    STARLING_FEATURE_STDIO=0 STARLING_FEATURE_RANDOM=0 STARLING_FEATURE_CLOCKS=0 \
    STARLING_FEATURE_HTTP=0 STARLING_FEATURE_FETCH_EVENT=0

  # --- 3. Mixed: explicitly-set macros keep their value; unset macros
  #        still default to 1 (per-macro independence) ---
  run_case "mixed-explicit-and-default-are-independent" "$ext" \
    -DSTARLING_FEATURE_HTTP=0 -DSTARLING_FEATURE_RANDOM=0 \
    -- \
    STARLING_FEATURE_STDIO=1 STARLING_FEATURE_RANDOM=0 STARLING_FEATURE_CLOCKS=1 \
    STARLING_FEATURE_HTTP=0 STARLING_FEATURE_FETCH_EVENT=1

  # --- 4. Explicit 1 for every macro (matching Zig's enabled-by-default
  #        `-D...=1`, or a hypothetical CMake `-Werror` build): must
  #        compile with zero warnings, i.e. the header's `#ifndef` guard
  #        never redefines an already-defined macro ---
  run_case "explicit-one-matches-default-no-redefinition-warning" "$ext" \
    -DSTARLING_FEATURE_STDIO=1 -DSTARLING_FEATURE_RANDOM=1 -DSTARLING_FEATURE_CLOCKS=1 \
    -DSTARLING_FEATURE_HTTP=1 -DSTARLING_FEATURE_FETCH_EVENT=1 \
    -- \
    STARLING_FEATURE_STDIO=1 STARLING_FEATURE_RANDOM=1 STARLING_FEATURE_CLOCKS=1 \
    STARLING_FEATURE_HTTP=1 STARLING_FEATURE_FETCH_EVENT=1
done

echo ""
echo "feature-selection macro-default tests: $pass_count passed, $fail_count failed"

if [ "$fail" != 0 ]; then
  exit 1
fi
exit 0
