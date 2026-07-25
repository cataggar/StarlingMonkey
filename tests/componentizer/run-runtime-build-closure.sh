#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <runtime-build-inputs> <zig>" >&2
  exit 2
fi

MANIFEST="$(realpath "$1")"
ROOT="$(cd "$(dirname "$MANIFEST")/../.." && pwd)"
ZIG="${STARLING_ZIG:-$2}"
if [[ "$ZIG" != */* ]]; then
  ZIG="$(command -v -- "$ZIG")" || {
    echo "runtime closure: Zig is not available: $ZIG" >&2
    exit 1
  }
fi
ZIG="$(realpath "$ZIG")"

required_version='0.17.0-dev.902+7255f3e72'
actual_version="$("$ZIG" version 2>/dev/null)" || {
  echo "runtime closure: failed to execute Zig at $ZIG" >&2
  exit 1
}
if [ "$actual_version" != "$required_version" ]; then
  echo "runtime closure: requires Zig $required_version; found $actual_version" >&2
  exit 1
fi

declare -A selected=()
while IFS= read -r raw || [ -n "$raw" ]; do
  path="${raw#"${raw%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  if [ -z "$path" ] || [[ "$path" == \#* ]]; then
    continue
  fi
  selected["$path"]=1
  candidate="$ROOT/$path"
  if [ ! -e "$candidate" ]; then
    echo "runtime closure: missing descriptor input: $path" >&2
    exit 1
  fi
  if [ -d "$candidate" ]; then
    broken="$(find "$candidate" -xtype l -print -quit)"
    if [ -n "$broken" ]; then
      echo "runtime closure: broken descriptor input symlink: ${broken#"$ROOT/"}" >&2
      exit 1
    fi
  elif [ ! -f "$candidate" ] || [ ! -s "$candidate" ]; then
    echo "runtime closure: unsupported descriptor input: $path" >&2
    exit 1
  fi
done < "$MANIFEST"

required_aot=(
  deps/sm-obj-zig-aot/dist/include
  deps/sm-obj-zig-aot/dist/libspidermonkey.a
  deps/sm-obj-zig-aot/js/src/js-confdefs.h
)
for path in "${required_aot[@]}"; do
  if [ -z "${selected[$path]:-}" ]; then
    echo "runtime closure: AOT build input is not selected: $path" >&2
    exit 1
  fi
done

echo "Runtime build closure and exact Zig toolchain are available"
