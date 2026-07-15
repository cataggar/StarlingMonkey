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
  mkdir -p "$bin"
  printf 'engine-%s\n' "$label" > "$bin/starling-raw.wasm"
  cp "$CACHE_TOOL" "$bin/starling-aot-cache"
  cat > "$bin/weval" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$bin/wasm-tools" <<EOF
#!/usr/bin/env bash
set -euo pipefail
test "\$1 \$2 \$3" = "validate --features all"
mkdir -p "$BARRIER/$label.ready"
while [ ! -d "$BARRIER/A.ready" ] || [ ! -d "$BARRIER/B.ready" ]; do
  sleep 0.01
done
EOF
  chmod +x "$bin/weval" "$bin/wasm-tools"
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
    --weval "$bin/weval" \
    --cache "$bin/starling-ics.wevalcache.raw" \
    --cache-out "$bin/starling-ics.wevalcache" \
    --primer "$PRIMER" \
    --feature-abi "package-race-$label" \
    --out "$bin/starling-ics.wevalcache.manifest"
  "$bin/starling-aot-cache" seal \
    --engine "$bin/starling-raw.wasm" \
    --weval "$bin/weval" \
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
    --weval "$owner/bin/weval" \
    --cache "$target/starling-ics.wevalcache" \
    --manifest "$target/starling-ics.wevalcache.manifest"
}

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
  "$PACKAGE_SCRIPT" "$PREFIX_B" "$RELEASE" \
    > "$SCRATCH/package-B.log" 2>&1 &
pid_b=$!
sleep 0.2
test ! -e "$HOOK_B/bundle-prepared.ready"
touch "$HOOK_A/before-bundle-switch.continue"
wait "$pid_a"
wait_for_hook "$HOOK_B/bundle-prepared.ready"
touch "$HOOK_B/bundle-prepared.continue"
wait "$pid_b"
assert_bundle "$RELEASE"
cmp "$RELEASE/starling-raw-weval.wasm" "$PREFIX_B/bin/starling-raw.wasm"

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
      --weval "$PREFIX_B/bin/weval" \
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
    --weval "$PREFIX_B/bin/weval" \
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
BUILD_BIN="$BUILD_PREFIX/bin"
mkdir -p "$BUILD_BIN"
"$PREFIX_A/bin/starling-aot-cache" publish-bundle \
  --target "$BUILD_BIN" \
  --engine "$PREFIX_A/bin/starling-raw.wasm" \
  --engine-name starling-raw.wasm \
  --weval "$PREFIX_A/bin/weval" \
  --cache "$PREFIX_A/bin/starling-ics.wevalcache" \
  --manifest "$PREFIX_A/bin/starling-ics.wevalcache.manifest"
printf 'preserved installed tool\n' > "$BUILD_BIN/starling-componentize"
for phase in \
  before-bundle-stage \
  after-bundle-stage \
  bundle-engine-staged \
  bundle-cache-staged \
  bundle-manifest-staged \
  bundle-prepared \
  before-bundle-switch \
  after-bundle-switch
do
  if STARLING_AOT_CACHE_TEST_FAIL="$phase" \
    "$PREFIX_B/bin/starling-aot-cache" publish-bundle \
      --target "$BUILD_BIN" \
      --engine "$PREFIX_B/bin/starling-raw.wasm" \
      --engine-name starling-raw.wasm \
      --weval "$PREFIX_B/bin/weval" \
      --cache "$PREFIX_B/bin/starling-ics.wevalcache" \
      --manifest "$PREFIX_B/bin/starling-ics.wevalcache.manifest" \
      > "$SCRATCH/build-prefix-$phase.log" 2>&1
  then
    echo "FAIL: build-prefix $phase injection unexpectedly succeeded" >&2
    exit 1
  fi
  "$PREFIX_A/bin/starling-aot-cache" recover-bundle \
    --target "$BUILD_BIN"
  cmp "$BUILD_BIN/starling-raw.wasm" "$PREFIX_A/bin/starling-raw.wasm"
  cmp "$BUILD_BIN/starling-ics.wevalcache" \
    "$PREFIX_A/bin/starling-ics.wevalcache"
  cmp "$BUILD_BIN/starling-ics.wevalcache.manifest" \
    "$PREFIX_A/bin/starling-ics.wevalcache.manifest"
  grep -Fq 'preserved installed tool' "$BUILD_BIN/starling-componentize"
done

echo "Serialized atomic-directory AOT package publication passed"
echo "AOT package SIGKILL recovery matrix passed"
echo "Transactional AOT build-prefix failure matrix passed"
