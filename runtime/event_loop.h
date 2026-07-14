#ifndef JS_COMPUTE_RUNTIME_EVENT_LOOP_H
#define JS_COMPUTE_RUNTIME_EVENT_LOOP_H

#include "extension-api.h"
#include "jsapi.h"

namespace core {

/**
 * Outcome of `EventLoop::pump_until_promise_settled`.
 */
enum class PromisePumpResult {
  // The promise transitioned to Fulfilled or Rejected; the caller should
  // inspect `JS::GetPromiseState`/`JS::GetPromiseResult` to see which.
  Settled,
  // Neither the microtask queue nor the async task queue had any further
  // work to perform, yet the promise is still Pending: nothing left could
  // ever settle it. A deterministic diagnostic, not a hang.
  NoProgress,
  // A JS exception became pending while pumping (either from a microtask
  // job or from an async task's callback). Left pending for the caller.
  JSException,
  // The event loop was already running (e.g. a reentrant synchronous
  // dispatch call while another pump is in progress); pumping again would
  // corrupt the single shared task queue, so this is rejected outright.
  AlreadyRunning,
};

class EventLoop {
public:
  /**
   * Initialize the event loop
   */
  static void init(JSContext *cx);

  /**
   * Check if there are any pending tasks (io requests or timers) to process.
   */
  static bool has_pending_async_tasks();

  /**
   * Run the event loop until all interests are complete.
   * See run_event_loop in extension-api.h for the complete description.
   */
  static bool run_event_loop(api::Engine *engine, double total_compute);

  static void incr_event_loop_interest();
  static void decr_event_loop_interest();

  /**
   * Pump the microtask/job queue and the queued async task list (the same
   * machinery `run_event_loop` uses) until `promise` settles (fulfills or
   * rejects), driving nested awaits/microtask chains and any interleaved
   * timer/host-task callbacks along the way. Unlike `run_event_loop`, this
   * is keyed on one specific promise's state rather than the global
   * interest-count bookkeeping, so it composes safely with callers (e.g. a
   * synchronous WIT export bridge) that must not perturb interest counts
   * used elsewhere, and it cannot hang: if both the job queue and the async
   * task queue run dry while `promise` is still Pending, nothing left could
   * ever settle it, so this returns `NoProgress` instead of blocking
   * forever.
   */
  static PromisePumpResult pump_until_promise_settled(api::Engine *engine,
                                                      JS::HandleObject promise);

  /**
   * Select on the next async tasks
   */
  static bool process_async_tasks(api::Engine *engine, double timeout);

  /**
   * Queue a new async task.
   */
  static void queue_async_task(const RefPtr<api::AsyncTask>& task);

  /**
   * Remove a queued async task.
   */
  static bool cancel_async_task(api::Engine *engine, const RefPtr<api::AsyncTask>& task);
};

} // namespace core

#endif
