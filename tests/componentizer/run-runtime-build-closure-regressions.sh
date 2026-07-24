#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <closure-check> <runtime-build-inputs> <zig>" >&2
  exit 2
fi

CHECK="$(realpath "$1")"
MANIFEST="$(realpath "$2")"
ZIG="$3"
if [[ "$ZIG" != */* ]]; then
  ZIG="$(command -v -- "$ZIG")"
fi
ZIG="$(realpath "$ZIG")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.runtime-closure-regressions"
RUNNER_ONE="$SCRATCH/runner one"
RUNNER_TWO="$SCRATCH/runner two"
PROJECT="$SCRATCH/project"
FIXTURE="$SCRATCH/clean checkout"
LOG="$SCRATCH/zig paths.log"

rm -rf "$SCRATCH"
mkdir -p "$RUNNER_ONE" "$PROJECT"
trap 'rm -rf "$SCRATCH"' EXIT

zig_lib="$("$ZIG" env | sed -n 's/^    \.lib_dir = "\(.*\)",$/\1/p')"
test -d "$zig_lib"
cp "$ZIG" "$RUNNER_ONE/zig"
ln -s "$zig_lib" "$RUNNER_ONE/lib"

cat > "$PROJECT/build.zig" <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const run = b.addSystemCommand(&.{ "bash", "check-zig.sh" });
    run.addArg("zig");
    b.getInstallStep().dependOn(&run.step);
}
EOF
cat > "$PROJECT/build.zig.zon" <<'EOF'
.{
    .name = .runtime_closure_cache_regression,
    .version = "0.0.0",
    .fingerprint = 0x766f7566d68df68a,
    .minimum_zig_version = "0.17.0",
    .paths = .{ "build.zig", "build.zig.zon", "check-zig.sh" },
}
EOF
cat > "$PROJECT/check-zig.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
zig="${STARLING_ZIG:-$1}"
resolved="$(realpath "$(command -v -- "$zig")")"
test "$("$resolved" version)" = '0.17.0-dev.902+7255f3e72'
printf '%s\n' "$resolved" >> "$ZIG_PATH_LOG"
EOF
chmod +x "$PROJECT/check-zig.sh"

cache="$SCRATCH/restored local cache"
global_cache="$SCRATCH/restored global cache"
(
  cd "$PROJECT"
  PATH="$RUNNER_ONE:$PATH" STARLING_ZIG="$RUNNER_ONE/zig" ZIG_PATH_LOG="$LOG" \
    "$RUNNER_ONE/zig" build --cache-dir "$cache" --global-cache-dir "$global_cache"
)
mv "$RUNNER_ONE" "$RUNNER_TWO"
(
  cd "$PROJECT"
  PATH="$RUNNER_TWO:$PATH" STARLING_ZIG="$RUNNER_TWO/zig" ZIG_PATH_LOG="$LOG" \
    "$RUNNER_TWO/zig" build --cache-dir "$cache" --global-cache-dir "$global_cache"
)
mapfile -t resolved_paths < "$LOG"
test "${#resolved_paths[@]}" -eq 2
test "${resolved_paths[1]}" = "$RUNNER_TWO/zig"

mkdir -p "$FIXTURE/tools/componentizer"
cp "$MANIFEST" "$FIXTURE/tools/componentizer/runtime-build-inputs.txt"
while IFS= read -r raw || [ -n "$raw" ]; do
  path="${raw#"${raw%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  if [ -z "$path" ] || [[ "$path" == \#* ]]; then
    continue
  fi
  if [ -d "$ROOT/$path" ]; then
    mkdir -p "$FIXTURE/$path"
  else
    mkdir -p "$(dirname "$FIXTURE/$path")"
    printf 'fixture\n' > "$FIXTURE/$path"
  fi
done < "$MANIFEST"

STARLING_ZIG="$RUNNER_TWO/zig" \
  "$CHECK" "$FIXTURE/tools/componentizer/runtime-build-inputs.txt" zig
rm "$FIXTURE/deps/sm-obj-zig-aot/dist/libspidermonkey.a"
if STARLING_ZIG="$RUNNER_TWO/zig" \
    "$CHECK" "$FIXTURE/tools/componentizer/runtime-build-inputs.txt" zig \
    >"$SCRATCH/missing.log" 2>&1; then
  echo "FAIL: incomplete clean-runner runtime closure was accepted" >&2
  exit 1
fi
grep -Fq \
  'missing descriptor input: deps/sm-obj-zig-aot/dist/libspidermonkey.a' \
  "$SCRATCH/missing.log"

echo "Clean-runner Zig cache relocation and runtime closure checks passed"
