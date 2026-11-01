/**
 * @file src/platform/macos/smooth_scroll.mm
 * @brief High-resolution pixel scrolling using immediate native macOS events.
 */

#include "src/platform/macos/smooth_scroll.h"

#include <ApplicationServices/ApplicationServices.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <pthread.h>
#include <string_view>
#include <thread>

#include "src/logging.h"

namespace platf::macos {

  namespace {
    std::chrono::steady_clock::time_point last_input_time {};
    bool scroll_in_progress = false;
    double scroll_velocity_y = 0.0;
    double scroll_velocity_x = 0.0;
    double pixel_remainder_y = 0.0;
    double pixel_remainder_x = 0.0;

    std::mutex scroll_mutex;
    std::mutex event_mutex;
    std::mutex lifecycle_mutex;
    std::condition_variable scroll_cv;
    std::atomic<bool> scroll_thread_stop {false};
    std::thread scroll_inertia_thread;

    /**
     * @brief Smoothed interval between client scroll packets, in milliseconds.
     *
     * The client packet period is what decides how long the host must wait before it may
     * assume the user lifted their finger. It was measured at roughly 9ms for slow drags and
     * 25-33ms for fast flicks, so a single fixed threshold cannot serve both.
     */
    std::atomic<double> input_cadence_ms {0.0};

    /// Idle time after which host-side inertia takes over, derived from ::input_cadence_ms.
    std::atomic<double> release_threshold_ms {45.0};
    bool scroll_thread_initialized = false;

    /**
     * @brief Low-overhead counters used by the optional scroll diagnostics.
     */
    struct scroll_diagnostics_t {
      std::atomic<uint64_t> input_events {0};  ///< Number of received scroll events.
      std::atomic<uint64_t> output_events {0};  ///< Number of posted CGEvents.
      std::atomic<uint64_t> output_interval_samples {0};  ///< Number of measured output intervals.
      std::atomic<uint64_t> output_interval_total_us {0};  ///< Sum of measured output intervals.
      std::atomic<uint64_t> output_interval_max_us {0};  ///< Largest measured output interval.
      std::atomic<uint64_t> post_duration_samples {0};  ///< Number of measured CGEventPost calls.
      std::atomic<uint64_t> post_duration_total_us {0};  ///< Sum of CGEventPost durations.
      std::atomic<uint64_t> post_duration_max_us {0};  ///< Largest CGEventPost duration.
      std::atomic<uint64_t> interval_samples {0};  ///< Number of measured input intervals.
      std::atomic<uint64_t> interval_total_us {0};  ///< Sum of measured input intervals.
      std::atomic<uint64_t> interval_max_us {0};  ///< Largest measured input interval.
      std::atomic<uint64_t> momentum_started {0};  ///< Number of host-side inertia phases.
      std::atomic<uint64_t> momentum_cancelled {0};  ///< Number of interrupted inertia phases.
    } scroll_diagnostics;
    bool scroll_diagnostics_enabled = false;
    bool scroll_diagnostics_trace = false;
    std::chrono::steady_clock::time_point last_diagnostics_report {};
    std::chrono::steady_clock::time_point last_output_time {};

