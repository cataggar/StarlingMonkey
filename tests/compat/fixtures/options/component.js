// Phase 0 compatibility fixture: option<T> arguments/results.
//
// Uses `== null` so this fixture also verifies that both JavaScript `null`
// and `undefined` lower to WIT `none`. The native dispatch bridge lifts a
// WIT `none` to JavaScript `undefined`, matching ComponentizeJS 0.21.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
export function maybenumber(value) {
  return value == null ? null : value + 1;
}

export function maybestring(value) {
  return value == null ? null : value.toUpperCase();
}

export function maybepoint(value) {
  return value == null ? null : { x: value.x, y: value.y };
}
