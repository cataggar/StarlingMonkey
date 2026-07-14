#ifndef CORE_ERRORS_H
#define CORE_ERRORS_H

bool throw_error(JSContext* cx, const JSErrorFormatString &error,
                 const char* arg1 = nullptr,
                 const char* arg2 = nullptr,
                 const char* arg3 = nullptr,
                 const char* arg4 = nullptr);

namespace Errors {
DEF_ERR(WrongReceiver, JSEXN_TYPEERR, "Method '{0}' called on receiver that's not an instance of {1}", 2)
DEF_ERR(NoCtorBuiltin, JSEXN_TYPEERR, "{0} builtin can't be instantiated directly", 1)
DEF_ERR(TypeError, JSEXN_TYPEERR, "{0}: {1} must {2}", 3)
DEF_ERR(CtorCalledWithoutNew, JSEXN_TYPEERR, "calling a builtin {0} constructor without new is forbidden", 1)
DEF_ERR(InvalidSequence, JSEXN_TYPEERR, "Failed to construct {0} object. If defined, the first "
                     "argument must be either a [ ['name', 'value'], ... ] sequence, "
                     "or a { 'name' : 'value', ... } record{1}.", 2)
DEF_ERR(InvalidBuffer, JSEXN_TYPEERR, "{0} must be of type ArrayBuffer or ArrayBufferView", 1)
DEF_ERR(ForEachCallback, JSEXN_TYPEERR, "Failed to execute 'forEach' on '{0}': "
                                        "parameter 1 is not of type 'Function'", 1)
DEF_ERR(RequestHandlerOnly, JSEXN_TYPEERR, "{0} can only be used during request handling, "
                                           "not during initialization", 1)
DEF_ERR(InitializationOnly, JSEXN_TYPEERR, "{0} can only be used during request handling, "
                                           "not during initialization", 1)
// cataggar/StarlingMonkey#6 Phase 6 (platform feature selection): thrown
// when JavaScript requests host functionality this build was configured to
// disable (`-Dfeature-clocks=false`, etc). Deterministic, catchable failure
// rather than a silent no-op or an unrecoverable wasm trap -- see
// docs/feature-selection/README.md.
DEF_ERR(FeatureDisabled, JSEXN_TYPEERR, "{0} is disabled by build configuration "
                                        "(feature-selection: {1} disabled)", 2)
};     // namespace Errors

#endif // CORE_ERRORS_H
