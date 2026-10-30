/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */
// system includes
#include <cstring>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/capture_guard.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/nv12_zero_device.h"
#include "src/utility.h"
#import "src/platform/macos/sc_capture.h"

// Avoid conflict between AVFoundation and libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "src/video.h"
#undef AVMediaType

namespace fs = std::filesystem;

namespace platf {
  using namespace std::literals;

  /**
   * @brief Zero-fill every plane of a locked CoreVideo pixel buffer.
   *
   * @param buffer Pixel buffer that is already locked for writing.
   */
  static void zero_planes(CVPixelBufferRef buffer) {
    auto plane_count = CVPixelBufferGetPlaneCount(buffer);
    if (plane_count == 0) {
      auto size = (std::size_t) CVPixelBufferGetBytesPerRow(buffer) * (std::size_t) CVPixelBufferGetHeight(buffer);
      std::memset(CVPixelBufferGetBaseAddress(buffer), 0, size);
      return;
    }

    for (auto plane = 0u; plane < plane_count; ++plane) {
      auto size = (std::size_t) CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * (std::size_t) CVPixelBufferGetHeightOfPlane(buffer, plane);
      std::memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 0, size);
    }
  }

  /**
   * @brief Process a CMSampleBuffer frame into an img_t for the encoder pipeline.
   * Shared between AVFoundation and ScreenCaptureKit capture backends.
   */
  static bool process_frame(CMSampleBufferRef sampleBuffer, img_t *img) {
    // Check for valid pixel data before processing (SCK can deliver status frames without image content)
    CVPixelBufferRef pixBuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixBuf) {
      return false;
    }

    auto new_sample_buffer = std::make_shared<av_sample_buf_t>(sampleBuffer);
    auto new_pixel_buffer = std::make_shared<av_pixel_buf_t>(new_sample_buffer->buf);

    auto av_img = (av_img_t *) img;

    auto old_data_retainer = std::make_shared<temp_retain_av_img_t>(
      av_img->sample_buffer,
      av_img->pixel_buffer,
      img->data
    );

    av_img->sample_buffer = new_sample_buffer;
    av_img->pixel_buffer = new_pixel_buffer;
    img->data = new_pixel_buffer->data();

    fill_img_geometry(img, new_pixel_buffer->buf);

    old_data_retainer = nullptr;
    return true;
  }

  // ── AVFoundation capture backend (AVCaptureScreenInput) ──────────────

  struct av_display_t: public display_t {
    AVVideo *av_capture {};
    CGDirectDisplayID display_id {};

    ~av_display_t() override {
      [av_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      // AVFoundation delivers frames on its own output queue while the polling loop below runs on
      // the capture thread. Both paths touch the image pool owned by video::captureThread(), so
      // every callback goes through the guard to keep that pool single threaded. The guard is
      // owned by an object retained by the capture block, so a late frame cannot call into the
      // capture thread's callbacks after this function returns.
      auto guard = [[SunshineCaptureCallbackGuard alloc] initWithPushCallback:push_captured_image_cb pullCallback:pull_free_image_cb];
      auto guard_release = util::fail_guard([&guard]() {
        [guard detach];
        [guard release];
      });

      auto signal = [av_capture capture:^(CMSampleBufferRef sampleBuffer) {
        std::shared_ptr<img_t> img_out;
        if (![guard pullImage:&img_out]) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }
        if (!process_frame(sampleBuffer, img_out.get())) {
          return true;  // skip this frame but continue capturing
        }
        if (![guard pushImage:&img_out captured:YES]) {
          // got interrupt signal
          // returning false here stops capture backend
          return false;
        }
        return true;
      }];

      if (!signal) {
        BOOST_LOG(error) << "AVFoundation capture failed to start"sv;
        return capture_e::error;
      }

      // Poll with timeout instead of waiting forever, so the capture thread
      // can respond to session shutdown and not deadlock on teardown.
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) != 0) {
        std::shared_ptr<img_t> probe_img;
        if (![guard pullImage:&probe_img]) {
          // Session is shutting down. Signal the semaphore so we exit the wait.
          // Don't call stopCapture here — the callback will detect shutdown on its
          // next invocation and do a clean teardown. Force-stopping AVFoundation
          // corrupts capture state for this display, causing black frames on reconnect.
          dispatch_semaphore_signal(signal);
          break;
        }
      }
      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        av_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();
        device->init(static_cast<void *>(av_capture), pix_fmt, setResolution, setPixelFormat);
        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Create a synthetic dummy frame to avoid starting a capture session.
      // Starting and stopping AVFoundation capture for dummy_img can cause
      // timeouts on virtual displays and interfere with the main capture.
      int w = av_capture.frameWidth;
      int h = av_capture.frameHeight;

      // Match the pixel format the capture backend is configured for: a dummy frame in a fixed
      // format would be handed to a zero copy encoder that expects NV12/P010.
      CVPixelBufferRef pixelBuffer = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        av_capture.pixelFormat,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        BOOST_LOG(error) << "AVFoundation dummy_img: failed to create pixel buffer"sv;
        return 1;
      }

      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      zero_planes(pixelBuffer);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      auto av_img = (av_img_t *)img;
      CMVideoFormatDescriptionRef formatDesc = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

      CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;
      CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timing, &sampleBuffer);

      if (formatDesc) CFRelease(formatDesc);

      if (sampleBuffer) {
        auto new_sample = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel = std::make_shared<av_pixel_buf_t>(new_sample->buf);
        av_img->sample_buffer = new_sample;
        av_img->pixel_buffer = new_pixel;
        img->data = new_pixel->data();
        CFRelease(sampleBuffer);
      }

      // Read the geometry before dropping our reference to the pixel buffer
      fill_img_geometry(img, pixelBuffer);

      CVPixelBufferRelease(pixelBuffer);
      return 0;
    }

    /**
     * @brief Update the AVFoundation capture resolution.
     *
     * Called by nv12_zero_device on the encoder thread, so the backend stores the value under its
     * own lock.
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<AVVideo *>(display) setFrameWidth:width frameHeight:height];
    }

    /**
     * @brief Update the AVFoundation capture pixel format.
     *
     * Called by nv12_zero_device on the encoder thread.
     */
    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<AVVideo *>(display).pixelFormat = pixelFormat;
    }
  };

  // ── ScreenCaptureKit capture backend (macOS 12.3+) ──────────────────

  struct sc_display_t: public display_t {
    SCCapture *sc_capture {};
    CGDirectDisplayID display_id {};

    ~sc_display_t() override {
      [sc_capture stopCapture];
      [sc_capture release];
    }

    capture_e capture(const push_captured_image_cb_t &push_captured_image_cb, const pull_free_image_cb_t &pull_free_image_cb, bool *cursor) override {
      sc_capture.showsCursor = *cursor;

      // ScreenCaptureKit delivers frames on its sample handler queue while the polling loop below
      // runs on the capture thread. Both paths touch the image pool owned by
      // video::captureThread(), so every callback goes through the guard to keep that pool single
      // threaded. The guard is owned by an object retained by the capture block, so a frame that
      // arrives after this function returns cannot call into destroyed callbacks.
      auto guard = [[SunshineCaptureCallbackGuard alloc] initWithPushCallback:push_captured_image_cb pullCallback:pull_free_image_cb];
      auto guard_release = util::fail_guard([&guard]() {
        [guard detach];
        [guard release];
      });

      auto signal = [sc_capture captureVideo:^(CMSampleBufferRef sampleBuffer) {
        std::shared_ptr<img_t> img_out;
        if (![guard pullImage:&img_out]) {
          return false;
        }
        if (!process_frame(sampleBuffer, img_out.get())) {
          return true;  // skip this frame but continue capturing
        }
        if (![guard pushImage:&img_out captured:YES]) {
          return false;
        }
        return true;
      } audioCallback:nil];

      if (!signal) {
        BOOST_LOG(error) << "SCCapture failed to start video capture"sv;
        return capture_e::error;
      }

      // Poll with timeout instead of waiting forever, so the capture thread
      // can respond to session shutdown or cursor toggle without reconnecting.
      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        // If cursor toggle occurred, stop capture cleanly so video loop reinitializes with new setting
        if (sc_capture.showsCursor != *cursor) {
          [sc_capture stopCapture];
          return capture_e::reinit;
        }

        // Check if the session is ending - a detached guard or a stopped capture context makes
        // the guarded pull return NO. This is needed because SCCapture may not deliver frames on
        // an idle display, so the video callback never gets a chance to detect shutdown.
        std::shared_ptr<img_t> probe_img;
        if (![guard pullImage:&probe_img]) {
          [sc_capture stopCapture];
          break;
        }
      }

      // Always stop the stream before returning so that no new frame callback can be scheduled
      // once the capture thread's callbacks go out of scope. stopCapture is idempotent.
      [sc_capture stopCapture];
      return capture_e::ok;
    }

    std::shared_ptr<img_t> alloc_img() override {
      return std::make_shared<av_img_t>();
    }

    std::unique_ptr<avcodec_encode_device_t> make_avcodec_encode_device(pix_fmt_e pix_fmt) override {
      if (pix_fmt == pix_fmt_e::yuv420p) {
        sc_capture.pixelFormat = kCVPixelFormatType_32BGRA;
        return std::make_unique<avcodec_encode_device_t>();
      } else if (pix_fmt == pix_fmt_e::nv12 || pix_fmt == pix_fmt_e::p010) {
        auto device = std::make_unique<nv12_zero_device>();
        device->init(static_cast<void *>(sc_capture), pix_fmt, setResolution, setPixelFormat);
        return device;
      } else {
        BOOST_LOG(error) << "Unsupported Pixel Format."sv;
        return nullptr;
      }
    }

    int dummy_img(img_t *img) override {
      if (!platf::is_screen_capture_allowed()) {
        return 1;
      }

      // Create a synthetic dummy frame instead of starting a separate capture.
      // Starting and stopping a capture just for dummy_img causes SCK to
      // not deliver frames to the subsequent main capture stream.
      int w = sc_capture.frameWidth;
      int h = sc_capture.frameHeight;

      // Match the pixel format the capture backend is configured for: a dummy frame in a fixed
      // format would be handed to a zero copy encoder that expects NV12/P010.
      CVPixelBufferRef pixelBuffer = NULL;
      NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, w, h,
        sc_capture.pixelFormat,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

      if (status != kCVReturnSuccess || !pixelBuffer) {
        BOOST_LOG(error) << "SCCapture dummy_img: failed to create pixel buffer"sv;
        return 1;
      }

      // Fill with black
      CVPixelBufferLockBaseAddress(pixelBuffer, 0);
      zero_planes(pixelBuffer);
      CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

      auto av_img = (av_img_t *)img;
      // Wrap in a CMSampleBuffer for the av_img pipeline
      CMVideoFormatDescriptionRef formatDesc = NULL;
      CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);

      CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
      CMSampleBufferRef sampleBuffer = NULL;
      CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, formatDesc, &timing, &sampleBuffer);

      if (formatDesc) CFRelease(formatDesc);

      if (sampleBuffer) {
        auto new_sample = std::make_shared<av_sample_buf_t>(sampleBuffer);
        auto new_pixel = std::make_shared<av_pixel_buf_t>(new_sample->buf);
        av_img->sample_buffer = new_sample;
        av_img->pixel_buffer = new_pixel;
        img->data = new_pixel->data();
        CFRelease(sampleBuffer);
      }

      // Read the geometry before dropping our reference to the pixel buffer
      fill_img_geometry(img, pixelBuffer);

      CVPixelBufferRelease(pixelBuffer);
      return 0;
    }

    /**
     * @brief Update the ScreenCaptureKit capture resolution.
     *
     * Called by nv12_zero_device on the encoder thread, so the backend stores the value under its
     * own lock.
     */
    static void setResolution(void *display, int width, int height) {
      [static_cast<SCCapture *>(display) setFrameWidth:width frameHeight:height];
    }

    /**
     * @brief Update the ScreenCaptureKit capture pixel format.
     *
     * Called by nv12_zero_device on the encoder thread.
     */
    static void setPixelFormat(void *display, OSType pixelFormat) {
      static_cast<SCCapture *>(display).pixelFormat = pixelFormat;
    }
  };

  // ── Display factory ─────────────────────────────────────────────────

  std::shared_ptr<display_t> display(platf::mem_type_e hwdevice_type, const std::string &display_name, const video::config_t &config) {
    if (hwdevice_type != platf::mem_type_e::system && hwdevice_type != platf::mem_type_e::videotoolbox) {
      BOOST_LOG(error) << "Could not initialize display with the given hw device type."sv;
      return nullptr;
    }

    CGDirectDisplayID selected_display_id;

    // Check if a virtual display is active — use it preferentially
    auto vd_id = platf::virtual_display_get_id();
    if (vd_id != 0) {
      BOOST_LOG(info) << "Using virtual display (id: "sv << vd_id << ") for capture"sv;
      selected_display_id = (CGDirectDisplayID) vd_id;
    } else {
      // Default to main display
      selected_display_id = CGMainDisplayID();

      // Print all displays available with it's name and id
      auto display_array = [AVVideo displayNames];
      BOOST_LOG(info) << "Detecting displays"sv;
      for (NSDictionary *item in display_array) {
        NSNumber *display_id = item[@"id"];
        NSString *name = item[@"displayName"];
        BOOST_LOG(info) << "Detected display: "sv << name.UTF8String << " (id: "sv << [NSString stringWithFormat:@"%@", display_id].UTF8String << ") connected: true"sv;
        if (!display_name.empty() && std::atoi(display_name.c_str()) == [display_id unsignedIntValue]) {
          selected_display_id = [display_id unsignedIntValue];
        }
      }
    }
    BOOST_LOG(info) << "Configuring selected display ("sv << selected_display_id << ") to stream"sv;

    // ScreenCaptureKit capture backend — handles virtual display reconnection
    // reliably. AVFoundation's AVCaptureScreenInput stops delivering frames
    // when a virtual display is destroyed and recreated between sessions.
    if (@available(macOS 12.3, *)) {
      if ([SCCapture isAvailable]) {
        auto disp = std::make_shared<sc_display_t>();
        disp->display_id = selected_display_id;
        disp->sc_capture = [[SCCapture alloc] initWithDisplay:selected_display_id frameRate:config.framerate captureAudio:NO];

        if (!disp->sc_capture) {
          BOOST_LOG(error) << "SCCapture setup failed, trying AVFoundation..."sv;
        } else {
          disp->width = disp->sc_capture.frameWidth;
          disp->height = disp->sc_capture.frameHeight;
          disp->env_width = disp->width;
          disp->env_height = disp->height;
          return disp;
        }
      }
    }

    // Fallback: AVFoundation capture backend
    auto disp = std::make_shared<av_display_t>();
    disp->display_id = selected_display_id;
    disp->av_capture = [[AVVideo alloc] initWithDisplay:selected_display_id frameRate:config.framerate];

    if (!disp->av_capture) {
      BOOST_LOG(error) << "Video setup failed."sv;
      return nullptr;
    }

    disp->width = disp->av_capture.frameWidth;
    disp->height = disp->av_capture.frameHeight;
    disp->env_width = disp->width;
    disp->env_height = disp->height;

    return disp;
  }

  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    __block std::vector<std::string> display_names;

    auto display_array = [AVVideo displayNames];

    display_names.reserve([display_array count]);
    [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
      NSString *name = obj[@"name"];
      display_names.emplace_back(name.UTF8String);
    }];

    return display_names;
  }

  /**
   * @brief Returns if GPUs/drivers have changed since the last call to this function.
   * @return `true` if a change has occurred or if it is unknown whether a change occurred.
   */
  bool needs_encoder_reenumeration() {
    // We don't track GPU state, so we will always reenumerate. Fortunately, it is fast on macOS.
    return true;
  }
}  // namespace platf
