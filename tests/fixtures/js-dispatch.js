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
