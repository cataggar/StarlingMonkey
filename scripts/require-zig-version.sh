#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <zig>" >&2
  exit 2
fi

required='0.17.0-dev.902+7255f3e72'
actual="$("$1" version 2>/dev/null)" || {
  echo "error: failed to execute Zig at $1" >&2
  exit 1
}
if [ "$actual" != "$required" ]; then
  echo "error: StarlingMonkey v0.4 requires Zig $required; found $actual" >&2
  exit 1
fi
