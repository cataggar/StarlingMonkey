export { api, rootAdd } from "./component.js";

const literalIncomingHandler = {
  "kebab-interface-add": (value) => value + 1,
};

const camelIncomingHandler = {
  "kebab-interface-add": (value) => value + 100,
};

export {
  literalIncomingHandler as "incoming-handler",
  camelIncomingHandler as incomingHandler,
};
