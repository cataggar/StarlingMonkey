#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <version-checker> <zig>" >&2
  exit 2
fi

CHECKER="$(realpath "$1")"
ZIG="$(realpath "$2")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.zig-version"
rm -rf "$SCRATCH"
mkdir "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

"$CHECKER" "$ZIG"

cat > "$SCRATCH/wrong-zig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '0.17.0-dev.903+wrong'
EOF
chmod +x "$SCRATCH/wrong-zig"
if "$CHECKER" "$SCRATCH/wrong-zig" >"$SCRATCH/wrong.log" 2>&1; then
  echo "FAIL: wrong Zig version was accepted" >&2
  exit 1
fi
grep -Fq 'requires Zig 0.17.0-dev.902+7255f3e72' "$SCRATCH/wrong.log"
grep -Fq 'found 0.17.0-dev.903+wrong' "$SCRATCH/wrong.log"

echo "Exact Zig version rejection passed"
