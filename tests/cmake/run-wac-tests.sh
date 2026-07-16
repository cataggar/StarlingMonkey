#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cmake -DROOT="$ROOT" -P "$ROOT/tests/cmake/test-wac-selection.cmake"
if output="$(cmake -DROOT="$ROOT" -DTEST_SYSTEM_NAME=Plan9 -DTEST_PROCESSOR=x86_64 \
    -P "$ROOT/tests/cmake/test-wac-unsupported.cmake" 2>&1)"; then
  echo "FAIL: unsupported WAC platform was accepted" >&2
  exit 1
fi
grep -q "unsupported on host OS 'Plan9'" <<<"$output"
if output="$(cmake -DROOT="$ROOT" -DTEST_SYSTEM_NAME=Linux -DTEST_PROCESSOR=mips64 \
    -P "$ROOT/tests/cmake/test-wac-unsupported.cmake" 2>&1)"; then
  echo "FAIL: unsupported WAC architecture was accepted" >&2
  exit 1
fi
grep -q "unsupported on host architecture 'mips64'" <<<"$output"
echo "CMake WAC platform selection tests passed"
