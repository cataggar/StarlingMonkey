export function add(a, b) {
  return a + b;
}

export function greet(name) {
  return `Hello, ${name}!`;
}

export function notify(message) {
  console.log(message);
}

export function move(point, dx, dy) {
  return { x: point.x + dx, y: point.y + dy };
}

export function maybe(value) {
  return value == null ? null : value + 1;
}

function optionShape(value) {
  if (value === undefined) return "undefined";
  if (value === null) return "null";
  return "value";
}

function directOptionShapeImpl(value) {
  return optionShape(value);
}
export { directOptionShapeImpl as "direct-option-shape" };

function aggregateOptionShapesImpl(value) {
  return [
    optionShape(value.direct),
    ...value.items.map(optionShape),
    ...value.pair.map(optionShape),
  ];
}
export { aggregateOptionShapesImpl as "aggregate-option-shapes" };

function nestedOptionShapeImpl(value) {
  const nested = value.nested;
  if (nested === undefined || nested === null) return optionShape(nested);
  const hasVal = Object.prototype.hasOwnProperty.call(nested, "val");
  return `${nested.tag}:${hasVal ? optionShape(nested.val) : "missing"}`;
}
export { nestedOptionShapeImpl as "nested-option-shape" };

function lowerNullImpl() {
  return null;
}
export { lowerNullImpl as "lower-null" };

function lowerUndefinedImpl() {
  return undefined;
}
export { lowerUndefinedImpl as "lower-undefined" };

// Exact u64/s64 round trips beyond 2^53: both operands and the result stay
// native BigInt end to end, so this is exact where a JSON-number round trip
// would lose precision.
function bigAddImpl(a, b) {
  return a + b;
}
export { bigAddImpl as "big-add" };

function bigSubImpl(a, b) {
  return a - b;
}
export { bigSubImpl as "big-sub" };

// Nested aggregate (a record embedding another record) plus an exact u64
// field, dispatched natively without JSON.
function tagPointImpl(p, id) {
  return { p, id };
}
export { tagPointImpl as "tag-point" };

// Record combining a string field with an exact u64 field: exercises the
// UAF fix directly, since both the string and the u64 are decoded out of
// the same native result before the C++ NativeArena is freed.
function labelIdImpl(label, id) {
  return { label: `${label}-tagged`, id };
}
export { labelIdImpl as "label-id" };

function nulLabelImpl(id) {
  return { label: "a\0b", id };
}
export { nulLabelImpl as "nul-label" };

// Optional 64-bit round trips, both present and absent.
function maybeBigImpl(value) {
  return value == null ? null : value + 1n;
}
export { maybeBigImpl as "maybe-big" };

function maybeSignedImpl(value) {
  return value == null ? null : value - 1n;
}
export { maybeSignedImpl as "maybe-signed" };

// list<u64>: sum and echo, exercising exact values beyond 2^53.
function sumListImpl(values) {
  return values.reduce((acc, v) => acc + v, 0n);
}
export { sumListImpl as "sum-list" };

function echoListImpl(values) {
  return values.map((v) => v);
}
export { echoListImpl as "echo-list" };

// Deliberately wrong return type (string instead of u64/BigInt) to prove
// the native decoder traps instead of silently returning zero.
function wrongTypeImpl() {
  return "not-a-bigint";
}
export { wrongTypeImpl as "wrong-type" };

// ---------------------------------------------------------------------------
// promise-sync roadmap phase: synchronous exports whose JS implementation
// returns a Promise (or a thenable). The bridge (runtime/js_dispatch.cpp)
// pumps the engine's event loop until it settles, then lowers the fulfilled
// value exactly as if it had been returned directly; a rejection surfaces
// as a component trap instead.

// Already-settled by the time the call returns: no `await`, so
// `Promise.resolve` fulfills synchronously (still requires exactly one
// microtask-queue drain to observe, per spec).
function promiseResolveAddImpl(a, b) {
  return Promise.resolve(a + b);
}
export { promiseResolveAddImpl as "promise-resolve-add" };

