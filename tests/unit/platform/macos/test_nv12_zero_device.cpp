/**
 * @file tests/unit/platform/macos/test_nv12_zero_device.cpp
 * @brief Regression checks for incomplete macOS capture frames.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/av_img_t.h"
  #include "src/platform/macos/nv12_zero_device.h"
extern "C" {
  #include <libavutil/frame.h>
}

/**
 * @brief Missing capture buffers are rejected before accessing the encoder frame.
 */
TEST(MacosNv12, RejectMissingCaptureBuffer) {
  platf::nv12_zero_device device;
  platf::av_img_t image;
  EXPECT_EQ(device.convert(image), -1);
}

/**
 * @brief A real pixel buffer is forwarded and a subsequent empty frame preserves it.
 */
TEST(MacosNv12, PreserveEncoderFrameOnMissingPixelBuffer) {
  CVPixelBufferRef pixels = nullptr;
  ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nullptr, &pixels), kCVReturnSuccess);
  CMVideoFormatDescriptionRef format = nullptr;
  ASSERT_EQ(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &format), noErr);
  CMSampleTimingInfo timing {CMTimeMake(1, 60), kCMTimeZero, kCMTimeInvalid};
  CMSampleBufferRef sample = nullptr;
  ASSERT_EQ(CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, format, &timing, &sample), noErr);
  {
    platf::av_img_t image;
    image.pixel_buffer = std::make_shared<platf::av_pixel_buf_t>(sample);
    platf::nv12_zero_device device;
    ASSERT_EQ(device.init(nullptr, platf::pix_fmt_e::nv12, [](void *, int, int) {
    },
                          [](void *, int) {
                          }),
              0);
    AVFrame *frame = av_frame_alloc();
    ASSERT_NE(frame, nullptr);
    ASSERT_EQ(device.set_frame(frame, nullptr), 0);
    ASSERT_EQ(device.convert(image), 0);
    auto *retained_buffer = frame->buf[0];
    ASSERT_NE(retained_buffer, nullptr);
    EXPECT_EQ(frame->data[3], reinterpret_cast<uint8_t *>(pixels));
    // Release the wrapper's lock before simulating a wrapper with no underlying image.
    CVPixelBufferUnlockBaseAddress(image.pixel_buffer->buf, kCVPixelBufferLock_ReadOnly);
    image.pixel_buffer->buf = nullptr;
    EXPECT_EQ(device.convert(image), -1);
    EXPECT_EQ(frame->buf[0], retained_buffer);
    EXPECT_EQ(frame->data[3], reinterpret_cast<uint8_t *>(pixels));
  }
  CFRelease(sample);
  CFRelease(format);
  CFRelease(pixels);
}
#endif
