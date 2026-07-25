#!/usr/bin/env bash

resolve_executable() {
  local executable="$1"
  if [[ "$executable" != */* ]]; then
    executable="$(command -v -- "$executable")" || {
      echo "executable not found on PATH: $1" >&2
      return 127
    }
  fi
  realpath -- "$executable"
}
