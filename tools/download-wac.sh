#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <url> <sha256> <output>" >&2
  exit 2
fi

url="$1"
expected="$2"
output="$3"

if [ -f "$output" ] &&
    [ "$(sha256sum "$output" | cut -d' ' -f1)" = "$expected" ]; then
  chmod +x "$output"
  exit 0
fi

mkdir -p "$(dirname "$output")"
partial="$output.part"
trap 'rm -f "$partial"' EXIT
curl --fail --location --silent --show-error "$url" -o "$partial"
actual="$(sha256sum "$partial" | cut -d' ' -f1)"
if [ "$actual" != "$expected" ]; then
  echo "wac sha256 mismatch: expected $expected, got $actual" >&2
  exit 1
fi
chmod +x "$partial"
mv "$partial" "$output"
trap - EXIT
