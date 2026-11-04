/**
 * @file tests/unit/platform/macos/test_hdr_capture.cpp
 * @brief Regression checks for the macOS HDR capture decision and the HDR10 metadata it synthesises.
 * @details The decision itself lives in `src/platform/macos/hdr_capture.h` precisely so that it can be
 *          checked here: the ScreenCaptureKit and AppKit calls that feed it cannot run in a test binary.
 *          The numbers these tests expect are the ones measured in section 10 of `docs/macos_hdr.md`.
 */
#ifdef __APPLE__
  #include <cstdlib>
  #include <limits>
  #include <string>

  #include "../../../tests_common.h"
  #include "src/platform/macos/hdr_capture.h"

using namespace std::literals;  ///< Lets the tests spell expected names as `"sdr"sv`.

using platf::macos_hdr::capture_dynamic_range_e;  ///< The dynamic range ScreenCaptureKit is asked for.
using platf::macos_hdr::mastering_defaults_t;  ///< The synthesised HDR10 luminances.

/**
 * @brief The environment tunables are cleared before and after each defaults test.
 */
class MacosHdrDefaultsTest: public testing::Test {
protected:
  /**
   * @brief Forget any tunable a previous test set.
   */
  void SetUp() override {
    clear();
  }

  /**
   * @brief Leave no tunable behind for the rest of the suite.
   */
  void TearDown() override {
    clear();
  }

private:
  /**
   * @brief Unset every `LUMEN_HDR_*` variable the synthesiser reads.
   */
  static void clear() {
    for (const auto *name: {"LUMEN_HDR_MAX_LUMINANCE", "LUMEN_HDR_MIN_LUMINANCE", "LUMEN_HDR_MAX_CLL", "LUMEN_HDR_MAX_FALL"}) {
      unsetenv(name);
    }
  }
};

/**
 * @brief Each accepted spelling names its dynamic range, and nothing else does.
 */
TEST(MacosHdrCapture, MapsConfiguredNamesToADynamicRange) {
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view("sdr"));
  EXPECT_EQ(capture_dynamic_range_e::hdr_local, platf::macos_hdr::dynamic_range_from_view("hdr_local"));
  EXPECT_EQ(capture_dynamic_range_e::hdr_canonical, platf::macos_hdr::dynamic_range_from_view("hdr_canonical"));

  // sunshine.conf is edited by hand, so case and stray whitespace must not silently drop a host to SDR.
  EXPECT_EQ(capture_dynamic_range_e::hdr_canonical, platf::macos_hdr::dynamic_range_from_view("  HDR_Canonical \t"));
  EXPECT_EQ(capture_dynamic_range_e::hdr_local, platf::macos_hdr::dynamic_range_from_view("HDR_LOCAL"));
}

/**
 * @brief An empty or unknown value keeps the dynamic range this platform captured before.
 */
TEST(MacosHdrCapture, FallsBackToSdrForAnythingElse) {
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view(""));
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view("   "));
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view("hdr"));
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view("hdr_canon"));
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view("sdrx"));
  EXPECT_EQ(capture_dynamic_range_e::sdr, platf::macos_hdr::dynamic_range_from_view("canonical"));
}

/**
 * @brief Naming a dynamic range reproduces a configuration value that names it again.
 */
TEST(MacosHdrCapture, NamesRangesTheWayTheConfigSpellsThem) {
  EXPECT_EQ("sdr"sv, platf::macos_hdr::to_string(capture_dynamic_range_e::sdr));
  EXPECT_EQ("hdr_local"sv, platf::macos_hdr::to_string(capture_dynamic_range_e::hdr_local));
  EXPECT_EQ("hdr_canonical"sv, platf::macos_hdr::to_string(capture_dynamic_range_e::hdr_canonical));

  for (const auto range: {capture_dynamic_range_e::sdr, capture_dynamic_range_e::hdr_local, capture_dynamic_range_e::hdr_canonical}) {
    EXPECT_EQ(range, platf::macos_hdr::dynamic_range_from_view(platf::macos_hdr::to_string(range)));
  }
}

/**
 * @brief Only headroom strictly above unity means a screen can display HDR.
 *
 * A screen that cannot do HDR at all reports exactly 1.0, which is why the boundary is exclusive.
 */
