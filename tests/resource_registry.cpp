#include "resource_registry.h"

#include <array>
#include <cstdlib>

using starling::ResourceError;
using starling::ResourceOwnership;
using starling::ResourceRegistry;

template <typename T> static void expect(const T &condition) {
  if (!static_cast<bool>(condition)) {
    std::abort();
  }
}

int main() {
  ResourceRegistry registry;

  const uint32_t first_type = registry.intern_type("test:resources/first@1.0.0", "item");
  expect(first_type != 0);
  expect(first_type == registry.intern_type("test:resources/first@1.0.0", "item"));
  const uint32_t second_provider =
      registry.intern_type("test:resources/second@1.0.0", "item");
  const uint32_t second_type =
      registry.intern_type("test:resources/first@1.0.0", "other");
  expect(first_type != second_provider);
  expect(first_type != second_type);

  const auto first = registry.acquire_owned("test:resources/first@1.0.0", "item", 1);
  const auto other_provider =
      registry.acquire_owned("test:resources/second@1.0.0", "item", 1);
  const auto other_type =
      registry.acquire_owned("test:resources/first@1.0.0", "other", 1);
  expect(first && other_provider && other_type);
  expect(first.token.type_id != other_provider.token.type_id);
  expect(first.token.type_id != other_type.token.type_id);
  expect(registry.validate(first.token) == ResourceError::None);
  expect(!registry.acquire_owned("test:resources/first@1.0.0", "item", 1));

  registry.enter_dispatch();
  const auto borrowed = registry.acquire_borrow("test:resources/first@1.0.0", "item", 1);
  expect(borrowed);
  expect(borrowed.token.ownership == ResourceOwnership::Borrow);
  expect(borrowed.token.generation == first.token.generation);
  expect(registry.validate(borrowed.token) == ResourceError::None);

  const uint64_t outer_epoch = registry.active_borrow_epoch();
  expect(registry.enter_dispatch() == outer_epoch);
  expect(!registry.leave_dispatch());
  expect(registry.validate(borrowed.token) == ResourceError::None);
  expect(registry.leave_dispatch());
  expect(registry.validate(borrowed.token) == ResourceError::ExpiredBorrow);

  registry.enter_dispatch();
  const auto deferred_owner =
      registry.acquire_owned("test:resources/first@1.0.0", "deferred", 3);
  const auto deferred_borrow =
      registry.acquire_borrow("test:resources/first@1.0.0", "deferred", 3);
  expect(deferred_owner && deferred_borrow);
  expect(registry.queue_drop(deferred_owner.token) == ResourceError::None);
  expect(registry.validate(deferred_borrow.token) == ResourceError::None);
  expect(!registry.take_queued_drop());
  expect(registry.leave_dispatch());
  expect(registry.take_queued_drop());

  registry.enter_dispatch();
  const auto ephemeral =
      registry.acquire_borrow("test:resources/first@1.0.0", "ephemeral", 9);
  expect(ephemeral);
  expect(registry.leave_dispatch());
  registry.enter_dispatch();
  const auto reused_borrow =
      registry.acquire_borrow("test:resources/first@1.0.0", "ephemeral", 9);
  expect(reused_borrow);
  expect(reused_borrow.token.generation != ephemeral.token.generation);
  expect(registry.leave_dispatch());

  expect(registry.transfer_owned(first.token) == ResourceError::None);
  expect(registry.transfer_owned(first.token) == ResourceError::InvalidState);
  expect(registry.queue_drop(first.token) == ResourceError::InvalidState);

  const auto reused_owned =
      registry.acquire_owned("test:resources/first@1.0.0", "item", 1);
  expect(reused_owned);
  expect(reused_owned.token.generation != first.token.generation);
  expect(registry.validate(first.token) == ResourceError::StaleToken);

  const auto atomic_first =
      registry.acquire_owned("test:resources/first@1.0.0", "atomic-first", 11);
  const auto atomic_second =
      registry.acquire_owned("test:resources/first@1.0.0", "atomic-second", 12);
  expect(atomic_first && atomic_second);
  const std::array valid_transfer{atomic_first.token, atomic_second.token};
  const std::array duplicate_transfer{atomic_first.token, atomic_first.token};
  expect(registry.transfer_owned_many(duplicate_transfer) == ResourceError::InvalidState);
  expect(registry.validate(atomic_first.token) == ResourceError::None);
  expect(registry.validate(atomic_second.token) == ResourceError::None);
  expect(registry.transfer_owned_many(valid_transfer) == ResourceError::None);
  expect(registry.validate(atomic_first.token) == ResourceError::InvalidState);
  expect(registry.validate(atomic_second.token) == ResourceError::InvalidState);

  size_t host_drop_calls = 0;
  expect(registry.queue_drop(reused_owned.token) == ResourceError::None);
  expect(host_drop_calls == 0);
  expect(registry.queue_drop(reused_owned.token) == ResourceError::InvalidState);
  const auto drop = registry.take_queued_drop();
  expect(drop);
  expect(drop->token.type_id == reused_owned.token.type_id);
  expect(drop->token.handle == reused_owned.token.handle);
  host_drop_calls++;
  expect(host_drop_calls == 1);
  expect(!registry.take_queued_drop());

  const auto shutdown_owned =
      registry.acquire_owned("test:resources/first@1.0.0", "shutdown", 5);
  expect(shutdown_owned);
  registry.queue_all_owned();
  size_t shutdown_drops = 0;
  while (registry.take_queued_drop()) {
    shutdown_drops++;
  }
  expect(shutdown_drops == 3);

  return 0;
}
