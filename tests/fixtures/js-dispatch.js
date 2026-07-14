export function add(a, b) {
  return a + b;
}

export function greet(name) {
  return `Hello, ${name}!`;
}

export function notify(message) {
  console.log(message);
}

export function move(point, dx, dy) {
  return { x: point.x + dx, y: point.y + dy };
}

export function maybe(value) {
  return value === null ? null : value + 1;
}

// Exact u64/s64 round trips beyond 2^53: both operands and the result stay
// native BigInt end to end, so this is exact where a JSON-number round trip
// would lose precision.
function bigAddImpl(a, b) {
  return a + b;
}
export { bigAddImpl as "big-add" };

function bigSubImpl(a, b) {
  return a - b;
}
export { bigSubImpl as "big-sub" };

// Nested aggregate (a record embedding another record) plus an exact u64
// field, dispatched natively without JSON.
function tagPointImpl(p, id) {
  return { p, id };
}
export { tagPointImpl as "tag-point" };

// Record combining a string field with an exact u64 field: exercises the
// UAF fix directly, since both the string and the u64 are decoded out of
// the same native result before the C++ NativeArena is freed.
function labelIdImpl(label, id) {
  return { label: `${label}-tagged`, id };
}
export { labelIdImpl as "label-id" };

// Optional 64-bit round trips, both present and absent.
function maybeBigImpl(value) {
  return value === null ? null : value + 1n;
}
export { maybeBigImpl as "maybe-big" };

function maybeSignedImpl(value) {
  return value === null ? null : value - 1n;
}
export { maybeSignedImpl as "maybe-signed" };

// list<u64>: sum and echo, exercising exact values beyond 2^53.
function sumListImpl(values) {
  return values.reduce((acc, v) => acc + v, 0n);
}
export { sumListImpl as "sum-list" };

function echoListImpl(values) {
  return values.map((v) => v);
}
export { echoListImpl as "echo-list" };

// Deliberately wrong return type (string instead of u64/BigInt) to prove
// the native decoder traps instead of silently returning zero.
function wrongTypeImpl() {
  return "not-a-bigint";
}
export { wrongTypeImpl as "wrong-type" };
