// Phase 0 compatibility fixture: exports with no WIT result.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
function notify(message) {
  console.log(message);
}

function ping() {
}

export const api = { notify, ping };
