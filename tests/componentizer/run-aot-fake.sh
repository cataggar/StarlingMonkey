#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <starling-componentize> <starling-aot-cache> <wasm-tools>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/harness-helpers.sh"
COMPONENTIZER="$(resolve_executable "$1")"
CACHE_TOOL="$(resolve_executable "$2")"
REAL_WASM_TOOLS="$(resolve_executable "$3")"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH="$ROOT/tests/componentizer/.scratch"
TOOLS="$SCRATCH/fake tools"
WORK="$SCRATCH/work with spaces"
ENGINE_PACKAGE="$WORK/external engine package"
WEVAL_PACKAGE="$ENGINE_PACKAGE/weval-package"
FAKE_WEVAL="$WEVAL_PACKAGE/fake weval"
FEATURE_ABI='starling-features-v1;stdio=1;random=1;clocks=1;http=1;fetch-event=1;optimize=ReleaseSmall;host-api=wasi-0.2.10;debugger=1'
rm -rf "$SCRATCH"
mkdir -p "$TOOLS/lib" "$WEVAL_PACKAGE" "$WORK/wit package" \
  "$ENGINE_PACKAGE/component-wit" "$ENGINE_PACKAGE/surface-wit" \
  "$ENGINE_PACKAGE/feature-wit"
NOEXEC_MOUNTED=0
NOEXEC_OUTPUT_DIR=""
MNT_PIPELINE_DIR=""
unmount_noexec() {
  if [ "${STARLING_NOEXEC_SUDO:-0}" = 1 ]; then
    sudo -n umount "$1"
  else
    umount "$1"
  fi
}
cleanup() {
  if [ "$NOEXEC_MOUNTED" -eq 1 ]; then
    unmount_noexec "$NOEXEC_OUTPUT_DIR" || true
  fi
  if [ -n "$MNT_PIPELINE_DIR" ]; then
    rm -rf "$MNT_PIPELINE_DIR"
  fi
  chmod -R u+w "$SCRATCH" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

if cmake -S "$ROOT" -B "$SCRATCH/cmake aot rejected" -DWEVAL=ON \
  >"$SCRATCH/cmake aot.log" 2>&1
then
  echo "FAIL: CMake accepted an unsealed WEVAL=ON build" >&2
  exit 1
fi
grep -Fq 'cannot produce the sealed, validated' "$SCRATCH/cmake aot.log"
grep -Fq 'AOT cache.' "$SCRATCH/cmake aot.log"
grep -Fq 'zig build -Doptimize=ReleaseSmall -Daot-engine=true' "$SCRATCH/cmake aot.log"

SOURCE="$WORK/source module.js"
ENGINE="$ENGINE_PACKAGE/fake engine.wasm"
ADAPTER="$ENGINE_PACKAGE/preview1-adapter.wasm"
WIT="$WORK/wit package"
printf 'export const api = {};\n' > "$SOURCE"
cp "$ROOT/host-apis/wasi-0.2.10/preview1-adapter-release/wasi_snapshot_preview1.wasm" \
  "$ADAPTER"
cat > "$ENGINE_PACKAGE/features.json" <<'EOF'
{"host-api":"wasi-0.2.10","component-world":"exports","surface-world":"exports","stdio":true,"random":true,"clocks":true,"http":true,"fetch-event":true}
EOF
cat > "$ENGINE_PACKAGE/component-wit/world.wit" <<'EOF'
package test:componentizer;
world exports {}
EOF
cat > "$ENGINE_PACKAGE/surface-wit/world.wit" <<'EOF'
package test:componentizer;
world exports {}
EOF
cat > "$ENGINE_PACKAGE/feature-wit/world.wit" <<'EOF'
package test:feature;
world feature {}
EOF
python3 - "$ENGINE" <<'PY'
import hashlib
import sys

name = b"starling:engine-provenance"
module = b"\0asm\1\0\0\0"
provenance = (
    "schema=1\n"
    f"sha256={hashlib.sha256(module).hexdigest()}\n"
    "host-api=wasi-0.2.10\n"
    "features=11111\n"
    "component-world=exports\n"
    "surface-world=exports\n"
).encode()

def uleb(value):
    result = bytearray()
    while True:
        byte = value & 0x7f
        value >>= 7
        result.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(result)

payload = uleb(len(name)) + name + provenance
open(sys.argv[1], "wb").write(
    module + b"\0" + uleb(len(payload)) + payload
)
PY
assert_engine_payload() {
  local output="$1"
  test -s "$output"
  if ! cmp -s -n "$(stat -c %s "$ENGINE")" "$ENGINE" "$output"; then
    "$REAL_WASM_TOOLS" validate --features all "$output"
  fi
}
cat > "$WIT/world.wit" <<'EOF'
package test:componentizer;
world exports {}
EOF

cat > "$TOOLS/fake wizer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -z "${STARLINGMONKEY_CONFIG+x}"
for arg in "$@"; do
  case "$arg" in
    -S|-W)
      echo "standalone Wizer received a Wasmtime-only argument: $arg" >&2
      exit 24
      ;;
  esac
done
printf '%s\n' "$*" | grep -q -- '--allow-wasi'
printf '%s\n' "$*" | grep -q -- '--init-func wizer-initialize'
printf '%s\n' "$*" | grep -q -- '--inherit-env true'
printf '%s\n' "$*" | grep -q -- '--wasm-bulk-memory true'
cat > "$FAKE_RUNTIME_ARGS_LOG"
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
input="${!#}"
cp "$input" "$out"
chmod u+w "$out"
EOF

cat > "$FAKE_WEVAL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -z "${STARLINGMONKEY_CONFIG+x}"
test "${RUST_MIN_STACK:-}" = "${EXPECTED_RUST_MIN_STACK:-8388608}"
test "$1" = "weval"
printf '%s\n' "$*" | grep -q -- '--cache-ro'
if printf '%s\n' "$*" | grep -Eq -- '(^| )--cache( |$)'; then
  echo "AOT componentization attempted to mutate its read-only cache" >&2
  exit 26
fi
printf '%s\0' "$@" > "$FAKE_AOT_ARGV_LOG"
cat > "$FAKE_AOT_RUNTIME_ARGS_LOG"
out=""
input=""
cache=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    -o)
      j=$((i + 1))
      out="${!j}"
      ;;
    -i)
      j=$((i + 1))
      input="${!j}"
      ;;
    --cache-ro)
      j=$((i + 1))
      cache="${!j}"
      ;;
  esac
done
if [ "${EXPECT_AOT_SNAPSHOT:-0}" = 1 ]; then
  test "$(basename "$0")" = "$(basename "$ORIGINAL_AOT_WEVAL")"
  test "$(dirname "$input")" = "$(dirname "$cache")"
  test "$(stat -c %a "$(dirname "$0")")" = 500
  case "$(stat -c %A "$0")" in
    *w*) exit 30 ;;
  esac
  printf 'replacement engine\n' > "$ORIGINAL_AOT_ENGINE"
  printf 'replacement cache\n' > "$ORIGINAL_AOT_CACHE"
  printf '# replaced after validation\n' > "$ORIGINAL_AOT_WEVAL"
  printf 'replacement sibling\n' > "$ORIGINAL_AOT_SIBLING"
  cmp "$input" "$EXPECTED_AOT_ENGINE"
  cmp "$cache" "$EXPECTED_AOT_CACHE"
  test "$(cat "$(dirname "$0")/$(basename "$ORIGINAL_AOT_SIBLING")")" = \
    "snapshot sibling"
fi
if [ -n "${EXPECT_AOT_EXEC_STAGE_OUTSIDE:-}" ]; then
  case "$0" in
    "$EXPECT_AOT_EXEC_STAGE_OUTSIDE"/*)
      echo "AOT executable snapshot remained under the output parent" >&2
      exit 28
      ;;
  esac
  test "$(stat -c %a "$(dirname "$0")")" = 500
  case "$(stat -c %A "$0")" in
    *w*) exit 31 ;;
  esac
fi
if [ -n "${EXPECT_AOT_EXEC_STAGE_ROOT:-}" ]; then
  case "$0" in
    /.__starling-package-*/*) ;;
    *)
      echo "AOT executable did not use the private immutable namespace" >&2
      exit 29
      ;;
  esac
fi
if [ "${FAKE_AOT_FAIL:-0}" = 1 ]; then
  exit 27
fi
cp "$input" "$out"
EOF

cat > "$TOOLS/fake wabt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$(basename "$0")" = "fake wabt"
if [ -n "${FAKE_WABT_CHILD_HOOK:-}" ] &&
  mkdir "$FAKE_WABT_CHILD_HOOK/claimed" 2>/dev/null
then
  touch "$FAKE_WABT_CHILD_HOOK/ready"
  while [ ! -e "$FAKE_WABT_CHILD_HOOK/continue" ]; do sleep 0.001; done
fi
test "$("$(dirname "$0")/tool sibling" wabt)" = "wabt-sibling-ok"
if [ -n "${FAKE_WABT_CHILD_HOOK:-}" ] &&
  [ -d "$FAKE_WABT_CHILD_HOOK/claimed" ] &&
  [ ! -e "$FAKE_WABT_CHILD_HOOK/consumed" ]
then
  touch "$FAKE_WABT_CHILD_HOOK/consumed"
  while [ ! -e "$FAKE_WABT_CHILD_HOOK/finish" ]; do sleep 0.001; done
fi
if [ -n "${FAKE_WABT_EXECUTABLE_LOG:-}" ]; then
  printf '%s\n' "$0" >> "$FAKE_WABT_EXECUTABLE_LOG"
fi
stage="$1 $2"
if [ "${FAKE_FAIL_STAGE:-}" = "$stage" ]; then
  echo "injected $stage failure" >&2
  exit 23
fi
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
if [ "$stage" = "component embed" ] &&
  [ -n "${FAKE_WIT_USED_LOG:-}" ]
then
  wit="${@: -2:1}"
  printf '%s\n' "$wit" > "$FAKE_WIT_USED_LOG"
  find "$wit" -type f -name '*.wit' -print0 |
    sort -z |
    xargs -0 cat >> "$FAKE_WIT_USED_LOG"
elif [ "$stage" = "component new" ] &&
  [ -n "${FAKE_ADAPTER_USED_LOG:-}" ]
then
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--adapt" ]; then
      j=$((i + 1))
      adapter="${!j#*=}"
      printf '%s\n' "$adapter" > "$FAKE_ADAPTER_USED_LOG"
      cat "$adapter" >> "$FAKE_ADAPTER_USED_LOG"
    fi
  done
fi
input="${!#}"
cp "$input" "$out"
chmod u+w "$out"
EOF

cat > "$TOOLS/fake wasm-tools" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$(basename "$0")" = "fake wasm-tools"
test "$("$(dirname "$0")/tool sibling" wasm-tools)" = \
  "wasm-tools-sibling-ok"
if [ -n "${FAKE_WASM_TOOLS_EXECUTABLE_LOG:-}" ]; then
  printf '%s\n' "$0" >> "$FAKE_WASM_TOOLS_EXECUTABLE_LOG"
fi
if [ "$1 $2" = "component embed" ] || [ "$1 $2" = "component wit" ]; then
  exec "$REAL_WASM_TOOLS" "$@"
elif [ "$1 $2" = "component new" ]; then
  out=""
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = "--output" ]; then
      j=$((i + 1))
      out="${!j}"
    fi
  done
  cp "${!#}" "$out"
fi
EOF

cat > "$TOOLS/tool sibling" <<'EOF'
wabt-sibling-ok
EOF

cat > "$TOOLS/fake zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = version ]; then
  printf '%s\n' '0.17.0-dev.902+7255f3e72'
  exit 0
fi
if [ -n "${FAKE_ZIG_ACTIVE_DIR:-}" ]; then
  if ! mkdir "$FAKE_ZIG_ACTIVE_DIR"; then
    echo "concurrent same-key Zig builds overlapped" >&2
    exit 25
  fi
  trap 'rmdir "$FAKE_ZIG_ACTIVE_DIR"' EXIT
  sleep "${FAKE_ZIG_DELAY:-0}"
fi
prefix=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--prefix" ]; then
    j=$((i + 1))
    prefix="${!j}"
  fi
done
printf '%s\n' "$prefix" >> "$FAKE_ZIG_PREFIX_LOG"
printf '%s|%s\n' "${ZIG_LOCAL_CACHE_DIR-unset}" "$ZIG_GLOBAL_CACHE_DIR" \
  >> "$FAKE_ZIG_ENV_LOG"
mkdir -p "$prefix/bin"
cp "$FAKE_ENGINE" "$prefix/bin/starling-raw.wasm"
cp "$FAKE_ADAPTER" "$prefix/bin/preview1-adapter.wasm"
cp -R "$FAKE_ENGINE_PACKAGE/feature-wit" "$prefix/bin/feature-wit"
cp -R "$FAKE_ENGINE_PACKAGE/component-wit" "$prefix/bin/component-wit"
cp -R "$FAKE_ENGINE_PACKAGE/surface-wit" "$prefix/bin/surface-wit"
printf '{"schema":"starling-componentize-build-tools/v1","tools":[]}\n' \
  > "$prefix/bin/runtime-build-tools.json"
EOF

cat > "$TOOLS/fake wasmtime" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = wizer
shift
cat > "$FAKE_RUNTIME_ARGS_LOG"
out=""
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "-o" ]; then
    j=$((i + 1))
    out="${!j}"
  fi
done
cp "${!#}" "$out"
EOF
cat > "$SCRATCH/fake-wabt.c" <<'EOF'
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int copy_file(const char *input, const char *output) {
  int in = open(input, O_RDONLY);
  int out = open(output, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (in < 0 || out < 0) return 80;
  char buffer[65536];
  ssize_t count;
  while ((count = read(in, buffer, sizeof(buffer))) > 0)
    if (write(out, buffer, (size_t)count) != count) return 81;
  close(in);
  return close(out) || count < 0 ? 82 : 0;
}

static void wait_for(const char *path) {
  while (access(path, F_OK) != 0) usleep(1000);
}

static void write_marker(const char *name, const char *text) {
  const char *path = getenv(name);
  if (!path) return;
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd >= 0) {
    write(fd, text, strlen(text));
    close(fd);
  }
}

