function shape(value) {
  if (value === undefined) return "undefined";
  if (value === null) return "null";
  return "value";
}

export function directShape(value) {
  return shape(value);
}

export function aggregateShapes(value) {
  return [shape(value.direct), ...value.items.map(shape)];
}

export function nestedShape(value) {
  if (value === undefined) {
    return { kind: "undefined", hasVal: false, valueShape: "missing" };
  }
  if (value === null) {
    return { kind: "null", hasVal: false, valueShape: "missing" };
  }
  const hasVal = Object.prototype.hasOwnProperty.call(value, "val");
  return {
    kind: String(value.tag ?? "object"),
    hasVal,
    valueShape: hasVal ? shape(value.val) : "missing",
  };
}

export function lowerNull() {
  return null;
}

export function lowerUndefined() {
  return undefined;
}
