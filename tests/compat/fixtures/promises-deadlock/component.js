// Phase 0 (promise-sync roadmap phase) compatibility fixture: a never-
// settling Promise export.
//
// Independently authored for cataggar/StarlingMonkey#6 (promise-sync phase).

export function deadlock() {
  // No resolve/reject ever called, and nothing (no timer, no microtask) is
  // ever queued to advance it: EventLoop::pump_until_promise_settled must
  // detect the exhausted job/task queues and return NoProgress
  // deterministically instead of hanging.
  return new Promise(() => {});
}