static void probe_inherited_directories(void) {
  DIR *fds = opendir("/proc/self/fd");
  if (!fds) return;
  int scan_fd = dirfd(fds);
  struct dirent *entry;
  while ((entry = readdir(fds)) != NULL) {
    char *end = NULL;
    long candidate = strtol(entry->d_name, &end, 10);
    if (!end || *end || candidate < 3 || candidate == scan_fd) continue;
    int sibling = openat((int)candidate, "tool sibling", O_RDONLY);
    if (sibling < 0) continue;
    char content[128] = {0};
    ssize_t count = read(sibling, content, sizeof(content) - 1);
    close(sibling);
    if (count <= 0 || !strstr(content, "substituted-sibling")) continue;
    write_marker("FAKE_FD_READ_LEAK_MARKER", "leaked sibling bytes\n");
    int executable = openat(
      (int)candidate,
      "fd leak executable",
      O_RDONLY
    );
    if (executable >= 0) {
      pid_t child = fork();
      if (child == 0) {
        char *const args[] = {"fd leak executable", NULL};
        fexecve(executable, args, environ);
        _exit(126);
      }
      int status = 0;
      if (child > 0) waitpid(child, &status, 0);
      close(executable);
    }
  }
  closedir(fds);
}

static int probe_standard_descriptors(void) {
  if (!getenv("FAKE_EXPECT_NULL_STDIO")) return 0;
  char path[64], target[256];
  for (int fd = 1; fd <= 2; ++fd) {
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t count = readlink(path, target, sizeof(target) - 1);
    if (count < 0) return 1;
    target[count] = '\0';
    if (strstr(target, "fake tools") != NULL ||
        strstr(target, ".__starling-transaction-") != NULL) return 1;
  }
  write_marker("FAKE_STDIO_PROBE_MARKER", "normalized stdio\n");
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) return 70;
  if (probe_standard_descriptors()) {
    write_marker("FAKE_STDIO_PROBE_MARKER", "invalid stdio\n");
    return 75;
  }
  char executable[4096], sibling[4096], value[64] = {0};
  snprintf(executable, sizeof(executable), "%s", argv[0]);
  snprintf(sibling, sizeof(sibling), "%s/tool sibling", dirname(executable));
  const char *hook = getenv("FAKE_WABT_CHILD_HOOK");
  char path[4096];
  if (hook) {
    snprintf(path, sizeof(path), "%s/claimed", hook);
    if (mkdir(path, 0700) == 0) {
      snprintf(path, sizeof(path), "%s/ready", hook);
      close(open(path, O_WRONLY | O_CREAT, 0600));
      snprintf(path, sizeof(path), "%s/continue", hook);
      wait_for(path);
      probe_inherited_directories();
      FILE *marker = fopen(sibling, "r");
      if (!marker || !fgets(value, sizeof(value), marker) ||
          strcmp(value, "wabt-sibling-ok\n") != 0) return 71;
      fclose(marker);
      snprintf(path, sizeof(path), "%s/consumed", hook);
      close(open(path, O_WRONLY | O_CREAT, 0600));
      snprintf(path, sizeof(path), "%s/finish", hook);
      wait_for(path);
    }
  } else {
    FILE *marker = fopen(sibling, "r");
    if (!marker || !fgets(value, sizeof(value), marker) ||
        strcmp(value, "wabt-sibling-ok\n") != 0) return 71;
    fclose(marker);
  }
  if (getenv("FAKE_TRY_LIVE_PATH")) {
    pid_t child = fork();
    if (child == 0) {
      execlp("retained-live-path", "retained-live-path", NULL);
      _exit(0);
    }
    int status = 0;
    if (child < 0 || waitpid(child, &status, 0) != child ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 74;
  }
  const char *log = getenv("FAKE_WABT_EXECUTABLE_LOG");
  if (log) {
    FILE *file = fopen(log, "a");
    if (!file) return 72;
    fprintf(file, "%s\n", argv[0]);
    fclose(file);
  }
  const char *fail = getenv("FAKE_FAIL_STAGE");
  char stage[256];
  snprintf(stage, sizeof(stage), "%s %s", argv[1], argv[2]);
  if (fail && strcmp(fail, stage) == 0) return 23;
  const char *output = NULL;
  for (int i = 1; i + 1 < argc; ++i)
    if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0)
      output = argv[++i];
  if (!output) return 73;
  return copy_file(argv[argc - 1], output);
}
EOF
cc -static -O2 -o "$TOOLS/fake wabt" "$SCRATCH/fake-wabt.c"
cat > "$SCRATCH/fd-leak-executable.c" <<'EOF'
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
  const char *path = getenv("FAKE_FD_EXEC_LEAK_MARKER");
  if (!path) return 1;
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return 2;
  const char message[] = "executed leaked sibling bytes\n";
  int failed = write(fd, message, strlen(message)) != strlen(message);
  close(fd);
  return failed;
}
EOF
cc -static -O2 \
  -o "$TOOLS/fd leak executable" \
  "$SCRATCH/fd-leak-executable.c"
cp "$REAL_WASM_TOOLS" "$TOOLS/fake wasm-tools"
cat > "$TOOLS/retained-live-path" <<EOF
#!/bin/sh
touch "$SCRATCH/live PATH executable consumed"
exit 97
EOF
cat > "$SCRATCH/fake-weval.c" <<'EOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int copy_file(const char *input, const char *output) {
  int in = open(input, O_RDONLY);
  int out = open(output, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (in < 0 || out < 0) return 80;
  char buffer[65536];
  ssize_t count;
  while ((count = read(in, buffer, sizeof(buffer))) > 0)
    if (write(out, buffer, (size_t)count) != count) return 81;
  close(in);
  return close(out) || count < 0 ? 82 : 0;
}

static int same_file(const char *a, const char *b) {
  int left = open(a, O_RDONLY), right = open(b, O_RDONLY);
  if (left < 0 || right < 0) return 0;
  char x[8192], y[8192];
  ssize_t xn, yn;
  do {
    xn = read(left, x, sizeof(x));
    yn = read(right, y, sizeof(y));
    if (xn != yn || (xn > 0 && memcmp(x, y, (size_t)xn))) return 0;
  } while (xn > 0);
  close(left);
  close(right);
  return xn == 0;
}

static void write_text(const char *path, const char *text) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd >= 0) {
    write(fd, text, strlen(text));
    close(fd);
  }
}

