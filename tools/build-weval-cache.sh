#!/usr/bin/env bash
set -euo pipefail
unset STARLINGMONKEY_CONFIG

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <weval> <runtime> <script> <cache>" >&2
  exit 2
fi

weval="$1"
runtime="$2"
script="$3"
cache="$4"
work_dir="$(dirname "$cache")"
script_arg="./$(basename "$script")"
seed_output="$cache.seed.wasm"
verify_output="$cache.verify.wasm"

rm -f "$cache" "$seed_output" "$verify_output"
trap 'rm -f "$seed_output" "$verify_output"' EXIT

(
  cd "$work_dir"
  printf '%s\n' "$script_arg" |
    "$weval" weval --dir . --show-stats --cache "$cache" -w \
      -i "$runtime" -o "$seed_output"
)
test -s "$cache"

# Weval 0.4.1 has no separate cache-seal inspector. Reading the generated
# cache back in read-only mode validates its format/version against the exact
# sibling runtime that the installed wrapper will use.
(
  cd "$work_dir"
  printf '%s\n' "$script_arg" |
    "$weval" weval --dir . --cache-ro "$cache" -w \
      -i "$runtime" -o "$verify_output"
)
test -s "$verify_output"
