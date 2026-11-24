/**
 * @file src/platform/macos/smooth_scroll.mm
 * @brief High-resolution pixel scrolling using immediate native macOS events.
 */

#include "src/platform/macos/smooth_scroll.h"

#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach_time.h>
#include <array>
#include <string>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
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
    std::atomic<double> release_threshold_ms {32.0};

    /**
     * @brief One scroll sample used to estimate velocity over a short window.
     */
    struct scroll_sample_t {
      double dt;  ///< Seconds since the previous packet, zero for the first one.
      double dy;  ///< Vertical delta in pixels.
      double dx;  ///< Horizontal delta in pixels.
    };

    /**
     * @brief The most recent scroll samples, newest at the back.
     *
     * A fast flick arrives as 28-90px packets. Dividing one of those by its own 4-9ms gap reaches
     * 14000 pixels per second, and half of all packets pinned against the velocity ceiling as a
     * result. Averaging over roughly the last 80ms first keeps a single large packet from deciding
     * how the inertia starts.
     */
    std::deque<scroll_sample_t> scroll_samples;

    /**
     * @brief Sub-pixel remainders held back from the integer pixel field.
     *
     * The exact motion travels in the fixed-point fields, but applications that read only the
     * pixel field must still receive the whole distance, so whatever an event cannot report as a
     * whole pixel is carried into the next event on the same axis.
     */
    double point_carry_y = 0.0;
    double point_carry_x = 0.0;
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

      /**
       * @brief Interval histogram of inertia loop frames, in milliseconds.
       *
       * Buckets are <4, 4-8, 8-12, 12-16, 16-25, 25-33, 33-50, >50. Unlike ::output_interval_*,
       * these samples come from the inertia loop alone, so idle time between gestures cannot
       * stretch them and they show what the loop's pacing really is.
       */
      std::array<std::atomic<uint64_t>, 8> frame_buckets {};
      std::atomic<uint64_t> frame_samples {0};
      std::atomic<double> frame_max_ms {0.0};
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
      std::array<uint64_t, 8> frame_buckets {};
      for (std::size_t bucket = 0; bucket < frame_buckets.size(); ++bucket) {
        frame_buckets[bucket] = scroll_diagnostics.frame_buckets[bucket].exchange(0);
      }
      const auto frame_samples = scroll_diagnostics.frame_samples.exchange(0);
      const auto frame_max_ms = scroll_diagnostics.frame_max_ms.exchange(0.0);
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

      // Reported separately because a single line per second is what tells the loop's own pacing
      // apart from the rate of events, which idle time between gestures otherwise blends in.
      if (frame_samples > 0) {
        std::string frame_report = "macOS inertia frames [" + std::to_string(frame_samples) +
          " frames, ms <4/4-8/8-12/12-16/16-25/25-33/33-50/>50]:";
        for (const auto bucket: frame_buckets) {
          frame_report += " " + std::to_string(bucket);
        }
        frame_report += " max=" + std::to_string(static_cast<uint64_t>(frame_max_ms)) + "ms";
        BOOST_LOG(info) << frame_report;
      }
    }

    /**
     * @brief Split off the whole-pixel part of a delta for the integer pixel field.
     *
     * @param delta Fractional pixel delta reported by this event.
     * @param carry Remainder carried into the next event on the same axis.
     * @return Whole pixels to report in the pixel field.
     */
    int32_t pixel_point_delta(double delta, double &carry) {
      carry += delta;
      const auto integral = static_cast<int32_t>(std::trunc(carry));
      carry -= integral;
      return integral;
    }

    /**
     * @brief Post a synthetic scroll event to the macOS HID event stream.
     *
     * The exact delta, fraction included, travels in the fixed-point fields. Without them slow
     * motion degenerates into one whole pixel every few frames, because a whole pixel only
     * accumulates every 1/v seconds: at 25 pixels per second that is a 40ms step, which reads as
     * stuttering. The whole-pixel part stays in the pixel field for applications that ignore the
     * fixed-point fields, and nothing is lost there because the remainder is carried forward.
     *
     * These events deliberately carry no scroll or momentum phase. Tagging them was measured to
     * remove the inertia tail entirely: the events still reached the HID tap, and views scrolled
     * while the fields were left unset, but as soon as kCGScrollWheelEventScrollPhase and
     * kCGScrollWheelEventMomentumPhase were populated the applications stopped moving. Phases are
     * honoured for gestures the window server recognises on a multitouch device, which a posted
     * event is not, so claiming them makes applications discard the motion.
     *
     * @param delta_y Vertical delta in pixels, fraction included.
     * @param delta_x Horizontal delta in pixels, fraction included.
     */
    void post_event(double delta_y, double delta_x) {
      // Measured through CoreGraphics: an event built with one line reports point delta 10 and
      // fixed-point delta 1.0, and a pixel-unit event gets fixed = pixels / 10. The fixed-point
      // fields are therefore line-scaled, and writing raw pixels into them would scroll ten times
      // too far.
      constexpr double PIXELS_PER_LINE = 10.0;

      std::lock_guard<std::mutex> lock(event_mutex);
      const auto post_start = std::chrono::steady_clock::now();
      const auto point_y = pixel_point_delta(delta_y, point_carry_y);
      const auto point_x = pixel_point_delta(delta_x, point_carry_x);
      CGEventRef event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, point_y, point_x);
      if (!event) {
        return;
      }
      CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
      CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, delta_y / PIXELS_PER_LINE);
      CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, delta_x / PIXELS_PER_LINE);
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
        BOOST_LOG(info) << "macOS scroll trace: output"
                        << " dy=" << delta_y << " dx=" << delta_x;
      }
    }

    /**
     * @brief Convert a high-resolution wheel delta into pixels.
     *
     * @param distance High-resolution wheel distance.
     * @return Pixel delta including its fraction, which the event fixed-point fields carry.
     */
    double to_pixel_distance(int32_t distance) {
      constexpr double PIXELS_PER_TICK = 44.0;  // Slightly more sensitive than the default 40 pixels.
      return (static_cast<double>(distance) / 120.0) * PIXELS_PER_TICK;
    }

    /**
     * @brief Nanoseconds per mach absolute time tick on this host.
     *
     * Apple Silicon reports 1, which makes mach absolute time plain nanoseconds.
     */
    double mach_nanoseconds_per_tick() {
      static const mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t info {};
        mach_timebase_info(&info);
        return info.denom == 0 || info.numer == 0 ? mach_timebase_info_data_t { .numer = 1, .denom = 1 } : info;
      }();
      return static_cast<double>(timebase.numer) / static_cast<double>(timebase.denom);
    }

    /**
     * @brief Convert milliseconds to mach absolute time ticks.
     *
     * @param milliseconds Duration to convert.
     * @return The same duration in mach absolute time units.
     */
    uint64_t milliseconds_to_mach_ticks(double milliseconds) {
      return static_cast<uint64_t>(milliseconds * 1'000'000.0 / mach_nanoseconds_per_tick());
    }

    void scroll_inertia_loop() {
      constexpr auto FRAME_DURATION = std::chrono::milliseconds(8);
      constexpr double FRICTION_PER_SECOND = 5.5;
      constexpr double MIN_VELOCITY = 12.0;

      // Host-side fallback for clients that do not generate inertia themselves.
      pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

      if (scroll_diagnostics_enabled) {
        // One-off calibration of what this thread can actually achieve, taken at startup before
        // anything is streaming, so the number separates "this process cannot be woken on time"
        // from "the stream load is delaying us". An 8ms deadline was chosen because that is the
        // frame period the inertia loop asks for.
        std::array<double, 16> oversleep_ms {};
        auto deadline = mach_absolute_time() + milliseconds_to_mach_ticks(8.0);
        for (auto &sample: oversleep_ms) {
          mach_wait_until(deadline);
          const auto now = mach_absolute_time();
          sample = static_cast<double>(now - deadline) * mach_nanoseconds_per_tick() / 1'000'000.0;
          deadline = now + milliseconds_to_mach_ticks(8.0);
        }
        std::sort(oversleep_ms.begin(), oversleep_ms.end());
        BOOST_LOG(info) << "macOS inertia timer calibration [16 x 8ms mach_wait_until, this thread]"
                        << " median_oversleep=" << oversleep_ms[oversleep_ms.size() / 2]
                        << "ms p95=" << oversleep_ms[oversleep_ms.size() - 2]
                        << "ms max=" << oversleep_ms.back() << "ms";
      }
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

        // Mach absolute time rather than std::chrono, because the wait itself is a Mach timer
        // deadline. A relative nanosleep of 8ms measured a median of 10ms on this host with a p95
        // of 24ms, and std::this_thread::sleep_until reached an 8ms average only by posting the
        // missed frames back to back, which a scroll view collapses into a single jump.
        const auto frame_ticks = milliseconds_to_mach_ticks(static_cast<double>(FRAME_DURATION.count()));
        const auto nanoseconds_per_tick = mach_nanoseconds_per_tick();
        auto previous_ticks = mach_absolute_time();
        auto next_ticks = previous_ticks + frame_ticks;
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

          const auto now_ticks = mach_absolute_time();
          const auto elapsed = static_cast<double>(now_ticks - previous_ticks) * nanoseconds_per_tick / 1'000'000'000.0;
          previous_ticks = now_ticks;

          if (scroll_diagnostics_enabled) {
            const auto elapsed_ms = elapsed * 1000.0;
            constexpr std::array<double, 7> BUCKET_EDGES {{4.0, 8.0, 12.0, 16.0, 25.0, 33.0, 50.0}};
            std::size_t bucket = 0;
            while (bucket < BUCKET_EDGES.size() && elapsed_ms >= BUCKET_EDGES[bucket]) {
              ++bucket;
            }
            scroll_diagnostics.frame_buckets[bucket].fetch_add(1, std::memory_order_relaxed);
            scroll_diagnostics.frame_samples.fetch_add(1, std::memory_order_relaxed);
            auto previous_max = scroll_diagnostics.frame_max_ms.load(std::memory_order_relaxed);
            while (previous_max < elapsed_ms && !scroll_diagnostics.frame_max_ms.compare_exchange_weak(
                     previous_max, elapsed_ms, std::memory_order_relaxed)) {
            }
          }
          velocity_y *= std::exp(-FRICTION_PER_SECOND * elapsed);
          velocity_x *= std::exp(-FRICTION_PER_SECOND * elapsed);
          if (std::abs(velocity_y) < MIN_VELOCITY && std::abs(velocity_x) < MIN_VELOCITY) {
            break;
          }

          pending_y += velocity_y * elapsed;
          pending_x += velocity_x * elapsed;
          if (pending_y != 0.0 || pending_x != 0.0) {
            post_event(pending_y, pending_x);
          }
          pending_y = 0.0;
          pending_x = 0.0;
          mach_wait_until(next_ticks);
          next_ticks += frame_ticks;

          // Never try to make up missed frames by posting several events at once: a scroll view
          // receiving two events in the same millisecond renders one jump of their sum, which is
          // the stutter this loop exists to remove. Any lateness therefore re-anchors the schedule
          // and skips the missed frames, while the elapsed-based decay above keeps the distance.
          // Tolerating lateness of up to one frame instead still posted pairs of events with a 0ms
          // gap, which measured 11% of all intervals.
          if (const auto wake_ticks = mach_absolute_time(); next_ticks <= wake_ticks) {
            next_ticks = wake_ticks + frame_ticks;
          }
        }
      }
    }

    void post_pixel_scroll(double delta_y, double delta_x) {
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
        // The floor sets how long the picture holds still after a flick is released, because
        // nothing is injected while waiting to learn whether the gesture ended. Measured client
        // packet gaps sit at 8ms with almost nothing between 12ms and 33ms, so 32ms stays clear
        // of streaming jitter while cutting the frozen window from about 119ms to 42ms.
        release_threshold_ms.store(std::clamp(smoothed_cadence_ms * 2.2, 32.0, 100.0), std::memory_order_relaxed);
      }

      // A new gesture starts a fresh window; a gesture gap in the middle of a stream keeps it.
      if (!had_scroll || sample_dt <= 0.0 || sample_dt > 0.08) {
        scroll_samples.clear();
      }
      scroll_samples.push_back({sample_dt, delta_y, delta_x});
      // Short on purpose. An 80ms window swallows about nine packets and averages away the speed
      // the finger actually had at the end of the flick, which started the coast at half the
      // speed of the last packets — still a brake, just a smaller one.
      constexpr double VELOCITY_WINDOW_DT = 0.025;  // 25ms, two or three packets
      constexpr std::size_t MAX_SAMPLES = 4;
      double window_dt = 0.0;
      while (!scroll_samples.empty() &&
             (scroll_samples.size() > MAX_SAMPLES || window_dt + scroll_samples.front().dt > VELOCITY_WINDOW_DT)) {
        window_dt += scroll_samples.front().dt;
        scroll_samples.pop_front();
      }

      double window_dy = 0.0;
      double window_dx = 0.0;
      double window_total_dt = 0.0;
      for (const auto &sample: scroll_samples) {
        window_dy += sample.dy;
        window_dx += sample.dx;
        window_total_dt += sample.dt;
      }

      // The windowed velocity is fed back through the estimator as the distance this packet's gap
      // would imply, so direction reversals, gesture resets and clamping keep working unchanged.
      const auto window_velocity_y = window_total_dt > 0.0 ? window_dy / window_total_dt : 0.0;
      const auto window_velocity_x = window_total_dt > 0.0 ? window_dx / window_total_dt : 0.0;
      scroll_velocity_y = update_scroll_velocity(scroll_velocity_y, window_velocity_y * sample_dt, sample_dt, had_scroll);
      scroll_velocity_x = update_scroll_velocity(scroll_velocity_x, window_velocity_x * sample_dt, sample_dt, had_scroll);
      const auto velocity_y = scroll_velocity_y;
      const auto velocity_x = scroll_velocity_x;
      scroll_in_progress = true;
      last_input_time = now;

      lock.unlock();
      if (scroll_diagnostics_trace) {
        BOOST_LOG(info) << "macOS scroll trace: input"
                        << " dy=" << delta_y << " dx=" << delta_x
                        << " interval=" << sample_dt * 1000.0 << "ms"
                        << " velocity_y=" << velocity_y
                        << " velocity_x=" << velocity_x
                        << " mode=host_inertia";
      }
      post_event(delta_y, delta_x);
      if (!had_scroll) {
        scroll_cv.notify_one();
      }
    }
  }

  double update_scroll_velocity(
    double current_velocity,
    double delta_pixels,
    double sample_dt,
    bool had_scroll
  ) {
    constexpr double MIN_SAMPLE_DT = 0.008;  // 8ms floor prevents burst packets from inflating velocity.
    constexpr double NOMINAL_FIRST_SAMPLE_DT = 0.016;  // Conservative 60Hz baseline for the first sample.
    constexpr double MAX_GESTURE_GAP_DT = 0.08;  // Reset stale momentum after >80ms idle gap.
    constexpr double FIRST_SAMPLE_WEIGHT = 0.35;
    constexpr double ALPHA = 0.55;
    // Measured release speeds on a fast trackpad flick reach 14000 pixels per second, and half of
    // all packets exceeded the old 2800 ceiling, which started the coast at a third of the speed
    // the page already had. That brake at the moment of release was visible as a hitch.
    constexpr double MAX_VELOCITY = 14000.0;

    const bool fresh_gesture = !had_scroll || sample_dt <= 0.0 || sample_dt > MAX_GESTURE_GAP_DT;
    if (delta_pixels == 0.0) {
      return fresh_gesture ? 0.0 : current_velocity;
    }

    if (fresh_gesture) {
      const double initial_velocity = (delta_pixels / NOMINAL_FIRST_SAMPLE_DT) * FIRST_SAMPLE_WEIGHT;
      return std::clamp(initial_velocity, -MAX_VELOCITY, MAX_VELOCITY);
    }

    // Immediately cancel opposing momentum when the user reverses scroll direction.
    if ((current_velocity > 0.0 && delta_pixels < 0) || (current_velocity < 0.0 && delta_pixels > 0)) {
      current_velocity = 0.0;
    }

    const double effective_dt = std::max(sample_dt, MIN_SAMPLE_DT);
    const double instant_velocity = delta_pixels / effective_dt;
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
        scroll_samples.clear();
        point_carry_y = 0.0;
        point_carry_x = 0.0;
      }
      const auto *diagnostics_value = std::getenv("LUMEN_SCROLL_DIAGNOSTICS");
      const auto &diagnostics_mode = config::input.macos_smooth_scrolling_diagnostics;
      scroll_diagnostics_enabled = diagnostics_mode != "disabled" || diagnostics_value != nullptr;
      scroll_diagnostics_trace = diagnostics_mode == "trace" ||
                                 (diagnostics_value != nullptr && std::string_view {diagnostics_value} == "trace");
      last_diagnostics_report = std::chrono::steady_clock::now();
      input_cadence_ms.store(0.0, std::memory_order_relaxed);
      release_threshold_ms.store(45.0, std::memory_order_relaxed);
      last_input_time = {};
      last_output_time = {};
      scroll_thread_stop.store(false, std::memory_order_relaxed);
      scroll_inertia_thread = std::thread(scroll_inertia_loop);
      scroll_thread_initialized = true;

      if (scroll_diagnostics_enabled) {
        // Announcing the mode once per session keeps trace verification independent of scrolling.
        BOOST_LOG(info) << "macOS scroll diagnostics active: macos_smooth_scrolling_diagnostics=" << diagnostics_mode
                        << ", per-event trace=" << (scroll_diagnostics_trace ? "yes" : "no");
      }
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
      scroll_samples.clear();
      point_carry_y = 0.0;
      point_carry_x = 0.0;
    }
    scroll_thread_initialized = false;
  }

  void scroll(int high_res_distance) {
    const auto delta_pixels = to_pixel_distance(high_res_distance);

    // Protocol noise below a hundredth of a pixel is not worth an event.
    if (std::abs(delta_pixels) < 0.01) {
      return;
    }
    post_pixel_scroll(delta_pixels, 0.0);
  }

  void hscroll(int high_res_distance) {
    const auto delta_pixels = to_pixel_distance(high_res_distance);
    if (std::abs(delta_pixels) < 0.01) {
      return;
    }
    post_pixel_scroll(0.0, delta_pixels);
  }

}  // namespace platf::macos