// A real `async function`, awaiting a short chain of plain (non-timer)
// microtasks/nested awaits before returning -- exercises RunJobs draining
// an arbitrary microtask chain, not just a single `.then`.
async function promiseAddImpl(a, b) {
  const doubled = await Promise.resolve(a).then((x) => x * 2);
  const halved = await (async () => doubled / 2)();
  return halved + b;
}
export { promiseAddImpl as "promise-add" };

// Rejects (via a thrown `Error`) after an `await`, so the rejection reason
// is a real `Error` with a stack -- must surface as a trap, never decode.
async function promiseRejectImpl() {
  await Promise.resolve();
  throw new Error("promise-reject: deliberate rejection");
}
export { promiseRejectImpl as "promise-reject" };

// A non-Promise "thenable": an ordinary object with a callable `then`,
// which must be driven to completion exactly like a real Promise (the same
// duck test `await`/`Promise.resolve` use).
function thenableAddImpl(a, b) {
  return {
    then(resolve) {
      Promise.resolve().then(() => resolve(a + b));
    },
  };
}
export { thenableAddImpl as "thenable-add" };

// Settles only once a `setTimeout` callback fires: exercises the queued
// async-task side of the pump loop, not just the microtask queue.
function promiseTimeoutAddImpl(a, b) {
  return new Promise((resolve) => {
    setTimeout(() => resolve(a + b), 0);
  });
}
export { promiseTimeoutAddImpl as "promise-timeout-add" };

// `void` result reached via a Promise resolving `undefined`. (Deliberately
// avoids `console.log`/stdio side effects here: this fixture is driven
// through `wasmtime run --invoke`, where writing to stdout from a plain
// `void` export is an unrelated, pre-existing tooling gap in this
// environment -- see the original `notify` export above, which this suite
// likewise never invokes through `--invoke`.)
let lastNotifyMessage = null;
async function promiseNotifyImpl(message) {
  await Promise.resolve();
  lastNotifyMessage = message;
}
export { promiseNotifyImpl as "promise-notify" };

// `Promise.resolve` of a typed nested record, proving the settled value
// re-enters the exact same typed/JSON conversion a direct record return
// from `move` above would use.
function promiseResolvePointImpl(point, dx, dy) {
  return Promise.resolve({ x: point.x + dx, y: point.y + dy });
}
export { promiseResolvePointImpl as "promise-resolve-point" };

// Deliberately never settles: no executor-side resolve/reject call and
// nothing else queued, so the bridge's job/task queues both run dry while
// this stays Pending forever -- must trap deterministically (a "no
// progress" diagnostic) instead of hanging the host.
function promiseDeadlockImpl() {
  return new Promise(() => {});
}
export { promiseDeadlockImpl as "promise-deadlock" };

// Same Promise-shapes again, for the typed native (BigInt) dispatch path.
function promiseResolveBigAddImpl(a, b) {
  return Promise.resolve(a + b);
}
export { promiseResolveBigAddImpl as "promise-resolve-big-add" };

async function promiseBigAddImpl(a, b) {
  const sum = await Promise.resolve(a).then((x) => x + b);
  return sum;
}
export { promiseBigAddImpl as "promise-big-add" };

async function promiseRejectBigImpl() {
  await Promise.resolve();
  throw new Error("promise-reject-big: deliberate rejection");
}
export { promiseRejectBigImpl as "promise-reject-big" };
// Numeric wraparound (matches ComponentizeJS/ECMAScript, not a trap): each
// field here is a deliberately out-of-range/negative/fractional Number or
// BigInt of the *correct kind*, which must lower via modular wraparound
// (ToInt32/ToUint32-family, ToBigInt64/ToBigUint64), not a trap. See
// tests/compat/fixtures/integers-64bit's "sum-list-basic" case for the same
// behavior verified against the pinned ComponentizeJS reference itself.
function wrapNumbersImpl() {
  return {
    overflowU8: 300, // 300 mod 256 = 44
    negativeU8: -5, // 256 - 5 = 251
    fractionalU8: 3.5, // truncates toward zero first, then wraps: 3
    overflowS32: 2147483648, // i32::MAX + 1 wraps to i32::MIN
    negativeU64: -5n, // 2**64 - 5
    overflowS64: 18446744073709551616n, // 2**64 wraps to 0
  };
}
export { wrapNumbersImpl as "wrap-numbers" };

