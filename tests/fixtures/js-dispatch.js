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
