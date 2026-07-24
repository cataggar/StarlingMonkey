#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZIG="${1:-${ZIG:-zig}}"
BUILD_ROOT="$ROOT/tests/feature-selection/.build/custom host acceptance"
HOST_PARENT="$BUILD_ROOT/host api fixtures"
CUSTOM_HOST="$HOST_PARENT/custom runtime api"
CUSTOM_HOST_REL="${CUSTOM_HOST#"$ROOT/"}"
FIXTURE="$ROOT/tests/feature-selection/fixtures/probe.js"

rm -rf "$BUILD_ROOT"
mkdir -p "$HOST_PARENT"
trap 'rm -rf "$BUILD_ROOT"' EXIT

cp -a "$ROOT/host-apis/wasi-0.2.10" "$CUSTOM_HOST"
cp -a "$ROOT/host-apis/wasi-0.2.0" "$HOST_PARENT/wasi-0.2.0"
cp -a "$ROOT/host-apis/wasi-0.2.3" "$HOST_PARENT/wasi-0.2.3"
find "$CUSTOM_HOST/wit" -maxdepth 1 -type f -name '*.wit' -print0 |
  xargs -0 sed -i \
    's/package local:bindings;/package custom:runtime-package;/'
cat > "$CUSTOM_HOST/wit/main.wit" <<'EOF'
package custom:runtime-package;

world custom-bindings {
  include wasi:cli/command@0.2.10;
  include wasi:http/proxy@0.2.10;
}
EOF

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$BUILD_ROOT/zig global cache}"

ZIG_PREFIX="$BUILD_ROOT/Zig install with spaces"
"$ZIG" build install \
  --prefix "$ZIG_PREFIX" \
  -Doptimize=ReleaseSmall \
  -Dhost-api="$CUSTOM_HOST_REL" \
  -Dhost-api-world=custom-bindings
ZIG_COMPONENT="$BUILD_ROOT/Zig custom component.wasm"
"$ZIG_PREFIX/bin/componentize.sh" "$FIXTURE" -o "$ZIG_COMPONENT"
"$ZIG_PREFIX/bin/wasm-tools" validate --features all "$ZIG_COMPONENT"
ZIG_WIT="$BUILD_ROOT/Zig custom component.wit"
"$ZIG_PREFIX/bin/wasm-tools" component wit "$ZIG_COMPONENT" -o "$ZIG_WIT"
grep -q '"host-api": "custom runtime api"' "$ZIG_PREFIX/bin/features.json"
grep -q '"component-world": "custom-bindings"' \
  "$ZIG_PREFIX/bin/features.json"

NATIVE_CACHE="$BUILD_ROOT/native componentizer cache"
NATIVE_COMPONENT="$BUILD_ROOT/native custom component.wasm"
NATIVE_METADATA="$BUILD_ROOT/native custom metadata.json"
WASM_TOOLS_BIN="$ZIG_PREFIX/bin/wasm-tools" \
  "$ZIG_PREFIX/bin/starling-componentize" \
  --build-root "$ROOT" \
  --cache-dir "$NATIVE_CACHE" \
  --zig-bin "$ZIG" \
  --wasmtime-bin "$ZIG_PREFIX/bin/wasmtime" \
  --wasm-tools-bin "$ZIG_PREFIX/bin/wasm-tools" \
  --metadata-out "$NATIVE_METADATA" \
  --out "$NATIVE_COMPONENT" \
  "$FIXTURE"
"$ZIG_PREFIX/bin/wasm-tools" validate --features all "$NATIVE_COMPONENT"
NATIVE_WIT="$BUILD_ROOT/native custom component.wit"
"$ZIG_PREFIX/bin/wasm-tools" component wit "$NATIVE_COMPONENT" -o "$NATIVE_WIT"

test "$(find "$NATIVE_CACHE/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
  -eq 1
RELEASE_RUNTIME="$ZIG_PREFIX/bin"
grep -q '"host-api": "custom runtime api"' "$RELEASE_RUNTIME/features.json"
grep -q '"component-world": "custom-bindings"' \
  "$RELEASE_RUNTIME/features.json"
python3 - "$RELEASE_RUNTIME/starling-raw.wasm" <<'PY'
import pathlib
import sys

module = pathlib.Path(sys.argv[1]).read_bytes()
assert b'"component_world":"custom-bindings"' in module
assert b'"component_world":"bindings"' not in module
PY

EXTERNAL_COMPONENT="$BUILD_ROOT/native external custom component.wasm"
EXTERNAL_METADATA="$BUILD_ROOT/native external custom metadata.json"
WASM_TOOLS_BIN="$ZIG_PREFIX/bin/wasm-tools" \
  "$ZIG_PREFIX/bin/starling-componentize" \
  --engine "$RELEASE_RUNTIME/starling-raw.wasm" \
  --wasmtime-bin "$ZIG_PREFIX/bin/wasmtime" \
  --wasm-tools-bin "$ZIG_PREFIX/bin/wasm-tools" \
  --metadata-out "$EXTERNAL_METADATA" \
  --out "$EXTERNAL_COMPONENT" \
  "$FIXTURE"
"$ZIG_PREFIX/bin/wasm-tools" validate --features all "$EXTERNAL_COMPONENT"
EXTERNAL_WIT="$BUILD_ROOT/native external custom component.wit"
"$ZIG_PREFIX/bin/wasm-tools" component wit "$EXTERNAL_COMPONENT" \
  -o "$EXTERNAL_WIT"
python3 - "$NATIVE_METADATA" "$EXTERNAL_METADATA" <<'PY'
import json
import re
import sys

