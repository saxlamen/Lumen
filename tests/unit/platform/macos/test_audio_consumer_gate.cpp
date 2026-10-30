/**
 * @file tests/unit/platform/macos/test_audio_consumer_gate.cpp
 * @brief Exercise the audio producer/consumer handshake in src/platform/macos/audio_consumer_gate.h.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/audio_consumer_gate.h"

  // standard includes
  #include <atomic>
  #include <chrono>
  #include <thread>

namespace {
  using namespace std::literals::chrono_literals;

  /**
   * @brief Fixture owning a fresh semaphore and parking request for one test.
   */
  class AudioConsumerGate: public ::testing::Test {
  protected:
    /**
     * @brief Create the synchronization objects shared by a producer and a consumer.
     */
    void SetUp() override {
      semaphore = dispatch_semaphore_create(0);
      ASSERT_NE(semaphore, nullptr);
    }

    /**
     * @brief Release the semaphore.
     */
    void TearDown() override {
      if (semaphore) {
        dispatch_release(semaphore);
        semaphore = nullptr;
      }
    }

    dispatch_semaphore_t semaphore {};  ///< Semaphore shared by the producer and the consumer.
    std::atomic<bool> waiting {false};  ///< Parking request owned by the consumer.
  };

  /**
   * @brief Report whether the ring buffer holds samples, backed by an atomic flag.
   *
   * @param has_samples Flag to read.
   * @return Callable for platf::audio_wait_for_data().
   */
  auto availability(const std::atomic<bool> &has_samples) {
    return [&has_samples]() {
      return has_samples.load();
    };
  }
}  // namespace

/**
 * @brief Producers that run while nobody is parked must leave no tokens behind.
 *
 * This is the busy-spin regression: an unconditionally signalled semaphore accumulates one token
 * per callback, and every later wait then returns immediately with an empty buffer, burning the
 * critical-priority audio thread.
 */
TEST_F(AudioConsumerGate, RepeatedProductionsDoNotAccumulateTokens) {
  std::atomic<bool> has_samples {false};

  for (auto i = 0; i < 500; ++i) {
    platf::audio_data_ready(semaphore, waiting);
  }

  const auto start = std::chrono::steady_clock::now();
  const auto result = platf::audio_wait_for_data(semaphore, waiting, 60ms, availability(has_samples));
  const auto elapsed = std::chrono::steady_clock::now() - start;

  EXPECT_EQ(result, platf::audio_wait_e::timed_out);
  EXPECT_GE(elapsed, 50ms);
  EXPECT_FALSE(waiting.load());
}

/**
 * @brief Samples already in the buffer are reported without waiting.
 */
TEST_F(AudioConsumerGate, ExistingDataReturnsImmediately) {
  std::atomic<bool> has_samples {true};

  const auto start = std::chrono::steady_clock::now();
  const auto result = platf::audio_wait_for_data(semaphore, waiting, 5s, availability(has_samples));
  const auto elapsed = std::chrono::steady_clock::now() - start;

  EXPECT_EQ(result, platf::audio_wait_e::immediate);
  EXPECT_LT(elapsed, 50ms);
  EXPECT_FALSE(waiting.load());
}

/**
 * @brief A consumer that parks is woken by the production that follows.
 *
 * The parking request is published before the buffer is re-read, so samples produced in between
 * are still observed by the consumer even though no signal is sent for them.
 */
TEST_F(AudioConsumerGate, ProductionWakesParkedConsumer) {
  std::atomic<bool> has_samples {false};
  platf::audio_wait_e result {platf::audio_wait_e::timed_out};

  std::thread consumer {[&]() {
    result = platf::audio_wait_for_data(semaphore, waiting, 2s, availability(has_samples));
  }};

  // Give the consumer time to drain, publish its parking request and re-read the buffer
  std::this_thread::sleep_for(50ms);
  EXPECT_TRUE(waiting.load());

  has_samples.store(true);
  platf::audio_data_ready(semaphore, waiting);

  consumer.join();

  EXPECT_EQ(result, platf::audio_wait_e::data);
  EXPECT_FALSE(waiting.load());
}

/**
 * @brief A token consumed by the drain must not hide the samples it belonged to.
 *
 * Draining stale tokens before re-reading the buffer is what keeps this correct. If the buffer
 * were read first and drained afterwards, the token for these samples would be discarded and the
 * consumer would block for the whole timeout on data that is already present.
 */
TEST_F(AudioConsumerGate, DrainedTokenStillRevealsItsSamples) {
  std::atomic<bool> has_samples {true};

  // A token left behind by an unconditional signal, e.g. the teardown wake
  platf::audio_consumer_wake(semaphore);

  const auto start = std::chrono::steady_clock::now();
  const auto result = platf::audio_wait_for_data(semaphore, waiting, 2s, availability(has_samples));
  const auto elapsed = std::chrono::steady_clock::now() - start;

  EXPECT_EQ(result, platf::audio_wait_e::immediate);
  EXPECT_LT(elapsed, 50ms);
  EXPECT_FALSE(waiting.load());
}

/**
 * @brief Teardown wakes a parked consumer even though no samples will ever arrive.
 */
TEST_F(AudioConsumerGate, TeardownWakeUnblocksConsumer) {
  std::atomic<bool> has_samples {false};
  platf::audio_wait_e result {platf::audio_wait_e::timed_out};

  std::thread consumer {[&]() {
    result = platf::audio_wait_for_data(semaphore, waiting, 2s, availability(has_samples));
  }};

  std::this_thread::sleep_for(50ms);
  platf::audio_consumer_wake(semaphore);

  consumer.join();

  EXPECT_EQ(result, platf::audio_wait_e::spurious);
  EXPECT_FALSE(waiting.load());
}
#endif
