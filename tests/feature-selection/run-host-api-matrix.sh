#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-zig}"
ZIG="${2:-${ZIG:-zig}}"
VERSIONS=(0.2.0 0.2.2 0.2.3 0.2.10)
BUILD_ROOT="$ROOT/tests/feature-selection/.build/host-api-matrix/$MODE"
FIXTURE="$ROOT/tests/feature-selection/fixtures/probe.js"
PURE_FLAGS=(
  -Dfeature-stdio=false
  -Dfeature-random=false
  -Dfeature-clocks=false
  -Dfeature-http=false
  -Dfeature-fetch-event=false
)

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$BUILD_ROOT/zig-global-cache}"

check_component() {
  local version="$1" runtime="$2" component="$3"
  "$runtime/wasm-tools" validate --features all "$component"
  if "$runtime/wasm-tools" component wit "$component" | grep -q 'import wasi:'; then
    echo "FAIL wasi-$version pure component retained a WASI import" >&2
    return 1
  fi
  "$runtime/wasm-tools" component wit "$component" |
    grep -q "export wasi:cli/run@${version};"
  STARLINGMONKEY_CONFIG=--invalid-if-visible \
    "$runtime/wasmtime" run -S cli -S inherit-env "$component" \
      -- --invalid-if-visible
}

for version in "${VERSIONS[@]}"; do
  echo "== $MODE wasi-$version pure production surface =="
  case "$MODE" in
    zig)
      prefix="$BUILD_ROOT/wasi-$version"
      "$ZIG" build install --prefix "$prefix" -Doptimize=ReleaseSmall \
        -Dhost-api="wasi-$version" "${PURE_FLAGS[@]}"
      runtime="$prefix/bin"
      component="$prefix/pure.wasm"
      WABT="$ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
        "$runtime/componentize.sh" "$FIXTURE" -o "$component"
      ;;
    cmake)
      prefix="$BUILD_ROOT/wasi-$version"
      HOST_API="wasi-$version" ZIG="$ZIG" cmake -S "$ROOT" -B "$prefix" \
        -DCMAKE_BUILD_TYPE=Release \
        -DFEATURE_STDIO=OFF \
        -DFEATURE_RANDOM=OFF \
        -DFEATURE_CLOCKS=OFF \
        -DFEATURE_HTTP=OFF \
        -DFEATURE_FETCH_EVENT=OFF
      cmake --build "$prefix" --parallel 2 --target starling-raw.wasm \
        starling-feature-surface-helper
      runtime="$prefix"
      component="$prefix/pure.wasm"
      WABT="$ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
        "$runtime/componentize.sh" "$FIXTURE" -o "$component"
      ;;
    *)
      echo "unknown mode: $MODE (expected zig or cmake)" >&2
      exit 2
      ;;
  esac

  adapter_version="$("$runtime/wasm-tools" component wit \
    "$runtime/preview1-adapter.wasm" |
    sed -n 's/.*import wasi:cli\/environment@\([^;]*\);.*/\1/p' | head -1)"
  test "$adapter_version" = "$version"
  check_component "$version" "$runtime" "$component"
done

echo "$MODE host API pure production matrix passed"
if [ "${KEEP_BUILDS:-0}" != 1 ]; then
  rm -rf "$BUILD_ROOT"
fi
