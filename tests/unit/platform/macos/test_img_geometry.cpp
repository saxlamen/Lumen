/**
 * @file tests/unit/platform/macos/test_img_geometry.cpp
 * @brief Regression checks for macOS image geometry helpers.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/av_img_t.h"

/**
 * @brief Pixel pitch is derived from the pixel format, not from a packed-pixel assumption.
 */
TEST(MacosImgGeometry, PixelPitchPerFormat) {
  EXPECT_EQ(platf::pixel_pitch_for_format(kCVPixelFormatType_32BGRA), 4);
  EXPECT_EQ(platf::pixel_pitch_for_format(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), 1);
  EXPECT_EQ(platf::pixel_pitch_for_format(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), 1);
  EXPECT_EQ(platf::pixel_pitch_for_format(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), 2);
  EXPECT_EQ(platf::pixel_pitch_for_format(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange), 2);
  EXPECT_EQ(platf::pixel_pitch_for_format(0), 4);
}

/**
 * @brief Planar buffers report the luma plane stride instead of a packed row length.
 */
TEST(MacosImgGeometry, PlanarRowPitchComesFromLumaPlane) {
  CVPixelBufferRef pixels = nullptr;
  ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nullptr, &pixels), kCVReturnSuccess);

  platf::img_t img;
  platf::fill_img_geometry(&img, pixels);

  EXPECT_EQ(img.width, 64);
  EXPECT_EQ(img.height, 32);
  EXPECT_EQ(img.row_pitch, (std::int32_t) CVPixelBufferGetBytesPerRowOfPlane(pixels, 0));
  EXPECT_EQ(img.pixel_pitch, 2);

  CVPixelBufferRelease(pixels);
}

/**
 * @brief Only formats that cannot go through VideoToolbox need a CPU base address.
 */
TEST(MacosImgGeometry, RequiresCpuCopyPerFormat) {
  // An empty kCVPixelBufferIOSurfacePropertiesKey value asks for an IOSurface-backed buffer,
  // which is what ScreenCaptureKit delivers.
  auto *empty = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const void *keys[] = {kCVPixelBufferIOSurfacePropertiesKey};
  const void *values[] = {empty};
  auto *iosurface = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

  for (const auto format : {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange}) {
    CVPixelBufferRef pixels = nullptr;
    ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, format, iosurface, &pixels), kCVReturnSuccess);
    EXPECT_FALSE(platf::requires_cpu_copy(pixels)) << "zero copy format " << (int) format;
    CVPixelBufferRelease(pixels);
  }

  for (const auto format : {kCVPixelFormatType_32BGRA, kCVPixelFormatType_24RGB}) {
    CVPixelBufferRef pixels = nullptr;
    ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, format, iosurface, &pixels), kCVReturnSuccess);
    EXPECT_TRUE(platf::requires_cpu_copy(pixels)) << "software format " << (int) format;
    CVPixelBufferRelease(pixels);
  }

  CFRelease(iosurface);
  CFRelease(empty);
}

/**
 * @brief A packed BGRA buffer keeps the geometry the software encode path expects.
 */
TEST(MacosImgGeometry, PackedGeometry) {
  CVPixelBufferRef pixels = nullptr;
  ASSERT_EQ(CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA, nullptr, &pixels), kCVReturnSuccess);

  platf::img_t img;
  platf::fill_img_geometry(&img, pixels);

  EXPECT_EQ(img.width, 16);
  EXPECT_EQ(img.height, 8);
  EXPECT_EQ(img.row_pitch, (std::int32_t) CVPixelBufferGetBytesPerRow(pixels));
  EXPECT_EQ(img.pixel_pitch, 4);

  CVPixelBufferRelease(pixels);
}
#endif