TEST(MacosHdrCapture, TreatsHeadroomAboveUnityAsCapability) {
  EXPECT_FALSE(platf::macos_hdr::display_can_hdr(1.0));
  EXPECT_FALSE(platf::macos_hdr::display_can_hdr(0.5));
  EXPECT_FALSE(platf::macos_hdr::display_can_hdr(-1.0));

  EXPECT_TRUE(platf::macos_hdr::display_can_hdr(1.0001));
  EXPECT_TRUE(platf::macos_hdr::display_can_hdr(5.0));  // The value measured with BetterDisplay enabled.
}

/**
 * @brief Garbage headroom is not a capability, so the capture stays SDR.
 */
TEST(MacosHdrCapture, RejectsHeadroomThatIsNotANumber) {
  EXPECT_FALSE(platf::macos_hdr::display_can_hdr(std::numeric_limits<double>::quiet_NaN()));
  EXPECT_FALSE(platf::macos_hdr::display_can_hdr(std::numeric_limits<double>::infinity()));
}

/**
 * @brief Every gate has to pass before a stream is captured and reported as HDR.
 */
TEST(MacosHdrCapture, RequiresEveryGateBeforeEnablingHdr) {
  constexpr auto canonical = capture_dynamic_range_e::hdr_canonical;
  constexpr auto local = capture_dynamic_range_e::hdr_local;
  constexpr auto sdr = capture_dynamic_range_e::sdr;
  constexpr double capable = 5.0;  ///< The headroom measured with BetterDisplay's HDR support turned on.
  constexpr double incapable = 1.0;  ///< What a screen that cannot show HDR reports.

  EXPECT_TRUE(platf::macos_hdr::hdr_capture_enabled({.range = canonical, .maximum_potential_edr = capable, .platform_supports_hdr = true, .session_requests_10bit = true}));
  EXPECT_TRUE(platf::macos_hdr::hdr_capture_enabled({.range = local, .maximum_potential_edr = capable, .platform_supports_hdr = true, .session_requests_10bit = true}));

  // The switch is what decides it, so a fully capable screen stays SDR until someone asks for HDR.
  EXPECT_FALSE(platf::macos_hdr::hdr_capture_enabled({.range = sdr, .maximum_potential_edr = capable, .platform_supports_hdr = true, .session_requests_10bit = true}));

  // A screen that cannot show HDR has already been tone mapped by macOS to a standard dynamic range
  // picture, so capturing it as HDR would only relabel it.
  EXPECT_FALSE(platf::macos_hdr::hdr_capture_enabled({.range = canonical, .maximum_potential_edr = incapable, .platform_supports_hdr = true, .session_requests_10bit = true}));

  // An older system or an Intel Mac cannot deliver an HDR capture at all.
  EXPECT_FALSE(platf::macos_hdr::hdr_capture_enabled({.range = canonical, .maximum_potential_edr = capable, .platform_supports_hdr = false, .session_requests_10bit = true}));

  // The capture is passed to the encoder unconverted, so PQ samples in an 8 bit stream would be
  // encoded and labelled as BT.709. An 8 bit client therefore gets an SDR capture.
  EXPECT_FALSE(platf::macos_hdr::hdr_capture_enabled({.range = canonical, .maximum_potential_edr = capable, .platform_supports_hdr = true, .session_requests_10bit = false}));
}

/**
 * @brief The BT.2020 mastering block is written from the specification, scaled for the host message.
 */
TEST(MacosHdrCapture, ScalesChromaticitiesForTheHostMessage) {
  std::uint16_t x {};
  std::uint16_t y {};

  platf::macos_hdr::scale_chromaticity(platf::macos_hdr::kBt2020RedX, platf::macos_hdr::kBt2020RedY, x, y);
  EXPECT_EQ(35400, x);
  EXPECT_EQ(14600, y);

  platf::macos_hdr::scale_chromaticity(platf::macos_hdr::kBt2020GreenX, platf::macos_hdr::kBt2020GreenY, x, y);
  EXPECT_EQ(8500, x);
  EXPECT_EQ(39850, y);

  platf::macos_hdr::scale_chromaticity(platf::macos_hdr::kBt2020BlueX, platf::macos_hdr::kBt2020BlueY, x, y);
  EXPECT_EQ(6550, x);
  EXPECT_EQ(2300, y);

  platf::macos_hdr::scale_chromaticity(platf::macos_hdr::kWhitePointX, platf::macos_hdr::kWhitePointY, x, y);
  EXPECT_EQ(15635, x);
  EXPECT_EQ(16450, y);
}

/**
 * @brief A coordinate that cannot fit the message field clamps, and one that is not a number counts as absent.
 */
