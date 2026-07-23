#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <starling-aot-cache> <package-script>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/harness-helpers.sh"
CACHE_TOOL="$(resolve_executable "$1")"
PACKAGE_SCRIPT="$(resolve_executable "$2")"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.aot-package-race"
BARRIER="$SCRATCH/validation barrier"
RELEASE="$SCRATCH/release"
PRIMER="$SCRATCH/primer.js"

rm -rf "$SCRATCH"
mkdir -p "$BARRIER" "$RELEASE"
trap 'rm -rf "$SCRATCH"' EXIT
printf 'function main() {}\n' > "$PRIMER"

make_bundle() {
  local label="$1"
  local prefix="$SCRATCH/source $label"
  local bin="$prefix/bin"
  local weval_package="$prefix/weval-package"
  mkdir -p "$bin" "$weval_package"
  printf 'engine-%s\n' "$label" > "$bin/starling-raw.wasm"
  cp "$CACHE_TOOL" "$bin/starling-aot-cache"
  cat > "$weval_package/weval" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cp "$weval_package/weval" "$bin/weval"
  cat > "$bin/wasm-tools" <<EOF
#!/usr/bin/env bash
set -euo pipefail
test "\$1 \$2 \$3" = "validate --features all"
mkdir -p "$BARRIER/$label.ready"
while [ ! -d "$BARRIER/A.ready" ] || [ ! -d "$BARRIER/B.ready" ]; do
  sleep 0.01
done
EOF
  chmod +x "$weval_package/weval" "$bin/weval" "$bin/wasm-tools"
  python3 - "$bin/starling-ics.wevalcache.raw" \
    "$bin/starling-raw.wasm" "$label" <<'PY'
import hashlib
import sqlite3
import sys

with open(sys.argv[2], "rb") as engine:
    engine_hash = hashlib.sha256(engine.read()).digest()
db = sqlite3.connect(sys.argv[1])
db.execute("""create table weval_cache(
    module_hash blob not null,
    key blob not null,
    result blob not null,
    created_time integer not null
)""")
label = sys.argv[3].encode()
db.executemany(
    "insert into weval_cache values (?, ?, ?, ?)",
    [
        (engine_hash, b"key-" + label, b"result-" + label, 101),
        (
            engine_hash,
            b"\x00\xfflarge-key-" + label,
            bytes(range(256)) * 32 + label,
            202,
        ),
        (engine_hash, b"", b"", 303),
    ],
)
db.execute("create index idx on weval_cache(module_hash, key)")
db.commit()
db.close()
PY
  "$bin/starling-aot-cache" seal \
    --engine "$bin/starling-raw.wasm" \
    --weval "$weval_package/weval" \
    --cache "$bin/starling-ics.wevalcache.raw" \
    --cache-out "$bin/starling-ics.wevalcache" \
    --primer "$PRIMER" \
    --feature-abi "package-race-$label" \
    --out "$bin/starling-ics.wevalcache.manifest"
  "$bin/starling-aot-cache" seal \
    --engine "$bin/starling-raw.wasm" \
    --weval "$weval_package/weval" \
    --cache "$bin/starling-ics.wevalcache.raw" \
    --cache-out "$bin/starling-ics.wevalcache.repeat" \
    --primer "$PRIMER" \
    --feature-abi "package-race-$label" \
    --out "$bin/starling-ics.wevalcache.repeat.manifest"
  cmp "$bin/starling-ics.wevalcache" \
    "$bin/starling-ics.wevalcache.repeat"
  cmp "$bin/starling-ics.wevalcache.manifest" \
    "$bin/starling-ics.wevalcache.repeat.manifest"
  python3 - "$bin/starling-ics.wevalcache.raw" \
    "$bin/starling-ics.wevalcache" <<'PY'
import sqlite3
import sys

raw = sqlite3.connect(sys.argv[1])
expected = [
    (module_hash, key, result, 0)
    for module_hash, key, result in raw.execute(
        "select module_hash, key, result "
        "from weval_cache order by module_hash, key, result"
    )
]
raw.close()

sealed = sqlite3.connect(sys.argv[2])
actual = list(sealed.execute(
    "select module_hash, key, result, created_time "
    "from weval_cache order by module_hash, key, result"
))
assert len(actual) == 3
assert actual == expected
assert sealed.execute("pragma integrity_check").fetchone() == ("ok",)
sealed.close()
PY
}

