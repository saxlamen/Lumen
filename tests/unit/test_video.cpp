/**
 * @file tests/unit/test_video.cpp
 * @brief Test src/video.*.
 */
// test includes
#include "../tests_common.h"

// standard includes
#include <algorithm>
#include <array>
#include <chrono>
#include <limits>
#include <optional>
#include <tuple>
#include <utility>
#include <vector>

// ffmpeg includes
extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

// local includes
#include <src/config.h>
#include <src/video.h>

using namespace std::literals;

struct EncoderTest: PlatformTestSuite, testing::WithParamInterface<video::encoder_t *> {
  void SetUp() override {
    BaseTest::SetUp();
    auto &encoder = *GetParam();
    if (!video::validate_encoder(encoder, false)) {
      // Encoder failed validation,
      // if it's software - fail, otherwise skip
      if (encoder.name == "software") {
        FAIL() << "Software encoder not available";
      } else {
        GTEST_SKIP() << "Encoder not available";
      }
    }
  }
};

INSTANTIATE_TEST_SUITE_P(
  EncoderVariants,
  EncoderTest,
  testing::Values(
#if !defined(__APPLE__)
    &video::nvenc,
#endif
#ifdef _WIN32
    &video::amdvce,
    &video::quicksync,
#endif
#if defined(__linux__) || defined(__FreeBSD__)
    &video::vaapi,
#endif
#ifdef __APPLE__
    &video::videotoolbox,
#endif
    &video::software
  ),
  [](const auto &info) {
    return std::string(info.param->name);
  }
);

#if !defined(_WIN32) && !defined(__APPLE__)
TEST(NvencAvcodecOptionsTest, UsesVersionStablePresetAndSpatialAqNames) {
  const std::array codecs {
    &video::nvenc.av1,
    &video::nvenc.hevc,
    &video::nvenc.h264,
  };

  for (const auto *codec : codecs) {
    const auto preset = std::ranges::find(codec->common_options, "preset"sv, &video::encoder_t::option_t::name);
    ASSERT_NE(codec->common_options.end(), preset);
    ASSERT_TRUE(std::holds_alternative<std::string *>(preset->value));
    EXPECT_EQ(&config::video.nv_legacy.preset, std::get<std::string *>(preset->value));

    const auto spatial_aq = std::ranges::find(codec->common_options, "spatial-aq"sv, &video::encoder_t::option_t::name);
    ASSERT_NE(codec->common_options.end(), spatial_aq);
    ASSERT_TRUE(std::holds_alternative<int *>(spatial_aq->value));
    EXPECT_EQ(&config::video.nv_legacy.spatial_aq, std::get<int *>(spatial_aq->value));

    EXPECT_EQ(
      codec->common_options.end(),
      std::ranges::find(codec->common_options, "aq"sv, &video::encoder_t::option_t::name)
    );
  }
}
#endif

TEST_P(EncoderTest, ValidateEncoder) {
  // todo:: test something besides fixture setup
}

/**
 * @brief Parameterized coverage for effective H.264 profile selection.
 */
struct H264ProfileTest: testing::TestWithParam<std::tuple<std::string_view, video::amf::coder_e, int, int>> {};

TEST_P(H264ProfileTest, SelectProfile) {
  const auto &[encoder_name, coder, chroma_sampling_type, expected_profile] = GetParam();
  video::config_t config {};
  config.chromaSamplingType = chroma_sampling_type;

  EXPECT_EQ(expected_profile, video::select_h264_profile(encoder_name, config, std::to_underlying(coder)));
}

