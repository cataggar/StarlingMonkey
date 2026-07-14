// JS fixture for tests/e2e/wit-imports/run.sh: exercises the reverse
// canonical-ABI bridge (runtime/js_dispatch.{h,cpp,zig} + the WABT
// `--js-imports` bindgen codegen) end to end. Every export below calls
// through to a *host-implemented* WIT import (see
// tests/e2e/wit-imports/wit/deps/test-wit-imports/package.wit `interface
// host`, registered by the Rust invoker at
// tests/compat/runtime/invoker/src/wit_imports_invoker.rs), proving that:
//   * the module specifier "test:wit-imports/host@1.2.3" resolves without
//     any user-written glue (requirement 2) -- this `import` is the ONLY
//     wiring needed;
//   * exact s64/u64 BigInt, strings, and nested records round-trip through
//     the native tagged-value bridge in the reverse direction (requirement
//     3);
//   * host functions can be called repeatedly and the manifest correctly
//     distinguishes each named import (requirement 5's "repeated calls");
//   * a host-side trap (`boom`) propagates back through JS and out through
//     the export call as a genuine wasm trap, not a swallowed error;
//   * a WIT import with no result (`note`) surfaces to JavaScript as
//     exactly `undefined` -- never `false`/`null` -- and its host-side
//     implementation genuinely ran (proven via the side-channel
//     `note-count` import, not just "no exception was thrown").
import {
  add,
  "sum-list" as sumList,
  greet,
  scale,
  boom,
  note,
  "note-count" as noteCount,
} from "test:wit-imports/host@1.2.3";

export function runAdd(a, b) {
  return add(a, b);
}
export { runAdd as "run-add" };

function runSumList(xs) {
  return sumList(xs);
}
export { runSumList as "run-sum-list" };

function runGreet(name) {
  return greet(name);
}
export { runGreet as "run-greet" };

// Bridges between the two nominally-independent WIT `point` records (host's
// vs api's) purely via JS object shape -- see js_dispatch's shape-based
// encode/decode; no cross-interface WIT `use` is required.
function runScale(x, y, factor) {
  return scale({ x, y }, factor);
}
export { runScale as "run-scale" };

// Calls the same host import multiple times in one export invocation,
// proving the dispatch-key lookup and per-call NativeArena lifecycle work
// correctly across repeated calls (not just a single call per component
// invocation).
function runRepeatedAdd() {
  const results = [];
  for (let i = 0; i < 5; i++) {
    results.push(add(BigInt(i), 10n));
  }
  return results;
}
export { runRepeatedAdd as "run-repeated-add" };

function runBoom() {
  // The host implementation of `boom` always traps; this proves the trap
  // propagates all the way out through the JS call and the export's own
  // canonical-ABI return, rather than being swallowed as a JS exception.
  return boom();
}
export { runBoom as "run-boom" };

function runNote() {
  // `note` has no WIT result: the call's own return value must be
  // JavaScript `undefined`, never `false` (a stray bool tag) or `null`
  // (the option-none tag, which means something different -- WIT
  // `option::none`, not "no result").
  const result = note();
  return result === undefined;
}
export { runNote as "run-note" };

function runNoteCount() {
  // A second, independent host import used purely to observe `note`'s
  // side effect (an incrementing host-side counter) -- proving the
  // canonical-ABI import actually executed on the host, not merely that
  // the JS call site returned without throwing.
  return noteCount();
}
export { runNoteCount as "run-note-count" };
