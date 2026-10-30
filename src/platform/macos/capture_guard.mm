/**
 * @file src/platform/macos/capture_guard.mm
 * @brief Definitions for serializing macOS capture backend callbacks with the capture thread.
 */
// system includes
#include <chrono>
#include <thread>

// local includes
#include "src/platform/macos/capture_guard.h"

namespace platf {
  capture_cb_guard_t::capture_cb_guard_t(const push_cb_t &push_cb, const pull_cb_t &pull_cb):
      push_cb {push_cb},
      pull_cb {pull_cb} {
  }

  bool capture_cb_guard_t::pull(std::shared_ptr<img_t> &img_out) {
    in_flight.fetch_add(1, std::memory_order_acq_rel);

    bool result = false;
    {
      std::lock_guard<std::mutex> lock {cb_mutex};
      if (!detached) {
        result = pull_cb(img_out);
      }
    }

    in_flight.fetch_sub(1, std::memory_order_acq_rel);
    return result;
  }

  bool capture_cb_guard_t::push(std::shared_ptr<img_t> &&img, bool frame_captured) {
    in_flight.fetch_add(1, std::memory_order_acq_rel);

    bool result = false;
    {
      std::lock_guard<std::mutex> lock {cb_mutex};
      if (!detached) {
        result = push_cb(std::move(img), frame_captured);
      }
    }

    in_flight.fetch_sub(1, std::memory_order_acq_rel);
    return result;
  }

  void capture_cb_guard_t::detach() {
    {
      std::lock_guard<std::mutex> lock {cb_mutex};
      detached = true;
    }

    // Wait without holding the mutex: an in-flight callback may still be inside the bound
    // callback, and a callback that has not started yet must be able to take the mutex to
    // observe the detached flag and leave.
    while (in_flight.load(std::memory_order_acquire) > 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds {1});
    }
  }

  int capture_cb_guard_t::in_flight_count() const {
    return in_flight.load(std::memory_order_acquire);
  }
}  // namespace platf

@implementation SunshineCaptureCallbackGuard

- (instancetype)initWithPushCallback:(const platf::capture_cb_guard_t::push_cb_t &)push_cb
                        pullCallback:(const platf::capture_cb_guard_t::pull_cb_t &)pull_cb {
  self = [super init];
  if (self != nil) {
    cb_guard = new platf::capture_cb_guard_t(push_cb, pull_cb);
  }
  return self;
}

- (void)dealloc {
  delete cb_guard;
  cb_guard = nullptr;

  [super dealloc];
}

- (BOOL)pullImage:(std::shared_ptr<platf::img_t> *)img_out {
  if (cb_guard == nullptr || img_out == nullptr) {
    return NO;
  }
  return cb_guard->pull(*img_out) ? YES : NO;
}

- (BOOL)pushImage:(std::shared_ptr<platf::img_t> *)img captured:(BOOL)frame_captured {
  if (cb_guard == nullptr || img == nullptr) {
    return NO;
  }
  return cb_guard->push(std::move(*img), frame_captured == YES) ? YES : NO;
}

- (void)detach {
  if (cb_guard != nullptr) {
    cb_guard->detach();
  }
}

@end
