#ifndef STARLINGMONKEY_HEAP_LIMIT_H
#define STARLINGMONKEY_HEAP_LIMIT_H

#include <charconv>
#include <cstdint>
#include <limits>
#include <string_view>
#include <system_error>

namespace starling {

inline constexpr uint32_t DEFAULT_JS_HEAP_LIMIT_BYTES = 1024U * 1024U * 1024U;
inline constexpr uint32_t BYTES_PER_MIB = 1024U * 1024U;

inline bool parse_js_heap_limit_mib(std::string_view value, uint32_t *out_bytes) {
  uint64_t mib = 0;
  const auto result = std::from_chars(value.data(), value.data() + value.size(), mib);
  if (result.ec != std::errc() || result.ptr != value.data() + value.size() || mib == 0 ||
      mib > std::numeric_limits<uint32_t>::max() / BYTES_PER_MIB) {
    return false;
  }

  *out_bytes = static_cast<uint32_t>(mib * BYTES_PER_MIB);
  return true;
}

} // namespace starling

#endif // STARLINGMONKEY_HEAP_LIMIT_H
