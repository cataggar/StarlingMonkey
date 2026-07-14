#!/usr/bin/env bash
#
# Build (and cache) a `wabt` CLI binary containing the reactor-export-lifting
# fix from cataggar/wabt#331 ("component new: lift typed reactor exports"),
# commit 9bb32091fbf7598921cfa364a814015ac4918777 on cataggar/wabt's `main`.
#
# Why this exists: as of this harness being written, that fix has not yet
# been included in any published cataggar/wabt release binary (the latest
# release predates the commit), so the runtime bridge harness
# (run-bridge-tests.sh) needs a binary built from source. Without this fix,
# `wabt component new` rejects the reactor-shaped core module StarlingMonkey
# produces with `error: splicing adapters: UnsupportedAdapterShape`.
#
# This also applies two small local patches (tests/compat/runtime/wabt-patches/)
# that are NOT upstream fixes -- they only adapt cataggar/wabt's Zig source to
# build under the specific pinned Zig toolchain
# (zig-x86_64-linux-0.17.0-dev.902+7255f3e72) this repository's build.zig.zon
# requires, which removed the generic `@Type` builtin (replaced by
# `@Int`/`@Enum`/etc.) and changed `std.builtin.Type.Enum` from a `.fields`
# array to parallel `.field_names`/`.field_values` arrays. They carry no
# behavior change to wabt itself.
#
# Usage: tests/compat/runtime/build-wabt.sh
#   Honors $ZIG (defaults to the pinated toolchain path documented in
#   README.md / AGENTS.md) and $WABT_CACHE_DIR (defaults to
#   tests/compat/runtime/.wabt-cache). Idempotent: skips the clone+build if
#   a working binary for the pinned commit is already cached.
# Prints the path to the built `wabt` binary on stdout as its only stdout
# output, so it can be captured with `WABT="$(build-wabt.sh)"`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

WABT_COMMIT="9bb32091fbf7598921cfa364a814015ac4918777"
WABT_REPO="https://github.com/cataggar/wabt.git"
WABT_CACHE_DIR="${WABT_CACHE_DIR:-$HERE/.wabt-cache}"
WABT_SRC_DIR="$WABT_CACHE_DIR/src"
WABT_BIN="$WABT_SRC_DIR/zig-out/bin/wabt"
STAMP="$WABT_CACHE_DIR/.built-commit"

ZIG="${ZIG:-}"
if [ -z "$ZIG" ]; then
  echo "error: \$ZIG must point at the pinned Zig binary (see README.md/AGENTS.md" >&2
  echo "for the exact required version); build-wabt.sh will not guess one." >&2
  exit 1
fi
if [ ! -x "$ZIG" ]; then
  echo "error: \$ZIG ('$ZIG') is not an executable file" >&2
  exit 1
fi

if [ -x "$WABT_BIN" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$WABT_COMMIT" ]; then
  echo "$WABT_BIN"
  exit 0
fi

echo "build-wabt.sh: building wabt @ $WABT_COMMIT (cataggar/wabt#331 fix, not yet in a release) ..." >&2

if [ ! -d "$WABT_SRC_DIR/.git" ]; then
  rm -rf "$WABT_SRC_DIR"
  mkdir -p "$WABT_CACHE_DIR"
  git clone --quiet "$WABT_REPO" "$WABT_SRC_DIR" >&2
fi

git -C "$WABT_SRC_DIR" fetch --quiet origin "$WABT_COMMIT" >&2 || true
git -C "$WABT_SRC_DIR" checkout --quiet --force "$WABT_COMMIT" >&2
git -C "$WABT_SRC_DIR" clean --quiet -fdx >&2

for patch in "$HERE"/wabt-patches/*.patch; do
  echo "build-wabt.sh: applying $(basename "$patch")" >&2
  git -C "$WABT_SRC_DIR" apply "$patch"
done

(
  cd "$WABT_SRC_DIR"
  unset ZIG_LOCAL_CACHE_DIR
  export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"
  # Deliberately the default (Debug) optimize mode, not -Doptimize=ReleaseFast:
  # a ReleaseFast build of this exact commit+patch combination was observed
  # (while developing this script) to silently produce components missing
  # their reactor exports (no error, just a wrong `wabt component new`
  # output) -- almost certainly a miscompilation/UB-exposure specific to
  # this stripped-down Zig fork's optimizer, not a functional issue with
  # cataggar/wabt#331 itself (the Debug build of the identical source is
  # correct, as verified against tests/fixtures/js-dispatch.js and every
  # positive tests/compat fixture). Since this binary is a build-time-only
  # host tool (not shipped/measured for wasm performance), the larger/slower
  # Debug binary is the safe choice here.
  "$ZIG" build >&2
)

if [ ! -x "$WABT_BIN" ]; then
  echo "error: build succeeded but $WABT_BIN was not produced" >&2
  exit 1
fi

echo "$WABT_COMMIT" > "$STAMP"
echo "$WABT_BIN"
