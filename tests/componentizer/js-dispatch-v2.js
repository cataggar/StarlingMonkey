function add(a, b) {
  return a + b;
}

function greet(name) {
  return `Hello, ${name}!`;
}

function notify(message) {
  console.log(message);
}

function move(point, dx, dy) {
  return { x: point.x + dx, y: point.y + dy };
}

function maybe(value) {
  return value == null ? null : value + 1;
}

function subtract(a, b) {
  return a - b;
}

export const api = { add, greet, notify, move, maybe, subtract };