INSTANTIATE_TEST_SUITE_P(
  H264ProfileTests,
  H264ProfileTest,
  testing::Values(
    std::make_tuple("h264_amf"sv, video::amf::coder_e::auto_, 0, AV_PROFILE_H264_HIGH),
    std::make_tuple("h264_amf"sv, video::amf::coder_e::cabac, 0, AV_PROFILE_H264_HIGH),
    std::make_tuple("h264_amf"sv, video::amf::coder_e::cavlc, 0, AV_PROFILE_H264_CONSTRAINED_BASELINE),
    std::make_tuple("h264_amf"sv, video::amf::coder_e::cavlc, 1, AV_PROFILE_H264_HIGH_444_PREDICTIVE),
    std::make_tuple("h264_nvenc"sv, video::amf::coder_e::cavlc, 0, AV_PROFILE_H264_HIGH)
  )
);

/**
 * @brief Parameterized coverage for resolving requested dynamic range against encoder capabilities.
 */
struct DynamicRangeTest: testing::TestWithParam<std::tuple<int, int, int, bool, bool, int>> {};

TEST_P(DynamicRangeTest, Resolve) {
  const auto &[video_format, chroma_sampling_type, requested_dynamic_range, supports_hdr, supports_hdr_yuv444, expected_dynamic_range] = GetParam();

  video::encoder_t encoder {
    "test"sv,
    {},
    {},
    {},
    {},
    0,
  };
  encoder.h264.name = "h264_test";
  encoder.hevc.name = "hevc_test";
  encoder.av1.name = "av1_test";

  video::config_t config {};
  config.videoFormat = video_format;
  config.dynamicRange = requested_dynamic_range;
  config.chromaSamplingType = chroma_sampling_type;

  auto *codec = &encoder.h264;
  if (video_format == 1) {
    codec = &encoder.hevc;
  } else if (video_format == 2) {
    codec = &encoder.av1;
  }
  (*codec)[video::encoder_t::DYNAMIC_RANGE] = supports_hdr;
  (*codec)[video::encoder_t::DYNAMIC_RANGE_YUV444] = supports_hdr_yuv444;

  const auto effective_config = video::resolve_dynamic_range(encoder, config);

  EXPECT_EQ(expected_dynamic_range, effective_config.dynamicRange);
  EXPECT_EQ(requested_dynamic_range, config.dynamicRange);
  EXPECT_EQ(video_format, effective_config.videoFormat);
  EXPECT_EQ(chroma_sampling_type, effective_config.chromaSamplingType);
}

INSTANTIATE_TEST_SUITE_P(
  DynamicRangeTests,
  DynamicRangeTest,
  testing::Values(
    std::make_tuple(0, 0, 1, false, true, 0),
    std::make_tuple(1, 0, 1, false, true, 0),
    std::make_tuple(1, 0, 1, true, false, 1),
    std::make_tuple(2, 1, 1, true, false, 0),
    std::make_tuple(2, 1, 1, false, true, 1),
    std::make_tuple(1, 0, 0, false, false, 0)
  )
);

#ifdef _WIN32
TEST(AmfH264OptionsTest, CoderUsesConfiguredValue) {
  const auto coder_option = std::ranges::find(video::amdvce.h264.common_options, "coder"sv, &video::encoder_t::option_t::name);

  ASSERT_NE(video::amdvce.h264.common_options.end(), coder_option);
  ASSERT_TRUE(std::holds_alternative<int *>(coder_option->value));
  EXPECT_EQ(&config::video.amd.amd_coder, std::get<int *>(coder_option->value));
}

/**
 * @brief Parameterized coverage for the AMF maximum access-unit-size option mappings.
 */
struct AmfMaxAuSizeOptionsTest: testing::TestWithParam<std::tuple<const video::encoder_t::codec_t *, bool>> {};

TEST_P(AmfMaxAuSizeOptionsTest, UsesConfiguredValueForSupportedCodecsOnly) {
  const auto &[codec, supported] = GetParam();
  const auto option = std::ranges::find(codec->common_options, "max_au_size"sv, &video::encoder_t::option_t::name);

  if (!supported) {
    EXPECT_EQ(codec->common_options.end(), option);
    return;
  }

  ASSERT_NE(codec->common_options.end(), option);
  ASSERT_TRUE(std::holds_alternative<std::optional<int> *>(option->value));
  EXPECT_EQ(&config::video.amd.amd_max_au_size, std::get<std::optional<int> *>(option->value));
}

