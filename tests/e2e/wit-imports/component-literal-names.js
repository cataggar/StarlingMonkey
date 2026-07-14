const literalIncomingHandler = {
  "kebab-interface-add": (value) => value + 1,
};

const camelIncomingHandler = {
  kebabInterfaceAdd: (value) => value + 100,
};

export {
  literalIncomingHandler as "incoming-handler",
  camelIncomingHandler as incomingHandler,
};
