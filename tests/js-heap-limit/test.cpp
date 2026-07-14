#include "config-parser.h"

#include <cassert>
#include <cstdint>
#include <string_view>
#include <vector>

int main() {
  static_assert(starling::DEFAULT_JS_HEAP_LIMIT_BYTES == 1024U * 1024U * 1024U);

  uint32_t bytes = 0;
  assert(starling::parse_js_heap_limit_mib("1", &bytes));
  assert(bytes == 1024U * 1024U);
  assert(starling::parse_js_heap_limit_mib("1024", &bytes));
  assert(bytes == starling::DEFAULT_JS_HEAP_LIMIT_BYTES);
  assert(starling::parse_js_heap_limit_mib("4095", &bytes));
  assert(bytes == 4095U * 1024U * 1024U);

  assert(!starling::parse_js_heap_limit_mib("", &bytes));
  assert(!starling::parse_js_heap_limit_mib("0", &bytes));
  assert(!starling::parse_js_heap_limit_mib("-1", &bytes));
  assert(!starling::parse_js_heap_limit_mib("1.5", &bytes));
  assert(!starling::parse_js_heap_limit_mib("1024MiB", &bytes));
  assert(!starling::parse_js_heap_limit_mib("4096", &bytes));

  starling::ConfigParser default_parser;
  assert(default_parser.take()->js_heap_limit_bytes ==
         starling::DEFAULT_JS_HEAP_LIMIT_BYTES);

  starling::ConfigParser configured_parser;
  configured_parser.apply_args(std::vector<std::string_view>{
      "starling-raw.wasm", "--js-heap-limit-mib", "256"});
  assert(configured_parser.take()->js_heap_limit_bytes == 256U * 1024U * 1024U);
  return 0;
}
