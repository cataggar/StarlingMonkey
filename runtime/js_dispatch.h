#ifndef STARLINGMONKEY_JS_DISPATCH_H
#define STARLINGMONKEY_JS_DISPATCH_H

#include <stddef.h>
#include <stdint.h>

struct StarlingJSDispatchResult {
  uint8_t *ptr;
  size_t len;
};

extern "C" uint32_t starling_js_dispatch(const uint8_t *export_name_ptr,
                                         size_t export_name_len,
                                         const uint8_t *args_json_ptr,
                                         size_t args_json_len,
                                         StarlingJSDispatchResult *result);

#endif
