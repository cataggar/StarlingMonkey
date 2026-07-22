#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <runtime-bin-dir>" >&2
  exit 2
fi

BIN="$(cd "$1" && pwd)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/tests/runtime-eval/.scratch"
GENERAL="$WORK/general starling.wasm"
SCRIPT="$WORK/script path with spaces.js"

rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

"$BIN/componentize.sh" -o "$GENERAL"
"$BIN/wasm-tools" validate --features all "$GENERAL"
"$BIN/wasm-tools" component wit "$GENERAL" |
  grep -q 'import wasi:cli/environment@'

eval_output="$("$BIN/wasmtime" run -S cli -S http "$GENERAL" \
  -e 'console.log(`GENERAL_EVAL_OK`)' 2>&1)"
grep -q 'GENERAL_EVAL_OK' <<<"$eval_output"

printf 'console.log(`GENERAL_SCRIPT_OK`);\n' > "$SCRIPT"
script_output="$("$BIN/wasmtime" run -S cli -S http --dir "$WORK" \
  "$GENERAL" "$SCRIPT" 2>&1)"
grep -q 'GENERAL_SCRIPT_OK' <<<"$script_output"

env_output="$(STARLINGMONKEY_CONFIG='-e "console.log(`GENERAL_ENV_OK`)"' \
  "$BIN/wasmtime" run -S cli -S http -S inherit-env "$GENERAL" 2>&1)"
grep -q 'GENERAL_ENV_OK' <<<"$env_output"

override_output="$(STARLINGMONKEY_CONFIG='-e "console.log(`WRONG_ENV_VALUE`)"' \
  "$BIN/wasmtime" run -S cli -S http -S inherit-env "$GENERAL" \
    -e 'console.log(`GENERAL_ARGS_OVERRIDE_ENV_OK`)' 2>&1)"
grep -q 'GENERAL_ARGS_OVERRIDE_ENV_OK' <<<"$override_output"
! grep -q 'WRONG_ENV_VALUE' <<<"$override_output"

echo "general runtime -e, script path, and STARLINGMONKEY_CONFIG tests passed"
