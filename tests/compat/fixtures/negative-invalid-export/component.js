// Phase 0 negative fixture: `phantom` is exported as a plain value, not a
// function, even though the WIT world declares it as `func`.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
const phantom = 42;

export const api = { phantom };
