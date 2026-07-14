import {
  Counter,
  read,
} from "contract:imported-resources/host@0.1.0";

export function useCounter(initial) {
  const counter = new Counter(initial);
  counter.increment(2);
  return read(counter);
}