INSTANTIATE_TEST_SUITE_P(
  AmfCodecOptions,
  AmfMaxAuSizeOptionsTest,
  testing::Values(
    std::make_tuple(&video::amdvce.h264, true),
    std::make_tuple(&video::amdvce.hevc, true),
    std::make_tuple(&video::amdvce.av1, false)
  )
);
#endif

using AmfMaxAuSizeConfigParam = std::tuple<std::string_view, std::optional<int>>;

/**
 * @brief Parameterized coverage for parsing and validating the AMF maximum access-unit size.
 */
struct AmfMaxAuSizeConfigTest: BaseTest, testing::WithParamInterface<AmfMaxAuSizeConfigParam> {
  void SetUp() override {
    BaseTest::SetUp();
    config::video.amd.amd_max_au_size.reset();
    config::stream.file_apps = SUNSHINE_SOURCE_DIR "/tests/unit/test_video.cpp";
  }

  void TearDown() override {
    config::video = original_video;
    config::audio = original_audio;
    config::stream = original_stream;
    config::nvhttp = original_nvhttp;
    config::input = original_input;
    config::sunshine = original_sunshine;
    config::modified_config_settings = original_modified_config_settings;
    BaseTest::TearDown();
  }

  config::video_t original_video {config::video};  ///< Video configuration restored after each parameterized test.
  config::audio_t original_audio {config::audio};  ///< Audio configuration restored after each parameterized test.
  config::stream_t original_stream {config::stream};  ///< Stream configuration restored after each parameterized test.
  config::nvhttp_t original_nvhttp {config::nvhttp};  ///< HTTP configuration restored after each parameterized test.
  config::input_t original_input {config::input};  ///< Input configuration restored after each parameterized test.
  config::sunshine_t original_sunshine {config::sunshine};  ///< Core configuration restored after each parameterized test.
  decltype(config::modified_config_settings) original_modified_config_settings {config::modified_config_settings};  ///< Modified settings restored after each parameterized test.
};

TEST_P(AmfMaxAuSizeConfigTest, AcceptsOnlyFfmpegSupportedRange) {
  const auto &[setting, expected] = GetParam();
  config::apply_config_for_test(setting);

  EXPECT_EQ(expected, config::video.amd.amd_max_au_size);
}

INSTANTIATE_TEST_SUITE_P(
  AmfMaxAuSizeValues,
  AmfMaxAuSizeConfigTest,
  testing::Values(
    AmfMaxAuSizeConfigParam {""sv, std::nullopt},
    AmfMaxAuSizeConfigParam {"amd_max_au_size = -2\n"sv, std::nullopt},
    AmfMaxAuSizeConfigParam {"amd_max_au_size = -1\n"sv, -1},
    AmfMaxAuSizeConfigParam {"amd_max_au_size = 0\n"sv, 0},
    AmfMaxAuSizeConfigParam {"amd_max_au_size = 800000\n"sv, 800000},
    AmfMaxAuSizeConfigParam {"amd_max_au_size = 2147483647\n"sv, std::numeric_limits<int>::max()}
  )
);

struct FramerateX100Test: BaseTest, testing::WithParamInterface<std::tuple<std::int32_t, AVRational>> {};

TEST_P(FramerateX100Test, Run) {
  const auto &[x100, expected] = GetParam();
  auto res = video::framerateX100_to_rational(x100);
  ASSERT_EQ(0, av_cmp_q(res, expected)) << "expected "
                                        << expected.num << "/" << expected.den
                                        << ", got "
                                        << res.num << "/" << res.den;
}

