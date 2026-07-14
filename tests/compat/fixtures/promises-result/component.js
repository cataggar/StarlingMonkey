// Integration fixture (feat/js-bridge-parity-integration): async
// (Promise-returning) counterparts to advanced-types' `divide`/
// `checked-negate`, isolating the two never-trapping Promise-vs-result
// sub-cases empirically confirmed against the pinned ComponentizeJS 0.21.0
// reference (see tests/compat/manifest.json's "promise-result-rejection-
// matches-throw" known_deviation for the full differential evidence).
//
// Written for cataggar/StarlingMonkey feat/js-bridge-parity-integration.

// Top-level export return type is the export's own `result<u32, string>`:
// fulfillment lowers as Ok(value); rejection with a reason whose JS shape
// matches E (here, a raw string) lowers as Err(reason) -- exactly like a
// synchronous throw of that same string would (see advanced-types'
// `divide`), not a hard dispatch failure.
async function divideAsync(a, b) {
  if (b === 0) {
    return Promise.reject("division by zero");
  }
  return Math.trunc(a / b);
}

// `result<s32>` (E is void, WIT's err-omitted shorthand): ComponentizeJS
// never inspects the rejection reason's shape at all when E is void, so
// *any* reason -- even a plain object, as used here -- becomes a bare
// Err() with no payload.
async function checkedNegateAsync(value) {
  if (value === -2147483648) {
    return Promise.reject({ note: "shape is irrelevant when E is void" });
  }
  return -value;
}

export const api = { divideAsync, checkedNegateAsync };
