// Phase 0 compatibility fixture: numeric primitive identities plus a small
// two-argument sum, exercised at type-width boundary values.
//
// Independently authored for cataggar/StarlingMonkey#6 (Phase 0).
function echou8(value) {
  return value;
}

function echou16(value) {
  return value;
}

function echou32(value) {
  return value;
}

function echos8(value) {
  return value;
}

function echos16(value) {
  return value;
}

function echos32(value) {
  return value;
}

function echof32(value) {
  return value;
}

function echof64(value) {
  return value;
}

function sum(a, b) {
  return a + b;
}

export const api = { echou8, echou16, echou32, echos8, echos16, echos32, echof32, echof64, sum };
