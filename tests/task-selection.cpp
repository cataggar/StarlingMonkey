#include "task-selection.h"

#include <vector>

int main() {
  {
    const std::vector<bool> ready{false, true, true};
    std::vector<std::size_t> checked;
    const auto selected = oldest_ready_or_immediate(ready.size(), [&](std::size_t index) {
      checked.push_back(index);
      return ready[index];
    });
    if (selected != 1 || checked != std::vector<std::size_t>{0, 1}) {
      return 1;
    }
  }

  {
    const std::vector<bool> ready{false, false};
    std::vector<std::size_t> checked;
    const auto selected = oldest_ready_or_immediate(ready.size(), [&](std::size_t index) {
      checked.push_back(index);
      return ready[index];
    });
    if (selected != ready.size() || checked != std::vector<std::size_t>{0, 1}) {
      return 1;
    }
  }
}