INSTANTIATE_TEST_SUITE_P(
  FramerateX100Tests,
  FramerateX100Test,
  testing::Values(
    std::make_tuple(2397, AVRational {24000, 1001}),
    std::make_tuple(2398, AVRational {24000, 1001}),
    std::make_tuple(2500, AVRational {25, 1}),
    std::make_tuple(2997, AVRational {30000, 1001}),
    std::make_tuple(3000, AVRational {30, 1}),
    std::make_tuple(5994, AVRational {60000, 1001}),
    std::make_tuple(6000, AVRational {60, 1}),
    std::make_tuple(11988, AVRational {120000, 1001}),
    std::make_tuple(23976, AVRational {240000, 1001}),  // future NTSC 240hz?
    std::make_tuple(9498, AVRational {4749, 50})  // from my LG 27GN950
  )
);

struct FramerateToRationalTest: testing::TestWithParam<std::tuple<int, int, AVRational>> {};

TEST_P(FramerateToRationalTest, Run) {
  const auto &[framerate, framerateX100, expected] = GetParam();
  video::config_t config {};
  config.framerate = framerate;
  config.framerateX100 = framerateX100;
  auto res = video::framerate_to_rational(config);
  ASSERT_EQ(0, av_cmp_q(res, expected)) << "expected "
                                        << expected.num << "/" << expected.den
                                        << ", got "
                                        << res.num << "/" << res.den;
}

INSTANTIATE_TEST_SUITE_P(
  FramerateToRationalTests,
  FramerateToRationalTest,
  testing::Values(
    std::make_tuple(60, 0, AVRational {60, 1}),  // no X100 value, fall back to integer framerate
    std::make_tuple(60, 5994, AVRational {60000, 1001}),
    std::make_tuple(120, 11988, AVRational {120000, 1001}),
    std::make_tuple(24, 2398, AVRational {24000, 1001})
  )
);

struct CaptureFrameIntervalTest: testing::TestWithParam<std::tuple<int, int, std::chrono::nanoseconds>> {};

TEST_P(CaptureFrameIntervalTest, Run) {
  const auto &[framerate, framerateX100, expected] = GetParam();
  video::config_t config {};
  config.framerate = framerate;
  config.framerateX100 = framerateX100;
  ASSERT_EQ(expected, video::capture_frame_interval(config));
}

INSTANTIATE_TEST_SUITE_P(
  CaptureFrameIntervalTests,
  CaptureFrameIntervalTest,
  testing::Values(
    std::make_tuple(60, 0, std::chrono::nanoseconds {16666666}),
    std::make_tuple(60, 5994, std::chrono::nanoseconds {16683333}),  // 1e9 * 1001 / 60000
    std::make_tuple(120, 11988, std::chrono::nanoseconds {8341666})  // 1e9 * 1001 / 120000
  )
);

/**
 * @brief Software encoder converts BGR0 and NV12 frames, including padded strides and
 *        backends that don't report the pixel pitch.
 */
