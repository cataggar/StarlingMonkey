// Phase 0 compatibility fixture: list<T> arguments/results.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
export function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

export function reverse(values) {
  return values.slice().reverse();
}

export function identity(values) {
  return values;
}
