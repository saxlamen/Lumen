/**
 * @file src/platform/macos/capture_guard.h
 * @brief Declarations for serializing macOS capture backend callbacks with the capture thread.
 */
#pragma once

// system includes
#include <atomic>
#include <memory>
#include <mutex>
#include <utility>

// local includes
#include "src/platform/common.h"

namespace platf {
  /**
   * @brief Serializes capture backend frame callbacks with the capture thread.
   *
   * macOS capture backends deliver frames on their own queue (ScreenCaptureKit's sample handler
   * queue or AVFoundation's video output queue), while the display capture loop polls for
   * shutdown on the capture thread. Both paths hand frames to, and take images from, the image
   * pool owned by `video::captureThread()`, which is only safe on a single thread. This guard
   * serializes those calls and lets the capture thread retire the callbacks without leaving a
   * running backend able to call into destroyed callbacks.
   */
  class capture_cb_guard_t {
  public:
    using push_cb_t = display_t::push_captured_image_cb_t;  ///< Callback that submits a captured frame.
    using pull_cb_t = display_t::pull_free_image_cb_t;  ///< Callback that retrieves a free image.

    /**
     * @brief Bind the guard to the capture thread's callbacks.
     *
     * @param push_cb Callback that submits a captured frame to the encoder sessions.
     * @param pull_cb Callback that retrieves a free image from the capture thread's pool.
     */
    capture_cb_guard_t(const push_cb_t &push_cb, const pull_cb_t &pull_cb);

    capture_cb_guard_t(const capture_cb_guard_t &) = delete;
    capture_cb_guard_t(capture_cb_guard_t &&) = delete;
    capture_cb_guard_t &operator=(const capture_cb_guard_t &) = delete;
    capture_cb_guard_t &operator=(capture_cb_guard_t &&) = delete;

    /**
     * @brief Request a free image from the capture thread's pool.
     *
     * @param img_out Receives the free image when one is available.
     * @return `false` when the guard is detached or the capture thread ended the session.
     */
    bool pull(std::shared_ptr<img_t> &img_out);

    /**
     * @brief Submit a captured image to the capture thread's encoder sessions.
     *
     * @param img Image to submit.
     * @param frame_captured `true` when a real frame was captured.
     * @return `false` when the guard is detached or the session ended.
     */
    bool push(std::shared_ptr<img_t> &&img, bool frame_captured);

    /**
     * @brief Detach the callbacks and wait for in-flight calls to complete.
     *
     * After this returns, later `pull()`/`push()` calls fail immediately without touching the
     * capture thread's callbacks, so the caller is free to destroy them.
     */
    void detach();

    /**
     * @brief Return the number of callbacks currently executing.
     *
     * @return The in-flight callback count.
     */
    [[nodiscard]] int in_flight_count() const;

  private:
    const push_cb_t &push_cb;  ///< Capture thread callback that submits frames.
    const pull_cb_t &pull_cb;  ///< Capture thread callback that retrieves images.

    std::mutex cb_mutex;  ///< Serializes the bound callbacks and the detached flag.
    std::atomic<int> in_flight {};  ///< Callbacks currently executing or entering.
    bool detached {};  ///< Set once the capture thread's callbacks must no longer be called.
  };
}  // namespace platf

#ifdef __OBJC__
  #import <Foundation/Foundation.h>

/**
 * @brief Reference counted handle for platf::capture_cb_guard_t usable from Objective-C blocks.
 *
 * Capture backend blocks outlive the display capture call when a backend is slow to stop, so the
 * guard is owned by an object retained by the block instead of by the capture thread's stack.
 */
@interface SunshineCaptureCallbackGuard: NSObject {
@public
  platf::capture_cb_guard_t *cb_guard;  ///< Guard owned by this object.
}

/**
 * @brief Create a guard bound to the capture thread's callbacks.
 *
 * @param push_cb Callback that submits a captured frame to the encoder sessions.
 * @param pull_cb Callback that retrieves a free image from the capture thread's pool.
 * @return An initialized guard, or `nil` on failure.
 */
- (instancetype)initWithPushCallback:(const platf::capture_cb_guard_t::push_cb_t &)push_cb
                        pullCallback:(const platf::capture_cb_guard_t::pull_cb_t &)pull_cb;

/**
 * @brief Request a free image from the capture thread's pool.
 *
 * @param img_out Receives the free image when one is available.
 * @return `NO` when the guard is detached or the capture thread ended the session.
 */
- (BOOL)pullImage:(std::shared_ptr<platf::img_t> *)img_out;

/**
 * @brief Submit a captured image to the capture thread's encoder sessions.
 *
 * @param img Image to submit; the pointee is moved out on success.
 * @param frame_captured `YES` when a real frame was captured.
 * @return `NO` when the guard is detached or the session ended.
 */
- (BOOL)pushImage:(std::shared_ptr<platf::img_t> *)img captured:(BOOL)frame_captured;

/**
 * @brief Detach the callbacks and wait for in-flight calls to complete.
 */
- (void)detach;
@end
#endif