TEST(SoftwareEncoderConversion, Bgr0AndNv12) {
  constexpr int w = 320;
  constexpr int h = 240;

  AVFrame *frame = av_frame_alloc();
  ASSERT_NE(frame, nullptr);
  frame->width = w;
  frame->height = h;
  frame->format = AV_PIX_FMT_YUV420P;

  video::avcodec_software_encode_device_t device;
  ASSERT_EQ(device.init(w, h, frame, AV_PIX_FMT_YUV420P, false), 0);
  // set_frame() takes ownership of the frame; the device frees it on destruction.
  ASSERT_EQ(device.set_frame(frame, nullptr), 0);

  // BGR0 frame (4 bytes per pixel) -- the classic KMS/DMABUF capture layout.
  std::vector<uint8_t> bgr0_buffer(static_cast<size_t>(w) * h * 4);
  platf::img_t bgr0_img {};
  bgr0_img.data = bgr0_buffer.data();
  bgr0_img.width = w;
  bgr0_img.height = h;
  bgr0_img.row_pitch = w * 4;
  bgr0_img.pixel_pitch = 4;
  EXPECT_EQ(device.convert(bgr0_img), 0);

  // NV12 frame (1 byte per pixel row pitch, Y plane + interleaved UV) -- the
  // layout delivered by PipeWire-based captures (KWin screencast / portal).
  std::vector<uint8_t> nv12_buffer(static_cast<size_t>(w) * h + static_cast<size_t>(w) * h / 2);
  platf::img_t nv12_img {};
  nv12_img.data = nv12_buffer.data();
  nv12_img.width = w;
  nv12_img.height = h;
  nv12_img.row_pitch = w;
  nv12_img.pixel_pitch = 1;
  EXPECT_EQ(device.convert(nv12_img), 0);

  // Padded-stride NV12 (alignment padding) -- the case the old row_pitch ==
  // width heuristic misdetected as BGR0, causing out-of-bounds reads.
  constexpr int padded_stride = w + 32;
  std::vector<uint8_t> padded_nv12_buffer(static_cast<size_t>(padded_stride) * h + static_cast<size_t>(padded_stride) * h / 2);
  platf::img_t padded_nv12_img {};
  padded_nv12_img.data = padded_nv12_buffer.data();
  padded_nv12_img.width = w;
  padded_nv12_img.height = h;
  padded_nv12_img.row_pitch = padded_stride;
  padded_nv12_img.pixel_pitch = 1;
  EXPECT_EQ(device.convert(padded_nv12_img), 0);

  // Capture backends that don't report pixel_pitch fall back to deriving it
  // from the row pitch (1 byte per pixel = NV12, 4 = BGR0).
  platf::img_t fallback_bgr0_img {};
  fallback_bgr0_img.data = bgr0_buffer.data();
  fallback_bgr0_img.width = w;
  fallback_bgr0_img.height = h;
  fallback_bgr0_img.row_pitch = w * 4;
  EXPECT_EQ(device.convert(fallback_bgr0_img), 0);

  platf::img_t fallback_nv12_img {};
  fallback_nv12_img.data = nv12_buffer.data();
  fallback_nv12_img.width = w;
  fallback_nv12_img.height = h;
  fallback_nv12_img.row_pitch = w;
  EXPECT_EQ(device.convert(fallback_nv12_img), 0);
}

/**
 * @brief A captured frame without a backend timestamp receives one before it is submitted.
 */
TEST(FrameTimestampTest, StampsFrameWithoutTimestamp) {
  auto img = std::make_shared<platf::img_t>();
  const auto capture_time = std::chrono::steady_clock::now();

  video::detail::stamp_frame_timestamp(img, true, capture_time);

  ASSERT_TRUE(img->frame_timestamp.has_value());
  EXPECT_EQ(*img->frame_timestamp, capture_time);
}

/**
 * @brief A timestamp supplied by the capture backend is never overwritten.
 */
TEST(FrameTimestampTest, KeepsBackendTimestamp) {
  auto img = std::make_shared<platf::img_t>();
  const auto backend_time = std::chrono::steady_clock::time_point {std::chrono::milliseconds {1234567}};
  img->frame_timestamp = backend_time;

  video::detail::stamp_frame_timestamp(img, true, std::chrono::steady_clock::now());

  ASSERT_TRUE(img->frame_timestamp.has_value());
  EXPECT_EQ(*img->frame_timestamp, backend_time);
}

/**
 * @brief Callbacks that produced no frame leave the image unstamped.
 */
TEST(FrameTimestampTest, IgnoresCallbacksWithoutFrame) {
  auto img = std::make_shared<platf::img_t>();

  video::detail::stamp_frame_timestamp(img, false, std::chrono::steady_clock::now());

  EXPECT_FALSE(img->frame_timestamp.has_value());
}

/**
 * @brief A missing image is tolerated, because the synchronous path can push an empty frame.
 */
TEST(FrameTimestampTest, ToleratesMissingImage) {
  video::detail::stamp_frame_timestamp(nullptr, true, std::chrono::steady_clock::now());
}

