// Phase 0 compatibility fixture: boolean arguments/results.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0). Not copied
// from ComponentizeJS; see ../../manifest.json for provenance and expected
// value shapes.
export function negate(value) {
  return !value;
}

export function both(a, b) {
  return a && b;
}

export function either(a, b) {
  return a || b;
}

export function majority(a, b, c) {
  return (a + b + c) >= 2;
}
