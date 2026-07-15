#ifndef STARLINGMONKEY_RESOURCE_REGISTRY_H
#define STARLINGMONKEY_RESOURCE_REGISTRY_H

#include <cstdint>
#include <deque>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>

namespace starling {

struct ResourceDescriptor {
  std::string provider;
  std::string name;
};

enum class ResourceOwnership : uint8_t {
  Own,
  Borrow,
};

enum class ResourceState : uint8_t {
  BorrowOnly,
  Owned,
  DropQueued,
  Transferred,
  Dropped,
};

enum class ResourceError : uint8_t {
  None,
  NotInDispatch,
  WrongOwnership,
  UnknownResource,
  StaleToken,
  ExpiredBorrow,
  InvalidState,
};

struct ResourceToken {
  uint32_t type_id = 0;
  int32_t handle = 0;
  uint64_t generation = 0;
  ResourceOwnership ownership = ResourceOwnership::Borrow;
  uint64_t borrow_epoch = 0;
};

struct ResourceTokenResult {
  ResourceError error = ResourceError::None;
  ResourceToken token{};

  explicit operator bool() const { return error == ResourceError::None; }
};

struct ResourceDropRequest {
  ResourceToken token;
};

class ResourceRegistry {
  struct ResourceKey {
    uint32_t type_id = 0;
    int32_t handle = 0;

    bool operator==(const ResourceKey &) const = default;
  };

  struct ResourceKeyHash {
    size_t operator()(const ResourceKey &key) const;
  };

  struct Entry {
    ResourceKey key;
    uint64_t generation = 0;
    uint64_t borrow_epoch = 0;
    ResourceState state = ResourceState::Dropped;
    Entry *next_borrow = nullptr;
    Entry *next_drop = nullptr;
  };

  std::deque<ResourceDescriptor> types_;
  std::unordered_map<ResourceKey, Entry, ResourceKeyHash> entries_;
  Entry *active_borrows_ = nullptr;
  Entry *queued_drops_ = nullptr;
  uint64_t active_borrow_epoch_ = 0;
  uint32_t dispatch_depth_ = 0;

  ResourceToken token(ResourceKey key, const Entry &entry, ResourceOwnership ownership) const;
  ResourceError validate_locked(const ResourceToken &token) const;
  void track_borrow(Entry &entry);
  void track_drop(Entry &entry);

public:
  uint32_t intern_type(std::string_view provider, std::string_view name);
  const ResourceDescriptor *descriptor(uint32_t type_id) const;

  ResourceTokenResult acquire_owned(std::string_view provider, std::string_view name,
                                    int32_t handle);
  ResourceTokenResult acquire_borrow(std::string_view provider, std::string_view name,
                                     int32_t handle);

  ResourceError validate(const ResourceToken &token) const;
  ResourceError transfer_owned(const ResourceToken &token);
  ResourceError transfer_owned_many(std::span<const ResourceToken> tokens);
  ResourceError queue_drop(const ResourceToken &token);

  uint64_t enter_dispatch();
  bool leave_dispatch();
  uint32_t dispatch_depth() const { return dispatch_depth_; }
  uint64_t active_borrow_epoch() const { return active_borrow_epoch_; }

  std::optional<ResourceDropRequest> take_queued_drop();
  void queue_all_owned();
};

} // namespace starling

#endif