int main(int argc, char **argv) {
  if (argc < 2 || strcmp(argv[1], "weval") != 0) return 70;
  if (getenv("STARLINGMONKEY_CONFIG")) return 71;
  const char *stack = getenv("RUST_MIN_STACK");
  const char *expected_stack = getenv("EXPECTED_RUST_MIN_STACK");
  if (!stack || strcmp(stack, expected_stack ? expected_stack : "8388608"))
    return 72;
  const char *output = NULL, *input = NULL, *cache = NULL;
  int cache_ro = 0;
  for (int i = 2; i < argc; ++i) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) output = argv[++i];
    else if (!strcmp(argv[i], "-i") && i + 1 < argc) input = argv[++i];
    else if (!strcmp(argv[i], "--cache-ro") && i + 1 < argc) {
      cache_ro = 1;
      cache = argv[++i];
    } else if (!strcmp(argv[i], "--cache")) return 73;
  }
  if (!output || !input || !cache || !cache_ro) return 74;
  const char *argv_log = getenv("FAKE_AOT_ARGV_LOG");
  if (argv_log) {
    int fd = open(argv_log, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 75;
    for (int i = 1; i < argc; ++i) write(fd, argv[i], strlen(argv[i]) + 1);
    close(fd);
  }
  const char *stdin_log = getenv("FAKE_AOT_RUNTIME_ARGS_LOG");
  if (stdin_log) {
    int fd = open(stdin_log, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    char buffer[4096];
    ssize_t count;
    while ((count = read(0, buffer, sizeof(buffer))) > 0)
      if (write(fd, buffer, (size_t)count) != count) return 76;
    close(fd);
  }
  if (getenv("EXPECT_AOT_SNAPSHOT")) {
    const char *original_engine = getenv("ORIGINAL_AOT_ENGINE");
    const char *original_cache = getenv("ORIGINAL_AOT_CACHE");
    const char *original_weval = getenv("ORIGINAL_AOT_WEVAL");
    const char *original_sibling = getenv("ORIGINAL_AOT_SIBLING");
    const char *expected_engine = getenv("EXPECTED_AOT_ENGINE");
    const char *expected_cache = getenv("EXPECTED_AOT_CACHE");
    if (!original_engine || !original_cache || !original_weval ||
        !original_sibling || !expected_engine || !expected_cache)
      return 77;
    write_text(original_engine, "replacement engine\n");
    write_text(original_cache, "replacement cache\n");
    write_text(original_weval, "replacement weval\n");
    write_text(original_sibling, "replacement sibling\n");
    if (!same_file(input, expected_engine) || !same_file(cache, expected_cache))
      return 78;
  }
  if (getenv("FAKE_AOT_FAIL")) return 27;
  const char *executed = getenv("FAKE_AOT_EXECUTED_MARKER");
  if (executed) write_text(executed, "sealed executable ran\n");
  return copy_file(input, output);
}
EOF
cc -static -O2 -o "$FAKE_WEVAL" "$SCRATCH/fake-weval.c"
cp "$FAKE_WEVAL" "$TOOLS/fake weval"
chmod +x "$TOOLS"/*
chmod +x "$FAKE_WEVAL"
for tool in zig wizer wasmtime wabt wasm-tools weval; do
  ln -s "fake $tool" "$TOOLS/path-$tool"
done

WRAPPER_DIR="$SCRATCH/wrapper with spaces"
mkdir -p "$WRAPPER_DIR"
python3 - "$ROOT/componentize.sh.in" "$WRAPPER_DIR/componentize.sh" <<'PY'
import sys

data = open(sys.argv[1], encoding="utf-8").read()
replacements = {
    "@WASMTIME_DIR@": ".",
    "@WASM_TOOLS_BIN@": "wasm-tools",
    "@WEVAL_BIN@": "weval",
    "@COMPONENT_WORLD@": "",
    "@COMPONENT_WIT_DIR@": "component wit",
    "@AOT@": "1",
    "@AOT_DRIVER@": "native",
}
for old, new in replacements.items():
    data = data.replace(old, new)
open(sys.argv[2], "w", encoding="utf-8").write(data)
PY
cat > "$WRAPPER_DIR/starling-componentize" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$WRAPPER_LOG"
EOF
chmod +x "$WRAPPER_DIR/componentize.sh" "$WRAPPER_DIR/starling-componentize"
touch "$WRAPPER_DIR/starling-raw.wasm" "$WRAPPER_DIR/preview1-adapter.wasm"
export WRAPPER_LOG="$SCRATCH/wrapper args.bin"
PREOPEN_DIR="$WORK/preopen dir" "$WRAPPER_DIR/componentize.sh" \
  --output "$WORK/wrapper output.wasm" "$SOURCE"
python3 - "$WRAPPER_LOG" "$WORK/preopen dir" "$WORK/wrapper output.wasm" "$SOURCE" <<'PY'
import sys

args = open(sys.argv[1], "rb").read().split(b"\0")[:-1]
args = [arg.decode() for arg in args]
assert "--legacy-wrapper-preopen" in args
preopen = args.index("--preopen-dir")
assert args[preopen + 1] == sys.argv[2]
assert args[-3:] == ["--output", sys.argv[3], sys.argv[4]]
PY
WASM_TOOLS=path-wasm-tools WABT=path-wabt WEVAL=path-weval \
  "$WRAPPER_DIR/componentize.sh" --output "$WORK/wrapper path output.wasm" "$SOURCE"
python3 - "$WRAPPER_LOG" <<'PY'
import sys

args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert args[args.index("--wasm-tools-bin") + 1] == "path-wasm-tools"
assert args[args.index("--wabt-bin") + 1] == "path-wabt"
assert args[args.index("--weval-bin") + 1] == "path-weval"
PY
"$WRAPPER_DIR/componentize.sh" "$SOURCE" "$WORK/positional output.wasm"
python3 - "$WRAPPER_LOG" "$SOURCE" "$WORK/positional output.wasm" <<'PY'
import sys
args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert "--legacy-wrapper-preopen" in args
assert args[-2:] == sys.argv[2:]
PY
"$WRAPPER_DIR/componentize.sh" --output "$WORK/runtime only.wasm"
python3 - "$WRAPPER_LOG" "$WORK/runtime only.wasm" <<'PY'
import sys
args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert "--legacy-wrapper-preopen" in args
assert args[-2:] == ["--output", sys.argv[2]]
PY

export FAKE_RUNTIME_ARGS_LOG="$SCRATCH/runtime args.log"
export FAKE_AOT_RUNTIME_ARGS_LOG="$SCRATCH/aot runtime args.log"
export FAKE_AOT_ARGV_LOG="$SCRATCH/aot argv.bin"
export FAKE_ENGINE="$ENGINE"
export FAKE_ADAPTER="$ADAPTER"
export FAKE_ENGINE_PACKAGE="$ENGINE_PACKAGE"
export FAKE_ZIG_PREFIX_LOG="$SCRATCH/zig prefixes.log"
export FAKE_ZIG_ENV_LOG="$SCRATCH/zig env.log"
export REAL_WASM_TOOLS
export STARLINGMONKEY_CONFIG="--ambient-config-must-not-reach-wizer"
EXPECTED_ZIG_GLOBAL_CACHE="${ZIG_GLOBAL_CACHE_DIR:-}"

wait_for_test_hook() {
  local ready="$1"
  for _ in $(seq 1 60000); do
    test -e "$ready" && return
    sleep 0.001
  done
  echo "FAIL: timed out waiting for componentizer hook" >&2
  exit 1
}

expect_external_package_rejection() {
  local package="$1" label="$2"
  local output="$WORK/$label external rejection.wasm"
  printf 'preserved external rejection\n' > "$output"
  if PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
    --engine "$package/fake engine.wasm" \
    --preview2-adapter "$package/preview1-adapter.wasm" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin path-wizer \
    --wabt-bin path-wabt \
    --wasm-tools-bin path-wasm-tools \
    --out "$output" \
    "$SOURCE" >"$SCRATCH/$label-external.log" 2>&1
  then
    echo "FAIL: $label external engine package was accepted" >&2
    exit 1
  fi
  grep -Eq \
    '(MissingEngineProvenance|InvalidEngineProvenance|EngineProvenanceMismatch|IncompatibleEngineOptions|MissingBuildArtifact|MissingWitFiles|UnsupportedWitEntry|InputChanged)' \
    "$SCRATCH/$label-external.log" || {
    cat "$SCRATCH/$label-external.log" >&2
    return 1
  }
  test "$(cat "$output")" = "preserved external rejection"
}

MISSING_PROVENANCE_PACKAGE="$WORK/missing provenance package"
cp -a "$ENGINE_PACKAGE" "$MISSING_PROVENANCE_PACKAGE"
printf '\0asm\1\0\0\0' \
  > "$MISSING_PROVENANCE_PACKAGE/fake engine.wasm"
expect_external_package_rejection \
  "$MISSING_PROVENANCE_PACKAGE" missing-provenance

INCOMPATIBLE_PROVENANCE_PACKAGE="$WORK/incompatible provenance package"
cp -a "$ENGINE_PACKAGE" "$INCOMPATIBLE_PROVENANCE_PACKAGE"
sed -i 's/schema=1/schema=2/' \
  "$INCOMPATIBLE_PROVENANCE_PACKAGE/fake engine.wasm"
expect_external_package_rejection \
  "$INCOMPATIBLE_PROVENANCE_PACKAGE" incompatible-provenance

MISSING_FEATURES_PACKAGE="$WORK/missing features package"
cp -a "$ENGINE_PACKAGE" "$MISSING_FEATURES_PACKAGE"
rm "$MISSING_FEATURES_PACKAGE/features.json"
expect_external_package_rejection \
  "$MISSING_FEATURES_PACKAGE" missing-features

INCOMPATIBLE_FEATURES_PACKAGE="$WORK/incompatible features package"
cp -a "$ENGINE_PACKAGE" "$INCOMPATIBLE_FEATURES_PACKAGE"
sed -i 's/"http":true/"http":false/' \
  "$INCOMPATIBLE_FEATURES_PACKAGE/features.json"
expect_external_package_rejection \
  "$INCOMPATIBLE_FEATURES_PACKAGE" incompatible-features

MISSING_WORLD_PACKAGE="$WORK/missing world package"
cp -a "$ENGINE_PACKAGE" "$MISSING_WORLD_PACKAGE"
sed -i 's/world exports/world absent/' \
  "$MISSING_WORLD_PACKAGE/component-wit/world.wit"
expect_external_package_rejection \
  "$MISSING_WORLD_PACKAGE" missing-component-world

MISSING_SURFACE_PACKAGE="$WORK/missing surface package"
cp -a "$ENGINE_PACKAGE" "$MISSING_SURFACE_PACKAGE"
rm -rf "$MISSING_SURFACE_PACKAGE/surface-wit"
expect_external_package_rejection \
  "$MISSING_SURFACE_PACKAGE" missing-surface-world

MISSING_FEATURE_WIT_PACKAGE="$WORK/missing feature WIT package"
cp -a "$ENGINE_PACKAGE" "$MISSING_FEATURE_WIT_PACKAGE"
rm -rf "$MISSING_FEATURE_WIT_PACKAGE/feature-wit"
expect_external_package_rejection \
  "$MISSING_FEATURE_WIT_PACKAGE" missing-feature-wit

MALFORMED_WIT_PACKAGE="$WORK/malformed WIT package"
cp -a "$ENGINE_PACKAGE" "$MALFORMED_WIT_PACKAGE"
printf 'this is not valid WIT\n' \
  > "$MALFORMED_WIT_PACKAGE/component-wit/world.wit"
expect_external_package_rejection \
  "$MALFORMED_WIT_PACKAGE" malformed-wit

COMMENT_ONLY_WORLD_PACKAGE="$WORK/comment-only world package"
cp -a "$ENGINE_PACKAGE" "$COMMENT_ONLY_WORLD_PACKAGE"
cat > "$COMMENT_ONLY_WORLD_PACKAGE/surface-wit/world.wit" <<'EOF'
package test:componentizer;
// world exports {}
EOF
expect_external_package_rejection \
  "$COMMENT_ONLY_WORLD_PACKAGE" comment-only-world

MALFORMED_FEATURE_WIT_PACKAGE="$WORK/malformed feature WIT package"
cp -a "$ENGINE_PACKAGE" "$MALFORMED_FEATURE_WIT_PACKAGE"
printf 'invalid feature closure\n' \
  > "$MALFORMED_FEATURE_WIT_PACKAGE/feature-wit/world.wit"
expect_external_package_rejection \
  "$MALFORMED_FEATURE_WIT_PACKAGE" malformed-feature-wit

expect_external_surface_rejection() {
  local wit="$1" world="$2" label="$3"
  local output="$WORK/$label external rejection.wasm"
  printf 'preserved external surface rejection\n' > "$output"
  if PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$wit" \
    --world-name "$world" \
    --wizer-bin path-wizer \
    --wabt-bin path-wabt \
    --wasm-tools-bin path-wasm-tools \
    --out "$output" \
    "$SOURCE" >"$SCRATCH/$label-external.log" 2>&1
  then
    echo "FAIL: $label external surface was accepted" >&2
    exit 1
  fi
  grep -Eq \
    '(InvalidEngineProvenance|IncompatibleEngineOptions|MissingWitFiles|UnsupportedWitEntry)' \
    "$SCRATCH/$label-external.log" || {
    cat "$SCRATCH/$label-external.log" >&2
    return 1
  }
  test "$(cat "$output")" = "preserved external surface rejection"
}

expect_external_surface_rejection "$WIT" absent surface-world-mismatch
MISMATCHED_SURFACE_WIT="$WORK/mismatched surface WIT"
mkdir "$MISMATCHED_SURFACE_WIT"
cat > "$MISMATCHED_SURFACE_WIT/world.wit" <<'EOF'
package test:componentizer;
world exports {
  export different: func();
}
EOF
expect_external_surface_rejection \
  "$MISMATCHED_SURFACE_WIT" exports surface-tree-mismatch

PATH_OVERRIDE_OUTPUT="$WORK/path override output.wasm"
WABT_EXECUTABLE_LOG="$SCRATCH/wabt executable.log"
FAKE_WABT_EXECUTABLE_LOG="$WABT_EXECUTABLE_LOG" \
FAKE_TRY_LIVE_PATH=1 \
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin path-wizer \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$PATH_OVERRIDE_OUTPUT" \
  "$SOURCE"
assert_engine_payload "$PATH_OVERRIDE_OUTPUT"
test ! -e "$SCRATCH/live PATH executable consumed"
grep -Eq '^(/\.__starling-package-[0-9a-f]{32}(/[^/]*)*|/proc/self/fd/[0-9]+)/fake wabt$' \
  "$WABT_EXECUTABLE_LOG" || {
  cat "$WABT_EXECUTABLE_LOG" >&2
  exit 1
}

CLOSED_STDIO_OUTPUT="$WORK/closed stdio output.wasm"
CLOSED_STDIO_MARKER="$SCRATCH/closed stdio probe completed"
if ! (
  exec 1>&- 2>&-
  FAKE_EXPECT_NULL_STDIO=1 \
  FAKE_STDIO_PROBE_MARKER="$CLOSED_STDIO_MARKER" \
  PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin path-wizer \
    --wabt-bin path-wabt \
    --wasm-tools-bin path-wasm-tools \
    --out "$CLOSED_STDIO_OUTPUT" \
    "$SOURCE"
); then
  test ! -e "$CLOSED_STDIO_MARKER" || cat "$CLOSED_STDIO_MARKER" >&2
  echo "FAIL: componentizer failed with initially closed stdout/stderr" >&2
  exit 1
fi
assert_engine_payload "$CLOSED_STDIO_OUTPUT"
test "$(cat "$CLOSED_STDIO_MARKER")" = "normalized stdio"
echo "Closed stdout/stderr descriptor normalization passed"

if [ -w /mnt ]; then
  MNT_PIPELINE_DIR="/mnt/starling-componentizer-$$"
  mkdir "$MNT_PIPELINE_DIR"
  cp "$SOURCE" "$MNT_PIPELINE_DIR/source.js"
  cp -a "$WIT" "$MNT_PIPELINE_DIR/wit"
  (
    cd "$MNT_PIPELINE_DIR"
    PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
      --engine "$ENGINE" \
      --preview2-adapter "$ADAPTER" \
      --wit "$MNT_PIPELINE_DIR/wit" \
      --world-name exports \
      --wizer-bin path-wizer \
      --wabt-bin path-wabt \
      --wasm-tools-bin path-wasm-tools \
      --out "$MNT_PIPELINE_DIR/output.wasm" \
      "$MNT_PIPELINE_DIR/source.js"
  )
  assert_engine_payload "$MNT_PIPELINE_DIR/output.wasm"
  echo "Caller-visible /mnt pipeline passed"
elif unshare --user --map-root-user true 2>/dev/null; then
  unshare --user --map-root-user --mount -- bash -c '
    set -euo pipefail
    mount -t tmpfs -o mode=700 starling-mnt-pipeline /mnt
    mkdir /mnt/work
    cp "$2" /mnt/work/source.js
    cp -a "$3" /mnt/work/wit
    cd /mnt/work
    PATH="$4:$PATH" "$1" \
      --engine "$5" \
      --preview2-adapter "$6" \
      --wit /mnt/work/wit \
      --world-name exports \
      --wizer-bin path-wizer \
      --wabt-bin path-wabt \
      --wasm-tools-bin path-wasm-tools \
      --out /mnt/work/output.wasm \
      /mnt/work/source.js
    cmp -n "$(stat -c %s "$5")" "$5" /mnt/work/output.wasm
  ' bash "$COMPONENTIZER" "$SOURCE" "$WIT" "$TOOLS" "$ENGINE" "$ADAPTER"
  echo "Private-namespace /mnt pipeline passed"
else
  echo "SKIP: private user namespaces are unavailable"
fi

CHILD_REPLACE_HOOK="$SCRATCH/retained child replacement hook"
CHILD_REPLACE_OUTPUT="$WORK/retained child replacement output.wasm"
WABT_ORIGINAL="$SCRATCH/fake wabt original"
SIBLING_ORIGINAL="$SCRATCH/tool sibling original"
FD_EXECUTABLE_ORIGINAL="$SCRATCH/fd leak executable original"
FD_READ_LEAK_MARKER="$SCRATCH/inherited directory bytes consumed"
FD_EXEC_LEAK_MARKER="$SCRATCH/inherited directory executable ran"
mkdir "$CHILD_REPLACE_HOOK"
printf 'preserved retained child output\n' > "$CHILD_REPLACE_OUTPUT"
FAKE_WABT_CHILD_HOOK="$CHILD_REPLACE_HOOK" \
FAKE_FD_READ_LEAK_MARKER="$FD_READ_LEAK_MARKER" \
FAKE_FD_EXEC_LEAK_MARKER="$FD_EXEC_LEAK_MARKER" \
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin path-wizer \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$CHILD_REPLACE_OUTPUT" \
  "$SOURCE" >"$SCRATCH/retained-child-replacement.log" 2>&1 &
child_replace_pid=$!
wait_for_test_hook "$CHILD_REPLACE_HOOK/ready"
mv "$TOOLS/fake wabt" "$WABT_ORIGINAL"
mv "$TOOLS/tool sibling" "$SIBLING_ORIGINAL"
mv "$TOOLS/fd leak executable" "$FD_EXECUTABLE_ORIGINAL"
cat > "$TOOLS/fake wabt" <<EOF
#!/bin/sh
touch "$SCRATCH/substituted wabt consumed"
exit 97
EOF
cat > "$TOOLS/tool sibling" <<EOF
#!/bin/sh
touch "$SCRATCH/substituted sibling consumed"
printf 'substituted-sibling\n'
EOF
chmod +x "$TOOLS/fake wabt" "$TOOLS/tool sibling"
cp "$FD_EXECUTABLE_ORIGINAL" "$TOOLS/fd leak executable"
touch "$CHILD_REPLACE_HOOK/continue"
wait_for_test_hook "$CHILD_REPLACE_HOOK/consumed"
rm "$TOOLS/fake wabt" "$TOOLS/tool sibling" "$TOOLS/fd leak executable"
mv "$WABT_ORIGINAL" "$TOOLS/fake wabt"
mv "$SIBLING_ORIGINAL" "$TOOLS/tool sibling"
mv "$FD_EXECUTABLE_ORIGINAL" "$TOOLS/fd leak executable"
touch "$CHILD_REPLACE_HOOK/finish"
if ! wait "$child_replace_pid"; then
  cat "$SCRATCH/retained-child-replacement.log" >&2
  echo "FAIL: retained tool snapshot did not isolate source substitution" >&2
  exit 1
fi
assert_engine_payload "$CHILD_REPLACE_OUTPUT"
test ! -e "$SCRATCH/substituted wabt consumed"
test ! -e "$SCRATCH/substituted sibling consumed"
test ! -e "$FD_READ_LEAK_MARKER"
test ! -e "$FD_EXEC_LEAK_MARKER"
echo "During-child executable and sibling substitutions isolated"

PACKAGE_CAPTURE_HOOK="$SCRATCH/external package capture hook"
PACKAGE_CAPTURE_OUTPUT="$WORK/external package capture output.wasm"
PACKAGE_ORIGINAL="$WORK/engine package original"
PACKAGE_SUBSTITUTE="$WORK/engine package substitute"
cp -a "$ENGINE_PACKAGE" "$PACKAGE_SUBSTITUTE"
printf 'substituted-adapter-generation\n' \
  > "$PACKAGE_SUBSTITUTE/preview1-adapter.wasm"
cat > "$PACKAGE_SUBSTITUTE/component-wit/world.wit" <<'EOF'
package test:componentizer;
world exports {
  substituted-generation: func();
}
EOF
mkdir "$PACKAGE_CAPTURE_HOOK"
printf 'preserved package capture output\n' > "$PACKAGE_CAPTURE_OUTPUT"
STARLING_COMPONENTIZER_TEST_HOOK_DIR="$PACKAGE_CAPTURE_HOOK" \
STARLING_COMPONENTIZER_TEST_WAIT_AT=external-package-engine-captured \
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin path-wizer \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$PACKAGE_CAPTURE_OUTPUT" \
  "$SOURCE" >"$SCRATCH/external-package-capture.log" 2>&1 &
package_capture_pid=$!
wait_for_test_hook \
  "$PACKAGE_CAPTURE_HOOK/external-package-engine-captured.ready"
mv "$ENGINE_PACKAGE" "$PACKAGE_ORIGINAL"
mv "$PACKAGE_SUBSTITUTE" "$ENGINE_PACKAGE"
touch "$PACKAGE_CAPTURE_HOOK/external-package-engine-captured.continue"
if wait "$package_capture_pid"; then
  echo "FAIL: external package sibling generations were mixed" >&2
  exit 1
fi
mv "$ENGINE_PACKAGE" "$PACKAGE_SUBSTITUTE"
mv "$PACKAGE_ORIGINAL" "$ENGINE_PACKAGE"
grep -Eq \
  '(InputChanged|EngineProvenanceMismatch|InvalidEngineProvenance|IncompatibleEngineOptions)' \
  "$SCRATCH/external-package-capture.log"
test "$(cat "$PACKAGE_CAPTURE_OUTPUT")" = \
  "preserved package capture output"
rm -rf "$PACKAGE_SUBSTITUTE"
echo "External package between-child substitution rejected"

assert_tool_replacement_isolated() {
  local label="$1" target="$2"
  local hook="$SCRATCH/$label tool replacement hook"
  local output="$WORK/$label tool replacement output.wasm"
  local original="$SCRATCH/$label original tool"
  mkdir "$hook"
  printf 'preserved tool replacement output\n' > "$output"
  STARLING_COMPONENTIZER_TEST_HOOK_DIR="$hook" \
  STARLING_COMPONENTIZER_TEST_WAIT_AT=tools-resolved \
  PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin path-wizer \
    --wabt-bin path-wabt \
    --wasm-tools-bin path-wasm-tools \
    --out "$output" \
    "$SOURCE" >"$SCRATCH/$label-tool-replacement.log" 2>&1 &
  local pid=$!
  wait_for_test_hook "$hook/tools-resolved.ready"
  mv "$target" "$original"
  printf '#!/usr/bin/env bash\nprintf substituted-tool-ran > \"%s\"\nexit 97\n' \
    "$SCRATCH/$label substituted tool ran" > "$target"
  chmod +x "$target"
  touch "$hook/tools-resolved.continue"
  if ! wait "$pid"; then
    cat "$SCRATCH/$label-tool-replacement.log" >&2
    echo "FAIL: retained $label snapshot did not isolate replacement" >&2
    exit 1
  fi
  rm "$target"
  mv "$original" "$target"
  assert_engine_payload "$output"
  test ! -e "$SCRATCH/$label substituted tool ran"
}

assert_tool_replacement_isolated wasm-tools "$TOOLS/fake wasm-tools"
assert_tool_replacement_isolated wabt "$TOOLS/fake wabt"
assert_tool_replacement_isolated tool-sibling "$TOOLS/tool sibling"
echo "Retained WABT/wasm-tools replacement matrix passed"

EXTERNAL_SNAPSHOT_HOOK="$SCRATCH/external snapshot hook"
EXTERNAL_SNAPSHOT_OUTPUT="$WORK/external snapshot mutation output.wasm"
EXTERNAL_ADAPTER_LOG="$SCRATCH/external snapshot adapter.log"
EXTERNAL_WIT_LOG="$SCRATCH/external snapshot WIT.log"
ADAPTER_BASELINE="$SCRATCH/adapter baseline"
FEATURES_BASELINE="$SCRATCH/features baseline"
COMPONENT_WIT_BASELINE="$SCRATCH/component WIT baseline"
mkdir "$EXTERNAL_SNAPSHOT_HOOK"
cp -p "$ADAPTER" "$ADAPTER_BASELINE"
cp -p "$ENGINE_PACKAGE/features.json" "$FEATURES_BASELINE"
cp -p "$ENGINE_PACKAGE/component-wit/world.wit" "$COMPONENT_WIT_BASELINE"
printf 'preserved external snapshot output\n' > "$EXTERNAL_SNAPSHOT_OUTPUT"
STARLING_COMPONENTIZER_TEST_HOOK_DIR="$EXTERNAL_SNAPSHOT_HOOK" \
STARLING_COMPONENTIZER_TEST_WAIT_AT=external-inputs-snapshotted \
FAKE_ADAPTER_USED_LOG="$EXTERNAL_ADAPTER_LOG" \
FAKE_WIT_USED_LOG="$EXTERNAL_WIT_LOG" \
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin path-wizer \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$EXTERNAL_SNAPSHOT_OUTPUT" \
  "$SOURCE" >"$SCRATCH/external-snapshot.log" 2>&1 &
external_snapshot_pid=$!
wait_for_test_hook \
  "$EXTERNAL_SNAPSHOT_HOOK/external-inputs-snapshotted.ready"
printf 'substituted-adapter-bytes\n' > "$ADAPTER"
printf '{"stdio":false}\n' > "$ENGINE_PACKAGE/features.json"
printf 'substituted component WIT bytes\n' \
  > "$ENGINE_PACKAGE/component-wit/world.wit"
touch "$EXTERNAL_SNAPSHOT_HOOK/external-inputs-snapshotted.continue"
if ! wait "$external_snapshot_pid"; then
  cat "$SCRATCH/external-snapshot.log" >&2
  echo "FAIL: immutable external snapshots did not isolate source mutation" >&2
  exit 1
fi
cp -p "$ADAPTER_BASELINE" "$ADAPTER"
cp -p "$FEATURES_BASELINE" "$ENGINE_PACKAGE/features.json"
cp -p "$COMPONENT_WIT_BASELINE" \
  "$ENGINE_PACKAGE/component-wit/world.wit"
assert_engine_payload "$EXTERNAL_SNAPSHOT_OUTPUT"
if grep -Fq 'substituted' "$EXTERNAL_ADAPTER_LOG" "$EXTERNAL_WIT_LOG" \
  2>/dev/null
then
  echo "FAIL: componentizer consumed mutated external inputs" >&2
  exit 1
fi
echo "External adapter/WIT immutable snapshot mutation passed"

PATH_SHADOW="$SCRATCH/non-executable path shadow"
mkdir "$PATH_SHADOW"
printf '#!/usr/bin/env bash\nexit 99\n' > "$PATH_SHADOW/path-wizer"
chmod 644 "$PATH_SHADOW/path-wizer"
PATH_SHADOW_OUTPUT="$WORK/path executable fallback output.wasm"
PATH="$PATH_SHADOW:$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin path-wizer \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$PATH_SHADOW_OUTPUT" \
  "$SOURCE"
assert_engine_payload "$PATH_SHADOW_OUTPUT"

PATH_ENV_OUTPUT="$WORK/path environment output.wasm"
env PATH="$TOOLS:$PATH" \
  WIZER_BIN=path-wizer WABT=path-wabt WASM_TOOLS_BIN=path-wasm-tools \
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --out "$PATH_ENV_OUTPUT" \
    "$SOURCE"
assert_engine_payload "$PATH_ENV_OUTPUT"

PATH_WASMTIME_OUTPUT="$WORK/path wasmtime output.wasm"
PATH="$TOOLS:$PATH" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wasmtime-bin path-wasmtime \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$PATH_WASMTIME_OUTPUT" \
  "$SOURCE"
assert_engine_payload "$PATH_WASMTIME_OUTPUT"

PATH_WASMTIME_ENV_OUTPUT="$WORK/path wasmtime environment output.wasm"
env PATH="$TOOLS:$PATH" \
  WASMTIME_BIN=path-wasmtime WASM_TOOLS_BIN=path-wasm-tools \
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wabt-bin path-wabt \
    --out "$PATH_WASMTIME_ENV_OUTPUT" \
    "$SOURCE"
assert_engine_payload "$PATH_WASMTIME_ENV_OUTPUT"

OUTPUT="$WORK/output component.wasm"
DEBUG_DIR="$WORK/debug output"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --runtime-arg -d \
  --js-heap-limit-mib 256 \
  --debug-dir "$DEBUG_DIR" \
  --out "$OUTPUT" \
  "$SOURCE"

assert_engine_payload "$OUTPUT"
grep -Fq -- '-d' "$FAKE_RUNTIME_ARGS_LOG"
grep -Fq -- '--js-heap-limit-mib 256' "$FAKE_RUNTIME_ARGS_LOG"
grep -Fq -- "\"$SOURCE\"" "$FAKE_RUNTIME_ARGS_LOG"
test -f "$DEBUG_DIR/initialized.wasm"
test -f "$DEBUG_DIR/embedded.wasm"
test -f "$DEBUG_DIR/component.wasm"
test -f "$DEBUG_DIR/commands.txt"

POSITIONAL_OUTPUT="$WORK/positional native output.wasm"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  "$SOURCE" \
  "$POSITIONAL_OUTPUT"
assert_engine_payload "$POSITIONAL_OUTPUT"

INVALID_WIZER="$WORK/ambient wizer must not resolve"
OUTPUT_ONLY="$WORK/non-aot output only.wasm"
WIZER_BIN="$INVALID_WIZER" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$OUTPUT_ONLY"
assert_engine_payload "$OUTPUT_ONLY"
if WIZER_BIN="$INVALID_WIZER" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$WORK/invalid required wizer.wasm" \
  "$SOURCE" >"$SCRATCH/invalid-required-wizer.log" 2>&1
then
  echo "FAIL: a Wizer-required run ignored invalid WIZER_BIN" >&2
  exit 1
fi
grep -Eq 'FileNotFound|MissingBuildArtifact|failed to resolve executable' \
  "$SCRATCH/invalid-required-wizer.log"

AOT_BUNDLE="$ENGINE_PACKAGE"
AOT_OUTPUT="$WORK/aot output component.wasm"
python3 - "$AOT_BUNDLE/starling-ics.wevalcache" "$ENGINE" <<'PY'
import hashlib
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.execute("""create table weval_cache(
    module_hash blob not null,
    key blob not null,
    result blob not null,
    created_time integer not null
)""")
db.execute("create index idx on weval_cache(module_hash, key)")
with open(sys.argv[2], "rb") as engine:
    engine_hash = hashlib.sha256(engine.read()).digest()
db.execute(
    "insert into weval_cache values (?, ?, ?, unixepoch())",
    (engine_hash, b"key", b"result"),
)
db.commit()
db.close()
PY
"$CACHE_TOOL" seal \
  --engine "$ENGINE" \
  --weval "$FAKE_WEVAL" \
  --cache "$AOT_BUNDLE/starling-ics.wevalcache" \
  --primer "$SOURCE" \
  --feature-abi "$FEATURE_ABI" \
  --out "$AOT_BUNDLE/starling-ics.wevalcache.manifest"
"$CACHE_TOOL" validate \
  --engine "$ENGINE" \
  --weval "$FAKE_WEVAL" \
  --cache "$AOT_BUNDLE/starling-ics.wevalcache" \
  --manifest "$AOT_BUNDLE/starling-ics.wevalcache.manifest" \
  --feature-abi "$FEATURE_ABI"
python3 - "$AOT_BUNDLE/starling-ics.wevalcache" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
assert db.execute("select distinct created_time from weval_cache").fetchall() == [(0,)]
assert db.execute("pragma integrity_check").fetchone() == ("ok",)
db.close()
PY

seal_fixture_bundle() {
  local weval="$1" bundle="$2"
  mkdir "$bundle"
  cp "$AOT_BUNDLE/starling-ics.wevalcache" \
    "$bundle/starling-ics.wevalcache"
  "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$weval" \
    --cache "$bundle/starling-ics.wevalcache" \
    --primer "$SOURCE" \
    --feature-abi "$FEATURE_ABI" \
    --out "$bundle/starling-ics.wevalcache.manifest"
}

run_fixture_aot() {
  local weval="$1" bundle="$2" output="$3"
  local package="$WORK/$(basename "$output").external-package"
  rm -rf "$package"
  cp -a "$ENGINE_PACKAGE" "$package"
  rm -rf "$package/weval-package"
  cp -a "$(dirname "$weval")" "$package/weval-package"
  cp "$bundle/starling-ics.wevalcache" "$package/"
  cp "$bundle/starling-ics.wevalcache.manifest" "$package/"
  "$COMPONENTIZER" \
    --aot \
    --engine "$package/$(basename "$ENGINE")" \
    --aot-cache-dir "$package" \
    --weval-bin "$package/weval-package/$(basename "$weval")" \
    --preview2-adapter "$package/$(basename "$ADAPTER")" \
    --wit "$WIT" \
    --world-name exports \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$output" \
    "$SOURCE"
  assert_engine_payload "$output"
}

expect_fixture_aot_rejection() {
  local weval="$1" bundle="$2" label="$3"
  local output="$WORK/$label rejected output.wasm"
  printf 'preserved package rejection\n' > "$output"
  if run_fixture_aot "$weval" "$bundle" "$output" \
    >"$SCRATCH/$label-package-rejection.log" 2>&1
  then
    echo "FAIL: $label Weval package mutation was accepted" >&2
    exit 1
  fi
  if [ "$(cat "$output")" != "preserved package rejection" ]; then
    cat "$SCRATCH/$label-package-rejection.log" >&2
    echo "FAIL: $label rejection changed the destination" >&2
    exit 1
  fi
}

WRAPPER_PACKAGE="$SCRATCH/wrapper weval package"
WRAPPER_BUNDLE="$WORK/wrapper weval bundle"
WRAPPER_OUTPUT="$WORK/wrapper weval output.wasm"
mkdir "$WRAPPER_PACKAGE"
cat > "$WRAPPER_PACKAGE/weval sibling" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
input=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    -o)
      j=$((i + 1))
      out="${!j}"
      ;;
    -i)
      j=$((i + 1))
      input="${!j}"
      ;;
  esac
done
cp "$input" "$out"
EOF
cat > "$WRAPPER_PACKAGE/wrapper weval" <<'EOF'
#!/usr/bin/env retained-test-interpreter
set -eu
test "$(basename "$0")" = "wrapper weval"
exec "$(dirname "$0")/weval sibling" "$@"
EOF
cat > "$TOOLS/retained-test-interpreter" <<EOF
#!/bin/sh
touch "$SCRATCH/live interpreter consumed"
exit 97
EOF
chmod +x "$WRAPPER_PACKAGE/weval sibling" "$WRAPPER_PACKAGE/wrapper weval"
chmod +x "$TOOLS/retained-test-interpreter"
seal_fixture_bundle "$WRAPPER_PACKAGE/wrapper weval" "$WRAPPER_BUNDLE"
PATH="$TOOLS:$PATH" expect_fixture_aot_rejection \
  "$WRAPPER_PACKAGE/wrapper weval" \
  "$WRAPPER_BUNDLE" \
  script-interpreter
grep -Eq \
  '(UnsupportedRetainedExecution|InvalidAotCache|StaleAotCache|InputChanged|MissingBuildArtifact|CommandFailed)' \
  "$SCRATCH/script-interpreter-package-rejection.log" || {
  cat "$SCRATCH/script-interpreter-package-rejection.log" >&2
  exit 1
}
test ! -e "$SCRATCH/live interpreter consumed"
test ! -e "$SCRATCH/live PATH executable consumed"
echo "Live interpreter and PATH executable closure rejected"

LAYOUT_FLAT_WEVAL="$SCRATCH/layout flat weval package"
LAYOUT_MANAGED_WEVAL="$SCRATCH/layout managed weval package"
LAYOUT_FLAT_BUNDLE="$WORK/layout flat bundle"
LAYOUT_MANAGED_BUNDLE="$WORK/layout managed bundle"
mkdir "$LAYOUT_FLAT_WEVAL" "$LAYOUT_MANAGED_WEVAL"
cp "$FAKE_WEVAL" "$LAYOUT_FLAT_WEVAL/weval"
cp "$FAKE_WEVAL" "$LAYOUT_MANAGED_WEVAL/weval"
printf 'managed closure marker\n' > "$LAYOUT_MANAGED_WEVAL/managed-marker"
seal_fixture_bundle "$LAYOUT_FLAT_WEVAL/weval" "$LAYOUT_FLAT_BUNDLE"
seal_fixture_bundle "$LAYOUT_MANAGED_WEVAL/weval" "$LAYOUT_MANAGED_BUNDLE"

run_layout_aot() {
  local runtime="$1" output="$2"
  shift 2
  "$COMPONENTIZER" \
    --aot \
    --engine "$runtime/$(basename "$ENGINE")" \
    --aot-cache-dir "$runtime" \
    --preview2-adapter "$runtime/$(basename "$ADAPTER")" \
    --wit "$WIT" \
    --world-name exports \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    "$@" \
    --out "$output" \
    "$SOURCE"
  assert_engine_payload "$output"
}

FLAT_BIN_PARENT="$WORK/flat package parent"
FLAT_BIN_RUNTIME="$FLAT_BIN_PARENT/bin"
mkdir -p "$FLAT_BIN_PARENT"
cp -a "$ENGINE_PACKAGE" "$FLAT_BIN_RUNTIME"
rm -rf "$FLAT_BIN_RUNTIME/weval-package"
cp -a "$LAYOUT_FLAT_WEVAL" "$FLAT_BIN_RUNTIME/weval-package"
cp "$LAYOUT_FLAT_BUNDLE/starling-ics.wevalcache" \
  "$LAYOUT_FLAT_BUNDLE/starling-ics.wevalcache.manifest" \
  "$FLAT_BIN_RUNTIME/"
run_layout_aot \
  "$FLAT_BIN_RUNTIME" \
  "$WORK/flat bin layout output.wasm"

AMBIGUOUS_ROOT="$WORK/ambiguous managed package"
AMBIGUOUS_RUNTIME="$AMBIGUOUS_ROOT/bin"
mkdir -p "$AMBIGUOUS_ROOT"
cp -a "$ENGINE_PACKAGE" "$AMBIGUOUS_RUNTIME"
rm -rf "$AMBIGUOUS_RUNTIME/weval-package"
cp -a "$LAYOUT_FLAT_WEVAL" "$AMBIGUOUS_RUNTIME/weval-package"
cp -a "$LAYOUT_MANAGED_WEVAL" "$AMBIGUOUS_ROOT/weval-package"
cp "$LAYOUT_FLAT_BUNDLE/starling-ics.wevalcache" \
  "$AMBIGUOUS_RUNTIME/starling-ics.wevalcache"
cp "$LAYOUT_FLAT_BUNDLE/starling-ics.wevalcache.manifest" \
  "$AMBIGUOUS_RUNTIME/starling-ics.wevalcache.manifest"
run_layout_aot \
  "$AMBIGUOUS_RUNTIME" \
  "$WORK/ambiguous default flat output.wasm"
cp "$LAYOUT_MANAGED_BUNDLE/starling-ics.wevalcache" \
  "$AMBIGUOUS_RUNTIME/starling-ics.wevalcache"
cp "$LAYOUT_MANAGED_BUNDLE/starling-ics.wevalcache.manifest" \
  "$AMBIGUOUS_RUNTIME/starling-ics.wevalcache.manifest"
run_layout_aot \
  "$AMBIGUOUS_RUNTIME" \
  "$WORK/ambiguous explicit managed output.wasm" \
  --weval-bin "$AMBIGUOUS_ROOT/weval-package/weval"
echo "Flat-bin and managed-layout ambiguity matrix passed"

cp -p "$WRAPPER_PACKAGE/weval sibling" \
  "$SCRATCH/wrapper-sibling.baseline"
printf '# sibling mutation\n' >> "$WRAPPER_PACKAGE/weval sibling"
expect_fixture_aot_rejection \
  "$WRAPPER_PACKAGE/wrapper weval" \
  "$WRAPPER_BUNDLE" \
  wrapper-sibling
cp -p "$SCRATCH/wrapper-sibling.baseline" \
  "$WRAPPER_PACKAGE/weval sibling"
chmod -x "$WRAPPER_PACKAGE/weval sibling"
expect_fixture_aot_rejection \
  "$WRAPPER_PACKAGE/wrapper weval" \
  "$WRAPPER_BUNDLE" \
  wrapper-permission
chmod +x "$WRAPPER_PACKAGE/weval sibling"

RELOCATED_PACKAGE_ONE="$SCRATCH/relocated package one"
RELOCATED_PACKAGE_TWO="$SCRATCH/relocated package two"
RELOCATED_BUNDLE_ONE="$WORK/relocated bundle one"
RELOCATED_BUNDLE_TWO="$WORK/relocated bundle two"
cp -a "$LAYOUT_FLAT_WEVAL" "$RELOCATED_PACKAGE_ONE"
cp -a "$LAYOUT_FLAT_WEVAL" "$RELOCATED_PACKAGE_TWO"
seal_fixture_bundle \
  "$RELOCATED_PACKAGE_ONE/weval" \
  "$RELOCATED_BUNDLE_ONE"
seal_fixture_bundle \
  "$RELOCATED_PACKAGE_TWO/weval" \
  "$RELOCATED_BUNDLE_TWO"
cmp "$RELOCATED_BUNDLE_ONE/starling-ics.wevalcache" \
  "$RELOCATED_BUNDLE_TWO/starling-ics.wevalcache"
cmp "$RELOCATED_BUNDLE_ONE/starling-ics.wevalcache.manifest" \
  "$RELOCATED_BUNDLE_TWO/starling-ics.wevalcache.manifest"
run_fixture_aot \
  "$RELOCATED_PACKAGE_TWO/weval" \
  "$RELOCATED_BUNDLE_ONE" \
  "$WORK/relocated package output.wasm"

ln -s "wrapper weval" "$WRAPPER_PACKAGE/selected path A"
ln -s "wrapper weval" "$WRAPPER_PACKAGE/selected path B"
SELECTED_PATH_BUNDLE="$WORK/selected path bundle"
seal_fixture_bundle \
  "$WRAPPER_PACKAGE/selected path A" \
  "$SELECTED_PATH_BUNDLE"
expect_fixture_aot_rejection \
  "$WRAPPER_PACKAGE/selected path B" \
  "$SELECTED_PATH_BUNDLE" \
  selected-path

LEGACY_PACKAGE_BUNDLE="$WORK/legacy package manifest bundle"
cp -R "$WRAPPER_BUNDLE" "$LEGACY_PACKAGE_BUNDLE"
sed -i 's/^schema=starling-weval-cache-v2$/schema=starling-weval-cache-v1/' \
  "$LEGACY_PACKAGE_BUNDLE/starling-ics.wevalcache.manifest"
expect_fixture_aot_rejection \
  "$WRAPPER_PACKAGE/wrapper weval" \
  "$LEGACY_PACKAGE_BUNDLE" \
  legacy-package-schema

ELF_PACKAGE="$SCRATCH/ELF weval package with spaces"
ELF_BUNDLE="$WORK/ELF weval bundle"
ELF_OUTPUT="$WORK/ELF weval output.wasm"
mkdir -p "$ELF_PACKAGE/bin"
ELF_LOADER="$ELF_PACKAGE/retained loader"
cp "$(realpath /lib64/ld-linux-x86-64.so.2)" "$ELF_LOADER"
cat > "$ELF_PACKAGE/libweval_fixture.c" <<'EOF'
const char *weval_fixture_marker(void) {
  return "origin-relative-library";
}
EOF
cat > "$ELF_PACKAGE/weval_fixture.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char *weval_fixture_marker(void);

static int copy_file(const char *input, const char *output) {
  FILE *source = fopen(input, "rb");
  if (source == NULL) return 74;
  FILE *destination = fopen(output, "wb");
  if (destination == NULL) {
    fclose(source);
    return 75;
  }
  char buffer[8192];
  size_t count;
  while ((count = fread(buffer, 1, sizeof(buffer), source)) != 0) {
    if (fwrite(buffer, 1, count, destination) != count) return 76;
  }
  if (ferror(source)) return 77;
  return fclose(source) != 0 || fclose(destination) != 0 ? 78 : 0;
}

int main(int argc, char **argv) {
  const char *executed = getenv("FAKE_AOT_EXECUTED_MARKER");
  if (executed != NULL) {
    FILE *marker = fopen(executed, "w");
    if (marker == NULL) return 79;
    fputs("sealed executable ran\n", marker);
    fclose(marker);
  }
  const char *basename = strrchr(argv[0], '/');
  basename = basename == NULL ? argv[0] : basename + 1;
  if (strcmp(basename, "weval argv0 alias") != 0) return 70;
  if (strcmp(weval_fixture_marker(), "origin-relative-library") != 0) return 71;
  if (argc < 2 || strcmp(argv[1], "weval") != 0) return 72;
  const char *input = NULL;
  const char *output = NULL;
  for (int i = 2; i + 1 < argc; ++i) {
    if (strcmp(argv[i], "-i") == 0) input = argv[++i];
    else if (strcmp(argv[i], "-o") == 0) output = argv[++i];
  }
  if (input == NULL || output == NULL) return 73;
  return copy_file(input, output);
}
EOF
cc -fPIC -shared \
  -o "$ELF_PACKAGE/bin/libweval_fixture.so" \
  "$ELF_PACKAGE/libweval_fixture.c"
cc -o "$ELF_PACKAGE/bin/weval-real" \
  "$ELF_PACKAGE/weval_fixture.c" \
  -L"$ELF_PACKAGE/bin" \
  -Wl,--dynamic-linker,"$ELF_LOADER" \
  -Wl,--enable-new-dtags \
  -Wl,-rpath,'$ORIGIN' \
  -lweval_fixture
ln -s "bin/weval-real" "$ELF_PACKAGE/weval argv0 alias"
seal_fixture_bundle "$ELF_PACKAGE/weval argv0 alias" "$ELF_BUNDLE"
run_fixture_aot \
  "$ELF_PACKAGE/weval argv0 alias" \
  "$ELF_BUNDLE" \
  "$ELF_OUTPUT"

build_rejected_runpath_package() {
  local label="$1" runpath="$2" soname="$3" dtags="$4"
  local package="$SCRATCH/$label runpath package"
  local bundle="$WORK/$label runpath bundle"
  mkdir -p \
    "$package/bin/lib" \
    "$package/bin/lib64" \
    "$package/bin/lib/x86_64-linux-gnu"
  cp "$ELF_LOADER" "$package/retained loader"
  cp "$ELF_PACKAGE/libweval_fixture.c" "$package/"
  cp "$ELF_PACKAGE/weval_fixture.c" "$package/"
  cc -fPIC -shared \
    -Wl,-soname,"$soname" \
    -o "$package/bin/$soname" \
    "$package/libweval_fixture.c"
  cp "$package/bin/$soname" "$package/bin/lib/$soname"
  cp "$package/bin/$soname" "$package/bin/lib64/$soname"
  cp "$package/bin/$soname" \
    "$package/bin/lib/x86_64-linux-gnu/$soname"
  local dtags_args=()
  if [ "$dtags" = rpath ]; then
    dtags_args=(-Wl,--disable-new-dtags)
  else
    dtags_args=(-Wl,--enable-new-dtags)
  fi
  cc -o "$package/bin/weval-real" \
    "$package/weval_fixture.c" \
    -L"$package/bin" \
    -Wl,--dynamic-linker,"$package/retained loader" \
    "${dtags_args[@]}" \
    -Wl,-rpath,"$runpath" \
    -Wl,-l:"$soname"
  ln -s "bin/weval-real" "$package/weval argv0 alias"
  seal_fixture_bundle "$package/weval argv0 alias" "$bundle"
  expect_fixture_aot_rejection \
    "$package/weval argv0 alias" \
    "$bundle" \
    "$label"
  grep -Fq UnsupportedRetainedExecution \
    "$SCRATCH/$label-package-rejection.log"
}

build_rejected_runpath_package \
  unsupported-token \
  '$ORIGIN/$LIB' \
  libz.so.1 \
  runpath
build_rejected_runpath_package \
  absolute-rpath \
  "$ELF_PACKAGE/bin" \
  libweval_absolute.so \
  rpath
build_rejected_runpath_package \
  ambiguous-runpath \
  "\$ORIGIN:$ELF_PACKAGE/bin" \
  libweval_ambiguous.so \
  runpath

TRANSITIVE_RPATH_PACKAGE="$SCRATCH/transitive RPATH package"
TRANSITIVE_RPATH_BUNDLE="$WORK/transitive RPATH bundle"
mkdir -p "$TRANSITIVE_RPATH_PACKAGE/bin"
cp "$ELF_LOADER" "$TRANSITIVE_RPATH_PACKAGE/retained loader"
cp "$ELF_PACKAGE/weval_fixture.c" "$TRANSITIVE_RPATH_PACKAGE/"
cat > "$TRANSITIVE_RPATH_PACKAGE/transitive-z.c" <<'EOF'
const char *transitive_z_marker(void) {
  return "origin-relative-library";
}
EOF
cat > "$TRANSITIVE_RPATH_PACKAGE/parent.c" <<'EOF'
extern const char *transitive_z_marker(void);
const char *weval_fixture_marker(void) {
  return transitive_z_marker();
}
EOF
cc -fPIC -shared \
  -Wl,-soname,libz.so.1 \
  -o "$TRANSITIVE_RPATH_PACKAGE/bin/libz.so.1" \
  "$TRANSITIVE_RPATH_PACKAGE/transitive-z.c"
cc -fPIC -shared \
  -Wl,-soname,libweval_parent.so \
  -L"$TRANSITIVE_RPATH_PACKAGE/bin" \
  -Wl,-l:libz.so.1 \
  -o "$TRANSITIVE_RPATH_PACKAGE/bin/libweval_parent.so" \
  "$TRANSITIVE_RPATH_PACKAGE/parent.c"
cc -o "$TRANSITIVE_RPATH_PACKAGE/bin/weval-real" \
  "$TRANSITIVE_RPATH_PACKAGE/weval_fixture.c" \
  -L"$TRANSITIVE_RPATH_PACKAGE/bin" \
  -Wl,--dynamic-linker,"$TRANSITIVE_RPATH_PACKAGE/retained loader" \
  -Wl,--disable-new-dtags \
  -Wl,-rpath,'$ORIGIN' \
  -Wl,-rpath-link,"$TRANSITIVE_RPATH_PACKAGE/bin" \
  -Wl,-l:libweval_parent.so
ln -s "bin/weval-real" \
  "$TRANSITIVE_RPATH_PACKAGE/weval argv0 alias"
seal_fixture_bundle \
  "$TRANSITIVE_RPATH_PACKAGE/weval argv0 alias" \
  "$TRANSITIVE_RPATH_BUNDLE"
expect_fixture_aot_rejection \
  "$TRANSITIVE_RPATH_PACKAGE/weval argv0 alias" \
  "$TRANSITIVE_RPATH_BUNDLE" \
  transitive-rpath
grep -Fq UnsupportedRetainedExecution \
  "$SCRATCH/transitive-rpath-package-rejection.log"
echo "Unsupported, ambiguous, and transitive RPATH closure matrix passed"

ELF_ENV_HOOK="$SCRATCH/ELF environment closure hook"
ELF_ENV_OUTPUT="$WORK/ELF environment substitution output.wasm"
ELF_ENV_EXECUTED="$SCRATCH/sealed ELF executable ran"
ELF_ENV_MALICIOUS="$SCRATCH/malicious library ran"
ELF_EXTERNAL_PACKAGE="$WORK/$(basename "$ELF_ENV_OUTPUT").external-package"
ELF_EXTERNAL_LIBRARY="$ELF_EXTERNAL_PACKAGE/weval-package/bin/libweval_fixture.so"
ELF_LOADER_BASELINE="$SCRATCH/retained-loader.baseline"
ELF_LIBRARY_BASELINE="$SCRATCH/retained-library.baseline"
mkdir "$ELF_ENV_HOOK"
cp -p "$ELF_LOADER" "$ELF_LOADER_BASELINE"
cp -p "$ELF_PACKAGE/bin/libweval_fixture.so" "$ELF_LIBRARY_BASELINE"
cat > "$SCRATCH/malicious-lib.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void loaded(void) {
  const char *path = getenv("MALICIOUS_LIBRARY_MARKER");
  if (path) {
    FILE *file = fopen(path, "w");
    if (file) { fputs("malicious library ran\n", file); fclose(file); }
  }
}
const char *weval_fixture_marker(void) { return "malicious"; }
EOF
cc -fPIC -shared \
  -o "$SCRATCH/malicious-libweval.so" \
  "$SCRATCH/malicious-lib.c"
mkdir "$SCRATCH/malicious library path"
cp "$SCRATCH/malicious-libweval.so" \
  "$SCRATCH/malicious library path/libweval_fixture.so"
printf 'preserved ELF environment output\n' > "$ELF_ENV_OUTPUT"
LD_LIBRARY_PATH="$SCRATCH/malicious library path" \
STARLING_COMPONENTIZER_TEST_HOOK_DIR="$ELF_ENV_HOOK" \
STARLING_COMPONENTIZER_TEST_WAIT_AT=retained-environment-captured-weval \
FAKE_AOT_EXECUTED_MARKER="$ELF_ENV_EXECUTED" \
MALICIOUS_LIBRARY_MARKER="$ELF_ENV_MALICIOUS" \
run_fixture_aot \
  "$ELF_PACKAGE/weval argv0 alias" \
  "$ELF_BUNDLE" \
  "$ELF_ENV_OUTPUT" \
  >"$SCRATCH/ELF-environment-substitution.log" 2>&1 &
elf_env_pid=$!
wait_for_test_hook \
  "$ELF_ENV_HOOK/retained-environment-captured-weval.ready"
printf 'substituted loader\n' > "$ELF_LOADER"
cp "$SCRATCH/malicious-libweval.so" "$ELF_EXTERNAL_LIBRARY"
touch "$ELF_ENV_HOOK/retained-environment-captured-weval.continue"
if wait "$elf_env_pid"; then
  echo "FAIL: loader/library substitution was accepted" >&2
  exit 1
fi
cp -p "$ELF_LOADER_BASELINE" "$ELF_LOADER"
cp -p "$ELF_LIBRARY_BASELINE" "$ELF_PACKAGE/bin/libweval_fixture.so"
grep -Fq TransactionChanged "$SCRATCH/ELF-environment-substitution.log" || {
  cat "$SCRATCH/ELF-environment-substitution.log" >&2
  exit 1
}
test "$(cat "$ELF_ENV_OUTPUT")" = "preserved ELF environment output"
test -e "$ELF_ENV_EXECUTED"
test ! -e "$ELF_ENV_MALICIOUS"
echo "Retained loader and shared-library substitution rejected"

cp -p "$ELF_PACKAGE/bin/libweval_fixture.so" \
  "$SCRATCH/libweval-fixture.baseline"
printf 'library mutation\n' >> "$ELF_PACKAGE/bin/libweval_fixture.so"
expect_fixture_aot_rejection \
  "$ELF_PACKAGE/weval argv0 alias" \
  "$ELF_BUNDLE" \
  origin-library
cp -p "$SCRATCH/libweval-fixture.baseline" \
  "$ELF_PACKAGE/bin/libweval_fixture.so"

SYMLINK_PACKAGE="$SCRATCH/symlink target package"
SYMLINK_BUNDLE="$WORK/symlink target bundle"
mkdir "$SYMLINK_PACKAGE"
cp "$FAKE_WEVAL" "$SYMLINK_PACKAGE/target A"
cp "$FAKE_WEVAL" "$SYMLINK_PACKAGE/target B"
ln -s "target A" "$SYMLINK_PACKAGE/selected weval"
seal_fixture_bundle \
  "$SYMLINK_PACKAGE/selected weval" \
  "$SYMLINK_BUNDLE"
ln -sfn "target B" "$SYMLINK_PACKAGE/selected weval"
expect_fixture_aot_rejection \
  "$SYMLINK_PACKAGE/selected weval" \
  "$SYMLINK_BUNDLE" \
  symlink-target

UNSAFE_PACKAGE="$SCRATCH/unsafe weval package"
UNSAFE_BUNDLE="$WORK/unsafe weval bundle"
UNSAFE_OUTPUT="$WORK/unsafe weval output.wasm"
mkdir "$UNSAFE_PACKAGE"
cp "$FAKE_WEVAL" "$UNSAFE_PACKAGE/weval"
printf 'outside package\n' > "$SCRATCH/outside package sibling"
ln -s "../outside package sibling" "$UNSAFE_PACKAGE/escaping sibling"
if seal_fixture_bundle \
  "$UNSAFE_PACKAGE/weval" \
  "$UNSAFE_BUNDLE" >"$SCRATCH/unsafe-weval.log" 2>&1
then
  echo "FAIL: escaping Weval package symlink was sealed" >&2
  exit 1
fi
grep -Fq UnsafeWevalPackage "$SCRATCH/unsafe-weval.log"

SAFE_LINK_PACKAGE="$SCRATCH/safe intermediate symlink package"
SAFE_LINK_BUNDLE="$WORK/safe intermediate symlink bundle"
SAFE_LINK_OUTPUT="$WORK/safe intermediate symlink output.wasm"
mkdir -p "$SAFE_LINK_PACKAGE/bin" "$SAFE_LINK_PACKAGE/aliases"
cp "$FAKE_WEVAL" "$SAFE_LINK_PACKAGE/bin/weval-real"
ln -s "../bin" "$SAFE_LINK_PACKAGE/aliases/tool-dir"
ln -s "aliases/tool-dir/weval-real" "$SAFE_LINK_PACKAGE/selected weval"
seal_fixture_bundle \
  "$SAFE_LINK_PACKAGE/selected weval" \
  "$SAFE_LINK_BUNDLE"
run_fixture_aot \
  "$SAFE_LINK_PACKAGE/selected weval" \
  "$SAFE_LINK_BUNDLE" \
  "$SAFE_LINK_OUTPUT"

EXTERNAL_UNSAFE_PACKAGE="$SCRATCH/external unsafe symlink package"
EXTERNAL_UNSAFE_BUNDLE="$WORK/external unsafe symlink bundle"
mkdir "$EXTERNAL_UNSAFE_PACKAGE"
cp "$FAKE_WEVAL" "$EXTERNAL_UNSAFE_PACKAGE/weval"
seal_fixture_bundle \
  "$EXTERNAL_UNSAFE_PACKAGE/weval" \
  "$EXTERNAL_UNSAFE_BUNDLE"
ln -s ".." "$EXTERNAL_UNSAFE_PACKAGE/parent"
ln -s "parent/outside package sibling" \
  "$EXTERNAL_UNSAFE_PACKAGE/through-parent"
expect_fixture_aot_rejection \
  "$EXTERNAL_UNSAFE_PACKAGE/weval" \
  "$EXTERNAL_UNSAFE_BUNDLE" \
  external-intermediate-escape
grep -Fq UnsupportedInputEntry \
  "$SCRATCH/external-intermediate-escape-package-rejection.log"

assert_unsafe_symlink_package() {
  local label="$1" link="$2" target="$3"
  local package="$SCRATCH/$label symlink package"
  local bundle="$WORK/$label symlink bundle"
  mkdir "$package"
  cp "$FAKE_WEVAL" "$package/weval"
  ln -s "$target" "$package/$link"
  if seal_fixture_bundle \
    "$package/weval" \
    "$bundle" >"$SCRATCH/$label-symlink.log" 2>&1
  then
    echo "FAIL: $label package symlink was accepted" >&2
    exit 1
  fi
  grep -Fq UnsafeWevalPackage "$SCRATCH/$label-symlink.log"
}

assert_unsafe_symlink_package dangling dangling missing
assert_unsafe_symlink_package cycle-a cycle-a cycle-b
ln -s cycle-a "$SCRATCH/cycle-a symlink package/cycle-b"
if seal_fixture_bundle \
  "$SCRATCH/cycle-a symlink package/weval" \
  "$WORK/cycle-a symlink retry bundle" \
  >"$SCRATCH/cycle-symlink.log" 2>&1
then
  echo "FAIL: cyclic package symlink was accepted" >&2
  exit 1
fi
grep -Fq UnsafeWevalPackage "$SCRATCH/cycle-symlink.log"

INTERMEDIATE_ESCAPE_PACKAGE="$SCRATCH/intermediate escape symlink package"
INTERMEDIATE_ESCAPE_BUNDLE="$WORK/intermediate escape symlink bundle"
mkdir "$INTERMEDIATE_ESCAPE_PACKAGE"
cp "$FAKE_WEVAL" "$INTERMEDIATE_ESCAPE_PACKAGE/weval"
ln -s ".." "$INTERMEDIATE_ESCAPE_PACKAGE/parent"
ln -s "parent/outside package sibling" \
  "$INTERMEDIATE_ESCAPE_PACKAGE/through-parent"
if seal_fixture_bundle \
  "$INTERMEDIATE_ESCAPE_PACKAGE/weval" \
  "$INTERMEDIATE_ESCAPE_BUNDLE" \
  >"$SCRATCH/intermediate-escape-symlink.log" 2>&1
then
  echo "FAIL: intermediate escaping symlink was accepted" >&2
  exit 1
fi
grep -Fq UnsafeWevalPackage "$SCRATCH/intermediate-escape-symlink.log"
echo "Descriptor-relative package symlink matrix passed"

NOEXEC_OUTPUT_DIR="$SCRATCH/noexec output"
mkdir "$NOEXEC_OUTPUT_DIR"
mount_noexec=(mount)
if [ "${STARLING_NOEXEC_SUDO:-0}" = 1 ]; then
  mount_noexec=(sudo -n mount)
fi
noexec_options="noexec,mode=700,size=8m,uid=$(id -u),gid=$(id -g)"
if command -v mount >/dev/null &&
  "${mount_noexec[@]}" -t tmpfs -o "$noexec_options" \
    starling-componentizer-noexec "$NOEXEC_OUTPUT_DIR" \
    2>"$SCRATCH/noexec-mount.log"; then
  NOEXEC_MOUNTED=1
  if ! findmnt -n -o OPTIONS --target "$NOEXEC_OUTPUT_DIR" |
    tr ',' '\n' | grep -Fxq noexec
  then
    unmount_noexec "$NOEXEC_OUTPUT_DIR"
    NOEXEC_MOUNTED=0
  fi
fi
if [ "$NOEXEC_MOUNTED" -ne 1 ]; then
  if [ "${STARLING_REQUIRE_NOEXEC:-0}" = 1 ]; then
    echo "FAIL: required genuine noexec mount is unavailable" >&2
    cat "$SCRATCH/noexec-mount.log" >&2 || true
    exit 1
  fi
  echo "SKIP: genuine noexec mount is unavailable"
else
  NOEXEC_OUTPUT="$NOEXEC_OUTPUT_DIR/aot component.wasm"
  EXPECT_AOT_EXEC_STAGE_OUTSIDE="$NOEXEC_OUTPUT_DIR" \
  "$COMPONENTIZER" \
    --aot \
    --engine "$ENGINE" \
    --aot-cache-dir "$AOT_BUNDLE" \
    --weval-bin "$FAKE_WEVAL" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$NOEXEC_OUTPUT" \
    "$SOURCE"
  assert_engine_payload "$NOEXEC_OUTPUT"
  test -z "$(find "$TOOLS" -maxdepth 1 \
    -name '.starling-aot-exec-*' -print -quit)"

  DEFAULT_TEMP="$SCRATCH/platform default temp"
  READONLY_INSTALL="$SCRATCH/read-only install"
  mkdir "$DEFAULT_TEMP" "$READONLY_INSTALL"
  cp "$COMPONENTIZER" "$READONLY_INSTALL/starling-componentize"
  mkdir "$READONLY_INSTALL/weval-package"
  cp "$FAKE_WEVAL" "$READONLY_INSTALL/weval-package/weval"
  chmod 500 "$READONLY_INSTALL/starling-componentize" \
    "$READONLY_INSTALL/weval-package/weval"
  chmod 500 "$READONLY_INSTALL"
  DEFAULT_TEMP_OUTPUT="$NOEXEC_OUTPUT_DIR/default temp aot component.wasm"
  (
    cd "$NOEXEC_OUTPUT_DIR"
    env -u ZIG_GLOBAL_CACHE_DIR -u XDG_RUNTIME_DIR -u TMPDIR -u TMP \
      -u TEMP \
      STARLING_AOT_CACHE_TEST_DEFAULT_TMPDIR="$DEFAULT_TEMP" \
      EXPECT_AOT_EXEC_STAGE_OUTSIDE="$NOEXEC_OUTPUT_DIR" \
      EXPECT_AOT_EXEC_STAGE_ROOT="$DEFAULT_TEMP" \
      "$READONLY_INSTALL/starling-componentize" \
        --aot \
        --engine "$ENGINE" \
        --aot-cache-dir "$AOT_BUNDLE" \
        --weval-bin "$READONLY_INSTALL/weval-package/weval" \
        --preview2-adapter "$ADAPTER" \
        --wit "$WIT" \
        --world-name exports \
        --wabt-bin "$TOOLS/fake wabt" \
        --wasm-tools-bin "$TOOLS/fake wasm-tools" \
        --out "$DEFAULT_TEMP_OUTPUT" \
        "$SOURCE"
  )
  assert_engine_payload "$DEFAULT_TEMP_OUTPUT"
  test -z "$(find "$DEFAULT_TEMP" -maxdepth 1 \
    -name '.starling-aot-exec-*' -print -quit)"
  chmod 700 "$READONLY_INSTALL"
  unmount_noexec "$NOEXEC_OUTPUT_DIR"
  NOEXEC_MOUNTED=0
  echo "AOT noexec output staging passed (mounted noexec filesystem)"
fi

expect_seal_failure() {
  local cache="$1" label="$2"
  if "$CACHE_TOOL" seal \
    --engine "$ENGINE" \
    --weval "$FAKE_WEVAL" \
    --cache "$cache" \
    --primer "$SOURCE" \
    --feature-abi "$FEATURE_ABI" \
    --out "$WORK/$label.manifest"
  then
    echo "FAIL: $label cache unexpectedly sealed" >&2
    exit 1
  fi
  test ! -e "$WORK/$label.manifest"
}

MALFORMED_SCHEMA_CACHE="$WORK/malformed schema.sqlite"
DECOY_CACHE="$WORK/decoy digest.sqlite"
python3 - "$MALFORMED_SCHEMA_CACHE" "$DECOY_CACHE" "$ENGINE" <<'PY'
import hashlib
import sqlite3
import sys

with open(sys.argv[3], "rb") as engine:
    engine_hash = hashlib.sha256(engine.read()).digest()

malformed = sqlite3.connect(sys.argv[1])
malformed.execute(
    "create table weval_cache(module_hash blob, key blob, result blob, created_time integer)"
)
malformed.execute(
    "insert into weval_cache values (?, ?, ?, 0)",
    (engine_hash, b"key", b"result"),
)
malformed.commit()
malformed.close()

decoy = sqlite3.connect(sys.argv[2])
decoy.execute("""create table weval_cache(
    module_hash blob not null,
    key blob not null,
    result blob not null,
    created_time integer not null
)""")
decoy.execute("create index idx on weval_cache(module_hash, key)")
decoy.execute(
    "insert into weval_cache values (?, ?, ?, 0)",
    (b"x" * 32, b"key", b"result"),
)
decoy.execute("create table digest_decoy(value blob not null)")
decoy.execute("insert into digest_decoy values (?)", (engine_hash,))
decoy.commit()
decoy.close()
PY
expect_seal_failure "$MALFORMED_SCHEMA_CACHE" malformed-schema
expect_seal_failure "$DECOY_CACHE" no-live-engine-row

EXTRA_INDEX_CACHE="$WORK/extra index.sqlite"
cp "$AOT_BUNDLE/starling-ics.wevalcache" "$EXTRA_INDEX_CACHE"
python3 - "$EXTRA_INDEX_CACHE" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("create index idx_extra on weval_cache(created_time)")
db.commit()
db.close()
PY
expect_seal_failure "$EXTRA_INDEX_CACHE" extra-index

INTEGRITY_CACHE="$WORK/integrity corrupt.sqlite"
cp "$AOT_BUNDLE/starling-ics.wevalcache" "$INTEGRITY_CACHE"
python3 - "$INTEGRITY_CACHE" <<'PY'
import sys
with open(sys.argv[1], "r+b") as cache:
    cache.seek(100)
    byte = cache.read(1)
    cache.seek(100)
    cache.write(bytes([byte[0] ^ 0xff]))
PY
expect_seal_failure "$INTEGRITY_CACHE" integrity-corrupt

RUNTIME_ONLY_OUTPUT="$WORK/runtime only output.wasm"
rm -f "$FAKE_AOT_RUNTIME_ARGS_LOG"
WIZER_BIN="$INVALID_WIZER" "$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --weval-bin "$FAKE_WEVAL" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --output "$RUNTIME_ONLY_OUTPUT"
"$REAL_WASM_TOOLS" validate --features all "$RUNTIME_ONLY_OUTPUT"
test -e "$FAKE_AOT_RUNTIME_ARGS_LOG"
test ! -s "$FAKE_AOT_RUNTIME_ARGS_LOG"
python3 - "$FAKE_AOT_ARGV_LOG" <<'PY'
import sys

args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
assert args[args.index("--init-func") + 1] == "starling-aot-runtime-initialize"
PY

export EXPECTED_RUST_MIN_STACK=123456
PATH="$WEVAL_PACKAGE:$TOOLS:$PATH" RUST_MIN_STACK=999 WIZER_BIN="$INVALID_WIZER" \
"$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --aot-min-stack-size "$EXPECTED_RUST_MIN_STACK" \
  --weval-bin "fake weval" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin path-wabt \
  --wasm-tools-bin path-wasm-tools \
  --out "$AOT_OUTPUT" \
  "$SOURCE"
assert_engine_payload "$AOT_OUTPUT"
grep -Fq -- "\"$SOURCE\"" "$FAKE_AOT_RUNTIME_ARGS_LOG"

LEGACY_PREOPEN="$SCRATCH/legacy preopen"
LEGACY_PREOPEN_OUTPUT="$WORK/legacy preopen output.wasm"
mkdir -p "$LEGACY_PREOPEN"
export EXPECTED_RUST_MIN_STACK=8388608
env PATH="$WEVAL_PACKAGE:$TOOLS:$PATH" \
  WEVAL_BIN="fake weval" WABT=path-wabt WASM_TOOLS_BIN=path-wasm-tools \
  "$COMPONENTIZER" \
  --aot \
  --legacy-wrapper-preopen \
  --preopen-dir "$LEGACY_PREOPEN" \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --out "$LEGACY_PREOPEN_OUTPUT" \
  "$SOURCE"
python3 - "$FAKE_AOT_ARGV_LOG" "$LEGACY_PREOPEN" "$WORK" <<'PY'
import sys
args = [arg.decode() for arg in open(sys.argv[1], "rb").read().split(b"\0")[:-1]]
preopens = [args[index + 1] for index, arg in enumerate(args) if arg == "--dir"]
assert [value.rsplit("::", 1)[-1] for value in preopens] == [
    sys.argv[3],
    sys.argv[2],
], preopens
PY

DIRECT_CACHE_OUTPUT="$WORK/direct cache output.wasm"
"$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE/starling-ics.wevalcache" \
  --weval-bin "$FAKE_WEVAL" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$DIRECT_CACHE_OUTPUT" \
  "$SOURCE"
assert_engine_payload "$DIRECT_CACHE_OUTPUT"

SUBSTITUTE_ROOT="$SCRATCH/coherent substituted AOT inputs"
SUBSTITUTE_ENGINE="$SUBSTITUTE_ROOT/substituted engine.wasm"
SUBSTITUTE_WEVAL_PACKAGE="$SUBSTITUTE_ROOT/substituted weval package"
SUBSTITUTE_WEVAL="$SUBSTITUTE_WEVAL_PACKAGE/fake weval"
SUBSTITUTE_BUNDLE="$SUBSTITUTE_ROOT/substituted bundle"
mkdir -p "$SUBSTITUTE_WEVAL_PACKAGE" "$SUBSTITUTE_BUNDLE"
cp "$ENGINE" "$SUBSTITUTE_ENGINE"
printf '\0\1\0' >> "$SUBSTITUTE_ENGINE"
cp -a "$WEVAL_PACKAGE/." "$SUBSTITUTE_WEVAL_PACKAGE/"
printf '# coherent substituted package\n' >> "$SUBSTITUTE_WEVAL"
python3 - "$SUBSTITUTE_BUNDLE/raw.wevalcache" \
  "$SUBSTITUTE_ENGINE" <<'PY'
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
db.execute("create index idx on weval_cache(module_hash, key)")
db.execute(
    "insert into weval_cache values (?, ?, ?, 1)",
    (engine_hash, b"substituted-key", b"substituted-result"),
)
db.commit()
db.close()
PY
"$CACHE_TOOL" seal \
  --engine "$SUBSTITUTE_ENGINE" \
  --weval "$SUBSTITUTE_WEVAL" \
  --cache "$SUBSTITUTE_BUNDLE/raw.wevalcache" \
  --cache-out "$SUBSTITUTE_BUNDLE/starling-ics.wevalcache" \
  --primer "$SOURCE" \
  --feature-abi "$FEATURE_ABI" \
  --out "$SUBSTITUTE_BUNDLE/starling-ics.wevalcache.manifest"
"$CACHE_TOOL" validate \
  --engine "$SUBSTITUTE_ENGINE" \
  --weval "$SUBSTITUTE_WEVAL" \
  --cache "$SUBSTITUTE_BUNDLE/starling-ics.wevalcache" \
  --manifest "$SUBSTITUTE_BUNDLE/starling-ics.wevalcache.manifest" \
  --feature-abi "$FEATURE_ABI"

wait_for_capture_hook() {
  local ready="$1"
  for _ in $(seq 1 10000); do
    test -e "$ready" && return
    sleep 0.001
  done
  echo "FAIL: timed out waiting for AOT capture hook" >&2
  exit 1
}

install_coherent_substitute() {
  mv "$ENGINE" "$ENGINE.capture-original"
  cp "$SUBSTITUTE_ENGINE" "$ENGINE"
  mv "$AOT_BUNDLE/starling-ics.wevalcache" \
    "$AOT_BUNDLE/starling-ics.wevalcache.capture-original"
  cp "$SUBSTITUTE_BUNDLE/starling-ics.wevalcache" \
    "$AOT_BUNDLE/starling-ics.wevalcache"
  mv "$AOT_BUNDLE/starling-ics.wevalcache.manifest" \
    "$AOT_BUNDLE/starling-ics.wevalcache.manifest.capture-original"
  cp "$SUBSTITUTE_BUNDLE/starling-ics.wevalcache.manifest" \
    "$AOT_BUNDLE/starling-ics.wevalcache.manifest"
  mv "$WEVAL_PACKAGE" "$WEVAL_PACKAGE.capture-original"
  cp -a "$SUBSTITUTE_WEVAL_PACKAGE" "$WEVAL_PACKAGE"
}

restore_captured_inputs() {
  rm -f "$ENGINE"
  mv "$ENGINE.capture-original" "$ENGINE"
  rm -f "$AOT_BUNDLE/starling-ics.wevalcache"
  mv "$AOT_BUNDLE/starling-ics.wevalcache.capture-original" \
    "$AOT_BUNDLE/starling-ics.wevalcache"
  rm -f "$AOT_BUNDLE/starling-ics.wevalcache.manifest"
  mv "$AOT_BUNDLE/starling-ics.wevalcache.manifest.capture-original" \
    "$AOT_BUNDLE/starling-ics.wevalcache.manifest"
  rm -rf "$WEVAL_PACKAGE"
  mv "$WEVAL_PACKAGE.capture-original" "$WEVAL_PACKAGE"
}

run_capture_race() {
  local hook="$1" output="$2"
  STARLING_COMPONENTIZER_TEST_HOOK_DIR="$hook" \
  STARLING_COMPONENTIZER_TEST_WAIT_AT=aot-inputs-captured \
    "$COMPONENTIZER" \
      --aot \
      --engine "$ENGINE" \
      --aot-cache-dir "$AOT_BUNDLE" \
      --weval-bin "$FAKE_WEVAL" \
      --preview2-adapter "$ADAPTER" \
      --wit "$WIT" \
      --world-name exports \
      --wabt-bin "$TOOLS/fake wabt" \
      --wasm-tools-bin "$TOOLS/fake wasm-tools" \
      --out "$output" \
      "$SOURCE"
}

ANCESTOR_HOOK="$SCRATCH/ancestor capture hook"
ANCESTOR_OUTPUT="$WORK/ancestor substitution output.wasm"
mkdir "$ANCESTOR_HOOK"
printf 'preserved package transaction output\n' > "$ANCESTOR_OUTPUT"
STARLING_COMPONENTIZER_TEST_HOOK_DIR="$ANCESTOR_HOOK" \
STARLING_COMPONENTIZER_TEST_WAIT_AT=external-inputs-snapshotted \
  "$COMPONENTIZER" \
    --aot \
    --engine "$ENGINE" \
    --aot-cache-dir "$AOT_BUNDLE" \
    --weval-bin "$FAKE_WEVAL" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$ANCESTOR_OUTPUT" \
    "$SOURCE" >"$SCRATCH/ancestor-capture.log" 2>&1 &
ancestor_pid=$!
wait_for_capture_hook \
  "$ANCESTOR_HOOK/external-inputs-snapshotted.ready"
install_coherent_substitute
touch "$ANCESTOR_HOOK/external-inputs-snapshotted.continue"
wait "$ancestor_pid"
restore_captured_inputs
assert_engine_payload "$ANCESTOR_OUTPUT"
echo "Unified runtime-to-AOT snapshot isolated from package substitution"

TRANSIENT_HOOK="$SCRATCH/transient capture hook"
TRANSIENT_OUTPUT="$WORK/transient substitution output.wasm"
mkdir "$TRANSIENT_HOOK"
printf 'preserved restored substitution output\n' > "$TRANSIENT_OUTPUT"
run_capture_race "$TRANSIENT_HOOK" "$TRANSIENT_OUTPUT" \
  >"$SCRATCH/transient-capture.log" 2>&1 &
capture_pid=$!
wait_for_capture_hook "$TRANSIENT_HOOK/aot-inputs-captured.ready"
install_coherent_substitute
restore_captured_inputs
touch "$TRANSIENT_HOOK/aot-inputs-captured.continue"
wait "$capture_pid"
assert_engine_payload "$TRANSIENT_OUTPUT"

UNRESTORED_HOOK="$SCRATCH/unrestored capture hook"
UNRESTORED_OUTPUT="$WORK/unrestored substitution output.wasm"
mkdir "$UNRESTORED_HOOK"
printf 'preserved unrestored output\n' > "$UNRESTORED_OUTPUT"
run_capture_race "$UNRESTORED_HOOK" "$UNRESTORED_OUTPUT" \
  >"$SCRATCH/unrestored-capture.log" 2>&1 &
capture_pid=$!
wait_for_capture_hook "$UNRESTORED_HOOK/aot-inputs-captured.ready"
install_coherent_substitute
touch "$UNRESTORED_HOOK/aot-inputs-captured.continue"
wait "$capture_pid"
restore_captured_inputs
assert_engine_payload "$UNRESTORED_OUTPUT"
echo "Retained AOT snapshot substitution isolation matrix passed"

RACE_ENGINE_PACKAGE="$WORK/race engine package"
cp -R "$ENGINE_PACKAGE" "$RACE_ENGINE_PACKAGE"
RACE_ENGINE="$RACE_ENGINE_PACKAGE/fake engine.wasm"
RACE_PACKAGE="$RACE_ENGINE_PACKAGE/weval-package"
RACE_WEVAL="$RACE_PACKAGE/race weval"
RACE_SIBLING="$RACE_PACKAGE/race sibling"
RACE_BUNDLE="$RACE_ENGINE_PACKAGE"
RACE_ENGINE_BASELINE="$WORK/race engine baseline.wasm"
RACE_CACHE_BASELINE="$WORK/race cache baseline.sqlite"
RACE_OUTPUT="$WORK/race output component.wasm"
cp "$FAKE_WEVAL" "$RACE_WEVAL"
printf 'snapshot sibling\n' > "$RACE_SIBLING"
rm -rf "$RACE_BUNDLE"/.starling-aot-seal-*
"$CACHE_TOOL" seal \
  --engine "$RACE_ENGINE" \
  --weval "$RACE_WEVAL" \
  --cache "$RACE_BUNDLE/starling-ics.wevalcache" \
  --primer "$SOURCE" \
  --feature-abi "$FEATURE_ABI" \
  --out "$RACE_BUNDLE/starling-ics.wevalcache.manifest"
cp "$RACE_ENGINE" "$RACE_ENGINE_BASELINE"
cp "$RACE_BUNDLE/starling-ics.wevalcache" "$RACE_CACHE_BASELINE"
printf 'preserved retained-object race output\n' > "$RACE_OUTPUT"
if ! EXPECT_AOT_SNAPSHOT=1 \
ORIGINAL_AOT_ENGINE="$RACE_ENGINE" \
ORIGINAL_AOT_CACHE="$RACE_BUNDLE/starling-ics.wevalcache" \
ORIGINAL_AOT_WEVAL="$RACE_WEVAL" \
ORIGINAL_AOT_SIBLING="$RACE_SIBLING" \
EXPECTED_AOT_ENGINE="$RACE_ENGINE_BASELINE" \
EXPECTED_AOT_CACHE="$RACE_CACHE_BASELINE" \
"$COMPONENTIZER" \
  --aot \
  --engine "$RACE_ENGINE" \
  --aot-cache-dir "$RACE_BUNDLE" \
  --weval-bin "$RACE_WEVAL" \
  --preview2-adapter "$RACE_ENGINE_PACKAGE/preview1-adapter.wasm" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$RACE_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: retained-object snapshot isolation failed" >&2
  exit 1
fi
test -s "$RACE_OUTPUT"
if ! cmp -s -n "$(stat -c %s "$RACE_ENGINE_BASELINE")" \
  "$RACE_ENGINE_BASELINE" "$RACE_OUTPUT"
then
  "$REAL_WASM_TOOLS" validate --features all "$RACE_OUTPUT"
fi
test "$(cat "$RACE_ENGINE")" = "replacement engine"
test "$(cat "$RACE_BUNDLE/starling-ics.wevalcache")" = "replacement cache"
test "$(cat "$RACE_SIBLING")" = "replacement sibling"
echo "Retained-object mutations isolated from published output"

AOT_FAILURE_OUTPUT="$WORK/aot failure output.wasm"
printf 'preserved-aot-output\n' > "$AOT_FAILURE_OUTPUT"
if FAKE_AOT_FAIL=1 "$COMPONENTIZER" \
  --aot \
  --engine "$ENGINE" \
  --aot-cache-dir "$AOT_BUNDLE" \
  --weval-bin "$FAKE_WEVAL" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$AOT_FAILURE_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: injected AOT failure unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$AOT_FAILURE_OUTPUT")" = "preserved-aot-output"
if find "$WORK" -maxdepth 1 -name '.*.starling-componentize-*' | grep -q .; then
  echo "FAIL: AOT componentization left private transaction artifacts" >&2
  while IFS= read -r artifact; do
    find "$artifact" -maxdepth 2 -ls >&2
  done < <(find "$WORK" -maxdepth 1 -name '.*.starling-componentize-*')
  exit 1
fi

expect_aot_cache_failure() {
  local bundle="$1" engine="$2" weval="$3" label="$4"
  local failure_output="$WORK/$label output.wasm"
  printf 'preserved\n' > "$failure_output"
  if "$COMPONENTIZER" \
    --aot \
    --engine "$engine" \
    --aot-cache-dir "$bundle" \
    --weval-bin "$weval" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$failure_output" \
    "$SOURCE"
  then
    echo "FAIL: $label AOT cache unexpectedly succeeded" >&2
    exit 1
  fi
  test "$(cat "$failure_output")" = "preserved"
}

expect_aot_cache_failure "$WORK/missing bundle" "$ENGINE" "$FAKE_WEVAL" missing

STALE_ENGINE_PACKAGE="$WORK/stale engine package"
cp -R "$ENGINE_PACKAGE" "$STALE_ENGINE_PACKAGE"
STALE_ENGINE="$STALE_ENGINE_PACKAGE/fake engine.wasm"
printf '\0\1\0' >> "$STALE_ENGINE"
expect_aot_cache_failure "$AOT_BUNDLE" "$STALE_ENGINE" "$FAKE_WEVAL" stale

CORRUPT_BUNDLE="$WORK/corrupt cache bundle"
cp -R "$AOT_BUNDLE" "$CORRUPT_BUNDLE"
printf 'corrupt\n' >> "$CORRUPT_BUNDLE/starling-ics.wevalcache"
expect_aot_cache_failure "$CORRUPT_BUNDLE" "$ENGINE" "$FAKE_WEVAL" corrupt

STALE_WEVAL="$TOOLS/stale weval"
cp "$FAKE_WEVAL" "$STALE_WEVAL"
printf '# stale tool\n' >> "$STALE_WEVAL"
expect_aot_cache_failure "$AOT_BUNDLE" "$ENGINE" "$STALE_WEVAL" stale-tool

INVALID_BUNDLE="$WORK/invalid manifest bundle"
cp -R "$AOT_BUNDLE" "$INVALID_BUNDLE"
printf 'not-a-manifest\n' > "$INVALID_BUNDLE/starling-ics.wevalcache.manifest"
expect_aot_cache_failure "$INVALID_BUNDLE" "$ENGINE" "$FAKE_WEVAL" invalid-manifest
unset EXPECTED_RUST_MIN_STACK

SOURCE_ALIAS_DIR="$SCRATCH/real sources"
SOURCE_ALIAS="$WORK/source alias.js"
SOURCE_ALIAS_OUTPUT="$WORK/source alias.wasm"
mkdir -p "$SOURCE_ALIAS_DIR"
printf 'export const aliased = true;\n' > "$SOURCE_ALIAS_DIR/source.js"
ln -s "$SOURCE_ALIAS_DIR/source.js" "$SOURCE_ALIAS"
(
  cd "$WORK"
  "$COMPONENTIZER" \
    --engine "$ENGINE" \
    --preview2-adapter "$ADAPTER" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    "$SOURCE_ALIAS"
)
grep -Fq -- "\"$SOURCE_ALIAS_DIR/source.js\"" "$FAKE_RUNTIME_ARGS_LOG"
assert_engine_payload "$SOURCE_ALIAS_OUTPUT"
rm "$SOURCE_ALIAS"

SOURCE_CONTENT="$(cat "$SOURCE")"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$SOURCE" \
  "$SOURCE"
then
  echo "FAIL: source/output collision unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$SOURCE")" = "$SOURCE_CONTENT"

printf 'original-output\n' > "$OUTPUT"
if FAKE_FAIL_STAGE="component embed" "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --out "$OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: injected component-embed failure unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$OUTPUT")" = "original-output"
if find "$WORK" -maxdepth 1 -name '.output component.wasm.starling-componentize-*' \
  | grep -q .; then
  echo "FAIL: failed componentization left transaction artifacts" >&2
  exit 1
fi

COLLISION_DIR="$WORK/debug collision"
COLLISION_OUTPUT="$COLLISION_DIR/component.wasm"
mkdir -p "$COLLISION_DIR"
printf 'collision-output\n' > "$COLLISION_OUTPUT"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$COLLISION_DIR" \
  --out "$COLLISION_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: debug/output collision unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$COLLISION_OUTPUT")" = "collision-output"

SYMLINK_DEBUG_DIR="$WORK/debug symlink"
SYMLINK_OUTPUT="$WORK/component.wasm"
ln -s "$WORK" "$SYMLINK_DEBUG_DIR"
printf 'symlink-collision-output\n' > "$SYMLINK_OUTPUT"
if "$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$SYMLINK_DEBUG_DIR" \
  --out "$SYMLINK_OUTPUT" \
  "$SOURCE"
then
  echo "FAIL: symlinked debug/output collision unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$SYMLINK_OUTPUT")" = "symlink-collision-output"
rm "$SYMLINK_DEBUG_DIR"

LINK_DEBUG_DIR="$WORK/debug file link"
LINK_TARGET="$WORK/commands link target.txt"
LINK_OUTPUT="$WORK/link-safe output.wasm"
mkdir -p "$LINK_DEBUG_DIR"
printf 'link-target\n' > "$LINK_TARGET"
ln -s "$LINK_TARGET" "$LINK_DEBUG_DIR/commands.txt"
"$COMPONENTIZER" \
  --engine "$ENGINE" \
  --preview2-adapter "$ADAPTER" \
  --wit "$WIT" \
  --world-name exports \
  --wizer-bin "$TOOLS/fake wizer" \
  --wabt-bin "$TOOLS/fake wabt" \
  --wasm-tools-bin "$TOOLS/fake wasm-tools" \
  --debug-dir "$LINK_DEBUG_DIR" \
  --out "$LINK_OUTPUT" \
  "$SOURCE"
test "$(cat "$LINK_TARGET")" = "link-target"
test ! -L "$LINK_DEBUG_DIR/commands.txt"
grep -Fxq 'wizer' "$LINK_DEBUG_DIR/commands.txt"
grep -Fq '<transaction>' "$LINK_DEBUG_DIR/commands.txt"

CACHE="$WORK/runtime cache"
BUILD_OUTPUT_1="$WORK/built output 1.wasm"
BUILD_OUTPUT_2="$WORK/built output 2.wasm"
BUILD_OUTPUT_3="$WORK/built output 3.wasm"
build_with_fake_zig() {
  local output="$1" zig_bin="${2:-$TOOLS/fake zig}"
  "$COMPONENTIZER" \
    --build-root "$ROOT" \
    --cache-dir "$CACHE" \
    --zig-bin "$zig_bin" \
    --wit "$WIT" \
    --world-name exports \
    --wizer-bin "$TOOLS/fake wizer" \
    --wabt-bin "$TOOLS/fake wabt" \
    --wasm-tools-bin "$TOOLS/fake wasm-tools" \
    --out "$output" \
    "$SOURCE"
}
build_with_env_tools() {
  local output="$1"
  env PATH="$TOOLS:$PATH" \
    ZIG=path-zig WIZER_BIN=path-wizer WABT=path-wabt \
    WASM_TOOLS_BIN=path-wasm-tools \
    "$COMPONENTIZER" \
      --build-root "$ROOT" \
      --cache-dir "$CACHE" \
      --wit "$WIT" \
      --world-name exports \
      --out "$output" \
      "$SOURCE"
}
PATH="$TOOLS:$PATH" build_with_fake_zig "$BUILD_OUTPUT_1" path-zig
build_with_env_tools "$BUILD_OUTPUT_2"
printf '\n// cache invalidation\n' >> "$WIT/world.wit"
build_with_fake_zig "$BUILD_OUTPUT_3"
rm -rf "$CACHE"
export FAKE_ZIG_ACTIVE_DIR="$SCRATCH/fake-zig-active"
export FAKE_ZIG_DELAY=1
CONCURRENT_OUTPUTS="$SCRATCH/concurrent outputs"
mkdir -p "$CONCURRENT_OUTPUTS/one" "$CONCURRENT_OUTPUTS/two"
build_with_fake_zig "$CONCURRENT_OUTPUTS/one/output.wasm" &
pid1=$!
build_with_fake_zig "$CONCURRENT_OUTPUTS/two/output.wasm" &
pid2=$!
wait "$pid1"
wait "$pid2"
unset FAKE_ZIG_ACTIVE_DIR FAKE_ZIG_DELAY

mapfile -t prefixes < "$FAKE_ZIG_PREFIX_LOG"
test "${#prefixes[@]}" -eq 5
for prefix in "${prefixes[@]}"; do
  case "$prefix" in
    /proc/self/fd/*) ;;
    *)
      echo "FAIL: fake Zig received a non-retained prefix: $prefix" >&2
      exit 1
      ;;
  esac
done
assert_engine_payload "$CONCURRENT_OUTPUTS/one/output.wasm"
assert_engine_payload "$CONCURRENT_OUTPUTS/two/output.wasm"
while IFS='|' read -r local_cache global_cache; do
  test "$local_cache" = "unset"
  if [ -n "$EXPECTED_ZIG_GLOBAL_CACHE" ]; then
    test "$global_cache" = "$EXPECTED_ZIG_GLOBAL_CACHE"
  else
    test "$global_cache" = "$CACHE/zig-global-cache"
  fi
done < "$FAKE_ZIG_ENV_LOG"
assert_engine_payload "$BUILD_OUTPUT_1"
assert_engine_payload "$BUILD_OUTPUT_2"
assert_engine_payload "$BUILD_OUTPUT_3"

echo "native componentizer fake-tool tests passed"
