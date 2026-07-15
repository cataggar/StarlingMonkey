#include "resource_registry.h"

#include <limits>

namespace starling {

size_t ResourceRegistry::ResourceKeyHash::operator()(const ResourceKey &key) const {
  const size_t type_hash = std::hash<uint32_t>{}(key.type_id);
  const size_t handle_hash = std::hash<int32_t>{}(key.handle);
  return type_hash ^ (handle_hash + 0x9e3779b9U + (type_hash << 6) + (type_hash >> 2));
}

ResourceToken ResourceRegistry::token(ResourceKey key, const Entry &entry,
                                      ResourceOwnership ownership) const {
  return {
      .type_id = key.type_id,
      .handle = key.handle,
      .generation = entry.generation,
      .ownership = ownership,
      .borrow_epoch = ownership == ResourceOwnership::Borrow ? active_borrow_epoch_ : 0,
  };
}

void ResourceRegistry::track_borrow(Entry &entry) {
  entry.next_borrow = active_borrows_;
  active_borrows_ = &entry;
}

void ResourceRegistry::track_drop(Entry &entry) {
  entry.next_drop = queued_drops_;
  queued_drops_ = &entry;
}

uint32_t ResourceRegistry::intern_type(std::string_view provider, std::string_view name) {
  for (size_t i = 0; i < types_.size(); ++i) {
    const auto &type = types_[i];
    if (type.provider == provider && type.name == name) {
      return static_cast<uint32_t>(i + 1);
    }
  }

  if (types_.size() == std::numeric_limits<uint32_t>::max()) {
    return 0;
  }
  types_.push_back({.provider = std::string(provider), .name = std::string(name)});
  return static_cast<uint32_t>(types_.size());
}

const ResourceDescriptor *ResourceRegistry::descriptor(uint32_t type_id) const {
  if (type_id == 0 || type_id > types_.size()) {
    return nullptr;
  }
  return &types_[type_id - 1];
}

ResourceTokenResult ResourceRegistry::acquire_owned(std::string_view provider,
                                                    std::string_view name, int32_t handle) {
  const uint32_t type_id = intern_type(provider, name);
  if (type_id == 0) {
    return {.error = ResourceError::UnknownResource};
  }

  const ResourceKey key{.type_id = type_id, .handle = handle};
  auto [it, inserted] = entries_.try_emplace(key);
  Entry &entry = it->second;
  if (inserted) {
    entry.key = key;
    entry.generation = 1;
    entry.state = ResourceState::Owned;
  } else {
    switch (entry.state) {
    case ResourceState::Owned:
      return {.error = ResourceError::InvalidState};
    case ResourceState::BorrowOnly:
      entry.state = ResourceState::Owned;
      entry.borrow_epoch = 0;
      break;
    case ResourceState::Transferred:
    case ResourceState::Dropped:
      entry.generation++;
      if (entry.generation == 0) {
        entry.generation = 1;
      }
      entry.state = ResourceState::Owned;
      entry.borrow_epoch = 0;
      break;
    case ResourceState::DropQueued:
      return {.error = ResourceError::InvalidState};
    }
  }
  return {.token = token(key, entry, ResourceOwnership::Own)};
}

ResourceTokenResult ResourceRegistry::acquire_borrow(std::string_view provider,
                                                     std::string_view name, int32_t handle) {
  if (dispatch_depth_ == 0) {
    return {.error = ResourceError::NotInDispatch};
  }

  const uint32_t type_id = intern_type(provider, name);
  if (type_id == 0) {
    return {.error = ResourceError::UnknownResource};
  }

  const ResourceKey key{.type_id = type_id, .handle = handle};
  auto [it, inserted] = entries_.try_emplace(key);
  Entry &entry = it->second;
  if (inserted) {
    entry.key = key;
    entry.generation = 1;
    entry.borrow_epoch = active_borrow_epoch_;
    entry.state = ResourceState::BorrowOnly;
    track_borrow(entry);
  } else {
    switch (entry.state) {
    case ResourceState::BorrowOnly:
      if (entry.borrow_epoch != active_borrow_epoch_) {
        entry.generation++;
        if (entry.generation == 0) {
          entry.generation = 1;
        }
        entry.borrow_epoch = active_borrow_epoch_;
        track_borrow(entry);
      }
      break;
    case ResourceState::Owned:
    case ResourceState::Transferred:
      break;
    case ResourceState::Dropped:
      entry.generation++;
      if (entry.generation == 0) {
        entry.generation = 1;
      }
      entry.borrow_epoch = active_borrow_epoch_;
      entry.state = ResourceState::BorrowOnly;
      track_borrow(entry);
      break;
    case ResourceState::DropQueued:
      return {.error = ResourceError::InvalidState};
    }
  }
  return {.token = token(key, entry, ResourceOwnership::Borrow)};
}

ResourceError ResourceRegistry::validate_locked(const ResourceToken &token_value) const {
  if (!descriptor(token_value.type_id)) {
    return ResourceError::UnknownResource;
  }
  const ResourceKey key{.type_id = token_value.type_id, .handle = token_value.handle};
  const auto it = entries_.find(key);
  if (it == entries_.end()) {
    return ResourceError::UnknownResource;
  }
  const Entry &entry = it->second;
  if (entry.generation != token_value.generation) {
    return ResourceError::StaleToken;
  }

  if (token_value.ownership == ResourceOwnership::Borrow) {
    if (dispatch_depth_ == 0 || token_value.borrow_epoch == 0 ||
        token_value.borrow_epoch != active_borrow_epoch_) {
      return ResourceError::ExpiredBorrow;
    }
    if (entry.state != ResourceState::BorrowOnly && entry.state != ResourceState::Owned &&
        entry.state != ResourceState::DropQueued && entry.state != ResourceState::Transferred) {
      return ResourceError::InvalidState;
    }
    return ResourceError::None;
  }

  if (token_value.borrow_epoch != 0) {
    return ResourceError::WrongOwnership;
  }
  return entry.state == ResourceState::Owned ? ResourceError::None
                                             : ResourceError::InvalidState;
}

ResourceError ResourceRegistry::validate(const ResourceToken &token_value) const {
  return validate_locked(token_value);
}

ResourceError ResourceRegistry::transfer_owned(const ResourceToken &token_value) {
  return transfer_owned_many(std::span<const ResourceToken>(&token_value, 1));
}

ResourceError
ResourceRegistry::transfer_owned_many(std::span<const ResourceToken> token_values) {
  for (size_t i = 0; i < token_values.size(); ++i) {
    const ResourceToken &token_value = token_values[i];
    if (token_value.ownership != ResourceOwnership::Own) {
      return ResourceError::WrongOwnership;
    }
    const ResourceError valid = validate_locked(token_value);
    if (valid != ResourceError::None) {
      return valid;
    }
    for (size_t j = 0; j < i; ++j) {
      if (token_values[j].type_id == token_value.type_id &&
          token_values[j].handle == token_value.handle &&
          token_values[j].generation == token_value.generation) {
        return ResourceError::InvalidState;
      }
    }
  }

  for (const ResourceToken &token_value : token_values) {
    const ResourceKey key{.type_id = token_value.type_id, .handle = token_value.handle};
    entries_.find(key)->second.state = ResourceState::Transferred;
  }
  return ResourceError::None;
}

ResourceError ResourceRegistry::queue_drop(const ResourceToken &token_value) {
  if (token_value.ownership != ResourceOwnership::Own) {
    return ResourceError::WrongOwnership;
  }
  const ResourceError valid = validate_locked(token_value);
  if (valid != ResourceError::None) {
    return valid;
  }
  const ResourceKey key{.type_id = token_value.type_id, .handle = token_value.handle};
  Entry &entry = entries_.find(key)->second;
  entry.state = ResourceState::DropQueued;
  track_drop(entry);
  return ResourceError::None;
}

uint64_t ResourceRegistry::enter_dispatch() {
  if (dispatch_depth_ == 0) {
    active_borrow_epoch_++;
    if (active_borrow_epoch_ == 0) {
      active_borrow_epoch_ = 1;
    }
  }
  dispatch_depth_++;
  return active_borrow_epoch_;
}

bool ResourceRegistry::leave_dispatch() {
  if (dispatch_depth_ == 0) {
    return false;
  }
  dispatch_depth_--;
  if (dispatch_depth_ != 0) {
    return false;
  }

  while (active_borrows_) {
    Entry *entry = active_borrows_;
    active_borrows_ = entry->next_borrow;
    entry->next_borrow = nullptr;
    if (entry->state == ResourceState::BorrowOnly &&
        entry->borrow_epoch == active_borrow_epoch_) {
      entry->state = ResourceState::Dropped;
      entry->borrow_epoch = 0;
    }
  }
  return true;
}

std::optional<ResourceDropRequest> ResourceRegistry::take_queued_drop() {
  if (dispatch_depth_ != 0) {
    return std::nullopt;
  }
  if (!queued_drops_) {
    return std::nullopt;
  }
  Entry *entry = queued_drops_;
  queued_drops_ = entry->next_drop;
  entry->next_drop = nullptr;
  entry->state = ResourceState::Dropped;
  return ResourceDropRequest{.token = token(entry->key, *entry, ResourceOwnership::Own)};
}

void ResourceRegistry::queue_all_owned() {
  if (dispatch_depth_ != 0) {
    return;
  }
  for (auto &[key, entry] : entries_) {
    (void)key;
    if (entry.state == ResourceState::Owned) {
      entry.state = ResourceState::DropQueued;
      track_drop(entry);
    }
  }
}

} // namespace starling
