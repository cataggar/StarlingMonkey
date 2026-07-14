// Phase 0 compatibility fixture: repeated calls against stateful exports.
//
// `calls` and `total` are module-level (top-level `let`) state, so their
// values must persist across separate dispatch calls within one component
// instance. See manifest.json fixture "repeated-calls" for the exact
// call-order-dependent expected sequence.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
let calls = 0;
let total = 0;

export function increment() {
  calls += 1;
  return calls;
}

export function accumulate(amount) {
  total += amount;
  return total;
}
