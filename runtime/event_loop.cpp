#include "event_loop.h"

#include "host_api.h"
#include "js_dispatch.h"
#include "js/Promise.h"
#include "jsapi.h"
#include "jsfriendapi.h"

#include <iostream>
#include <print>
#include <vector>

struct TaskQueue {
  std::vector<RefPtr<api::AsyncTask>> tasks;
  int interest_cnt = 0;
  bool event_loop_running = false;

  void trace(JSTracer *trc) const {
    for (const auto &task : tasks) {
      task->trace(trc);
    }
  }
};

static PersistentRooted<TaskQueue> queue;

namespace core {

void EventLoop::queue_async_task(const RefPtr<api::AsyncTask>& task) {
  MOZ_ASSERT(task);
  queue.get().tasks.emplace_back(task);
}

bool EventLoop::cancel_async_task(api::Engine *engine, const RefPtr<api::AsyncTask>& task) {
  auto *const tasks = &queue.get().tasks;
  for (auto it = tasks->begin(); it != tasks->end(); ++it) {
    if (*it == task) {
      tasks->erase(it);
      task->cancel(engine);
      return true;
    }
  }
  return false;
}

bool EventLoop::has_pending_async_tasks() { return !queue.get().tasks.empty(); }

void EventLoop::incr_event_loop_interest() { queue.get().interest_cnt++; }

void EventLoop::decr_event_loop_interest() {
  MOZ_ASSERT(queue.get().interest_cnt > 0);
  queue.get().interest_cnt--;
}

inline bool interest_complete() { return queue.get().interest_cnt == 0; }

inline void exit_event_loop() { queue.get().event_loop_running = false; }

bool EventLoop::run_event_loop(api::Engine *engine, double total_compute) {
  if (queue.get().event_loop_running) {
    std::print(stderr, "cannot run event loop as it is already running");
    return false;
  }
  queue.get().event_loop_running = true;
  JSContext *cx = engine->cx();

  while (true) {
    // Run a microtask checkpoint
    js::RunJobs(cx);
    if (!starling::drain_resource_drops(engine)) {
      exit_event_loop();
      return false;
    }

    if (JS_IsExceptionPending(cx)) {
      exit_event_loop();
      return false;
    }
    // if there is no interest in the event loop at all, just run one tick
    if (interest_complete()) {
      exit_event_loop();
      return true;
    }

    auto *const tasks = &queue.get().tasks;
    size_t tasks_size = tasks->size();
    if (tasks_size == 0) {
      exit_event_loop();
      MOZ_ASSERT(!interest_complete());
      return false;
    }

    // Select the next task to run according to event-loop semantics of oldest-first.
    size_t task_idx = api::AsyncTask::select(*tasks);

    auto task = tasks->at(task_idx);
    tasks->erase(tasks->begin() + task_idx);
    bool success = task->run(engine);
    if (!starling::drain_resource_drops(engine) || !success) {
      exit_event_loop();
      return false;
    }
  }
}

PromisePumpResult EventLoop::pump_until_promise_settled(api::Engine *engine,
                                                        JS::HandleObject promise) {
  if (queue.get().event_loop_running) {
    std::print(stderr, "cannot pump the event loop for a Promise while it is already running "
                       "(reentrant synchronous dispatch)");
    return PromisePumpResult::AlreadyRunning;
  }
  queue.get().event_loop_running = true;
  JSContext *cx = engine->cx();

  PromisePumpResult result;
  while (true) {
    // Run a microtask checkpoint: this alone drains an arbitrary chain of
    // `.then`/`await` reactions and nested microtasks, so a purely
    // microtask-driven promise (including one that's already settled by the
    // time we get here) never needs to touch the async task queue below.
    js::RunJobs(cx);
    if (!starling::drain_resource_drops(engine)) {
      result = PromisePumpResult::JSException;
      break;
    }

    if (JS_IsExceptionPending(cx)) {
      result = PromisePumpResult::JSException;
      break;
    }
    if (JS::GetPromiseState(promise) != JS::PromiseState::Pending) {
      result = PromisePumpResult::Settled;
      break;
    }

    auto *const tasks = &queue.get().tasks;
    if (tasks->empty()) {
      // No queued timer/host-I/O task remains and the microtask queue is
      // empty, yet the promise is still pending: nothing left in this
      // engine could ever advance it further. Deterministic diagnostic
      // instead of hanging.
      result = PromisePumpResult::NoProgress;
      break;
    }

    // Select the next task to run according to event-loop semantics of
    // oldest-first, exactly like `run_event_loop` above.
    size_t task_idx = api::AsyncTask::select(*tasks);

    auto task = tasks->at(task_idx);
    tasks->erase(tasks->begin() + task_idx);
    bool success = task->run(engine);
    if (!starling::drain_resource_drops(engine) || !success) {
      result = PromisePumpResult::JSException;
      break;
    }
  }

  exit_event_loop();
  return result;
}

void EventLoop::init(JSContext *cx) { queue.init(cx); }

} // namespace core
