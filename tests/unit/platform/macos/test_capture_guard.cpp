/**
 * @file tests/unit/platform/macos/test_capture_guard.cpp
 * @brief Regression checks for the macOS capture callback guard.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/capture_guard.h"

  #include <atomic>
  #include <chrono>
  #include <future>
  #include <memory>
  #include <thread>

namespace {
  /**
   * @brief Records callback entry so overlapping callbacks can be detected.
   */
  class callback_recorder_t {
  public:
    /**
     * @brief Called by every guarded callback while it holds the guard's serialization lock.
     */
    void enter() {
      if (in_callback.fetch_add(1) > 0) {
        overlaps.fetch_add(1);
      }
      calls.fetch_add(1);
      std::this_thread::sleep_for(std::chrono::milliseconds {10});
      in_callback.fetch_sub(1);
    }

    std::atomic<int> calls {0};  ///< Total callback invocations.
    std::atomic<int> overlaps {0};  ///< Invocations that observed another callback running.
    std::atomic<int> in_callback {0};  ///< Callbacks currently executing.
  };
}  // namespace

/**
 * @brief A detached guard never calls the capture thread's callbacks again.
 */
TEST(MacosCaptureGuard, DetachedGuardStopsInvokingCallbacks) {
  callback_recorder_t recorder;

  platf::capture_cb_guard_t::push_cb_t push = [&](std::shared_ptr<platf::img_t> &&img, bool) {
    recorder.enter();
    return true;
  };
  platf::capture_cb_guard_t::pull_cb_t pull = [&](std::shared_ptr<platf::img_t> &img_out) {
    recorder.enter();
    img_out = std::make_shared<platf::img_t>();
    return true;
  };

  platf::capture_cb_guard_t guard {push, pull};

  std::shared_ptr<platf::img_t> img;
  ASSERT_TRUE(guard.pull(img));
  ASSERT_NE(img, nullptr);
  ASSERT_TRUE(guard.push(std::move(img), true));
  ASSERT_EQ(recorder.calls.load(), 2);

  guard.detach();

  std::shared_ptr<platf::img_t> detached_img;
  EXPECT_FALSE(guard.pull(detached_img));
  EXPECT_EQ(detached_img, nullptr);
  EXPECT_FALSE(guard.push(std::make_shared<platf::img_t>(), true));

  // The bound callbacks must not have been touched after detach()
  EXPECT_EQ(recorder.calls.load(), 2);
  EXPECT_EQ(guard.in_flight_count(), 0);
}

/**
 * @brief Callbacks from the capture thread and the capture backend never overlap.
 */
TEST(MacosCaptureGuard, SerializesCallbacksAcrossThreads) {
  callback_recorder_t recorder;

  platf::capture_cb_guard_t::push_cb_t push = [&](std::shared_ptr<platf::img_t> &&img, bool) {
    recorder.enter();
    return true;
  };
  platf::capture_cb_guard_t::pull_cb_t pull = [&](std::shared_ptr<platf::img_t> &img_out) {
    recorder.enter();
    img_out = std::make_shared<platf::img_t>();
    return true;
  };

  platf::capture_cb_guard_t guard {push, pull};

  std::atomic<int> completed {0};
  auto worker = [&guard, &completed]() {
    for (auto i = 0; i < 4; ++i) {
      std::shared_ptr<platf::img_t> img;
      if (!guard.pull(img)) {
        return;
      }
      guard.push(std::move(img), true);
      completed.fetch_add(1);
    }
  };

  std::thread backend_thread(worker);
  worker();
  backend_thread.join();
  guard.detach();

  EXPECT_EQ(completed.load(), 8);
  EXPECT_EQ(recorder.calls.load(), 16);
  EXPECT_EQ(recorder.overlaps.load(), 0);
  EXPECT_EQ(guard.in_flight_count(), 0);
}

/**
 * @brief Detach() waits for a callback that is still running on the backend thread.
 */
TEST(MacosCaptureGuard, DetachWaitsForInFlightCallback) {
  std::atomic<int> pull_calls {0};
  std::atomic<bool> release_pull {false};
  std::atomic<bool> backend_finished {false};

  platf::capture_cb_guard_t::push_cb_t push = [&](std::shared_ptr<platf::img_t> &&img, bool) {
    return true;
  };
  platf::capture_cb_guard_t::pull_cb_t pull = [&](std::shared_ptr<platf::img_t> &img_out) {
    pull_calls.fetch_add(1);
    while (!release_pull.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds {1});
    }
    img_out = std::make_shared<platf::img_t>();
    return true;
  };

  platf::capture_cb_guard_t guard {push, pull};

  std::thread backend([&guard, &backend_finished]() {
    std::shared_ptr<platf::img_t> img;
    guard.pull(img);
    backend_finished.store(true);
  });

  while (pull_calls.load() == 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds {1});
  }

  // detach() must not return while the backend callback is still inside pull()
  auto detached = std::async(std::launch::async, [&guard]() {
    guard.detach();
    return true;
  });

  std::this_thread::sleep_for(std::chrono::milliseconds {5});
  EXPECT_EQ(guard.in_flight_count(), 1);
  EXPECT_FALSE(backend_finished.load());

  release_pull.store(true);
  EXPECT_TRUE(detached.get());
  backend.join();

  EXPECT_TRUE(backend_finished.load());
  EXPECT_EQ(guard.in_flight_count(), 0);
}
#endif