/**
 * @brief A packet that comes out immediately resolves to the frame just submitted.
 */
TEST(InFlightTrackerTest, SynchronousMatch) {
  video::detail::in_flight_frame_tracker_t tracker;
  const auto capture_time = std::chrono::steady_clock::time_point {std::chrono::milliseconds {1000}};

  tracker.record_submitted_frame(5, capture_time, true);
  auto matched = tracker.resolve_packet(5, 5);

  ASSERT_TRUE(matched.has_value());
  EXPECT_EQ(matched->pts, 5);
  ASSERT_TRUE(matched->frame_timestamp.has_value());
  EXPECT_EQ(*matched->frame_timestamp, capture_time);
  EXPECT_TRUE(matched->idr_requested);
  EXPECT_EQ(tracker.match_count(), 1U);

  // A packet can never be attributed twice.
  EXPECT_FALSE(tracker.resolve_packet(5, 5).has_value());
  EXPECT_EQ(tracker.miss_count(), 1U);
}

/**
 * @brief A packet that lags the submission by several frames still gets its own capture timestamp.
 *
 * The frames submitted after the captured one are re-encodes of the previous image and therefore
 * carry no timestamp at all, which is what makes the ring lookup necessary.
 */
TEST(InFlightTrackerTest, PipelineOffsetWithTimeoutReencodes) {
  video::detail::in_flight_frame_tracker_t tracker;
  const auto capture_time = std::chrono::steady_clock::time_point {std::chrono::milliseconds {2000}};

  tracker.record_submitted_frame(100, capture_time, false);
  for (auto frame_nr : {101, 102, 103, 104}) {
    tracker.record_submitted_frame(frame_nr, std::nullopt, frame_nr == 104);
  }

  auto matched = tracker.resolve_packet(100, 104);
  ASSERT_TRUE(matched.has_value());
  EXPECT_EQ(matched->pts, 100);
  ASSERT_TRUE(matched->frame_timestamp.has_value());
  EXPECT_EQ(*matched->frame_timestamp, capture_time);
  EXPECT_FALSE(matched->idr_requested);

  auto idr_packet = tracker.resolve_packet(104, 104);
  ASSERT_TRUE(idr_packet.has_value());
  EXPECT_TRUE(idr_packet->idr_requested);
  EXPECT_FALSE(idr_packet->frame_timestamp.has_value());
}

/**
 * @brief An encoder that strips the packet PTS falls back to the current frame index.
 */
TEST(InFlightTrackerTest, MissingPtsFallsBackToCurrentFrame) {
  video::detail::in_flight_frame_tracker_t tracker;
  const auto capture_time = std::chrono::steady_clock::time_point {std::chrono::milliseconds {3000}};

  tracker.record_submitted_frame(7, capture_time, false);
  auto matched = tracker.resolve_packet(AV_NOPTS_VALUE, 7);

  ASSERT_TRUE(matched.has_value());
  EXPECT_EQ(matched->pts, 7);
  EXPECT_EQ(*matched->frame_timestamp, capture_time);
}

/**
 * @brief Packets from unknown or evicted frames are reported as misses instead of guessing.
 */
TEST(InFlightTrackerTest, UnknownAndEvictedFramesMiss) {
  video::detail::in_flight_frame_tracker_t tracker;
  const auto capture_time = std::chrono::steady_clock::time_point {std::chrono::milliseconds {4000}};

  EXPECT_FALSE(tracker.resolve_packet(1000, 1000).has_value());

  // A slot that is overwritten before it is drained loses the older frame that shared the slot.
  constexpr auto kSlots = (int64_t) video::detail::in_flight_frame_tracker_t::kSlots;
  tracker.record_submitted_frame(0, capture_time, false);
  for (int64_t frame_nr = 1; frame_nr <= kSlots; ++frame_nr) {
    tracker.record_submitted_frame(frame_nr, capture_time, false);
  }

  EXPECT_FALSE(tracker.resolve_packet(0, 0).has_value());
  EXPECT_TRUE(tracker.resolve_packet(kSlots, kSlots).has_value());
  EXPECT_TRUE(tracker.resolve_packet(1, 1).has_value());
}

