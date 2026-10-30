/**
 * @file src/platform/macos/smooth_scroll.mm
 * @brief High-resolution pixel scrolling with native macOS momentum / inertia loop.
 */

#include "src/platform/macos/smooth_scroll.h"
#include "src/config.h"

#include <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <thread>

namespace platf::macos {

  namespace {
    std::chrono::steady_clock::time_point last_scroll_time {};
    bool scroll_in_progress = false;
    bool momentum_active = false;
    double scroll_velocity_y = 0.0;
    double scroll_velocity_x = 0.0;

    std::mutex scroll_mutex;
    std::condition_variable scroll_cv;
    std::atomic<bool> scroll_thread_stop {false};
    std::thread scroll_inertia_thread;

    void log_scroll_event(const char *type, int32_t raw_dist, int32_t delta_y, int32_t delta_x, int phase, int64_t dt_ms) {
      static std::ofstream log_file("/tmp/lumen_scroll.log", std::ios::app);
      if (log_file.is_open()) {
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::system_clock::now().time_since_epoch()
        ).count();
        log_file << ms << " [" << type << "] raw=" << raw_dist
                 << " dy=" << delta_y << " dx=" << delta_x
                 << " phase=" << phase << " dt=" << dt_ms << "ms" << std::endl;
      }
    }

    void scroll_inertia_loop() {
      constexpr auto FRAME_DURATION = std::chrono::milliseconds(8); // ~120fps matching iPad Pro display
      constexpr double FRICTION = 0.95; // smooth natural decay
      constexpr double MIN_VELOCITY = 0.5; // pixel stop threshold
      // If no packet arrives for 25ms (packet rate is ~8ms on iPad), user has released!
      constexpr auto RELEASE_THRESHOLD = std::chrono::milliseconds(25);

      while (!scroll_thread_stop.load(std::memory_order_relaxed)) {
        std::unique_lock<std::mutex> lock(scroll_mutex);

        // Wait until there is an active scroll or stop requested
        scroll_cv.wait_for(lock, std::chrono::milliseconds(15), [&] {
          return scroll_thread_stop.load(std::memory_order_relaxed) || scroll_in_progress;
        });

        if (scroll_thread_stop.load(std::memory_order_relaxed)) {
          break;
        }

        if (!scroll_in_progress) {
          continue;
        }

        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_scroll_time);

        // Still receiving touch packets from iPad within 25ms
        if (elapsed < RELEASE_THRESHOLD) {
          lock.unlock();
          std::this_thread::sleep_for(std::chrono::milliseconds(4));
          continue;
        }

        // User released fingers! Immediately take over momentum with zero freeze
        double vy = scroll_velocity_y;
        double vx = scroll_velocity_x;
        scroll_in_progress = false;

        // 1. Close touch gesture cleanly
        log_scroll_event("GESTURE_END", 0, 0, 0, kCGScrollPhaseEnded, elapsed.count());
        CGEventRef end_event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, 0, 0);
        CGEventSetIntegerValueField(end_event, kCGScrollWheelEventIsContinuous, 1);
        CGEventSetIntegerValueField(end_event, kCGScrollWheelEventScrollPhase, kCGScrollPhaseEnded);
        CGEventPost(kCGHIDEventTap, end_event);
        CFRelease(end_event);

        // 2. If release velocity is significant, seamlessly glide with momentum
        if (std::abs(vy) > 2.0 || std::abs(vx) > 2.0) {
          momentum_active = true;
          log_scroll_event("MOMENTUM_BEGIN", 0, (int32_t)vy, (int32_t)vx, 1, elapsed.count());

          CGEventRef m_begin = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, 0, 0);
          CGEventSetIntegerValueField(m_begin, kCGScrollWheelEventIsContinuous, 1);
          CGEventSetIntegerValueField(m_begin, kCGScrollWheelEventMomentumPhase, kCGMomentumScrollPhaseBegin);
          CGEventPost(kCGHIDEventTap, m_begin);
          CFRelease(m_begin);

