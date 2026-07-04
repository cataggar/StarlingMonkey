#ifndef STARLING_WASI_COMPAT_H
#define STARLING_WASI_COMPAT_H
/* Zig's wasi-libc (musl top-half) gates out the legacy allocator functions
 * memalign()/valloc() that wasi-sdk's wasi-libc still provides. SpiderMonkey's
 * memory/build (mozjemalloc/Fallback.cpp) references ::memalign, so declare them
 * here. Definitions are provided at final link time (see deps/wasi-compat.c). */
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *memalign(size_t alignment, size_t size);
void *valloc(size_t size);
#ifdef __cplusplus
}
#endif
#endif
