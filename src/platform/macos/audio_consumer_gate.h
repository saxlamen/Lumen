/**
 * @file src/platform/macos/audio_consumer_gate.h
 * @brief Realtime-safe handshake between audio producers and the audio capture consumer.
 *
 * The system tap IOProc and the AVFoundation capture delegate both write samples into a
 * TPCircularBuffer and then wake the consumer thread. Signalling unconditionally leaks one
 * semaphore token per producer call whenever the consumer is still draining the buffer from an
 * earlier callback, and the leaked tokens make `dispatch_semaphore_wait()` return immediately
 * with an empty buffer. On the critical-priority audio thread that turns into a busy spin, and
 * it also delays the point at which a real timeout can be detected.
 *
 * The gate keeps at most one token alive: a producer only signals when the consumer has declared
 * that it is about to park, and the consumer parks with the sequence documented on
 * audio_wait_for_data().
 */
#pragma once

// system includes
#include <atomic>
#include <chrono>
#include <dispatch/dispatch.h>

namespace platf {
  /**
   * @brief Outcome of a consumer wait on the audio ring buffer.
   */
  enum class audio_wait_e : int {
    data,  ///< Waited for a producer signal and data is available.
    immediate,  ///< Data was already available before waiting.
    spurious,  ///< A token was consumed but the buffer was still empty; callers may retry.
    timed_out  ///< No data became available within the timeout.
  };

  /**
   * @brief Wake the audio consumer after samples were produced into the ring buffer.
   *
   * Call this after the produce step. It consumes the consumer's parking request, so a producer
   * that runs while nobody is waiting leaves no token behind.
   *
   * @param semaphore Semaphore shared with the audio consumer.
   * @param consumer_waiting Parking request owned by the audio consumer.
   */
  inline void audio_data_ready(dispatch_semaphore_t semaphore, std::atomic<bool> &consumer_waiting) {
    if (consumer_waiting.exchange(false)) {
      dispatch_semaphore_signal(semaphore);
    }
  }

  /**
   * @brief Wake the audio consumer unconditionally.
   *
   * Only for teardown, where the consumer must leave its wait even though no samples will arrive.
   * The consumer drains stale tokens before parking, so an extra signal here cannot accumulate.
   *
   * @param semaphore Semaphore shared with the audio consumer.
   */
  inline void audio_consumer_wake(dispatch_semaphore_t semaphore) {
    dispatch_semaphore_signal(semaphore);
  }

  /**
   * @brief Park until audio samples are available.
   *
   * The order below is load bearing:
   * 1. Drain any stale token.
   * 2. Declare the parking request.
   * 3. Re-read the buffer, because samples may have been produced between the drain and the
   *    parking request, in which case no signal will ever arrive for them.
   * 4. Only then wait for a signal.
   *
   * Draining before the re-read is what makes this safe: a token that the drain consumed belongs
   * to data that the re-read then observes. The reverse order loses that token and waits for a
   * signal that has already been spent.
   *
   * @param semaphore Semaphore shared with the audio producers.
   * @param consumer_waiting Parking request owned by the audio consumer.
   * @param timeout How long to wait for a producer signal.
   * @param has_data Callable that returns true when the ring buffer holds readable samples.
   * @return One of platf::audio_wait_e describing why the wait ended.
   */
  template<class HasData>
  inline audio_wait_e audio_wait_for_data(dispatch_semaphore_t semaphore, std::atomic<bool> &consumer_waiting, std::chrono::milliseconds timeout, HasData &&has_data) {
    while (dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0) {
      // Drop tokens that were left by an unconditional signal
    }

    consumer_waiting.store(true);

    if (has_data()) {
      consumer_waiting.store(false);
      return audio_wait_e::immediate;
    }

    const bool signalled = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (std::int64_t) timeout.count() * 1000000LL)) == 0;

    consumer_waiting.store(false);

    if (has_data()) {
      return audio_wait_e::data;
    }

    return signalled ? audio_wait_e::spurious : audio_wait_e::timed_out;
  }
}  // namespace platf