    /**
     * @brief Emit and reset the current one-second scroll diagnostic counters.
     *
     * @param now Current monotonic time.
     */
    void report_scroll_diagnostics(std::chrono::steady_clock::time_point now) {
      if (!scroll_diagnostics_enabled || now - last_diagnostics_report < std::chrono::seconds(1)) {
        return;
      }
      last_diagnostics_report = now;

      const auto input_events = scroll_diagnostics.input_events.exchange(0);
      const auto output_events = scroll_diagnostics.output_events.exchange(0);
      const auto output_interval_samples = scroll_diagnostics.output_interval_samples.exchange(0);
      const auto output_interval_total_us = scroll_diagnostics.output_interval_total_us.exchange(0);
      const auto output_interval_max_us = scroll_diagnostics.output_interval_max_us.exchange(0);
      const auto post_duration_samples = scroll_diagnostics.post_duration_samples.exchange(0);
      const auto post_duration_total_us = scroll_diagnostics.post_duration_total_us.exchange(0);
      const auto post_duration_max_us = scroll_diagnostics.post_duration_max_us.exchange(0);
      const auto interval_samples = scroll_diagnostics.interval_samples.exchange(0);
      const auto interval_total_us = scroll_diagnostics.interval_total_us.exchange(0);
      const auto interval_max_us = scroll_diagnostics.interval_max_us.exchange(0);
      const auto momentum_started = scroll_diagnostics.momentum_started.exchange(0);
      const auto momentum_cancelled = scroll_diagnostics.momentum_cancelled.exchange(0);
      const auto average_interval_ms = interval_samples == 0
        ? 0.0
        : static_cast<double>(interval_total_us) / interval_samples / 1000.0;
      const auto average_output_interval_ms = output_interval_samples == 0
        ? 0.0
        : static_cast<double>(output_interval_total_us) / output_interval_samples / 1000.0;
      const auto average_post_duration_ms = post_duration_samples == 0
        ? 0.0
        : static_cast<double>(post_duration_total_us) / post_duration_samples / 1000.0;

      BOOST_LOG(info) << "macOS scroll diagnostics: input=" << input_events
                      << " output=" << output_events
                      << " avg_input_interval=" << average_interval_ms << "ms"
                      << " max_input_interval=" << static_cast<double>(interval_max_us) / 1000.0 << "ms"
                      << " avg_output_interval=" << average_output_interval_ms << "ms"
                      << " max_output_interval=" << static_cast<double>(output_interval_max_us) / 1000.0 << "ms"
                      << " avg_post_duration=" << average_post_duration_ms << "ms"
                      << " max_post_duration=" << static_cast<double>(post_duration_max_us) / 1000.0 << "ms"
                      << " mode=host_inertia"
                      << " input_cadence_ms=" << input_cadence_ms.load(std::memory_order_relaxed)
                      << " release_threshold_ms=" << release_threshold_ms.load(std::memory_order_relaxed)
                      << " momentum_started=" << momentum_started
                      << " momentum_cancelled=" << momentum_cancelled;
    }

