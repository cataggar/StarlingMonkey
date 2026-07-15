#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <zig>" >&2
  exit 2
fi

ZIG="$(realpath "$1")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.absolute-wit-scratch"
WIT_A="$SCRATCH/WIT tree with spaces A"
WIT_B="$SCRATCH/WIT tree with spaces B"
CACHE="$SCRATCH/local-cache"
GLOBAL_CACHE="$SCRATCH/global-cache"
INSTALL="$SCRATCH/install"
rm -rf "$SCRATCH"
mkdir -p "$WIT_A/deps/helper" "$WIT_B/deps/helper"
trap 'rm -rf "$SCRATCH"' EXIT

write_package() {
  local root="$1" function_name="$2"
  cat > "$root/world.wit" <<EOF
package test:absolute-inputs;

world js-exports {
    import test:helper/api;
    export $function_name: func() -> u32;
}
EOF
  cat > "$root/deps/helper/helper.wit" <<'EOF'
package test:helper;

interface api {
    value: func() -> u32;
}
EOF
  cat > "$root/types.wit" <<'EOF'
package test:absolute-inputs;

interface local-types {
    record point {
        x: u32,
        y: u32,
    }
}
EOF
}

run_bindgen() {
  local wit="$1"
  (
    cd "$ROOT"
    ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE" \
      "$ZIG" build wit-bindgen \
        --cache-dir "$CACHE" \
        --prefix "$INSTALL" \
        -Ddispatch-wit="$wit" \
        -Ddispatch-world=js-exports
  )
}

write_package "$WIT_A" first
run_bindgen "$WIT_A"
BINDINGS="$INSTALL/wit-bindgen/component_bindings.zig"
test -s "$BINDINGS"
first_hash="$(sha256sum "$BINDINGS" | cut -d' ' -f1)"

write_package "$WIT_A" second
run_bindgen "$WIT_A"
second_hash="$(sha256sum "$BINDINGS" | cut -d' ' -f1)"
test "$first_hash" != "$second_hash"
grep -Fq 'second' "$BINDINGS"

write_package "$WIT_B" second
touch "$WIT_B/types.wit" "$WIT_B/world.wit" \
  "$WIT_B/deps/helper/helper.wit"
run_bindgen "$WIT_B"
third_hash="$(sha256sum "$BINDINGS" | cut -d' ' -f1)"
test "$second_hash" = "$third_hash"

echo "absolute WIT input tracking test passed"
