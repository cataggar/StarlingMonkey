#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>
#include <utility>

#include "builtin.h"
#include "extension-api.h"
#include "config-parser.h"
#include "host_api.h"
#include "js_dispatch.h"
#include "wasi/api.h"
#include "wasi/libc-environ.h"
#include "wizer.h"
#ifdef MEM_STATS
#include <string>
#endif

api::Engine *engine;

api::Engine* initialize(std::vector<std::string_view> args) {
  auto config_parser = starling::ConfigParser();
  config_parser.apply_env()->apply_args(std::move(args));
  return new api::Engine(config_parser.take());
}

static api::Engine *ENGINE = nullptr;

enum class RuntimeConfigurationMode {
  External,
  Snapshotted,
};

// Wizer explicitly transitions the runtime to snapshotted configuration.
// An unsnapshotted runtime remains in external mode and reads its invocation
// arguments and environment when wasi:cli/run is called.
static RuntimeConfigurationMode configuration_mode = RuntimeConfigurationMode::External;

extern "C" bool starling_uses_snapshotted_configuration() {
  return configuration_mode == RuntimeConfigurationMode::Snapshotted;
}

__attribute__((weak))
int main(int argc, const char *argv[]) {
  MOZ_ASSERT_UNREACHABLE("main() should not be called");
}

static uint64_t mono_clock_offset = 0;
#define NSECS_PER_SEC 1000000000;

// This overrides wasi-libc's weakly linked implementation of clock_gettime to ensure that
// monotonic clocks really are monotonic, even across resumptions of wizer snapshots.
int clock_gettime(clockid_t clock, timespec * ts) {
  __wasi_clockid_t clock_id = 0;
  if (clock == CLOCK_REALTIME) {
    clock_id = __WASI_CLOCKID_REALTIME;
  } else if (clock == CLOCK_MONOTONIC) {
    clock_id = __WASI_CLOCKID_MONOTONIC;
  } else {
    return EINVAL;
  }
  __wasi_timestamp_t t = 0;
  auto errno = __wasi_clock_time_get(clock_id, 1, &t);
  if (errno != 0) {
    return EINVAL;
  }
  if (clock == CLOCK_MONOTONIC) {
    t += mono_clock_offset;
  }
  ts->tv_sec = t / NSECS_PER_SEC;
  ts->tv_nsec = t % NSECS_PER_SEC;
  return 0;
}

void wizen() {
  std::string args;
  std::getline(std::cin, args);
  auto config_parser = starling::ConfigParser();
  config_parser.apply_env()->apply_args(args);
  auto config = config_parser.take();
  config->pre_initialize = true;
  ENGINE = new api::Engine(std::move(config));
  if (!starling_validate_required_exports()) {
    ENGINE->abort("validating required JavaScript exports");
  }
  ENGINE->finish_pre_initialization();
  configuration_mode = RuntimeConfigurationMode::Snapshotted;

  // Ensure that the monotonic clock is always increasing, even across multiple resumptions.
  __wasi_timestamp_t t = 0;
  MOZ_RELEASE_ASSERT(!__wasi_clock_time_get(__WASI_CLOCKID_MONOTONIC, 1, &t));
  mono_clock_offset = std::max(mono_clock_offset, t);
  __wasilibc_deinitialize_environ();
}

WIZER_INIT(wizen);

/**
 * The main entry function for the runtime.
 *
 * The runtime will be initialized with a configuration derived in the following way:
 * 1. A runtime explicitly initialized by Wizer reuses its snapshotted engine.
 * 2. Otherwise, invocation arguments override STARLINGMONKEY_CONFIG.
 * 3. Otherwise, the default configuration loads ./index.js.
 */
extern "C" bool exports_wasi_cli_run_run() {
  switch (configuration_mode) {
  case RuntimeConfigurationMode::Snapshotted:
    MOZ_RELEASE_ASSERT(ENGINE);
    break;
  case RuntimeConfigurationMode::External: {
    auto arg_strings = host_api::environment_get_arguments();
    std::vector<std::string_view> args;
    args.reserve(arg_strings.size());
    for (auto &arg : arg_strings) {
      args.push_back(arg);
    }

    auto config_parser = starling::ConfigParser();
    config_parser.apply_env()->apply_args(std::move(args));
    ENGINE = new api::Engine(config_parser.take());
    break;
  }
  }
  return starling::shutdown_resources(ENGINE);
}

// Embedders that invoke JavaScript-backed exports directly need an explicit
// depth-zero lifecycle checkpoint without entering the one-shot WASI CLI path.
extern "C" STARLING_ENGINE_EXPORT
    __attribute__((export_name("starling-js-shutdown-resources")))
bool starling_js_shutdown_resources() {
  return ENGINE && starling::shutdown_resources(ENGINE);
}

extern "C" STARLING_ENGINE_EXPORT
    __attribute__((export_name("starling-js-exported-resource-count")))
uint32_t starling_js_exported_resource_count() {
  return static_cast<uint32_t>(starling::exported_resource_count());
}

/**
 * Initialize the runtime with the configuration provided via an environment variable.
 *
 * This initializer checks for the environment variable `STARLINGMONKEY_CONFIG` and parses
 * it as a command line arguments string. The variable not being set is treated as an empty
 * command line.
 */
extern "C" bool init_from_environment() {
  auto config_parser = starling::ConfigParser();
  config_parser.apply_env();
  ENGINE = new api::Engine(config_parser.take());
  return true;
}
