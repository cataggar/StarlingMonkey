// Phase 0 compatibility fixture: list<T> arguments/results.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
function sum(values) {
  return values.reduce((total, value) => total + value, 0);
}

function reverse(values) {
  return values.slice().reverse();
}

function identity(values) {
  return values;
}

export const api = { sum, reverse, identity };