// --- char --------------------------------------------------------------
function echoCharImpl(c) {
  return c;
}
export { echoCharImpl as "echo-char" };

function wrongTypeCharImpl() {
  return 42; // not a string at all
}
export { wrongTypeCharImpl as "wrong-type-char" };

function invalidCharMultiCodepointImpl() {
  return "ab"; // two codepoints, not exactly one Unicode scalar value
}
export { invalidCharMultiCodepointImpl as "invalid-char-multi-codepoint" };

// --- list<u8> vs string --------------------------------------------------
function echoBytesImpl(data) {
  // `data` must be a genuine Uint8Array (see js_dispatch.h); returning it
  // unchanged also exercises the lenient decode (a plain Array would be
  // equally acceptable coming back, but a real Uint8Array is what a
  // faithful JS implementation would naturally produce here).
  return data;
}
export { echoBytesImpl as "echo-bytes" };

function bytesLenImpl(data) {
  return data.length;
}
export { bytesLenImpl as "bytes-len" };

function wrongTypeBytesImpl() {
  return "not-bytes"; // neither a Uint8Array nor a plain Array
}
export { wrongTypeBytesImpl as "wrong-type-bytes" };

// --- tuple ---------------------------------------------------------------
function swapPairImpl(pair) {
  return [pair[1], pair[0]];
}
export { swapPairImpl as "swap-pair" };

function wrongTypeTupleImpl() {
  return { 0: 1, 1: 2 }; // a plain object, not a real JS Array
}
export { wrongTypeTupleImpl as "wrong-type-tuple" };

// --- enum ------------------------------------------------------------
function echoDirectionImpl(d) {
  return d;
}
export { echoDirectionImpl as "echo-direction" };

function invalidEnumCaseImpl() {
  return "north-west"; // not one of direction's declared case labels
}
export { invalidEnumCaseImpl as "invalid-enum-case" };

function wrongTypeEnumImpl() {
  return 0; // not a string
}
export { wrongTypeEnumImpl as "wrong-type-enum" };

// --- flags -----------------------------------------------------------
function echoPermsImpl(p) {
  return p;
}
export { echoPermsImpl as "echo-perms" };

function missingFlagsPropertyImpl() {
  return { canRead: true, canWrite: false }; // missing required canExecute
}
export { missingFlagsPropertyImpl as "missing-flags-property" };

function wrongTypeFlagsImpl() {
  return "not-an-object";
}
export { wrongTypeFlagsImpl as "wrong-type-flags" };

// --- variant -----------------------------------------------------------
function echoShapeImpl(s) {
  return s;
}
export { echoShapeImpl as "echo-shape" };

function invalidVariantTagImpl() {
  return { tag: "triangle" }; // not one of shape's declared case names
}
export { invalidVariantTagImpl as "invalid-variant-tag" };

function wrongTypeVariantImpl() {
  return 42; // not a {tag, val} object
}
export { wrongTypeVariantImpl as "wrong-type-variant" };

function echoOptionAggregateImpl(value) {
  return value;
}
export { echoOptionAggregateImpl as "echo-option-aggregate" };

// --- result<T, E> --------------------------------------------------------
function echoWrappedResultImpl(w) {
  return w;
}
export { echoWrappedResultImpl as "echo-wrapped-result" };

// The export's own top-level return type is `result<u32, string>`:
// ComponentizeJS's calling convention returns the Ok payload directly and
// signals Err by throwing (see js_dispatch.h).
function divideImpl(a, b) {
  if (b === 0) {
    throw "division by zero";
  }
  return Math.trunc(a / b);
}
export { divideImpl as "divide" };

// `result<s32>` (E is void, per WIT's err-omitted shorthand): failure is
// signaled by throwing anything at all, since there's no err payload to
// carry.
function checkedNegateImpl(value) {
  if (value === -2147483648) {
    throw new Error("negating i32::MIN would overflow");
  }
  return -value;
}
export { checkedNegateImpl as "checked-negate" };

