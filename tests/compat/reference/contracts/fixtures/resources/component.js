class Counter {
  constructor(initial) {
    this.current = initial;
  }

  static fromDouble(value) {
    return new Counter(value * 2);
  }

  increment(by) {
    this.current += by;
    return this.current;
  }

  value() {
    return this.current;
  }
}

function borrowValue(value) {
  return value.value();
}

function takeValue(value) {
  return value.value();
}

export const api = { Counter, borrowValue, takeValue };
