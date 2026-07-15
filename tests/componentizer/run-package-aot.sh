#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <starling-aot-cache> <package-script>" >&2
  exit 2
fi

CACHE_TOOL="$(realpath "$1")"
PACKAGE_SCRIPT="$(realpath "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.aot-package-race"
BARRIER="$SCRATCH/validation barrier"
MOVE_TOOLS="$SCRATCH/move tools"
RELEASE="$SCRATCH/release"
PRIMER="$SCRATCH/primer.js"

rm -rf "$SCRATCH"
mkdir -p "$BARRIER" "$MOVE_TOOLS" "$RELEASE"
validator_pid=""
cleanup() {
  if [ -n "$validator_pid" ]; then
    kill "$validator_pid" 2>/dev/null || true
  fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
printf 'function main() {}\n' > "$PRIMER"
real_mv="$(command -v mv)"
cat > "$MOVE_TOOLS/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
publishing=0
for arg in "\$@"; do
  case "\$arg" in
    */.aot-package-*/*)
      publishing=1
      ;;
  esac
done
if [ "\$publishing" -eq 1 ] &&
  [ ! -e "$SCRATCH/publisher-\$PPID" ]; then
  touch "$SCRATCH/publisher-\$PPID"
  if ! mkdir "$SCRATCH/publication-active"; then
    echo "concurrent AOT publications overlapped" >&2
    exit 91
  fi
  trap 'rmdir "$SCRATCH/publication-active"' EXIT
  sleep 1
fi
"$real_mv" "\$@"
EOF
chmod +x "$MOVE_TOOLS/mv"

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
validation_parent="\${4%/*}"
if [ -n "\${HOLD_POST_LOCK_VALIDATOR:-}" ] &&
  [[ "\${validation_parent##*/}" != .aot-package-* ]]; then
  printf '%s\n' "\$\$" > "\$HOLD_POST_LOCK_VALIDATOR.pid"
  touch "\$HOLD_POST_LOCK_VALIDATOR"
  sleep 30
fi
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

PATH="$MOVE_TOOLS:$PATH" "$PACKAGE_SCRIPT" "$PREFIX_A" "$RELEASE" \
  > "$SCRATCH/package-A.log" 2>&1 &
pid_a=$!
PATH="$MOVE_TOOLS:$PATH" "$PACKAGE_SCRIPT" "$PREFIX_B" "$RELEASE" \
  > "$SCRATCH/package-B.log" 2>&1 &
pid_b=$!
status_a=0
status_b=0
wait "$pid_a" || status_a=$?
wait "$pid_b" || status_b=$?
if [ "$status_a" -ne 0 ] || [ "$status_b" -ne 0 ]; then
  cat "$SCRATCH/package-A.log" "$SCRATCH/package-B.log" >&2
  exit 1
fi
test -d "$BARRIER/A.ready"
test -d "$BARRIER/B.ready"
test ! -e "$SCRATCH/publication-active"

if cmp -s "$RELEASE/starling-raw-weval.wasm" \
  "$PREFIX_A/bin/starling-raw.wasm"; then
  owner="$PREFIX_A"
elif cmp -s "$RELEASE/starling-raw-weval.wasm" \
  "$PREFIX_B/bin/starling-raw.wasm"; then
  owner="$PREFIX_B"
else
  echo "FAIL: published engine belongs to neither source bundle" >&2
  exit 1
fi

cmp "$RELEASE/starling-ics.wevalcache" \
  "$owner/bin/starling-ics.wevalcache"
cmp "$RELEASE/starling-ics.wevalcache.manifest" \
  "$owner/bin/starling-ics.wevalcache.manifest"
"$owner/bin/wasm-tools" validate --features all \
  "$RELEASE/starling-raw-weval.wasm"
"$owner/bin/starling-aot-cache" validate \
  --engine "$RELEASE/starling-raw-weval.wasm" \
  --weval "$owner/bin/weval" \
  --cache "$RELEASE/starling-ics.wevalcache" \
  --manifest "$RELEASE/starling-ics.wevalcache.manifest"
test -z "$(find "$RELEASE" -maxdepth 1 -name '.aot-package-*' -print -quit)"

ABNORMAL_RELEASE="$SCRATCH/abnormal release"
VALIDATOR_MARKER="$SCRATCH/post-lock-validator"
mkdir "$ABNORMAL_RELEASE"
HOLD_POST_LOCK_VALIDATOR="$VALIDATOR_MARKER" \
PATH="$MOVE_TOOLS:$PATH" "$PACKAGE_SCRIPT" "$PREFIX_A" "$ABNORMAL_RELEASE" \
  > "$SCRATCH/abnormal-A.log" 2>&1 &
controller_pid=$!
for _ in {1..500}; do
  [ -e "$VALIDATOR_MARKER" ] && break
  sleep 0.01
done
if [ ! -e "$VALIDATOR_MARKER" ]; then
  cat "$SCRATCH/abnormal-A.log" >&2
  echo "post-lock validator did not start" >&2
  exit 1
fi
validator_pid="$(cat "$VALIDATOR_MARKER.pid")"
kill -KILL "$controller_pid"
wait "$controller_pid" 2>/dev/null || true

SECONDS=0
if ! timeout 5s env PATH="$MOVE_TOOLS:$PATH" \
  "$PACKAGE_SCRIPT" "$PREFIX_B" "$ABNORMAL_RELEASE" \
  > "$SCRATCH/abnormal-B.log" 2>&1
then
  cat "$SCRATCH/abnormal-B.log" >&2
  echo "replacement publisher did not acquire the released lock promptly" >&2
  exit 1
fi
test "$SECONDS" -lt 5
kill "$validator_pid" 2>/dev/null || true
validator_pid=""

echo "Concurrent AOT package publication passed"
echo "Abnormal publication lock release passed"