          while (!scroll_thread_stop.load(std::memory_order_relaxed)) {
            // If user touches again, abort momentum immediately
            if (scroll_in_progress) {
              break;
            }

            vy *= FRICTION;
            vx *= FRICTION;

            if (std::abs(vy) < MIN_VELOCITY && std::abs(vx) < MIN_VELOCITY) {
              break;
            }

            int32_t step_y = static_cast<int32_t>(std::round(vy));
            int32_t step_x = static_cast<int32_t>(std::round(vx));

            if (step_y != 0 || step_x != 0) {
              CGEventRef m_event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, step_y, step_x);
              CGEventSetIntegerValueField(m_event, kCGScrollWheelEventIsContinuous, 1);
              CGEventSetIntegerValueField(m_event, kCGScrollWheelEventMomentumPhase, kCGMomentumScrollPhaseContinue);
              CGEventPost(kCGHIDEventTap, m_event);
              CFRelease(m_event);
            }

            lock.unlock();
            std::this_thread::sleep_for(FRAME_DURATION);
            lock.lock();
          }

          momentum_active = false;
          log_scroll_event("MOMENTUM_END", 0, 0, 0, 3, 0);

          CGEventRef m_end = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, 0, 0);
          CGEventSetIntegerValueField(m_end, kCGScrollWheelEventIsContinuous, 1);
          CGEventSetIntegerValueField(m_end, kCGScrollWheelEventMomentumPhase, kCGMomentumScrollPhaseEnd);
          CGEventPost(kCGHIDEventTap, m_end);
          CFRelease(m_end);
        }
      }
    }

    void post_pixel_scroll(int32_t raw_dist, int32_t delta_y, int32_t delta_x) {
      std::lock_guard<std::mutex> lock(scroll_mutex);
      auto now = std::chrono::steady_clock::now();
      int64_t dt_ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_scroll_time).count();

      // If momentum was running, user touch aborts it
      if (momentum_active) {
        momentum_active = false;
      }

      CGScrollPhase phase = scroll_in_progress ? kCGScrollPhaseChanged : kCGScrollPhaseBegan;
      scroll_in_progress = true;
      last_scroll_time = now;

      // Responsive velocity tracking (weighted towards latest release frames)
      constexpr double ALPHA = 0.7;
      scroll_velocity_y = (scroll_velocity_y * (1.0 - ALPHA)) + (delta_y * ALPHA);
      scroll_velocity_x = (scroll_velocity_x * (1.0 - ALPHA)) + (delta_x * ALPHA);

      log_scroll_event("SCROLL", raw_dist, delta_y, delta_x, phase, dt_ms);

      CGEventRef event = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, delta_y, delta_x);
      CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
      CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, phase);
      CGEventPost(kCGHIDEventTap, event);
      CFRelease(event);

      scroll_cv.notify_one();
    }
  }

  void init_smooth_scroll() {
    static std::once_flag init_flag;
    std::call_once(init_flag, []() {
      scroll_thread_stop.store(false, std::memory_order_relaxed);
      scroll_inertia_thread = std::thread(scroll_inertia_loop);
    });
  }

  void shutdown_smooth_scroll() {
    scroll_thread_stop.store(true, std::memory_order_relaxed);
    scroll_cv.notify_all();
    if (scroll_inertia_thread.joinable()) {
      scroll_inertia_thread.join();
    }
  }

  void scroll(int high_res_distance) {
    constexpr double PIXELS_PER_TICK = 40.0;
    double pixel_delta = (static_cast<double>(high_res_distance) / 120.0) * PIXELS_PER_TICK;
    int32_t delta_int = static_cast<int32_t>(std::round(pixel_delta));
    if (delta_int == 0 && high_res_distance != 0) {
      delta_int = high_res_distance > 0 ? 1 : -1;
    }
    post_pixel_scroll(high_res_distance, delta_int, 0);
  }

  void hscroll(int high_res_distance) {
    constexpr double PIXELS_PER_TICK = 40.0;
    double pixel_delta = (static_cast<double>(high_res_distance) / 120.0) * PIXELS_PER_TICK;
    int32_t delta_int = static_cast<int32_t>(std::round(pixel_delta));
    if (delta_int == 0 && high_res_distance != 0) {
      delta_int = high_res_distance > 0 ? 1 : -1;
    }
    post_pixel_scroll(high_res_distance, 0, delta_int);
  }

}  // namespace platf::macos
