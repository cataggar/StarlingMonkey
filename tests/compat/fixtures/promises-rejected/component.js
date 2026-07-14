// Phase 0 (promise-sync roadmap phase) compatibility fixture: a rejecting
// Promise export.
//
// Independently authored for cataggar/StarlingMonkey#6 (promise-sync phase).

async function reject() {
  throw new Error("promises-rejected: reject always rejects");
}

export const api = { reject };
