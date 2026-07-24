#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-zig}"
ZIG="${2:-${ZIG:-zig}}"
VERSIONS=(0.2.0 0.2.2 0.2.3 0.2.10)
BUILD_ROOT="$ROOT/tests/feature-selection/.build/host-api-matrix/$MODE"
SHARED_NATIVE_CACHE="$BUILD_ROOT/shared native cache"
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

check_wit_versions() {
  local version="$1" directory="$2"
  python3 - "$directory" "$version" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
versions = set()
for path in root.rglob("*.wit"):
    versions.update(re.findall(r"\bwasi:[^\s@;]+@(\d+\.\d+\.\d+)", path.read_text()))
if versions != {expected}:
    raise SystemExit(f"{root}: expected only WASI {expected}, found {sorted(versions)}")
PY
}

version_index=0
for version in "${VERSIONS[@]}"; do
  version_index=$((version_index + 1))
  echo "== $MODE wasi-$version pure production surface =="
  if [ "${STARLING_MATRIX_PROBE_ONLY:-0}" = 1 ]; then
    if [ "${STARLING_MATRIX_FAIL_VERSION:-}" = "$version" ]; then
      echo "injected matrix failure at wasi-$version" >&2
      exit 97
    fi
    continue
  fi
  case "$MODE" in
    zig)
      prefix="$BUILD_ROOT/wasi-$version"
      "$ZIG" build install --prefix "$prefix" -Doptimize=ReleaseSmall \
        -Dhost-api="wasi-$version" "${PURE_FLAGS[@]}"
      runtime="$prefix/bin"
      grep -q "\"host-api\": \"wasi-$version\"" "$runtime/features.json"
      check_wit_versions "$version" "$runtime/feature-wit"
      check_wit_versions "$version" "$runtime/component-wit"
      component="$prefix/pure-shell.wasm"
      WABT="$ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
      WABT_COMPOSE_BIN="$runtime/wabt" \
      WASM_TOOLS_BIN="$runtime/wasm-tools" \
        "$runtime/componentize.sh" "$FIXTURE" -o "$component"
      native_component="$prefix/pure-native.wasm"
      native_metadata="$prefix/pure-native.metadata.json"
      native_cache="$SHARED_NATIVE_CACHE"
      WASM_TOOLS_BIN="$runtime/wasm-tools" "$runtime/starling-componentize" \
        --build-root "$ROOT" \
        --cache-dir "$native_cache" \
        --zig-bin "$ZIG" \
        --wasmtime-bin "$runtime/wasmtime" \
        --wasm-tools-bin "$runtime/wasm-tools" \
        --disable stdio,random,clocks,http,fetch-event \
        --metadata-out "$native_metadata" \
        --out "$native_component" \
        "$FIXTURE"
      # Native runtimes stay transaction-private; the cache records identity
      # keys while the resulting component proves the selected surface.
      test "$(find "$native_cache/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
        -eq "$version_index"
      check_component "$version" "$runtime" "$native_component"
      external_component="$prefix/pure-external-engine.wasm"
      external_metadata="$prefix/pure-external-engine.metadata.json"
      WASM_TOOLS_BIN="$runtime/wasm-tools" "$runtime/starling-componentize" \
        --engine "$runtime/starling-raw.wasm" \
        --wasmtime-bin "$runtime/wasmtime" \
        --wasm-tools-bin "$runtime/wasm-tools" \
        --metadata-out "$external_metadata" \
        --out "$external_component" \
        "$FIXTURE"
      check_component "$version" "$runtime" "$external_component"
      python3 - "$native_metadata" "$external_metadata" "$version" <<'PY'
import json
import re
import sys

native, external = [
    json.load(open(path, encoding="utf-8"))["provenance"]
    for path in sys.argv[1:3]
]
for provenance in (native, external):
    assert provenance["dispatch_world"]["name"] == "caller", provenance
    assert provenance["component_world"]["name"] == "bindings", provenance
    assert [(feature["name"], feature["enabled"])
            for feature in provenance["features"]] == [
        ("stdio", False),
        ("random", False),
        ("clocks", False),
        ("http", False),
        ("fetch-event", False),
    ], provenance
    for field in ("worlds_sha256", "features_sha256"):
        assert re.fullmatch(r"[0-9a-f]{64}", provenance[field]), provenance
    for world in ("dispatch_world", "component_world"):
        assert re.fullmatch(
            r"[0-9a-f]{64}", provenance[world]["wit_sha256"]
        ), provenance
for field in ("dispatch_world", "component_world",
              "worlds_sha256", "features", "features_sha256"):
    assert native[field] == external[field], (sys.argv[3], field)
PY
      ;;
    cmake)
      prefix="$BUILD_ROOT/wasi-$version"
      build_dir="$prefix/build"
      install_dir="$prefix/install root"
      HOST_API="wasi-$version" ZIG="$ZIG" cmake -S "$ROOT" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DFEATURE_STDIO=OFF \
        -DFEATURE_RANDOM=OFF \
        -DFEATURE_CLOCKS=OFF \
        -DFEATURE_HTTP=OFF \
        -DFEATURE_FETCH_EVENT=OFF
      cmake --build "$build_dir" --parallel 2 --target install
      runtime="$install_dir/bin"
      grep -q "\"host-api\": \"wasi-$version\"" "$runtime/features.json"
      check_wit_versions "$version" "$runtime/feature-wit"
      check_wit_versions "$version" "$runtime/component-wit"
      component="$prefix/pure-shell.wasm"
      WABT="$ROOT/tests/e2e/native-dispatch/wabt-shim.sh" \
      WABT_COMPOSE_BIN="$runtime/wabt" \
      WASM_TOOLS_BIN="$runtime/wasm-tools" \
        "$runtime/componentize.sh" "$FIXTURE" -o "$component"
      ctest --test-dir "$build_dir" -R '^componentize-exact-surface$' \
        --output-on-failure
      HOST_API="wasi-$version" ZIG="$ZIG" cmake -S "$ROOT" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DFEATURE_STDIO=ON \
        -DFEATURE_RANDOM=ON \
        -DFEATURE_CLOCKS=ON \
        -DFEATURE_HTTP=ON \
        -DFEATURE_FETCH_EVENT=ON
      cmake --build "$build_dir" --parallel 2 --target starling-raw.wasm \
        starling-feature-surface-helper
      ctest --test-dir "$build_dir" -R '^componentize-exact-surface$' \
        --output-on-failure
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
