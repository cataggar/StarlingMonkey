#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
zig="${1:?usage: run.sh /path/to/zig [/path/to/wasmtime]}"
wasmtime="${2:-wasmtime}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$zig" c++ --target=wasm32-wasi -std=gnu++23 -Wall -Werror \
  -Wno-error=unused-result -Wno-unused-parameter -Qunused-arguments \
  -fno-rtti -fno-exceptions \
  -include "$root/deps/sm-obj-zig/dist/include/js-confdefs.h" \
  -I"$root/include" \
  -isystem "$root/deps/sm-obj-zig/dist/include" \
  "$root/tests/js-heap-limit/test.cpp" \
  -o "$tmp/js-heap-limit-test.wasm"
"$wasmtime" run "$tmp/js-heap-limit-test.wasm"

echo "js heap limit tests passed"
