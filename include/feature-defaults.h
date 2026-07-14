#ifndef STARLING_FEATURE_DEFAULTS_H
#define STARLING_FEATURE_DEFAULTS_H

// Default-on contract for the platform feature-selection macros
// (cataggar/StarlingMonkey#6 Phase 6; see docs/feature-selection/README.md).
//
// build.zig always threads `-DSTARLING_FEATURE_*=0/1` explicitly for every
// one of these macros (see build.zig's "Feature-selection macro defines"),
// so under Zig these `#ifndef` guards never fire and this header is a no-op.
//
// CMake (and any other non-Zig compiler invocation) does not define these
// macros at all. Left undefined, `#if STARLING_FEATURE_*` / `#if
// !STARLING_FEATURE_*` are preprocessed as `#if 0` / `#if !0`, which
// silently compiles every gated feature as *disabled* -- the opposite of
// the intended default-enabled behavior. Including this header from every
// translation unit that gates behavior on these macros closes that gap:
// each macro defaults to `1` (enabled) unless a build system has already
// defined it, matching Zig's default (see build.zig's `Features` struct).
//
// This file is plain C89-compatible (no C++-only syntax) since it is also
// included from runtime/feature_stubs.c.
#ifndef STARLING_FEATURE_STDIO
#define STARLING_FEATURE_STDIO 1
#endif

#ifndef STARLING_FEATURE_RANDOM
#define STARLING_FEATURE_RANDOM 1
#endif

#ifndef STARLING_FEATURE_CLOCKS
#define STARLING_FEATURE_CLOCKS 1
#endif

#ifndef STARLING_FEATURE_HTTP
#define STARLING_FEATURE_HTTP 1
#endif

#ifndef STARLING_FEATURE_FETCH_EVENT
#define STARLING_FEATURE_FETCH_EVENT 1
#endif

#endif // STARLING_FEATURE_DEFAULTS_H
