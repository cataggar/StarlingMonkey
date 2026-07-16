// Preview1-level platform feature stubs (cataggar/StarlingMonkey#6 Phase 6:
// platform feature selection and pure components).
//
// wasi-libc's auto-generated `__wasilibc_real.c` declares each raw
// `wasi_snapshot_preview1` import as a plain, no-body C function decorated
// with `__attribute__((__import_module__(...), __import_name__(...)))`,
// e.g.:
//
//   int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t, int32_t,
//                                                       int32_t, int32_t)
//       __attribute__((__import_module__("wasi_snapshot_preview1"),
//                       __import_name__("fd_write")));
//
// Such a declaration only creates an *undefined* reference tagged for
// import binding; if this translation unit instead provides a strong
// *definition* for the same symbol name/signature, wasm-ld resolves the
// call internally and the corresponding `wasi_snapshot_preview1` import
// disappears entirely from the linked module -- with function indices
// assigned normally by the toolchain (no hand-editing of the compiled wasm
// module's import/function sections, which would risk silently corrupting
// numeric call-site indices; see docs/feature-selection/README.md
// "preview1-level stubbing" for why that approach was rejected in favor of
// this one).
//
// Each override below is gated by this build's `-Dfeature-*` flags
// (`STARLING_FEATURE_*`, threaded in as compiler defines from build.zig).
// When a feature is *enabled* (the default), this file defines nothing for
// it, and the corresponding function is imported exactly as it always was.
//
// Behavior when disabled is chosen to match the pinned ComponentizeJS
// 0.21.0 reference's documented/observed semantics (see
// docs/feature-selection/README.md for the full matrix and any deviations):
//   * stdio:  fd_write/fd_fdstat_get become silent no-op successes (matches
//     the reference: disabled stdio discards output rather than trapping).
//   * clocks: clock_time_get returns a fixed build-time-like constant;
//     clock_res_get traps (deterministic `unreachable`-equivalent).
//   * random: random_get is replaced by a small deterministic PRNG (matches
//     the reference: disabled random is deterministic, not a trap, so
//     callers relying on *some* bytes still function predictably).
//
// Note: unlike the reference (whose Rust splicer unconditionally stubs
// preview1 `random_get` regardless of the `random` feature, reasoning that
// StarlingMonkey's own JS-visible randomness goes through preview2 only),
// this build only stubs it when `random` is explicitly disabled -- see
// task requirement to preserve existing default behavior; this preview1
// path may still be exercised by wasi-libc runtime internals (e.g.
// `arc4random`) even by default, and we don't want to change that
// unconditionally.

#include <stddef.h>
#include <stdint.h>
#include <wasi/api.h>

#include "feature-defaults.h"

// Keep real preview1 argument/environment imports in the raw runtime, but
// return an empty process view after Wizer has explicitly frozen the runtime
// configuration. This lets general starling.wasm continue to receive host CLI
// configuration while surfaced snapshots can safely internalize the imports.
extern _Bool starling_uses_snapshotted_configuration(void);

extern int32_t starling_wasi_args_get(int32_t argv, int32_t argv_buf)
    __attribute__((__import_module__("wasi_snapshot_preview1"), __import_name__("args_get")));
extern int32_t starling_wasi_args_sizes_get(int32_t argc_ptr, int32_t argv_buf_size_ptr)
    __attribute__((__import_module__("wasi_snapshot_preview1"),
                   __import_name__("args_sizes_get")));
extern int32_t starling_wasi_environ_get(int32_t environ, int32_t environ_buf)
    __attribute__((__import_module__("wasi_snapshot_preview1"),
                   __import_name__("environ_get")));
extern int32_t starling_wasi_environ_sizes_get(int32_t environ_count_ptr,
                                                int32_t environ_buf_size_ptr)
    __attribute__((__import_module__("wasi_snapshot_preview1"),
                   __import_name__("environ_sizes_get")));

