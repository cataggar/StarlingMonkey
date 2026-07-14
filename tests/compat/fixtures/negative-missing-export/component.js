// Phase 0 negative fixture: `present` is implemented, `phantom` (declared by
// the WIT world) is intentionally NOT implemented.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
function present() {
  return 1;
}

// `phantom` is intentionally missing.

export const api = { present };