/**
 * @brief Clearing the tracker forgets frames that were submitted before a reconfiguration.
 */
TEST(InFlightTrackerTest, ClearDiscardsRecordedFrames) {
  video::detail::in_flight_frame_tracker_t tracker;

  tracker.record_submitted_frame(9, std::chrono::steady_clock::now(), true);
  tracker.clear();

  EXPECT_FALSE(tracker.resolve_packet(9, 9).has_value());
  EXPECT_EQ(tracker.submission_count(), 1U);
}

/**
 * @brief A negative frame index is never recorded or resolved.
 */
TEST(InFlightTrackerTest, RejectsNegativePts) {
  video::detail::in_flight_frame_tracker_t tracker;

  tracker.record_submitted_frame(-1, std::chrono::steady_clock::now(), false);

  EXPECT_EQ(tracker.submission_count(), 0U);
  EXPECT_FALSE(tracker.resolve_packet(-1, -1).has_value());
}

/**
 * @brief VideoToolbox keeps both flags while low-latency mode is requested.
 */
TEST(EncodeFlagsTest, VideotoolboxWithLowLatency) {
  EXPECT_EQ(video::detail::encode_flags_for_encoder(true, true), AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY);
}

/**
 * @brief Clearing low-latency mode leaves the closed-GOP behaviour untouched.
 */
TEST(EncodeFlagsTest, VideotoolboxWithoutLowLatency) {
  EXPECT_EQ(video::detail::encode_flags_for_encoder(true, false), AV_CODEC_FLAG_CLOSED_GOP);
}

/**
 * @brief Encoders other than VideoToolbox always keep the previous flags.
 */
TEST(EncodeFlagsTest, OtherEncodersIgnoreTheOption) {
  EXPECT_EQ(video::detail::encode_flags_for_encoder(false, false), AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY);
  EXPECT_EQ(video::detail::encode_flags_for_encoder(false, true), AV_CODEC_FLAG_CLOSED_GOP | AV_CODEC_FLAG_LOW_DELAY);
}

/**
 * @brief The rate meter reports nothing until its window closes.
 */
TEST(EncodeRateMeterTest, SilentUntilWindowCloses) {
  video::detail::encode_rate_meter_t meter;
  const auto start = std::chrono::steady_clock::time_point {std::chrono::seconds {100}};

  EXPECT_FALSE(meter.record(start, true).has_value());
  EXPECT_FALSE(meter.record(start + 10s, true).has_value());
  EXPECT_FALSE(meter.record(start + meter.window - 1ms, true).has_value());
}

/**
 * @brief A closed window reports the submitted frame rate and restarts counting.
 */
TEST(EncodeRateMeterTest, ReportsRateAndRestarts) {
  video::detail::encode_rate_meter_t meter;
  const auto start = std::chrono::steady_clock::time_point {std::chrono::seconds {100}};

  // 199 counted passes plus the closing pass, all inside a 20 s window. The first call only
  // establishes the window, so 200 frames in 20 s is 10 fps.
  meter.record(start, true);
  for (int i = 1; i < 200; ++i) {
    EXPECT_FALSE(meter.record(start + std::chrono::milliseconds {100 * i}, true).has_value());
  }

  auto rate = meter.record(start + meter.window, true);
  ASSERT_TRUE(rate.has_value());
  EXPECT_DOUBLE_EQ(*rate, 10.0);

  // The next window counts from scratch, so an idle window reports zero frames per second.
  EXPECT_FALSE(meter.record(start + meter.window + 1s, false).has_value());
  auto idle = meter.record(start + 2 * meter.window, false);
  ASSERT_TRUE(idle.has_value());
  EXPECT_DOUBLE_EQ(*idle, 0.0);
}