TEST(MacosHdrCapture, ClampsChromaticitiesThatDoNotFit) {
  constexpr auto max_coordinate = std::numeric_limits<std::uint16_t>::max();
  std::uint16_t x {};
  std::uint16_t y {};

  platf::macos_hdr::scale_chromaticity(9.0, -0.5, x, y);
  EXPECT_EQ(max_coordinate, x);
  EXPECT_EQ(0, y);

  platf::macos_hdr::scale_chromaticity(std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity(), x, y);
  EXPECT_EQ(0, x);
  EXPECT_EQ(0, y);

  // A zero coordinate is how video.cpp decides that there are no primaries to write.
  platf::macos_hdr::scale_chromaticity(0.0, 0.0, x, y);
  EXPECT_EQ(0, x);
  EXPECT_EQ(0, y);
}

/**
 * @brief The four luminance options as sunshine.conf leaves them when none is named.
 *
 * @return A configuration carrying `kUnsetMasteringValue` in every field.
 */
platf::macos_hdr::mastering_config_t unset_mastering_config() {
  return platf::macos_hdr::mastering_config_t {
    .max_luminance_nits = platf::macos_hdr::kUnsetMasteringValue,
    .min_luminance_nits = platf::macos_hdr::kUnsetMasteringValue,
    .max_cll_nits = platf::macos_hdr::kUnsetMasteringValue,
    .max_fall_nits = platf::macos_hdr::kUnsetMasteringValue,
  };
}

/**
 * @brief With nothing named, the peak is this screen's brightest picture.
 *
 * The derivation is 100 cd/m2 of SDR white times the screen's EDR headroom, which is what sections 10.3
 * and 10.4 of `docs/macos_hdr.md` measure the host producing, and it can never be over-declared.
 */
TEST_F(MacosHdrDefaultsTest, DerivesThePeakFromTheScreensHeadroom) {
  const mastering_defaults_t hdr = platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config());

  EXPECT_DOUBLE_EQ(500.0, hdr.max_luminance_nits);
  EXPECT_DOUBLE_EQ(0.005, hdr.min_luminance_nits);

  // Content statistics that were not named follow the peak, or stay out of the stream.
  EXPECT_EQ(500, hdr.max_cll_nits);
  EXPECT_EQ(0, hdr.max_fall_nits);

  // A screen that cannot do HDR has no headroom to derive from, so its own white is the peak.
  EXPECT_DOUBLE_EQ(100.0, platf::macos_hdr::mastering_defaults(1.0, unset_mastering_config()).max_luminance_nits);
  EXPECT_DOUBLE_EQ(2000.0, platf::macos_hdr::mastering_defaults(20.0, unset_mastering_config()).max_luminance_nits);

  // A headroom that is not a number is a screen nobody measured, not an infinite one.
  EXPECT_DOUBLE_EQ(100.0, platf::macos_hdr::mastering_defaults(std::numeric_limits<double>::quiet_NaN(), unset_mastering_config()).max_luminance_nits);
}

/**
 * @brief A configured luminance is used instead of the derived one.
 */
TEST_F(MacosHdrDefaultsTest, ReadsTheConfiguredLuminances) {
  const auto config = platf::macos_hdr::mastering_config_t {
    .max_luminance_nits = 300.0,
    .min_luminance_nits = 0.01,
    .max_cll_nits = 240.0,
    .max_fall_nits = 120.0,
  };

  const mastering_defaults_t defaults = platf::macos_hdr::mastering_defaults(5.0, config);

  EXPECT_DOUBLE_EQ(300.0, defaults.max_luminance_nits);
  EXPECT_DOUBLE_EQ(0.01, defaults.min_luminance_nits);
  EXPECT_EQ(240, defaults.max_cll_nits);
  EXPECT_EQ(120, defaults.max_fall_nits);
}

/**
 * @brief The environment wins over the configuration, which is the knob used while measuring a client.
 */
TEST_F(MacosHdrDefaultsTest, EnvironmentOverridesTheConfiguration) {
  setenv("LUMEN_HDR_MAX_LUMINANCE", "1500", 1);

  const auto config = platf::macos_hdr::mastering_config_t {
    .max_luminance_nits = 300.0,
    .min_luminance_nits = platf::macos_hdr::kUnsetMasteringValue,
    .max_cll_nits = platf::macos_hdr::kUnsetMasteringValue,
    .max_fall_nits = platf::macos_hdr::kUnsetMasteringValue,
  };

  const mastering_defaults_t defaults = platf::macos_hdr::mastering_defaults(5.0, config);

  EXPECT_DOUBLE_EQ(1500.0, defaults.max_luminance_nits);

  // The statistics nobody named follow the peak that actually won.
  EXPECT_EQ(1500, defaults.max_cll_nits);
}

