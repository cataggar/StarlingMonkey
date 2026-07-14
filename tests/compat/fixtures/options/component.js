// Phase 0 compatibility fixture: option<T> arguments/results.
//
// Uses `== null` (matches both `null` and `undefined`) and always returns
// `null` for "none" so the same source is portable across the current
// Zig/WABT JSON bridge (which represents WIT `none` as JS `null`) and the
// pinned ComponentizeJS reference (which represents it as JS `undefined`).
// See manifest.json known_deviations "option-none-representation".
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
