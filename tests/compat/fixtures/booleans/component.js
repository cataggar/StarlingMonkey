// Phase 0 compatibility fixture: boolean arguments/results.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0). Not copied
// from ComponentizeJS; see ../../manifest.json for provenance and expected
// value shapes.
function negate(value) {
  return !value;
}

function both(a, b) {
  return a && b;
}

function either(a, b) {
  return a || b;
}

function majority(a, b, c) {
  return (a + b + c) >= 2;
}

export const api = { negate, both, either, majority };