    /**
     * @brief Post a synthetic scroll event to the macOS HID event stream.
     *
     * @param phase Scroll phase to attach to the event.
     * @param momentum_phase Momentum phase to attach, or zero for a gesture event.
     * @param delta_y Vertical pixel delta.
     * @param delta_x Horizontal pixel delta.
     */
    void post_event(CGScrollPhase phase, CGMomentumScrollPhase momentum_phase, int32_t delta_y, int32_t delta_x) {
      std::lock_guard<std::mutex> lock(event_mutex);
      const auto post_start = std::chrono::steady_clock::now();
      CGEventRef event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, delta_y, delta_x);
      if (!event) {
        return;
      }
      CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
      if (momentum_phase != 0) {
        CGEventSetIntegerValueField(event, kCGScrollWheelEventMomentumPhase, momentum_phase);
      } else {
        CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, phase);
      }
      CGEventPost(kCGHIDEventTap, event);
      CFRelease(event);
      if (scroll_diagnostics_enabled) {
        const auto post_duration_us = static_cast<uint64_t>(
          std::chrono::duration<double>(std::chrono::steady_clock::now() - post_start).count() * 1'000'000.0
        );
        scroll_diagnostics.post_duration_samples.fetch_add(1, std::memory_order_relaxed);
        scroll_diagnostics.post_duration_total_us.fetch_add(post_duration_us, std::memory_order_relaxed);
        auto previous_post_max = scroll_diagnostics.post_duration_max_us.load(std::memory_order_relaxed);
        while (previous_post_max < post_duration_us && !scroll_diagnostics.post_duration_max_us.compare_exchange_weak(
                 previous_post_max, post_duration_us, std::memory_order_relaxed)) {
        }
        scroll_diagnostics.output_events.fetch_add(1, std::memory_order_relaxed);
        const auto now = std::chrono::steady_clock::now();
        if (last_output_time.time_since_epoch().count() != 0) {
          const auto interval_us = static_cast<uint64_t>(
            std::chrono::duration<double>(now - last_output_time).count() * 1'000'000.0
          );
          scroll_diagnostics.output_interval_samples.fetch_add(1, std::memory_order_relaxed);
          scroll_diagnostics.output_interval_total_us.fetch_add(interval_us, std::memory_order_relaxed);
          auto previous_max = scroll_diagnostics.output_interval_max_us.load(std::memory_order_relaxed);
          while (previous_max < interval_us && !scroll_diagnostics.output_interval_max_us.compare_exchange_weak(
                   previous_max, interval_us, std::memory_order_relaxed)) {
          }
        }
        last_output_time = now;
      }
      if (scroll_diagnostics_trace) {
        BOOST_LOG(info) << "macOS scroll trace: output phase=" << phase
                        << " momentum_phase=" << momentum_phase
                        << " dy=" << delta_y << " dx=" << delta_x;
      }
    }

    /**
     * @brief Convert a high-resolution wheel delta while retaining fractional pixels.
     *
     * @param distance High-resolution wheel distance.
     * @param remainder Fractional pixels retained between events.
     * @return Integral pixel delta suitable for CGEvent.
     */
    int32_t to_pixel_delta(int32_t distance, double &remainder) {
      constexpr double PIXELS_PER_TICK = 44.0;  // Slightly more sensitive than the default 40 pixels.
      remainder += (static_cast<double>(distance) / 120.0) * PIXELS_PER_TICK;
      const auto delta = static_cast<int32_t>(std::trunc(remainder));
      remainder -= delta;
      return delta;
    }

    void scroll_inertia_loop() {
      constexpr auto FRAME_DURATION = std::chrono::milliseconds(8);
      constexpr double FRICTION_PER_SECOND = 5.5;
      constexpr double MIN_VELOCITY = 12.0;

      // Host-side fallback for clients that do not generate inertia themselves.
      pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
      while (!scroll_thread_stop.load(std::memory_order_relaxed)) {
        report_scroll_diagnostics(std::chrono::steady_clock::now());

        // Derived from the measured client packet period: a gap must be about two packets wide
        // before it counts as a release, otherwise normal streaming jitter starts inertia.
        const auto release_threshold = std::chrono::milliseconds {
          static_cast<std::chrono::milliseconds::rep>(release_threshold_ms.load(std::memory_order_relaxed))
        };

        std::unique_lock<std::mutex> lock(scroll_mutex);
        if (!scroll_in_progress) {
          scroll_cv.wait_for(lock, release_threshold, [&] {
            return scroll_thread_stop.load(std::memory_order_relaxed) || scroll_in_progress;
          });
        } else {
          const auto release_deadline = last_input_time + release_threshold;
          if (std::chrono::steady_clock::now() < release_deadline) {
            scroll_cv.wait_until(lock, release_deadline, [&] {
              return scroll_thread_stop.load(std::memory_order_relaxed);
            });
          }
        }
        if (scroll_thread_stop.load(std::memory_order_relaxed)) {
          break;
        }
        if (!scroll_in_progress || std::chrono::steady_clock::now() - last_input_time < release_threshold) {
          continue;
        }

        auto velocity_y = scroll_velocity_y;
        auto velocity_x = scroll_velocity_x;
        scroll_in_progress = false;
        const bool start_momentum = std::abs(velocity_y) > MIN_VELOCITY || std::abs(velocity_x) > MIN_VELOCITY;
        lock.unlock();
        if (!start_momentum) {
          continue;
        }

        if (scroll_diagnostics_enabled) {
          scroll_diagnostics.momentum_started.fetch_add(1, std::memory_order_relaxed);
        }
        double pending_y = 0.0;
        double pending_x = 0.0;
        auto previous_frame = std::chrono::steady_clock::now();
        while (!scroll_thread_stop.load(std::memory_order_relaxed)) {
          lock.lock();
          const bool interrupted = scroll_in_progress;
          lock.unlock();
          if (interrupted) {
            if (scroll_diagnostics_enabled) {
              scroll_diagnostics.momentum_cancelled.fetch_add(1, std::memory_order_relaxed);
            }
            break;
          }

          const auto now = std::chrono::steady_clock::now();
          const auto elapsed = std::chrono::duration<double>(now - previous_frame).count();
          previous_frame = now;
          velocity_y *= std::exp(-FRICTION_PER_SECOND * elapsed);
          velocity_x *= std::exp(-FRICTION_PER_SECOND * elapsed);
          if (std::abs(velocity_y) < MIN_VELOCITY && std::abs(velocity_x) < MIN_VELOCITY) {
            break;
          }

          pending_y += velocity_y * elapsed;
          pending_x += velocity_x * elapsed;
          const auto step_y = static_cast<int32_t>(std::trunc(pending_y));
          const auto step_x = static_cast<int32_t>(std::trunc(pending_x));
          pending_y -= step_y;
          pending_x -= step_x;
          if (step_y != 0 || step_x != 0) {
            post_event(static_cast<CGScrollPhase>(0), static_cast<CGMomentumScrollPhase>(0), step_y, step_x);
          }
          std::this_thread::sleep_for(FRAME_DURATION);
        }
      }
    }

    void post_pixel_scroll(int32_t delta_y, int32_t delta_x) {
      std::unique_lock<std::mutex> lock(scroll_mutex);
      const auto now = std::chrono::steady_clock::now();
      const bool has_previous_input = last_input_time.time_since_epoch().count() != 0;
      const auto sample_dt = has_previous_input
        ? std::chrono::duration<double>(now - last_input_time).count()
        : 0.0;
      const bool had_scroll = scroll_in_progress;

      if (scroll_diagnostics_enabled) {
        scroll_diagnostics.input_events.fetch_add(1, std::memory_order_relaxed);
        if (has_previous_input && sample_dt > 0.0) {
          const auto interval_us = static_cast<uint64_t>(sample_dt * 1'000'000.0);
          scroll_diagnostics.interval_samples.fetch_add(1, std::memory_order_relaxed);
          scroll_diagnostics.interval_total_us.fetch_add(interval_us, std::memory_order_relaxed);
          auto previous_max = scroll_diagnostics.interval_max_us.load(std::memory_order_relaxed);
          while (previous_max < interval_us && !scroll_diagnostics.interval_max_us.compare_exchange_weak(
                   previous_max, interval_us, std::memory_order_relaxed)) {
          }
        }
      }

      // Keep idle time between independent gestures out of output-jitter metrics.
      if (!has_previous_input || sample_dt > 0.1) {
        std::lock_guard<std::mutex> event_lock(event_mutex);
        last_output_time = {};
      }
      // Learn how fast the client is delivering packets. Gaps wider than 100ms are treated as
      // the end of a gesture and are left out, so idle time between gestures cannot stretch the
      // threshold and delay the start of inertia.
      if (sample_dt > 0.001 && sample_dt < 0.1) {
        const auto sample_ms = sample_dt * 1000.0;
        const auto previous_cadence_ms = input_cadence_ms.load(std::memory_order_relaxed);
        const auto smoothed_cadence_ms = previous_cadence_ms == 0.0 ? sample_ms : previous_cadence_ms * 0.75 + sample_ms * 0.25;
        input_cadence_ms.store(smoothed_cadence_ms, std::memory_order_relaxed);
        release_threshold_ms.store(std::clamp(smoothed_cadence_ms * 2.2, 45.0, 100.0), std::memory_order_relaxed);
      }

      scroll_velocity_y = update_scroll_velocity(scroll_velocity_y, delta_y, sample_dt, had_scroll);
      scroll_velocity_x = update_scroll_velocity(scroll_velocity_x, delta_x, sample_dt, had_scroll);
      const auto velocity_y = scroll_velocity_y;
      const auto velocity_x = scroll_velocity_x;
      scroll_in_progress = true;
      last_input_time = now;

      lock.unlock();
      if (scroll_diagnostics_trace) {
        BOOST_LOG(info) << "macOS scroll trace: input phase=none"
                        << " dy=" << delta_y << " dx=" << delta_x
                        << " interval=" << sample_dt * 1000.0 << "ms"
                        << " velocity_y=" << velocity_y
                        << " velocity_x=" << velocity_x
                        << " mode=host_inertia";
      }
      post_event(static_cast<CGScrollPhase>(0), static_cast<CGMomentumScrollPhase>(0), delta_y, delta_x);
      if (!had_scroll) {
        scroll_cv.notify_one();
      }
    }
  }

  double update_scroll_velocity(
    double current_velocity,
    int32_t delta_pixels,
    double sample_dt,
    bool had_scroll
  ) {
    constexpr double MIN_SAMPLE_DT = 0.008;  // 8ms floor prevents burst packets from inflating velocity.
    constexpr double NOMINAL_FIRST_SAMPLE_DT = 0.016;  // Conservative 60Hz baseline for the first sample.
    constexpr double MAX_GESTURE_GAP_DT = 0.08;  // Reset stale momentum after >80ms idle gap.
    constexpr double FIRST_SAMPLE_WEIGHT = 0.35;
    constexpr double ALPHA = 0.55;
    constexpr double MAX_VELOCITY = 2800.0;

    const bool fresh_gesture = !had_scroll || sample_dt <= 0.0 || sample_dt > MAX_GESTURE_GAP_DT;
    if (delta_pixels == 0) {
      return fresh_gesture ? 0.0 : current_velocity;
    }

    if (fresh_gesture) {
      const double initial_velocity = (static_cast<double>(delta_pixels) / NOMINAL_FIRST_SAMPLE_DT) * FIRST_SAMPLE_WEIGHT;
      return std::clamp(initial_velocity, -MAX_VELOCITY, MAX_VELOCITY);
    }

    // Immediately cancel opposing momentum when the user reverses scroll direction.
    if ((current_velocity > 0.0 && delta_pixels < 0) || (current_velocity < 0.0 && delta_pixels > 0)) {
      current_velocity = 0.0;
    }

    const double effective_dt = std::max(sample_dt, MIN_SAMPLE_DT);
    const double instant_velocity = static_cast<double>(delta_pixels) / effective_dt;
    // Scale down the blend factor for sub-frame packet bursts so coalesced network packets
    // cannot ratchet velocity up to the ceiling in a single millisecond.
    const double burst_scale = std::min(1.0, sample_dt / MIN_SAMPLE_DT);
    const double weight = ALPHA * burst_scale;
    const double blended = (current_velocity * (1.0 - weight)) + (instant_velocity * weight);
    return std::clamp(blended, -MAX_VELOCITY, MAX_VELOCITY);
  }

  void init_smooth_scroll() {
    std::lock_guard<std::mutex> lock(lifecycle_mutex);
    if (!scroll_thread_initialized) {
      {
        std::lock_guard<std::mutex> state_lock(scroll_mutex);
        scroll_in_progress = false;
        scroll_velocity_y = 0.0;
        scroll_velocity_x = 0.0;
        pixel_remainder_y = 0.0;
        pixel_remainder_x = 0.0;
      }
      const auto *diagnostics_value = std::getenv("LUMEN_SCROLL_DIAGNOSTICS");
      scroll_diagnostics_enabled = config::input.macos_smooth_scrolling_diagnostics || diagnostics_value != nullptr;
      scroll_diagnostics_trace = diagnostics_value != nullptr && std::string_view {diagnostics_value} == "trace";
      last_diagnostics_report = std::chrono::steady_clock::now();
      input_cadence_ms.store(0.0, std::memory_order_relaxed);
      release_threshold_ms.store(45.0, std::memory_order_relaxed);
      last_input_time = {};
      last_output_time = {};
      scroll_thread_stop.store(false, std::memory_order_relaxed);
      scroll_inertia_thread = std::thread(scroll_inertia_loop);
      scroll_thread_initialized = true;
    }
  }

  void shutdown_smooth_scroll() {
    std::lock_guard<std::mutex> lock(lifecycle_mutex);
    if (!scroll_thread_initialized) {
      return;
    }
    scroll_thread_stop.store(true, std::memory_order_relaxed);
    scroll_cv.notify_all();
    if (scroll_inertia_thread.joinable()) {
      scroll_inertia_thread.join();
    }
    {
      std::lock_guard<std::mutex> state_lock(scroll_mutex);
      scroll_in_progress = false;
      scroll_velocity_y = 0.0;
      scroll_velocity_x = 0.0;
      pixel_remainder_y = 0.0;
      pixel_remainder_x = 0.0;
    }
    scroll_thread_initialized = false;
  }

  void scroll(int high_res_distance) {
    int32_t delta_int;
    {
      std::lock_guard<std::mutex> lock(scroll_mutex);
      if (!scroll_in_progress) {
        pixel_remainder_y = 0.0;
      }
      delta_int = to_pixel_delta(high_res_distance, pixel_remainder_y);
    }
    if (delta_int == 0) {
      return;
    }
    post_pixel_scroll(delta_int, 0);
  }

  void hscroll(int high_res_distance) {
    int32_t delta_int;
    {
      std::lock_guard<std::mutex> lock(scroll_mutex);
      if (!scroll_in_progress) {
        pixel_remainder_x = 0.0;
      }
      delta_int = to_pixel_delta(high_res_distance, pixel_remainder_x);
    }
    if (delta_int == 0) {
      return;
    }
    post_pixel_scroll(0, delta_int);
  }

}  // namespace platf::macos
