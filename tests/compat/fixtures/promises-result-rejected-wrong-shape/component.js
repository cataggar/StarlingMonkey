// Integration fixture (feat/js-bridge-parity-integration): a Promise
// rejection on a top-level `result<u32, string>` export whose reason is an
// `Error` object, not a raw string -- the wrong JS shape for E. Must trap,
// exactly like a synchronous `throw new Error(...)` here would (see
// advanced-types' `divide`, which never itself exercises the mismatched-
// shape sub-case): "wrong-kind value traps, no coercion" applies equally
// whether the err payload arrives via a synchronous throw or an async
// rejection (see tests/compat/manifest.json's "promise-result-rejection-
// matches-throw" known_deviation).
//
// Written for cataggar/StarlingMonkey feat/js-bridge-parity-integration.
export async function divideAsync(a, b) {
  if (b === 0) {
    return Promise.reject(new Error("division by zero"));
  }
  return Math.trunc(a / b);
}
