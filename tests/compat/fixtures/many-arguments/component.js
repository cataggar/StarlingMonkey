// Phase 0 compatibility fixture: many-argument exports.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
export function sum8(a, b, c, d, e, f, g, h) {
  return a + b + c + d + e + f + g + h;
}

export function describe(flag, count, label, delta, ready, scale) {
  return `${label}:${count}:${delta}:${scale}:${flag}:${ready}`;
}
