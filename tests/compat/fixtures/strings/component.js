// Phase 0 compatibility fixture: string identity, concatenation and length.
//
// `length` intentionally returns the JS UTF-16 code-unit count (`.length`),
// which is what any JS engine embedding observes once wasi-string content is
// lifted into a JS string; see manifest.json for the fixture's expected
// values with astral characters (e.g. emoji) that span two code units.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
function identity(value) {
  return value;
}

function concat(a, b) {
  return a + b;
}

function length(value) {
  return value.length;
}

export const api = { identity, concat, length };