/**
 * @brief A content light level above the declared peak is clamped, not trusted.
 */
TEST_F(MacosHdrDefaultsTest, ClampsContentLightLevelsToThePeak) {
  const auto over = platf::macos_hdr::mastering_config_t {
    .max_luminance_nits = 300.0,
    .min_luminance_nits = platf::macos_hdr::kUnsetMasteringValue,
    .max_cll_nits = 1000.0,
    .max_fall_nits = 4000.0,
  };

  const mastering_defaults_t configured = platf::macos_hdr::mastering_defaults(5.0, over);
  EXPECT_EQ(300, configured.max_cll_nits);
  EXPECT_EQ(300, configured.max_fall_nits);

  setenv("LUMEN_HDR_MAX_CLL", "9000", 1);
  setenv("LUMEN_HDR_MAX_FALL", "9000", 1);
  const mastering_defaults_t from_environment = platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config());
  EXPECT_EQ(500, from_environment.max_cll_nits);
  EXPECT_EQ(500, from_environment.max_fall_nits);
}

/**
 * @brief The tunables exist to re-reference the 100 cd/m2 white this host renders on a real client.
 */
TEST_F(MacosHdrDefaultsTest, ReadsTheEnvironmentTunables) {
  setenv("LUMEN_HDR_MAX_LUMINANCE", "4000", 1);
  setenv("LUMEN_HDR_MIN_LUMINANCE", "0.01", 1);
  setenv("LUMEN_HDR_MAX_CLL", "400", 1);
  setenv("LUMEN_HDR_MAX_FALL", "200", 1);

  const mastering_defaults_t defaults = platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config());

  EXPECT_DOUBLE_EQ(4000.0, defaults.max_luminance_nits);
  EXPECT_DOUBLE_EQ(0.01, defaults.min_luminance_nits);
  EXPECT_EQ(400, defaults.max_cll_nits);
  EXPECT_EQ(200, defaults.max_fall_nits);
}

/**
 * @brief A tunable that is not a plain non-negative number is ignored rather than trusted.
 */
TEST_F(MacosHdrDefaultsTest, IgnoresMalformedTunables) {
  const mastering_defaults_t reference = platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config());

  for (const char *bad: {"", "abc", "12x", "1 2", "-5", "0x10"}) {
    setenv("LUMEN_HDR_MAX_LUMINANCE", bad, 1);
    EXPECT_DOUBLE_EQ(reference.max_luminance_nits, platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config()).max_luminance_nits) << "value was [" << bad << ']';

    setenv("LUMEN_HDR_MIN_LUMINANCE", bad, 1);
    EXPECT_DOUBLE_EQ(reference.min_luminance_nits, platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config()).min_luminance_nits) << "value was [" << bad << ']';

    unsetenv("LUMEN_HDR_MAX_LUMINANCE");
    unsetenv("LUMEN_HDR_MIN_LUMINANCE");
  }

  // Zero is a plain number, and it is what suppresses the content light level side data.
  setenv("LUMEN_HDR_MAX_CLL", "0", 1);
  setenv("LUMEN_HDR_MAX_FALL", "0", 1);
  const mastering_defaults_t suppressed = platf::macos_hdr::mastering_defaults(5.0, unset_mastering_config());
  EXPECT_EQ(0, suppressed.max_cll_nits);
  EXPECT_EQ(0, suppressed.max_fall_nits);
}

/**
 * @brief A configured 0 leaves the content light level side data out just like the tunable does.
 */
TEST_F(MacosHdrDefaultsTest, ConfiguredZeroStillSuppressesTheSideData) {
  const auto config = platf::macos_hdr::mastering_config_t {
    .max_luminance_nits = platf::macos_hdr::kUnsetMasteringValue,
    .min_luminance_nits = platf::macos_hdr::kUnsetMasteringValue,
    .max_cll_nits = 0.0,
    .max_fall_nits = 0.0,
  };

  const mastering_defaults_t defaults = platf::macos_hdr::mastering_defaults(5.0, config);

  EXPECT_DOUBLE_EQ(500.0, defaults.max_luminance_nits);
  EXPECT_EQ(0, defaults.max_cll_nits);
  EXPECT_EQ(0, defaults.max_fall_nits);
}

#endif