native, external = [
    json.load(open(path, encoding="utf-8"))["provenance"]
    for path in sys.argv[1:]
]
for provenance in (native, external):
    assert provenance["dispatch_world"]["name"] == "caller", provenance
    assert provenance["component_world"]["name"] == "custom-bindings", provenance
    assert [(feature["name"], feature["enabled"])
            for feature in provenance["features"]] == [
        ("stdio", True),
        ("random", True),
        ("clocks", True),
        ("http", True),
        ("fetch-event", True),
    ], provenance
    for field in ("worlds_sha256", "features_sha256"):
        assert re.fullmatch(r"[0-9a-f]{64}", provenance[field]), provenance
    for world in ("dispatch_world", "component_world"):
        assert re.fullmatch(
            r"[0-9a-f]{64}", provenance[world]["wit_sha256"]
        ), provenance
for field in ("dispatch_world", "component_world",
              "worlds_sha256", "features", "features_sha256"):
    assert native[field] == external[field], (field, native[field], external[field])
PY
python3 "$ROOT/tests/feature-selection/check-production-surface.py" \
  "$ROOT/tests/feature-selection/reference/expected/import-surfaces.json" \
  defaults \
  "wasi:cli/run@0.2.10,wasi:http/incoming-handler@0.2.10" \
  "$ZIG_WIT" "$NATIVE_WIT" "$EXTERNAL_WIT"

CMAKE_BUILD="$BUILD_ROOT/CMake build with spaces"
CMAKE_INSTALL="$BUILD_ROOT/CMake install with spaces"
CMAKE_CONFIGURE_LOG="$BUILD_ROOT/CMake configure.log"
PARTIAL_BUILD="$BUILD_ROOT/CMake partial oracle"
if HOST_API="$CUSTOM_HOST" ZIG="$ZIG" cmake -S "$ROOT" -B "$PARTIAL_BUILD" \
    -DHOST_API_WORLD=custom-bindings \
    -DCUSTOM_FEATURE_SURFACE_CASE=defaults \
    >"$BUILD_ROOT/CMake partial oracle.out" \
    2>"$BUILD_ROOT/CMake partial oracle.err"
then
  echo "partial CUSTOM_FEATURE_SURFACE_* settings unexpectedly configured" >&2
  exit 1
fi
grep -q 'Custom exact-surface validation requires all of' \
  "$BUILD_ROOT/CMake partial oracle.out" \
  "$BUILD_ROOT/CMake partial oracle.err"

HOST_API="$CUSTOM_HOST" ZIG="$ZIG" cmake -S "$ROOT" -B "$CMAKE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$CMAKE_INSTALL" \
  -DHOST_API_WORLD=custom-bindings \
  -DUSE_WASM_OPT=OFF >"$CMAKE_CONFIGURE_LOG"
grep -q "Skipping built-in exact-surface oracle for custom host API" \
  "$CMAKE_CONFIGURE_LOG"
cmake --build "$CMAKE_BUILD" --parallel 2 --target install
CTEST_LIST="$BUILD_ROOT/CMake tests.list"
ctest --test-dir "$CMAKE_BUILD" -N >"$CTEST_LIST"
grep -q 'componentize-production-surface' "$CTEST_LIST"
! grep -q 'componentize-exact-surface' "$CTEST_LIST"
! grep -q 'wasi:cli/run@;' "$CMAKE_CONFIGURE_LOG" "$CTEST_LIST"
ctest --test-dir "$CMAKE_BUILD" \
  -R '^componentize-production-surface$' --output-on-failure

HOST_API="$CUSTOM_HOST" ZIG="$ZIG" cmake -S "$ROOT" -B "$CMAKE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$CMAKE_INSTALL" \
  -DHOST_API_WORLD=custom-bindings \
  -DUSE_WASM_OPT=OFF \
  -DCUSTOM_FEATURE_SURFACE_ORACLE="$ROOT/tests/feature-selection/reference/expected/import-surfaces.json" \
  -DCUSTOM_FEATURE_SURFACE_CASE=defaults \
  -DCUSTOM_HOST_API_VERSION=0.2.10 \
  -DCUSTOM_FEATURE_SURFACE_EXPECTED_EXPORTS=wasi:cli/run@0.2.10,wasi:http/incoming-handler@0.2.10 \
  >"$BUILD_ROOT/CMake exact oracle configure.log"
CTEST_EXACT_LIST="$BUILD_ROOT/CMake exact tests.list"
ctest --test-dir "$CMAKE_BUILD" -N >"$CTEST_EXACT_LIST"
grep -q 'componentize-exact-surface' "$CTEST_EXACT_LIST"
! grep -q 'componentize-production-surface' "$CTEST_EXACT_LIST"
ctest --test-dir "$CMAKE_BUILD" \
  -R '^componentize-exact-surface$' --output-on-failure

CMAKE_COMPONENT="$BUILD_ROOT/CMake custom component.wasm"
"$CMAKE_INSTALL/bin/componentize.sh" "$FIXTURE" -o "$CMAKE_COMPONENT"
"$CMAKE_INSTALL/bin/wasm-tools" validate --features all "$CMAKE_COMPONENT"
"$CMAKE_INSTALL/bin/wasm-tools" component wit "$CMAKE_COMPONENT" |
  grep -q 'export wasi:cli/run@0.2.10;'
grep -q '"host-api": "custom runtime api"' \
  "$CMAKE_INSTALL/bin/features.json"
grep -q '"component-world": "custom-bindings"' \
  "$CMAKE_INSTALL/bin/features.json"

echo "custom non-bindings host Zig/CMake production and exact-oracle tests passed"
