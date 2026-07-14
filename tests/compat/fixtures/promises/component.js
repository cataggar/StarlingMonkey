// Phase 0 (promise-sync roadmap phase) compatibility fixture: fulfilling
// Promise/thenable exports. See ../promises-rejected/component.js and ../promises-deadlock/component.js for
// rejection and no-progress (deadlock) cases.
//
// Independently authored for cataggar/StarlingMonkey#6 (promise-sync phase).

function resolveadd(a, b) {
  return Promise.resolve(a + b);
}

async function asyncadd(a, b) {
  // Nested awaits force a multi-hop microtask chain rather than a single
  // resolved-promise tick, exercising js::RunJobs being driven more than
  // once by EventLoop::pump_until_promise_settled.
  const left = await Promise.resolve(a);
  const right = await (async () => b)();
  return left + right;
}

function thenableadd(a, b) {
  // Not a real Promise instance -- a duck-typed thenable object, matching
  // the JS spec's PromiseResolve/then-chaining semantics that
  // resolve_promise_like reuses via JS::NewPromiseObject + JS::ResolvePromise
  // instead of hand-rolling a `.then()` call.
  return {
    then(resolve) {
      resolve(a + b);
    },
  };
}

function timeoutadd(a, b) {
  return new Promise((resolve) => {
    setTimeout(() => resolve(a + b), 0);
  });
}

let lastNotified = "";
async function asyncnotify(message) {
  // No console.log: only asserts on module-level state, avoiding a
  // stdio-related trap seen in some sandboxed wasmtime CLI invocations
  // when a guest writes to stderr/stdout (see
  // tests/e2e/native-dispatch/run.sh's `promise-notify` fixture for the
  // same convention).
  lastNotified = message;
}

function resolvepoint(p, dx, dy) {
  return Promise.resolve({ x: p.x + dx, y: p.y + dy });
}

let asyncCalls = 0;
async function asyncincrement() {
  await Promise.resolve();
  asyncCalls += 1;
  return asyncCalls;
}

export const api = { resolveadd, asyncadd, thenableadd, timeoutadd, asyncnotify, resolvepoint, asyncincrement };
