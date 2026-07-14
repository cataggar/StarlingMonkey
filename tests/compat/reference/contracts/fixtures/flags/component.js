export function echo32(value) {
  return value;
}

export function echo33(value) {
  return value;
}

export function echo64(value) {
  return value;
}

export function echo65(value) {
  return value;
}

export function describe32(value) {
  return {
    setCount: Object.values(value).filter(Boolean).length,
    first: value.flagA00,
    last: value.flagA31,
  };
}

export function describe65(value) {
  return {
    setCount: Object.values(value).filter(Boolean).length,
    first: value.flagA00,
    word1: value.flagA32,
    word2: value.flagA64,
  };
}
