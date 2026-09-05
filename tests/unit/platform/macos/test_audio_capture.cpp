/**
 * @file tests/unit/platform/macos/test_audio_capture.cpp
 * @brief Tests for legacy macOS audio source compatibility.
 */
#include "../../../tests_common.h"
#include "src/platform/macos/audio_capture.h"

/**
 * @brief Accept legacy system source aliases regardless of ASCII case.
 */
TEST(MacosAudioCapture, SystemAliases) {
  for (const auto sink : {"", "system", "desktop", "screencapturekit", "SYSTEM", "Desktop", "ScreenCaptureKit"}) {
    EXPECT_TRUE(platf::macos::is_system_audio_sink(sink)) << sink;
  }
}

/**
 * @brief Preserve device names and reject partial or padded aliases.
 */
TEST(MacosAudioCapture, ExplicitDevices) {
  for (const auto sink : {"BlackHole 2ch", "MacBook Pro Microphone", "system ", " system", "systematic", "desktap", "screencapturekix", "SYSTEMX"}) {
    EXPECT_FALSE(platf::macos::is_system_audio_sink(sink)) << sink;
  }
}
