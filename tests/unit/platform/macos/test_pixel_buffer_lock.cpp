/**
 * @file tests/unit/platform/macos/test_pixel_buffer_lock.cpp
 * @brief Checks and offline measurement for the lazy CVPixelBuffer lock in av_pixel_buf_t.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/av_img_t.h"

  // system includes
  #import <CoreMedia/CoreMedia.h>
  #import <CoreVideo/CoreVideo.h>

  // standard includes
  #include <algorithm>
  #include <chrono>
  #include <string>

namespace {
  /**
   * @brief Create an IOSurface-backed 1080p sample buffer, the way ScreenCaptureKit delivers them.
   *
   * @param format Pixel format of the pixel buffer inside the sample buffer.
   * @return A new sample buffer the caller must release, or null on failure.
   */
  CMSampleBufferRef make_sample_buffer(OSType format) {
    // An empty kCVPixelBufferIOSurfacePropertiesKey value asks for an IOSurface-backed buffer,
    // which is what ScreenCaptureKit delivers.
    auto *empty = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = {kCVPixelBufferIOSurfacePropertiesKey};
    const void *values[] = {empty};
    auto *attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CVPixelBufferRef pixels = nullptr;
    const auto created = CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, format, attributes, &pixels);

    CFRelease(attributes);
    CFRelease(empty);

    if (created != kCVReturnSuccess) {
      return nullptr;
    }

    CMVideoFormatDescriptionRef description = nullptr;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &description) != noErr) {
      CVPixelBufferRelease(pixels);
      return nullptr;
    }

    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    CMSampleBufferRef sampleBuffer = nullptr;
    const auto status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, true, nullptr, nullptr, description, &timing, &sampleBuffer);

    CFRelease(description);
    CVPixelBufferRelease(pixels);

    return status == noErr ? sampleBuffer : nullptr;
  }

  /**
   * @brief Time repeated av_pixel_buf_t lifetimes over the same sample buffer.
   *
   * @param sample Sample buffer to wrap.
   * @param iterations Number of construct/destruct cycles.
   * @param touch_base_address When true, ask for the base address, which takes and releases the lock.
   * @return Average nanoseconds per cycle.
   */
  double time_wraps(CMSampleBufferRef sample, int iterations, bool touch_base_address) {
    const auto start = std::chrono::steady_clock::now();

    for (auto i = 0; i < iterations; ++i) {
      platf::av_pixel_buf_t pixels {sample};
      if (touch_base_address) {
        volatile auto *address = pixels.data();
        (void) address;
      }
    }

    const auto elapsed = std::chrono::duration<double, std::nano> {std::chrono::steady_clock::now() - start}.count();
    return elapsed / iterations;
  }
}  // namespace

/**
 * @brief Wrapping a sample buffer no longer locks the IOSurface; asking for the address does.
 *
 * An IOSurface-backed buffer reports a null base address while it is unlocked, which makes the
 * lazy behaviour directly observable: the encode path that hands the buffer to VideoToolbox never
 * touches it, while the software path still gets a valid pointer.
 */
TEST(MacosPixelBufferLock, LockIsTakenOnlyOnDemand) {
  auto *sample = make_sample_buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  ASSERT_NE(sample, nullptr);

  {
    platf::av_pixel_buf_t pixels {sample};
    ASSERT_NE(pixels.buf, nullptr);

    EXPECT_EQ(CVPixelBufferGetBaseAddress(pixels.buf), nullptr) << "the wrapper must not lock on construction";

    auto *first = pixels.data();
    ASSERT_NE(first, nullptr);
    EXPECT_EQ(CVPixelBufferGetBaseAddress(pixels.buf), first);
    EXPECT_EQ(pixels.data(), first) << "a second call must reuse the same lock";
  }

  EXPECT_EQ(CVPixelBufferGetBaseAddress(sample ? CMSampleBufferGetImageBuffer(sample) : nullptr), nullptr) << "destruction must release the lock it took";

  CFRelease(sample);
}

/**
 * @brief Destroying a wrapper that never asked for the base address is safe.
 */
TEST(MacosPixelBufferLock, DestroyWithoutLockingIsSafe) {
  auto *sample = make_sample_buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  ASSERT_NE(sample, nullptr);

  {
    platf::av_pixel_buf_t pixels {sample};
    EXPECT_EQ(CVPixelBufferGetBaseAddress(pixels.buf), nullptr);
  }

  EXPECT_NE(CMSampleBufferGetImageBuffer(sample), nullptr);

  CFRelease(sample);
}

/**
 * @brief The zero copy handoff must not cost more than taking the CPU base address.
 *
 * This is the offline measurement behind the lazy lock: it isolates CVPixelBufferLockBaseAddress()
 * and UnlockBaseAddress() on a real IOSurface-backed 1080p buffer, which is what every captured
 * frame used to pay. Only the direction of the difference is asserted, so a slow machine cannot
 * make the check flaky.
 */
TEST(MacosPixelBufferLock, CpuAccessCostsNoLessThanZeroCopyHandoff) {
  constexpr int iterations = 20000;

  auto *sample = make_sample_buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  ASSERT_NE(sample, nullptr);

  double eager_ns {};
  double lazy_ns {};

  for (auto pass = 0; pass < 2; ++pass) {
    const auto eager = time_wraps(sample, iterations, true);
    const auto lazy = time_wraps(sample, iterations, false);

    eager_ns = pass == 0 ? eager : std::min(eager_ns, eager);
    lazy_ns = pass == 0 ? lazy : std::min(lazy_ns, lazy);
  }

  RecordProperty("zero_copy_ns_per_frame", std::to_string((int) lazy_ns));
  RecordProperty("cpu_access_ns_per_frame", std::to_string((int) eager_ns));
  RecordProperty("saving_ns_per_frame", std::to_string((int) (eager_ns - lazy_ns)));

  EXPECT_LE(lazy_ns, eager_ns);

  CFRelease(sample);
}
#endif
