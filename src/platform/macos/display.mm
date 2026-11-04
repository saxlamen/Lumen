/**
 * @file src/platform/macos/display.mm
 * @brief Definitions for display capture on macOS.
 */
// system includes
#include <cmath>
#include <cstring>
#include <sys/sysctl.h>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/av_img_t.h"
#include "src/platform/macos/av_video.h"
#include "src/platform/macos/capture_guard.h"
#include "src/platform/macos/hdr_capture.h"
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

    // Measurement point for the capture backend queue: how long a composed frame waited before
    // this handler ran. This is the number the capture queue QoS class controls.
    const auto sample_time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_VALID(sample_time)) {
      const auto host_time = CMClockGetTime(CMClockGetHostTimeClock());
      const auto queued_ms = (CMTimeGetSeconds(host_time) - CMTimeGetSeconds(sample_time)) * 1000.0;
      if (queued_ms >= 0.0) {
        static logging::min_max_avg_periodic_logger<double> capture_queue_logger {debug, "Video: sample queue delivery", "ms"};
        capture_queue_logger.collect_and_log(queued_ms);
      }
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

    // The zero copy encode path reads the CVPixelBufferRef itself, so taking the CPU base address
    // here would lock the IOSurface on every captured frame for nothing.
    img->data = requires_cpu_copy(new_pixel_buffer->buf) ? new_pixel_buffer->data() : nullptr;

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
        img->data = requires_cpu_copy(new_pixel->buf) ? new_pixel->data() : nullptr;
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

  /**
   * @brief Look up how much EDR headroom the screen being captured can reach.
   *
   * macOS reports HDR capability per screen rather than per display mode, and there is no public API
   * that puts a display into HDR mode, so this is the only query available for deciding whether a
   * captured picture carries HDR. A screen that cannot do HDR at all reports 1.0, measured in
   * section 10.1 of `docs/macos_hdr.md`.
   *
   * @param display_id The CoreGraphics display being captured.
   * @return The AppKit screen's maximum potential EDR headroom, or 1.0 when the display has no screen.
   */
  static double display_potential_edr(CGDirectDisplayID display_id) {
    for (NSScreen *screen in [NSScreen screens]) {
      const NSNumber *screen_number = screen.deviceDescription[@"NSScreenNumber"];
      if (screen_number.unsignedIntValue == display_id) {
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
      }
    }

    BOOST_LOG(warning) << "Display "sv << display_id << " has no AppKit screen; assuming it cannot display HDR"sv;
    return 1.0;
  }

  /**
   * @brief Report whether the running system version exposes ScreenCaptureKit's HDR capture.
   *
   * Split out from `platform_supports_hdr_capture()` so that the `@available` block does not have to
   * wrap the CPU query.
   *
   * @return True on macOS 15 and newer.
   */
  static bool platform_supports_hdr_os() {
    if (@available(macOS 15.0, *)) {
      return true;
    }
    return false;
  }

  /**
   * @brief Report whether this machine can deliver an HDR ScreenCaptureKit capture.
   *
   * `SCStreamConfiguration.captureDynamicRange` appeared in macOS 15, and ScreenCaptureKit only offers
   * an HDR picture on Apple Silicon. Upstream PR 5817 checks the same two things, so a capture asked
   * for HDR on an Intel Mac or an older system silently stays SDR unless the platform is checked too.
   *
   * @return True when ScreenCaptureKit can be asked for an HDR picture.
   */
  static bool platform_supports_hdr_capture() {
    if (!platform_supports_hdr_os()) {
      return false;
    }

    // Apple reports this sysctl as set on Apple Silicon even when the process runs under Rosetta,
    // which is the case a plain __arm64__ test would get wrong.
    int arm64 {};
    size_t size = sizeof(arm64);
    if (sysctlbyname("hw.optional.arm64", &arm64, &size, nullptr, 0) != 0) {
      BOOST_LOG(warning) << "Could not read hw.optional.arm64; assuming this machine cannot capture HDR"sv;
      return false;
    }

    return arm64 != 0;
  }

  struct sc_display_t: public display_t {
    SCCapture *sc_capture {};  ///< ScreenCaptureKit capture object driving this display backend.
    CGDirectDisplayID display_id {};  ///< Output display being captured.

    /**
     * @brief True when the captured picture is an HDR one.
     *
     * Set once while the capture is configured, because the screen's capability and the configured
     * dynamic range are both settled there. See `is_hdr()`.
     */
    bool hdr_capture {};

    /**
     * @brief The captured screen's potential EDR headroom when the capture was configured.
     */
    double maximum_potential_edr {1.0};

    /**
     * @brief Report whether the captured picture carries HDR.
     *
     * macOS has no HDR display mode to query, so this is the decision taken when the capture was
     * configured: an HDR dynamic range was asked for, the machine can deliver one, the screen reports
     * EDR headroom above unity, and the client negotiated a 10 bit dynamic range. The last condition
     * is checked again by `colorspace_from_client_config()` before the stream is labelled HDR; it is
     * checked here because the captured pixels themselves would be wrong otherwise.
     *
     * @return True when captured frames are PQ-encoded Rec.2100 samples.
     */
    bool is_hdr() override {
      return hdr_capture;
    }

    /**
     * @brief Fill in the HDR10 metadata for a captured macOS screen.
     *
     * macOS publishes no mastering display or content light level metadata for a screen, measured in
     * section 10.2 of `docs/macos_hdr.md`, so the mastering block is written from the BT.2020
     * specification and the luminances come from `macos_hdr::mastering_defaults()`. Those luminances are
     * configuration options with an environment override on purpose: this host renders the picture with
     * its SDR white at 100 cd/m2, measured in section 10.3 of `docs/macos_hdr.md`, and the mastering
     * block is the only lever that can re-reference it without spending a GPU pass on tone mapping on the
     * zero-copy path. The default is derived from this screen's EDR headroom, so it needs no tuning on a
     * host whose display is not the one it was measured on.
     *
     * @param metadata The metadata to fill in, in the units `video.cpp` writes into the encoder.
     * @return True, because the synthesised values are always usable.
     */
    bool get_hdr_metadata(SS_HDR_METADATA &metadata) override {
      const auto defaults = macos_hdr::mastering_defaults(maximum_potential_edr, macos_hdr::mastering_config_t {
                                                                   .max_luminance_nits = config::video.vt.hdr_max_luminance_macos,
                                                                   .min_luminance_nits = config::video.vt.hdr_min_luminance_macos,
                                                                   .max_cll_nits = config::video.vt.hdr_max_cll_macos,
                                                                   .max_fall_nits = config::video.vt.hdr_max_fall_macos,
                                                                 });

      // Chromaticities travel as integers normalised to 50000, the peak luminance in nits and the
      // black luminance in ten-thousandths of a nit, which is what `video.cpp` turns back into the
      // rational values the encoder expects.
      macos_hdr::scale_chromaticity(macos_hdr::kBt2020RedX, macos_hdr::kBt2020RedY, metadata.displayPrimaries[0].x, metadata.displayPrimaries[0].y);
      macos_hdr::scale_chromaticity(macos_hdr::kBt2020GreenX, macos_hdr::kBt2020GreenY, metadata.displayPrimaries[1].x, metadata.displayPrimaries[1].y);
      macos_hdr::scale_chromaticity(macos_hdr::kBt2020BlueX, macos_hdr::kBt2020BlueY, metadata.displayPrimaries[2].x, metadata.displayPrimaries[2].y);
      macos_hdr::scale_chromaticity(macos_hdr::kWhitePointX, macos_hdr::kWhitePointY, metadata.whitePoint.x, metadata.whitePoint.y);

      metadata.maxDisplayLuminance = (std::uint16_t) std::llround(defaults.max_luminance_nits);
      metadata.minDisplayLuminance = (std::uint16_t) std::llround(defaults.min_luminance_nits * 10000.0);
      metadata.maxContentLightLevel = defaults.max_cll_nits;
      metadata.maxFrameAverageLightLevel = defaults.max_fall_nits;

      BOOST_LOG(info) << "Synthesised HDR10 metadata for a macOS screen: peak "sv << defaults.max_luminance_nits << " nits, black "sv << defaults.min_luminance_nits << " nits, maxCLL "sv << defaults.max_cll_nits << " nits, maxFALL "sv << defaults.max_fall_nits << " nits"sv;
      return true;
    }

    /**
     * @brief Spacing between reports of skipped idle ScreenCaptureKit deliveries.
     */
    static constexpr std::chrono::seconds idle_report_interval {20};

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
      std::uint64_t reported_idle_skips {};
      auto next_idle_report = std::chrono::steady_clock::now() + idle_report_interval;

      while (dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0) {
        // If cursor toggle occurred, stop capture cleanly so video loop reinitializes with new setting
        if (sc_capture.showsCursor != *cursor) {
          [sc_capture stopCapture];
          return capture_e::reinit;
        }

        // Report how many status deliveries were skipped, so the effect of not re-delivering the
        // cached frame is visible in the log instead of inferred from the client's frame rate.
        if (auto now = std::chrono::steady_clock::now(); now >= next_idle_report) {
          next_idle_report = now + idle_report_interval;
          const auto skipped = (std::uint64_t) [sc_capture idleSampleBuffersSkipped];
          if (skipped != reported_idle_skips) {
            BOOST_LOG(debug) << "Video: skipped "sv << (skipped - reported_idle_skips) << " idle sample buffers, "sv << skipped << " total"sv;
            reported_idle_skips = skipped;
          }
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
        img->data = requires_cpu_copy(new_pixel->buf) ? new_pixel->data() : nullptr;
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
          // macOS never switches a display into HDR mode, so the dynamic range has to be requested
          // from ScreenCaptureKit for every stream. The screen's capability and the machine's are
          // settled here, once, because the capture cannot change underneath a running encoder and
          // `is_hdr()` is what the encoder's colorspace decision reads.
          const auto requested_range = macos_hdr::dynamic_range_from_view(config::video.vt.capture_dynamic_range_macos);
          disp->maximum_potential_edr = display_potential_edr(selected_display_id);
          const bool platform_supports_hdr = platform_supports_hdr_capture();
          disp->hdr_capture = macos_hdr::hdr_capture_enabled(macos_hdr::hdr_capture_request_t {
            .range = requested_range,
            .maximum_potential_edr = disp->maximum_potential_edr,
            .platform_supports_hdr = platform_supports_hdr,
            .session_requests_10bit = config.dynamicRange > 0,
          });

          if (disp->hdr_capture) {
            // Raw SCCaptureDynamicRange values: 1 is the picture tuned to the host panel, 2 is the
            // canonical Rec.2100 one a remote client wants. The color space is not optional next to
            // the dynamic range, see sc_capture.h.
            disp->sc_capture.captureDynamicRange = requested_range == macos_hdr::capture_dynamic_range_e::hdr_canonical ? 2 : 1;
            disp->sc_capture.hdrColorSpaceName = (NSString *) kCGColorSpaceITUR_2100_PQ;

            BOOST_LOG(info) << "Capturing "sv << macos_hdr::to_string(requested_range) << " HDR from display "sv << selected_display_id << ", screen headroom "sv << disp->maximum_potential_edr << "x"sv;
          } else if (requested_range != macos_hdr::capture_dynamic_range_e::sdr) {
            BOOST_LOG(warning) << "capture_dynamic_range_macos = "sv << macos_hdr::to_string(requested_range) << " but capturing SDR: screen headroom "sv << disp->maximum_potential_edr << "x, this machine can capture HDR: "sv << (platform_supports_hdr ? "yes"sv : "no"sv) << ", the client negotiated 10 bit: "sv << (config.dynamicRange > 0 ? "yes"sv : "no"sv);
          }

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
