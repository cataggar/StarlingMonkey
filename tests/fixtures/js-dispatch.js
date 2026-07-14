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
  return value === null ? null : value + 1;
}

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
  return value === null ? null : value + 1n;
}
export { maybeBigImpl as "maybe-big" };

function maybeSignedImpl(value) {
  return value === null ? null : value - 1n;
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
