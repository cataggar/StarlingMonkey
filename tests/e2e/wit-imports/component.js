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
//     `note-count` import, not just "no exception was thrown");
//   * requirement 5 (every synchronous type the native bridge supports,
//     reverse direction): nesting (a list of lists), `char`/`option<char>`,
//     `list<u8>` (a genuine `Uint8Array`, plus its `option<list<u8>>`
//     nested/optional form), `tuple`, `enum`/`option<enum>`,
//     `flags`/`option<flags>`, `variant` (void and payload cases), and
//     `result<T,E>` (both-payload and void-ok-payload forms) all round-trip
//     through the reverse bridge -- see package.wit's doc comment for the
//     upstream cataggar/wabt fix (PR #335) that made this possible.
//
// A note on `result<T,E>` calling conventions, since this fixture exercises
// both directions: ComponentizeJS's "return means Ok, throw means Err"
// sugar is an *export's own top-level return type* convention only (see
// `checkedDiv`/`validateNonNegative` below for a plain host *import* call,
// vs. `runCheckedDiv`/`runValidateNonNegative` for an *export*'s own
// top-level result). Calling a `result<T,E>`-returning *import* (from
// either direction) always yields the ordinary `{tag: "ok"|"err", val:
// ...}` object -- `val` omitted entirely for a void payload -- never a
// thrown exception; only an export's own top-level result position gets
// the throw-based sugar.
import {
  add,
  "sum-list" as sumList,
  greet,
  scale,
  boom,
  note,
  "note-count" as noteCount,
  "sum-nested-lists" as sumNestedLists,
  "identity-char" as identityChar,
  "identity-option-char" as identityOptionChar,
  "sum-bytes" as sumBytes,
  "xor-bytes" as xorBytes,
  "identity-optional-bytes" as identityOptionalBytes,
  "swap-tuple" as swapTuple,
  "next-color" as nextColor,
  "next-option-color" as nextOptionColor,
  "toggle-permissions" as togglePermissions,
  "toggle-option-permissions" as toggleOptionPermissions,
  "identity-shape" as identityShape,
  "checked-div" as checkedDiv,
  "validate-non-negative" as validateNonNegative,
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

function runSumNestedLists(rows) {
  return sumNestedLists(rows);
}
export { runSumNestedLists as "run-sum-nested-lists" };

// -- advanced synchronous value types (requirement 5) --

// `char`: a one-codepoint JS string both as an export argument (encoded
// from the host's native WIT `char`) and as the host import's own
// argument/result.
function runChar(c) {
  return identityChar(c);
}
export { runChar as "run-char" };

// `option<char>`: a present value decodes/encodes as the bare one-codepoint
// string directly (no wrapper); `none` is JS `null`.
function runOptionChar(c) {
  return identityOptionChar(c);
}
export { runOptionChar as "run-option-char" };

// `list<u8>`: proves the export argument itself is a genuine JS
// `Uint8Array` (never a plain Array or an ArrayBuffer) -- no host call
// needed for this shape assertion alone.
function runBytesIsUint8Array(bytes) {
  return bytes instanceof Uint8Array;
}
export { runBytesIsUint8Array as "run-bytes-is-uint8array" };

// Calls the host `sum-bytes` import with the real `Uint8Array` export
// argument, proving a direct `list<u8>` *parameter* lowers correctly
// through the reverse bridge.
function runSumBytes(bytes) {
  return sumBytes(bytes);
}
export { runSumBytes as "run-sum-bytes" };

// Calls the host `xor-bytes` import and returns its `list<u8>` *result*
// (itself a `Uint8Array`, produced by the import wrapper's encode step)
// directly as this export's own `list<u8>` return value.
function runXorBytes(bytes, key) {
  return xorBytes(bytes, key);
}
export { runXorBytes as "run-xor-bytes" };

// `option<list<u8>>`: the nested/optional byte case -- `none` round-trips
// as `null`; a present `Uint8Array` round-trips as itself (no wrapper).
function runOptionalBytes(bytes) {
  return identityOptionalBytes(bytes);
}
export { runOptionalBytes as "run-optional-bytes" };

// `tuple`: a plain positional JS Array both ways.
function runSwapTuple(t) {
  return swapTuple(t);
}
export { runSwapTuple as "run-swap-tuple" };

// `enum`: a plain kebab-case JS string both ways.
function runColor(c) {
  return nextColor(c);
}
export { runColor as "run-color" };

// `option<enum>`: same as `option<char>` above -- present decodes/encodes
// as the bare string, `none` is `null`.
function runOptionColor(c) {
  return nextOptionColor(c);
}
export { runOptionColor as "run-option-color" };

// `flags`: a plain JS object with every label present as a boolean
// (`{read, write, execute}`), both ways.
function runPermissions(p) {
  return togglePermissions(p);
}
export { runPermissions as "run-permissions" };

// `option<flags>`: present decodes/encodes as the bare full-label object;
// `none` is `null`.
function runOptionPermissions(p) {
  return toggleOptionPermissions(p);
}
export { runOptionPermissions as "run-option-permissions" };

// `variant`: a `{tag, val}` object, `val` omitted for the void `empty`
// case.
function runShape(s) {
  return identityShape(s);
}
export { runShape as "run-shape" };

// `result<T, E>`, both-payload form: THIS export's own top-level return
// type is `result<s32, string>`, so -- unlike the plain `{tag, val}` object
// `checkedDiv` (the host *import*) returns -- ComponentizeJS's
// throw-means-err convention applies here: a plain `return` signals `ok`,
// a `throw` signals `err` (see the module doc comment above).
function runCheckedDiv(a, b) {
  const result = checkedDiv(a, b);
  if (result.tag === "err") {
    throw result.val;
  }
  return result.val;
}
export { runCheckedDiv as "run-checked-div" };

// `result<_, E>`, void-ok-payload form: same throw-means-err export
// convention as above, but the `ok` case carries no payload, so a
// successful call returns nothing (`undefined`).
function runValidateNonNegative(n) {
  const result = validateNonNegative(n);
  if (result.tag === "err") {
    throw result.val;
  }
}
export { runValidateNonNegative as "run-validate-non-negative" };

export function rootAdd(a, b) {
  return a + b;
}

export const api = {
  "run-add": runAdd,
  "run-sum-list": runSumList,
  "run-greet": runGreet,
  "run-scale": runScale,
  "run-repeated-add": runRepeatedAdd,
  "run-boom": runBoom,
  "run-note": runNote,
  "run-note-count": runNoteCount,
  "run-sum-nested-lists": runSumNestedLists,
  "run-char": runChar,
  "run-option-char": runOptionChar,
  "run-bytes-is-uint8array": runBytesIsUint8Array,
  "run-sum-bytes": runSumBytes,
  "run-xor-bytes": runXorBytes,
  "run-optional-bytes": runOptionalBytes,
  "run-swap-tuple": runSwapTuple,
  "run-color": runColor,
  "run-option-color": runOptionColor,
  "run-permissions": runPermissions,
  "run-option-permissions": runOptionPermissions,
  "run-shape": runShape,
  "run-checked-div": runCheckedDiv,
  "run-validate-non-negative": runValidateNonNegative,
};