// --- naming/version edge cases -------------------------------------------
function echoMultiWordRecordImpl(r) {
  return r;
}
export { echoMultiWordRecordImpl as "echo-multi-word-record" };

function echoMultiWordFlagsImpl(f) {
  return f;
}
export { echoMultiWordFlagsImpl as "echo-multi-word-flags" };

function echoMultiWordEnumImpl(e) {
  return e;
}
export { echoMultiWordEnumImpl as "echo-multi-word-enum" };

function echoMultiWordVariantImpl(v) {
  return v;
}
export { echoMultiWordVariantImpl as "echo-multi-word-variant" };

// Exported ONLY under its camelCase spelling (never the literal kebab
// string "multi-word-echo") -- proves resolve_export_function's camelCase
// fallback lookup actually engages, not just that every other export's
// literal-kebab lookup still works.
export function multiWordEcho(value) {
  return value + 1;
}

// Named-interface export contract used by `world js-exports { export api; }`.
// Keep the legacy root exports above: root-function WIT worlds still resolve them.
export const api = {
  add: add,
  greet: greet,
  notify: notify,
  move: move,
  maybe: maybe,
  "direct-option-shape": directOptionShapeImpl,
  "aggregate-option-shapes": aggregateOptionShapesImpl,
  "nested-option-shape": nestedOptionShapeImpl,
  "lower-null": lowerNullImpl,
  "lower-undefined": lowerUndefinedImpl,
  "big-add": bigAddImpl,
  "big-sub": bigSubImpl,
  "tag-point": tagPointImpl,
  "label-id": labelIdImpl,
  "nul-label": nulLabelImpl,
  "maybe-big": maybeBigImpl,
  "maybe-signed": maybeSignedImpl,
  "sum-list": sumListImpl,
  "echo-list": echoListImpl,
  "wrong-type": wrongTypeImpl,
  "promise-resolve-add": promiseResolveAddImpl,
  "promise-add": promiseAddImpl,
  "promise-reject": promiseRejectImpl,
  "thenable-add": thenableAddImpl,
  "promise-timeout-add": promiseTimeoutAddImpl,
  "promise-notify": promiseNotifyImpl,
  "promise-resolve-point": promiseResolvePointImpl,
  "promise-deadlock": promiseDeadlockImpl,
  "promise-resolve-big-add": promiseResolveBigAddImpl,
  "promise-big-add": promiseBigAddImpl,
  "promise-reject-big": promiseRejectBigImpl,
  "wrap-numbers": wrapNumbersImpl,
  "echo-char": echoCharImpl,
  "wrong-type-char": wrongTypeCharImpl,
  "invalid-char-multi-codepoint": invalidCharMultiCodepointImpl,
  "echo-bytes": echoBytesImpl,
  "bytes-len": bytesLenImpl,
  "wrong-type-bytes": wrongTypeBytesImpl,
  "swap-pair": swapPairImpl,
  "wrong-type-tuple": wrongTypeTupleImpl,
  "echo-direction": echoDirectionImpl,
  "invalid-enum-case": invalidEnumCaseImpl,
  "wrong-type-enum": wrongTypeEnumImpl,
  "echo-perms": echoPermsImpl,
  "missing-flags-property": missingFlagsPropertyImpl,
  "wrong-type-flags": wrongTypeFlagsImpl,
  "echo-shape": echoShapeImpl,
  "invalid-variant-tag": invalidVariantTagImpl,
  "wrong-type-variant": wrongTypeVariantImpl,
  "echo-option-aggregate": echoOptionAggregateImpl,
  "echo-wrapped-result": echoWrappedResultImpl,
  divide: divideImpl,
  "checked-negate": checkedNegateImpl,
  "echo-multi-word-record": echoMultiWordRecordImpl,
  "echo-multi-word-flags": echoMultiWordFlagsImpl,
  "echo-multi-word-enum": echoMultiWordEnumImpl,
  "echo-multi-word-variant": echoMultiWordVariantImpl,
  multiWordEcho: multiWordEcho,
};