make_bundle A
make_bundle B
PREFIX_A="$SCRATCH/source A"
PREFIX_B="$SCRATCH/source B"
test "$(sha256sum "$PREFIX_A/bin/starling-ics.wevalcache" | cut -d ' ' -f 1)" != \
  "$(sha256sum "$PREFIX_B/bin/starling-ics.wevalcache" | cut -d ' ' -f 1)"

wait_for_hook() {
  local ready="$1"
  for _ in $(seq 1 10000); do
    test -e "$ready" && return
    sleep 0.001
  done
  echo "FAIL: timed out waiting for $ready" >&2
  for log in "$SCRATCH"/*.log; do
    [ -f "$log" ] && {
      echo "--- $log" >&2
      cat "$log" >&2
    }
  done
  exit 1
}

assert_bundle() {
  local target="$1" owner
  if cmp -s "$target/starling-raw-weval.wasm" \
    "$PREFIX_A/bin/starling-raw.wasm"; then
    owner="$PREFIX_A"
  elif cmp -s "$target/starling-raw-weval.wasm" \
    "$PREFIX_B/bin/starling-raw.wasm"; then
    owner="$PREFIX_B"
  else
    echo "FAIL: published engine belongs to neither source bundle" >&2
    exit 1
  fi
  cmp "$target/starling-ics.wevalcache" \
    "$owner/bin/starling-ics.wevalcache"
  cmp "$target/starling-ics.wevalcache.manifest" \
    "$owner/bin/starling-ics.wevalcache.manifest"
  "$owner/bin/starling-aot-cache" validate \
    --engine "$target/starling-raw-weval.wasm" \
    --weval "$owner/weval-package/weval" \
    --cache "$target/starling-ics.wevalcache" \
    --manifest "$target/starling-ics.wevalcache.manifest"
}

FIRST_BUNDLE_TARGET="$SCRATCH/first bundle target"
FIRST_BUNDLE_HOOK="$SCRATCH/first-bundle-hook"
mkdir "$FIRST_BUNDLE_HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$FIRST_BUNDLE_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-bundle-stage \
  "$PREFIX_A/bin/starling-aot-cache" publish-bundle \
    --target "$FIRST_BUNDLE_TARGET" \
    --engine "$PREFIX_A/bin/starling-raw.wasm" \
    --engine-name starling-raw-weval.wasm \
    --weval "$PREFIX_A/weval-package/weval" \
    --cache "$PREFIX_A/bin/starling-ics.wevalcache" \
    --manifest "$PREFIX_A/bin/starling-ics.wevalcache.manifest" \
    >"$SCRATCH/first-bundle.log" 2>&1 &
first_bundle_pid=$!
wait_for_hook "$FIRST_BUNDLE_HOOK/before-bundle-stage.ready"
FIRST_BUNDLE_JOURNAL="$(
  find "$SCRATCH" -maxdepth 1 \
    -name '.starling-aot-publish-*.journal' -print -quit
)"
test -n "$FIRST_BUNDLE_JOURNAL"
FIRST_BUNDLE_RECORD="$SCRATCH/first-bundle-record"
cp "$FIRST_BUNDLE_JOURNAL" "$FIRST_BUNDLE_RECORD"
kill -KILL "$first_bundle_pid"
wait "$first_bundle_pid" 2>/dev/null || true
python3 - "$PREFIX_A/bin/starling-aot-cache" "$FIRST_BUNDLE_TARGET" \
  "$FIRST_BUNDLE_JOURNAL" "$FIRST_BUNDLE_RECORD" <<'PY'
import subprocess
import sys

tool, target, journal, record_path = sys.argv[1:]
record = open(record_path, "rb").read()
header_size = 56
payload_size = int.from_bytes(record[16:20], "little")
baseline = record[:header_size + payload_size]

def recover(data, label):
    with open(journal, "wb") as output:
        output.write(data)
        output.flush()
    result = subprocess.run(
        [tool, "recover-bundle", "--target", target],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise AssertionError(
            f"{label}: {result.stderr.decode(errors='replace')}"
        )

for length in range(len(baseline) + 1):
    recover(baseline[:length], f"bundle baseline byte {length}")

slot = 64 * 1024
assert len(record) > slot
for length in range(slot, len(record) + 1):
    recover(record[:length], f"bundle first record byte {length - slot}")
PY
"$PREFIX_A/bin/starling-aot-cache" recover-bundle \
  --target "$FIRST_BUNDLE_TARGET"
echo "AOT bundle first-journal-write interruption matrix passed"

HOOK_A="$SCRATCH/publisher-A-hook"
HOOK_B="$SCRATCH/publisher-B-hook"
mkdir "$HOOK_A" "$HOOK_B"
mkdir -p "$BARRIER/A.ready" "$BARRIER/B.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK_A" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-bundle-switch \
  "$PACKAGE_SCRIPT" "$PREFIX_A" "$RELEASE" \
    > "$SCRATCH/package-A.log" 2>&1 &
pid_a=$!
wait_for_hook "$HOOK_A/before-bundle-switch.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$HOOK_B" \
STARLING_AOT_CACHE_TEST_WAIT_AT=bundle-prepared \
STARLING_AOT_CACHE_TEST_NOTIFY_AT=bundle-lock-attempt \
  "$PACKAGE_SCRIPT" "$PREFIX_B" "$RELEASE" \
    > "$SCRATCH/package-B.log" 2>&1 &
pid_b=$!
wait_for_hook "$HOOK_B/bundle-lock-attempt.ready"
test ! -e "$HOOK_B/bundle-prepared.ready"
touch "$HOOK_A/before-bundle-switch.continue"
wait "$pid_a"
wait_for_hook "$HOOK_B/bundle-prepared.ready"
touch "$HOOK_B/bundle-prepared.continue"
wait "$pid_b"
grep -Fq "generation $(sed -n 's/^key=//p' \
  "$PREFIX_A/bin/starling-ics.wevalcache.manifest")" \
  "$SCRATCH/package-A.log"
grep -Fq "generation $(sed -n 's/^key=//p' \
  "$PREFIX_B/bin/starling-ics.wevalcache.manifest")" \
  "$SCRATCH/package-B.log"
assert_bundle "$RELEASE"
cmp "$RELEASE/starling-raw-weval.wasm" "$PREFIX_B/bin/starling-raw.wasm"

BUNDLE_STAGE_HOOK="$SCRATCH/bundle-stage-race-hook"
mkdir "$BUNDLE_STAGE_HOOK"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$BUNDLE_STAGE_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-bundle-switch \
  "$PACKAGE_SCRIPT" "$PREFIX_A" "$RELEASE" \
    >"$SCRATCH/bundle-stage-race.log" 2>&1 &
bundle_stage_pid=$!
wait_for_hook "$BUNDLE_STAGE_HOOK/before-bundle-switch.ready"
bundle_stage="$(find "$SCRATCH" -maxdepth 1 \
  -name '.release.starling-aot-generation-*' -print -quit)"
test -n "$bundle_stage"
mv "$bundle_stage" "$bundle_stage.validated"
mkdir "$bundle_stage"
printf 'unvalidated bundle\n' > "$bundle_stage/unvalidated"
touch "$BUNDLE_STAGE_HOOK/before-bundle-switch.continue"
if wait "$bundle_stage_pid"; then
  echo "FAIL: replaced unvalidated bundle stage was published" >&2
  exit 1
fi
grep -Fq SealPathRace "$SCRATCH/bundle-stage-race.log"
assert_bundle "$RELEASE"
cmp "$RELEASE/starling-raw-weval.wasm" "$PREFIX_B/bin/starling-raw.wasm"
rm -rf "$bundle_stage"
mv "$bundle_stage.validated" "$bundle_stage"
"$PREFIX_A/bin/starling-aot-cache" recover-bundle --target "$RELEASE"

BUNDLE_PARENT_ROOT="$SCRATCH/bundle parent root"
BUNDLE_PARENT="$BUNDLE_PARENT_ROOT/parent"
BUNDLE_PARENT_TARGET="$BUNDLE_PARENT/release"
BUNDLE_PARENT_HOOK="$SCRATCH/bundle-parent-race-hook"
mkdir -p "$BUNDLE_PARENT" "$BUNDLE_PARENT_HOOK"
"$PACKAGE_SCRIPT" "$PREFIX_A" "$BUNDLE_PARENT_TARGET" \
  >"$SCRATCH/bundle-parent-initial.log" 2>&1
STARLING_AOT_CACHE_TEST_HOOK_DIR="$BUNDLE_PARENT_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-bundle-switch \
  "$PACKAGE_SCRIPT" "$PREFIX_B" "$BUNDLE_PARENT_TARGET" \
    >"$SCRATCH/bundle-parent-race.log" 2>&1 &
bundle_parent_pid=$!
wait_for_hook "$BUNDLE_PARENT_HOOK/before-bundle-switch.ready"
mv "$BUNDLE_PARENT" "$BUNDLE_PARENT.retained"
mkdir "$BUNDLE_PARENT"
printf 'unvalidated parent\n' > "$BUNDLE_PARENT/unvalidated"
rm -rf "$BUNDLE_PARENT"
mv "$BUNDLE_PARENT.retained" "$BUNDLE_PARENT"
touch "$BUNDLE_PARENT_HOOK/before-bundle-switch.continue"
wait "$bundle_parent_pid"
assert_bundle "$BUNDLE_PARENT_TARGET"
cmp "$BUNDLE_PARENT_TARGET/starling-raw-weval.wasm" \
  "$PREFIX_B/bin/starling-raw.wasm"

CRASH_RELEASE="$SCRATCH/crash release"
mkdir "$CRASH_RELEASE"
"$PACKAGE_SCRIPT" "$PREFIX_A" "$CRASH_RELEASE" \
  > "$SCRATCH/crash-initial.log" 2>&1

for phase in \
  before-bundle-stage \
  after-bundle-stage \
  bundle-engine-staged \
  bundle-cache-staged \
  bundle-manifest-staged \
  bundle-prepared \
  before-bundle-switch \
  after-bundle-switch \
  bundle-committed \
  before-bundle-cleanup \
  after-bundle-cleanup
do
  hook="$SCRATCH/crash-$phase"
  rm -rf "$hook"
  mkdir "$hook"
  STARLING_AOT_CACHE_TEST_HOOK_DIR="$hook" \
  STARLING_AOT_CACHE_TEST_WAIT_AT="$phase" \
    "$PREFIX_B/bin/starling-aot-cache" publish-bundle \
      --target "$CRASH_RELEASE" \
      --engine "$PREFIX_B/bin/starling-raw.wasm" \
      --engine-name starling-raw-weval.wasm \
      --weval "$PREFIX_B/weval-package/weval" \
      --cache "$PREFIX_B/bin/starling-ics.wevalcache" \
      --manifest "$PREFIX_B/bin/starling-ics.wevalcache.manifest" \
      > "$SCRATCH/crash-$phase.log" 2>&1 &
  publisher_pid=$!
  wait_for_hook "$hook/$phase.ready"
  kill -KILL "$publisher_pid"
  wait "$publisher_pid" 2>/dev/null || true
  timeout 5s "$PREFIX_A/bin/starling-aot-cache" recover-bundle \
    --target "$CRASH_RELEASE"
  assert_bundle "$CRASH_RELEASE"
  test -z "$(find "$SCRATCH" -maxdepth 1 \
    -name '.crash release.starling-aot-generation-*' -print -quit)"
done

ROLLBACK_RELEASE="$SCRATCH/rollback release"
mkdir "$ROLLBACK_RELEASE"
"$PACKAGE_SCRIPT" "$PREFIX_A" "$ROLLBACK_RELEASE" \
  > "$SCRATCH/rollback-initial.log" 2>&1
switch_hook="$SCRATCH/rollback-switch"
mkdir "$switch_hook"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$switch_hook" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-bundle-switch \
  "$PREFIX_B/bin/starling-aot-cache" publish-bundle \
    --target "$ROLLBACK_RELEASE" \
    --engine "$PREFIX_B/bin/starling-raw.wasm" \
    --engine-name starling-raw-weval.wasm \
    --weval "$PREFIX_B/weval-package/weval" \
    --cache "$PREFIX_B/bin/starling-ics.wevalcache" \
    --manifest "$PREFIX_B/bin/starling-ics.wevalcache.manifest" \
    > "$SCRATCH/rollback-switch.log" 2>&1 &
publisher_pid=$!
wait_for_hook "$switch_hook/after-bundle-switch.ready"
kill -KILL "$publisher_pid"
wait "$publisher_pid" 2>/dev/null || true
rollback_hook="$SCRATCH/rollback-recovery"
mkdir "$rollback_hook"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$rollback_hook" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-bundle-rollback \
  "$PREFIX_A/bin/starling-aot-cache" recover-bundle \
    --target "$ROLLBACK_RELEASE" \
    > "$SCRATCH/rollback-recovery.log" 2>&1 &
recovery_pid=$!
wait_for_hook "$rollback_hook/before-bundle-rollback.ready"
kill -KILL "$recovery_pid"
wait "$recovery_pid" 2>/dev/null || true
timeout 5s "$PREFIX_A/bin/starling-aot-cache" recover-bundle \
  --target "$ROLLBACK_RELEASE"
assert_bundle "$ROLLBACK_RELEASE"
cmp "$ROLLBACK_RELEASE/starling-raw-weval.wasm" \
  "$PREFIX_A/bin/starling-raw.wasm"

BUILD_PREFIX="$SCRATCH/existing build prefix"
mkdir -p "$BUILD_PREFIX/bin" "$BUILD_PREFIX/unrelated/nested"
printf 'unrelated user tool\n' > "$BUILD_PREFIX/bin/user-tool"
printf 'unrelated nested bytes\n' > \
  "$BUILD_PREFIX/unrelated/nested/preserved.txt"
UNRELATED_TOOL_INODE="$(stat -c '%d:%i' "$BUILD_PREFIX/bin/user-tool")"
UNRELATED_NESTED_INODE="$(
  stat -c '%d:%i' "$BUILD_PREFIX/unrelated/nested/preserved.txt"
)"
UNRELATED_HASH="$(
  sha256sum "$BUILD_PREFIX/bin/user-tool" \
    "$BUILD_PREFIX/unrelated/nested/preserved.txt"
)"

assert_unrelated_prefix() {
  test "$(stat -c '%d:%i' "$BUILD_PREFIX/bin/user-tool")" = \
    "$UNRELATED_TOOL_INODE"
  test "$(
    stat -c '%d:%i' "$BUILD_PREFIX/unrelated/nested/preserved.txt"
  )" = "$UNRELATED_NESTED_INODE"
  test "$(
    sha256sum "$BUILD_PREFIX/bin/user-tool" \
      "$BUILD_PREFIX/unrelated/nested/preserved.txt"
  )" = "$UNRELATED_HASH"
}

make_prefix_generation() {
  local label="$1" serial="$2"
  local source generation bin
  source="$SCRATCH/source $label"
  generation="$SCRATCH/.existing build prefix.generation-$label-$serial"
  bin="$generation/bin"
  rm -rf "$generation"
  mkdir -p "$bin" "$generation/shared"
  cp "$source/bin/starling-raw.wasm" "$bin/"
  cp "$source/bin/starling-ics.wevalcache" "$bin/"
  cp "$source/bin/starling-ics.wevalcache.manifest" "$bin/"
  cp "$source/bin/starling-aot-cache" "$bin/"
  cp "$source/bin/weval" "$bin/"
  cp -R "$source/weval-package" "$generation/"
  cp "$source/bin/wasm-tools" "$bin/"
  cp "$source/bin/wasm-tools" "$bin/wasmtime"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/starling-componentize"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/componentize.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/wabt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$generation/shared/wabt.real"
  printf 'preview adapter %s\n' "$label" > "$bin/preview1-adapter.wasm"
  printf '{"generation":"%s"}\n' "$label" > "$bin/features.json"
  printf 'console.log("smoke %s");\n' "$label" > "$bin/smoke.js"
  chmod +x "$bin/starling-aot-cache" "$bin/weval" "$bin/wasm-tools" \
    "$bin/wasmtime" "$bin/starling-componentize" "$bin/componentize.sh" \
    "$bin/wabt" "$generation/shared/wabt.real"
  printf '%s\n' "$generation"
}

assert_prefix() {
  local target="$1" owner="$2"
  local source="$SCRATCH/source $owner"
  cmp "$target/bin/starling-raw.wasm" "$source/bin/starling-raw.wasm"
  cmp "$target/bin/starling-ics.wevalcache" \
    "$source/bin/starling-ics.wevalcache"
  cmp "$target/bin/starling-ics.wevalcache.manifest" \
    "$source/bin/starling-ics.wevalcache.manifest"
  test -s "$target/bin/starling-componentize"
  test -s "$target/bin/componentize.sh"
  test -s "$target/bin/preview1-adapter.wasm"
  test -s "$target/bin/features.json"
  test -s "$target/bin/smoke.js"
  test -s "$target/bin/wabt"
  test -x "$target/bin/wasmtime"
}

generation_a="$(make_prefix_generation A initial)"
"$PREFIX_A/bin/starling-aot-cache" publish-prefix \
  --target "$BUILD_PREFIX" \
  --generation "$generation_a" \
  --feature-abi package-race-A
assert_prefix "$BUILD_PREFIX" A
assert_unrelated_prefix
test -f "$BUILD_PREFIX/.starling-aot-engine/owner"
test -f "$BUILD_PREFIX/.starling-aot-engine/ownership.manifest"
test -L "$BUILD_PREFIX/bin/starling-raw.wasm"
BUILD_INODE="$(stat -c '%d:%i' "$BUILD_PREFIX")"

for kind in dangling absolute escaping intermediate; do
  unsafe_generation="$(make_prefix_generation B "unsafe-$kind")"
  rm "$unsafe_generation/bin/wabt"
  case "$kind" in
    dangling)
      ln -s missing "$unsafe_generation/bin/wabt"
      ;;
    absolute)
      ln -s "$PREFIX_B/bin/wabt" "$unsafe_generation/bin/wabt"
      ;;
    escaping)
      ln -s ../../outside-wabt "$unsafe_generation/bin/wabt"
      ;;
    intermediate)
      mkdir "$unsafe_generation/links"
      ln -s ../../outside "$unsafe_generation/links/escape"
      ln -s ../links/escape/wabt "$unsafe_generation/bin/wabt"
      ;;
  esac
  if "$PREFIX_B/bin/starling-aot-cache" publish-prefix \
    --target "$BUILD_PREFIX" \
    --generation "$unsafe_generation" \
    --feature-abi package-race-B \
    >"$SCRATCH/unsafe-prefix-$kind.log" 2>&1
  then
    echo "FAIL: $kind generation symlink was accepted" >&2
    exit 1
  fi
  grep -Fq InvalidDestinationKind "$SCRATCH/unsafe-prefix-$kind.log"
  assert_prefix "$BUILD_PREFIX" A
done

internal_generation="$(make_prefix_generation A internal-link)"
rm "$internal_generation/bin/wabt"
ln -s ../shared/wabt.real "$internal_generation/bin/wabt"
"$PREFIX_A/bin/starling-aot-cache" publish-prefix \
  --target "$BUILD_PREFIX" \
  --generation "$internal_generation" \
  --feature-abi package-race-A
test "$(readlink "$BUILD_PREFIX/.starling-aot-engine/current/bin/wabt")" = \
  "../shared/wabt.real"
assert_prefix "$BUILD_PREFIX" A

STAGE_RACE_HOOK="$SCRATCH/prefix-stage-race-hook"
mkdir "$STAGE_RACE_HOOK"
generation_b="$(make_prefix_generation B stage-race)"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$STAGE_RACE_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-prefix-switch \
  "$PREFIX_B/bin/starling-aot-cache" publish-prefix \
    --target "$BUILD_PREFIX" \
    --generation "$generation_b" \
    --feature-abi package-race-B \
    >"$SCRATCH/prefix-stage-race.log" 2>&1 &
stage_race_pid=$!
wait_for_hook "$STAGE_RACE_HOOK/before-prefix-switch.ready"
stage_path="$(find "$BUILD_PREFIX/.starling-aot-engine" -maxdepth 1 \
  -name '.current.starling-aot-generation-*' -print -quit)"
test -n "$stage_path"
mv "$stage_path" "$stage_path.validated"
mkdir "$stage_path"
printf 'unvalidated tree\n' > "$stage_path/unvalidated"
touch "$STAGE_RACE_HOOK/before-prefix-switch.continue"
if wait "$stage_race_pid"; then
  echo "FAIL: replaced unvalidated stage was published" >&2
  exit 1
fi
grep -Fq SealPathRace "$SCRATCH/prefix-stage-race.log"
assert_prefix "$BUILD_PREFIX" A
rm -rf "$stage_path"
mv "$stage_path.validated" "$stage_path"
"$PREFIX_A/bin/starling-aot-cache" recover-bundle --target "$BUILD_PREFIX"
assert_prefix "$BUILD_PREFIX" A

PARENT_RACE_HOOK="$SCRATCH/prefix-parent-race-hook"
mkdir "$PARENT_RACE_HOOK"
generation_b="$(make_prefix_generation B parent-race)"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$PARENT_RACE_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-prefix-switch \
  "$PREFIX_B/bin/starling-aot-cache" publish-prefix \
    --target "$BUILD_PREFIX" \
    --generation "$generation_b" \
    --feature-abi package-race-B \
    >"$SCRATCH/prefix-parent-race.log" 2>&1 &
parent_race_pid=$!
wait_for_hook "$PARENT_RACE_HOOK/before-prefix-switch.ready"
mv "$BUILD_PREFIX/.starling-aot-engine" \
  "$BUILD_PREFIX/.starling-aot-engine.retained"
mkdir "$BUILD_PREFIX/.starling-aot-engine"
printf 'replacement parent\n' > \
  "$BUILD_PREFIX/.starling-aot-engine/unvalidated"
rm -rf "$BUILD_PREFIX/.starling-aot-engine"
mv "$BUILD_PREFIX/.starling-aot-engine.retained" \
  "$BUILD_PREFIX/.starling-aot-engine"
touch "$PARENT_RACE_HOOK/before-prefix-switch.continue"
wait "$parent_race_pid"
assert_prefix "$BUILD_PREFIX" B
"$PREFIX_A/bin/starling-aot-cache" publish-prefix \
  --target "$BUILD_PREFIX" \
  --generation "$generation_a" \
  --feature-abi package-race-A
assert_prefix "$BUILD_PREFIX" A

for phase in \
  prefix-files-durable \
  prefix-validated \
  prefix-prepared \
  before-prefix-switch \
  after-prefix-switch
do
  generation_b="$(make_prefix_generation B "$phase")"
  if STARLING_AOT_CACHE_TEST_FAIL="$phase" \
    "$PREFIX_B/bin/starling-aot-cache" publish-prefix \
      --target "$BUILD_PREFIX" \
      --generation "$generation_b" \
      --feature-abi package-race-B \
      > "$SCRATCH/build-prefix-$phase.log" 2>&1
  then
    echo "FAIL: build-prefix $phase injection unexpectedly succeeded" >&2
    exit 1
  fi
  "$PREFIX_A/bin/starling-aot-cache" recover-bundle \
    --target "$BUILD_PREFIX"
  assert_prefix "$BUILD_PREFIX" A
  assert_unrelated_prefix
  test "$(stat -c '%d:%i' "$BUILD_PREFIX")" = "$BUILD_INODE"
done

PREFIX_KILL_HOOK="$SCRATCH/prefix-kill-hook"
mkdir "$PREFIX_KILL_HOOK"
generation_b="$(make_prefix_generation B sigkill)"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$PREFIX_KILL_HOOK" \
STARLING_AOT_CACHE_TEST_WAIT_AT=after-prefix-switch \
  "$PREFIX_B/bin/starling-aot-cache" publish-prefix \
    --target "$BUILD_PREFIX" \
    --generation "$generation_b" \
    --feature-abi package-race-B \
    > "$SCRATCH/prefix-sigkill.log" 2>&1 &
prefix_kill_pid=$!
wait_for_hook "$PREFIX_KILL_HOOK/after-prefix-switch.ready"
kill -KILL "$prefix_kill_pid"
wait "$prefix_kill_pid" 2>/dev/null || true
"$PREFIX_A/bin/starling-aot-cache" recover-bundle --target "$BUILD_PREFIX"
assert_prefix "$BUILD_PREFIX" A
assert_unrelated_prefix

PREFIX_HOOK_A="$SCRATCH/prefix-publisher-A-hook"
PREFIX_HOOK_B="$SCRATCH/prefix-publisher-B-hook"
mkdir "$PREFIX_HOOK_A" "$PREFIX_HOOK_B"
generation_a="$(make_prefix_generation A concurrent)"
generation_b="$(make_prefix_generation B concurrent)"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$PREFIX_HOOK_A" \
STARLING_AOT_CACHE_TEST_WAIT_AT=before-prefix-switch \
  "$PREFIX_A/bin/starling-aot-cache" publish-prefix \
    --target "$BUILD_PREFIX" \
    --generation "$generation_a" \
    --feature-abi package-race-A \
    > "$SCRATCH/prefix-A.log" 2>&1 &
prefix_pid_a=$!
wait_for_hook "$PREFIX_HOOK_A/before-prefix-switch.ready"
STARLING_AOT_CACHE_TEST_HOOK_DIR="$PREFIX_HOOK_B" \
STARLING_AOT_CACHE_TEST_WAIT_AT=prefix-prepared \
STARLING_AOT_CACHE_TEST_NOTIFY_AT=prefix-lock-attempt \
  "$PREFIX_B/bin/starling-aot-cache" publish-prefix \
    --target "$BUILD_PREFIX" \
    --generation "$generation_b" \
    --feature-abi package-race-B \
    > "$SCRATCH/prefix-B.log" 2>&1 &
prefix_pid_b=$!
wait_for_hook "$PREFIX_HOOK_B/prefix-lock-attempt.ready"
test ! -e "$PREFIX_HOOK_B/prefix-prepared.ready"
touch "$PREFIX_HOOK_A/before-prefix-switch.continue"
wait "$prefix_pid_a"
wait_for_hook "$PREFIX_HOOK_B/prefix-prepared.ready"
touch "$PREFIX_HOOK_B/prefix-prepared.continue"
wait "$prefix_pid_b"
assert_prefix "$BUILD_PREFIX" B
assert_unrelated_prefix
test "$(stat -c '%d:%i' "$BUILD_PREFIX")" = "$BUILD_INODE"

CONFLICT_PREFIX="$SCRATCH/conflicting shared prefix"
mkdir -p "$CONFLICT_PREFIX/bin"
printf 'foreign artifact\n' > "$CONFLICT_PREFIX/bin/starling-raw.wasm"
CONFLICT_INODE="$(
  stat -c '%d:%i' "$CONFLICT_PREFIX/bin/starling-raw.wasm"
)"
if "$PREFIX_A/bin/starling-aot-cache" publish-prefix \
  --target "$CONFLICT_PREFIX" \
  --generation "$generation_a" \
  --feature-abi package-race-A \
  >"$SCRATCH/prefix-conflict.log" 2>&1
then
  echo "FAIL: unowned prefix artifact conflict was accepted" >&2
  exit 1
fi
grep -Fq InstallOwnershipConflict "$SCRATCH/prefix-conflict.log"
test "$(cat "$CONFLICT_PREFIX/bin/starling-raw.wasm")" = \
  "foreign artifact"
test "$(stat -c '%d:%i' "$CONFLICT_PREFIX/bin/starling-raw.wasm")" = \
  "$CONFLICT_INODE"

echo "Serialized atomic-directory AOT package publication passed"
echo "AOT package SIGKILL recovery matrix passed"
echo "Transactional AOT build-prefix failure/concurrency matrix passed"
