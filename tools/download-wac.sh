#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 <url> <sha256> <output> [cmake]" >&2
  exit 2
fi

url="$1"
expected="$2"
output="$3"
cmake_bin="${4:-${CMAKE_COMMAND:-}}"

checksum() {
  if [ -n "$cmake_bin" ] && [ -x "$cmake_bin" ]; then
    "$cmake_bin" -E sha256sum "$1" | awk '{print $1}'
  elif command -v cmake >/dev/null 2>&1; then
    cmake -E sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "no portable SHA-256 implementation found (tried cmake, openssl, shasum)" >&2
    return 1
  fi
}

if [ -f "$output" ] &&
    [ "$(checksum "$output")" = "$expected" ]; then
  chmod +x "$output"
  exit 0
fi

mkdir -p "$(dirname "$output")"
partial="$output.part"
trap 'rm -f "$partial"' EXIT
curl --fail --location --silent --show-error "$url" -o "$partial"
actual="$(checksum "$partial")"
if [ "$actual" != "$expected" ]; then
  echo "wac sha256 mismatch: expected $expected, got $actual" >&2
  exit 1
fi
chmod +x "$partial"
mv "$partial" "$output"
trap - EXIT