int32_t __imported_wasi_snapshot_preview1_args_get(int32_t argv, int32_t argv_buf) {
  if (!starling_uses_snapshotted_configuration()) {
    return starling_wasi_args_get(argv, argv_buf);
  }
  (void)argv;
  (void)argv_buf;
  return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_args_sizes_get(int32_t argc_ptr,
                                                         int32_t argv_buf_size_ptr) {
  if (!starling_uses_snapshotted_configuration()) {
    return starling_wasi_args_sizes_get(argc_ptr, argv_buf_size_ptr);
  }
  *(uint32_t *)(uintptr_t)argc_ptr = 0;
  *(uint32_t *)(uintptr_t)argv_buf_size_ptr = 0;
  return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_environ_get(int32_t environ, int32_t environ_buf) {
  if (!starling_uses_snapshotted_configuration()) {
    return starling_wasi_environ_get(environ, environ_buf);
  }
  (void)environ;
  (void)environ_buf;
  return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_environ_sizes_get(int32_t environ_count_ptr,
                                                            int32_t environ_buf_size_ptr) {
  if (!starling_uses_snapshotted_configuration()) {
    return starling_wasi_environ_sizes_get(environ_count_ptr, environ_buf_size_ptr);
  }
  *(uint32_t *)(uintptr_t)environ_count_ptr = 0;
  *(uint32_t *)(uintptr_t)environ_buf_size_ptr = 0;
  return __WASI_ERRNO_SUCCESS;
}

#if !STARLING_FEATURE_STDIO

int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t fd, int32_t iovs_ptr, int32_t iovs_len,
                                                    int32_t retptr0) {
  (void)fd;
  const __wasi_ciovec_t *iovs = (const __wasi_ciovec_t *)(uintptr_t)iovs_ptr;
  __wasi_size_t total = 0;
  for (int32_t i = 0; i < iovs_len; i++) {
    total += iovs[i].buf_len;
  }
  *(__wasi_size_t *)(uintptr_t)retptr0 = total;
  return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_get(int32_t fd, int32_t retptr0) {
  (void)fd;
  __wasi_fdstat_t *stat = (__wasi_fdstat_t *)(uintptr_t)retptr0;
  stat->fs_filetype = __WASI_FILETYPE_CHARACTER_DEVICE;
  stat->fs_flags = 0;
  // Only the (valid, in-range) rights actually needed for a silent-success
  // fd_write stub -- the preview1->preview2 adapter used by componentize.sh
  // rejects out-of-range bits (e.g. all-bits-set) when converting fdstat
  // rights into its bitflags representation.
  stat->fs_rights_base = __WASI_RIGHTS_FD_WRITE | __WASI_RIGHTS_FD_DATASYNC | __WASI_RIGHTS_FD_SYNC;
  stat->fs_rights_inheriting = 0;
  return __WASI_ERRNO_SUCCESS;
}

#endif // !STARLING_FEATURE_STDIO

#if !STARLING_FEATURE_CLOCKS

// Fixed constant stand-in for "now", chosen deterministically rather than
// reading any real clock. Matches the reference's "fixed build-time
// constant" behavior for a disabled clocks feature.
#define STARLING_STUBBED_CLOCK_TIME_NS UINT64_C(1000000000)

int32_t __imported_wasi_snapshot_preview1_clock_time_get(int32_t id, int64_t precision,
                                                          int32_t retptr0) {
  (void)id;
  (void)precision;
  *(__wasi_timestamp_t *)(uintptr_t)retptr0 = STARLING_STUBBED_CLOCK_TIME_NS;
  return __WASI_ERRNO_SUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_clock_res_get(int32_t id, int32_t retptr0) {
  (void)id;
  (void)retptr0;
  __builtin_trap();
}

#endif // !STARLING_FEATURE_CLOCKS

#if !STARLING_FEATURE_RANDOM

// Small deterministic PRNG (splitmix64) used in place of real entropy.
// Deterministic-but-not-cryptographically-secure output for a disabled
// random feature, matching the reference's documented behavior.
static uint64_t starling_stub_rng_state = UINT64_C(0x9E3779B97F4A7C15);

static uint64_t starling_stub_rng_next(void) {
  uint64_t z = (starling_stub_rng_state += UINT64_C(0x9E3779B97F4A7C15));
  z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
  z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
  return z ^ (z >> 31);
}

int32_t __imported_wasi_snapshot_preview1_random_get(int32_t buf_ptr, int32_t buf_len) {
  uint8_t *buf = (uint8_t *)(uintptr_t)buf_ptr;
  int32_t i = 0;
  while (i < buf_len) {
    uint64_t r = starling_stub_rng_next();
    for (int32_t b = 0; b < 8 && i < buf_len; b++, i++) {
      buf[i] = (uint8_t)(r >> (8 * b));
    }
  }
  return __WASI_ERRNO_SUCCESS;
}

#endif // !STARLING_FEATURE_RANDOM
