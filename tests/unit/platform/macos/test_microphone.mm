/**
 * @file tests/unit/platform/macos/test_microphone.mm
 * @brief Exercise audio backend failover without requesting capture permissions.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/config.h"
  #include "src/platform/macos/av_audio.h"
  #include "src/platform/macos/sc_audio.h"

  #include <objc/runtime.h>

namespace {
  /**
   * @brief Fixture that intercepts backend startup while leaving real ownership cleanup active.
   */
  class MacosAudioFailover: public ::testing::Test {
  protected:
    static inline int tap_status = 0;  ///< Injected primary startup result.
    static inline int fallback_status = 0;  ///< Injected fallback startup result.
    static inline int tap_calls = 0;  ///< Number of primary startup attempts.
    static inline int fallback_calls = 0;  ///< Number of fallback startup attempts.
    std::string saved_sink;  ///< Configuration restored after the test.
    Method tap_method {};  ///< Primary startup method.
    Method fallback_method {};  ///< ScreenCaptureKit startup method.
    IMP original_tap {};  ///< Original primary implementation.
    IMP original_fallback {};  ///< Original fallback implementation.

    /**
     * @brief Return an injected primary result without starting capture.
     * @param object Capture object.
     * @param selector Invoked selector.
     * @param rate Requested sample rate.
     * @param frames Requested frame size.
     * @param channels Requested channels.
     * @return Injected startup status.
     */
    static int start_tap(id object, SEL selector, UInt32 rate, UInt32 frames, UInt8 channels) {
      ++tap_calls;
      EXPECT_EQ(rate, 48000u);
      EXPECT_EQ(frames, 240u);
      EXPECT_EQ(channels, 2);
      return tap_status;
    }

    /**
     * @brief Return an injected fallback result without starting capture.
     * @param object Capture object.
     * @param selector Invoked selector.
     * @param rate Requested sample rate.
     * @param channels Requested channels.
     * @return Injected startup status.
     */
    static int start_fallback(id object, SEL selector, UInt32 rate, UInt8 channels) {
      ++fallback_calls;
      EXPECT_EQ(rate, 48000u);
      EXPECT_EQ(channels, 2);
      return fallback_status;
    }

    /**
     * @brief Replace capture startup methods and save the existing audio configuration.
     */
    void SetUp() override {
      saved_sink = config::audio.sink;
      config::audio.sink = "ScreenCaptureKit";
      tap_status = fallback_status = tap_calls = fallback_calls = 0;
      tap_method = class_getInstanceMethod([AVAudio class], @selector(setupSystemTap:frameSize:channels:));
      fallback_method = class_getInstanceMethod([SCAudioCapture class], @selector(startCaptureWithSampleRate:channels:));
      ASSERT_NE(tap_method, nullptr);
      ASSERT_NE(fallback_method, nullptr);
      original_tap = method_setImplementation(tap_method, reinterpret_cast<IMP>(&start_tap));
      original_fallback = method_setImplementation(fallback_method, reinterpret_cast<IMP>(&start_fallback));
    }

    /**
     * @brief Restore capture methods and configuration even after a failed assertion.
     */
    void TearDown() override {
      if (original_tap) {
        method_setImplementation(tap_method, original_tap);
      }
      if (original_fallback) {
        method_setImplementation(fallback_method, original_fallback);
      }
      config::audio.sink = saved_sink;
    }

    /**
     * @brief Open a stereo stream using the real platform selection code.
     * @param host_audio Whether host playback is requested.
     * @return Selected capture stream, or null after both backends fail.
     */
    std::unique_ptr<platf::mic_t> open(bool host_audio = true) {
      auto control = platf::audio_control();
      return control->microphone(nullptr, 2, 48000, 240, false, host_audio);
    }
  };
}  // namespace

/**
 * @brief Legacy aliases use Core Audio first and never start the fallback on success.
 */
TEST_F(MacosAudioFailover, PrimarySuccess) {
  auto mic = open();
  ASSERT_NE(mic, nullptr);
  EXPECT_EQ(tap_calls, 1);
  EXPECT_EQ(fallback_calls, 0);
}

/**
 * @brief A primary failure selects ScreenCaptureKit successfully.
 */
TEST_F(MacosAudioFailover, FallbackSuccess) {
  tap_status = -1;
  auto mic = open();
  ASSERT_NE(mic, nullptr);
  EXPECT_EQ(tap_calls, 1);
  EXPECT_EQ(fallback_calls, 1);
}

/**
 * @brief Muting requested by a client does not discard a working fallback stream.
 */
TEST_F(MacosAudioFailover, FallbackWithHostMuted) {
  tap_status = -1;
  EXPECT_NE(open(false), nullptr);
  EXPECT_EQ(fallback_calls, 1);
}

/**
 * @brief Both backend startup failures return no stream.
 */
TEST_F(MacosAudioFailover, BothBackendsFail) {
  tap_status = fallback_status = -1;
  EXPECT_EQ(open(), nullptr);
  EXPECT_EQ(tap_calls, 1);
  EXPECT_EQ(fallback_calls, 1);
}
#endif
