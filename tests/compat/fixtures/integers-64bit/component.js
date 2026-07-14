// Phase 1a compatibility fixture: full-domain u64/s64 BigInt round-tripping.
// Written once and run unmodified against both the pinned ComponentizeJS
// reference and the real StarlingMonkey bridge.
//
// Independently authored for cataggar/StarlingMonkey#6 (sync-value-parity).
export function bigAdd(a, b) {
  return a + b;
}

export function bigSub(a, b) {
  return a - b;
}

export function labelId(label, id) {
  return { label, id };
}

export function maybeBig(value) {
  return value == null ? null : value + 1n;
}

export function sumList(values) {
  return values.reduce((acc, v) => acc + v, 0n);
}
