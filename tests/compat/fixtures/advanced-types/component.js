// Phase 1b+ compatibility fixture: char, list<u8>, tuple, enum, flags,
// variant, result<T, E> (nested and top-level), and multi-word-identifier
// naming edge cases. Written once and run unmodified against both the
// pinned ComponentizeJS reference and the real StarlingMonkey bridge (see
// tests/compat/manifest.json's provenance.verified_by_reference_run and
// runtime_verification fields for this fixture).
//
// Independently authored for cataggar/StarlingMonkey#6 (sync-value-parity).
function echoChar(c) {
  return c;
}

function echoBytes(data) {
  return data;
}

function bytesLen(data) {
  return data.length;
}

function swapPair(pair) {
  return [pair[1], pair[0]];
}

function echoDirection(d) {
  return d;
}

function echoPerms(p) {
  return p;
}

function echoShape(s) {
  return s;
}

function echoWrappedResult(w) {
  return w;
}

// The export's own top-level return type is `result<u32, string>`:
// ComponentizeJS's calling convention returns the Ok payload directly and
// signals Err by throwing.
function divide(a, b) {
  if (b === 0) {
    throw "division by zero";
  }
  return Math.trunc(a / b);
}

// `result<s32>` (E is void, per WIT's err-omitted shorthand): failure is
// signaled by throwing anything at all.
function checkedNegate(value) {
  if (value === -2147483648) {
    throw new Error("negating i32::MIN would overflow");
  }
  return -value;
}

function echoMultiWordRecord(r) {
  return r;
}

function echoMultiWordFlags(f) {
  return f;
}

function echoMultiWordEnum(e) {
  return e;
}

function echoMultiWordVariant(v) {
  return v;
}

export const api = { echoChar, echoBytes, bytesLen, swapPair, echoDirection, echoPerms, echoShape, echoWrappedResult, divide, checkedNegate, echoMultiWordRecord, echoMultiWordFlags, echoMultiWordEnum, echoMultiWordVariant };
