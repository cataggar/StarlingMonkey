#ifndef STARLING_TASK_SELECTION_H
#define STARLING_TASK_SELECTION_H

#include <cstddef>

template <typename IsReady>
std::size_t oldest_ready_or_immediate(std::size_t immediate_index, IsReady is_ready) {
  for (std::size_t index = 0; index < immediate_index; ++index) {
    if (is_ready(index)) {
      return index;
    }
  }
  return immediate_index;
}

#endif
