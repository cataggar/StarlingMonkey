export { api, rootAdd } from "./component.js";

const literalIncomingHandler = {
  "kebab-interface-add": (value) => value + 1,
  kebabInterfaceAdd: (value) => value + 10,
};

export {
  literalIncomingHandler as "incoming-handler",
};
