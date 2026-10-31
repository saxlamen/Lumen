/**
 * @file tests/unit/test_config.cpp
 * @brief Tests for Sunshine configuration persistence helpers.
 */

// test includes
#include "../tests_common.h"

// standard includes
#include <filesystem>
#include <string>
#include <utility>

// local includes
#include <src/config.h>
#include <src/file_handler.h>

using namespace std::literals;

using NvencPresetNameParam = std::pair<int, std::string_view>;

/**
 * @brief Parameterized coverage for FFmpeg's symbolic NVENC preset names.
 */
struct NvencPresetNameTest: testing::TestWithParam<NvencPresetNameParam> {};

TEST_P(NvencPresetNameTest, UsesStableSymbolicName) {
  const auto &[quality_preset, expected] = GetParam();

  EXPECT_EQ(expected, config::nv::ffmpeg_preset_from_quality(quality_preset));
}

INSTANTIATE_TEST_SUITE_P(
  NvencQualityPresets,
  NvencPresetNameTest,
  testing::Values(
    NvencPresetNameParam {1, "p1"sv},
    NvencPresetNameParam {2, "p2"sv},
    NvencPresetNameParam {3, "p3"sv},
    NvencPresetNameParam {4, "p4"sv},
    NvencPresetNameParam {5, "p5"sv},
    NvencPresetNameParam {6, "p6"sv},
    NvencPresetNameParam {7, "p7"sv}
  )
);

namespace {

  /**
   * @brief Fixture that redirects configuration persistence to a temporary file.
   */
  class ConfigPersistenceTest: public testing::Test {
  protected:
    /**
     * @brief Preserve the active config path and prepare an empty temporary path.
     */
    void SetUp() override {
      original_config_file_ = config::sunshine.config_file;
      original_gamepad_driver_ = config::input.gamepad_driver;
      config_file_ = std::filesystem::temp_directory_path() / "sunshine_test_config_persistence.conf";  // NOSONAR(cpp:S5443): safe for tests
      std::filesystem::remove(config_file_);
      config::sunshine.config_file = config_file_.string();
      config::input.gamepad_driver.clear();
    }

    /**
     * @brief Remove the temporary file and restore the active config path.
     */
    void TearDown() override {
      config::sunshine.config_file = std::move(original_config_file_);
      config::input.gamepad_driver = std::move(original_gamepad_driver_);
      std::filesystem::remove(config_file_);
    }

    /**
     * @brief Get the temporary configuration file used by the test.
     *
     * @return Temporary configuration file path.
     */
    const std::filesystem::path &config_file() const {
      return config_file_;
    }

  private:
    std::filesystem::path config_file_;  ///< Temporary configuration file used by the test.
    std::string original_config_file_;  ///< Active configuration path restored after each test.
    std::string original_gamepad_driver_;  ///< Gamepad driver preference restored after each test.
  };

}  // namespace

TEST_F(ConfigPersistenceTest, AppendsMissingOptionWithoutReplacingExistingText) {
  ASSERT_EQ(file_handler::write_file(config_file().string().c_str(), "# retained comment"), 0);

  EXPECT_TRUE(config::persist_config_option_if_missing("gamepad_driver", "all"));
  EXPECT_EQ(
    file_handler::read_file(config_file().string().c_str()),
    "# retained comment\ngamepad_driver = all\n"
  );

  EXPECT_FALSE(config::persist_config_option_if_missing("gamepad_driver", "virtualhid"));
  EXPECT_EQ(
    file_handler::read_file(config_file().string().c_str()),
    "# retained comment\ngamepad_driver = all\n"
  );
}

TEST_F(ConfigPersistenceTest, DoesNotReplaceAnExistingOption) {
  ASSERT_EQ(file_handler::write_file(config_file().string().c_str(), "gamepad_driver = vigembus\n"), 0);

  EXPECT_FALSE(config::persist_config_option_if_missing("gamepad_driver", "all"));
  EXPECT_EQ(file_handler::read_file(config_file().string().c_str()), "gamepad_driver = vigembus\n");
}

TEST_F(ConfigPersistenceTest, SelectsAllDriversOnlyForLicensedUsersWithoutAPreference) {
  EXPECT_FALSE(config::select_all_gamepad_drivers_if_licensed(false));
  EXPECT_TRUE(config::input.gamepad_driver.empty());
  EXPECT_TRUE(file_handler::read_file(config_file().string().c_str()).empty());

  EXPECT_TRUE(config::select_all_gamepad_drivers_if_licensed(true));
  EXPECT_EQ(config::input.gamepad_driver, config::GAMEPAD_DRIVER_ALL);
  EXPECT_EQ(file_handler::read_file(config_file().string().c_str()), "gamepad_driver = all\n");

  EXPECT_FALSE(config::select_all_gamepad_drivers_if_licensed(true));
  EXPECT_EQ(file_handler::read_file(config_file().string().c_str()), "gamepad_driver = all\n");
}

/**
 * @brief The words and numbers accepted by vt_drain map to a drain cadence.
 */
TEST(VideotoolboxDrainTest, MapsWordsAndNumbersToACadence) {
  EXPECT_EQ(0, config::vt::drain_from_view("disabled"));
  EXPECT_EQ(0, config::vt::drain_from_view("off"));
  EXPECT_EQ(0, config::vt::drain_from_view("0"));

  EXPECT_EQ(1, config::vt::drain_from_view("enabled"));
  EXPECT_EQ(1, config::vt::drain_from_view("on"));

  EXPECT_EQ(2, config::vt::drain_from_view("2"));
  EXPECT_EQ(16, config::vt::drain_from_view("16"));
}

/**
 * @brief Anything that is neither a keyword nor a plain decimal keeps the synchronous default.
 */
TEST(VideotoolboxDrainTest, FallsBackToSynchronousDrain) {
  EXPECT_EQ(1, config::vt::drain_from_view(""));
  EXPECT_EQ(1, config::vt::drain_from_view("maybe"));
  EXPECT_EQ(1, config::vt::drain_from_view("2x"));
  EXPECT_EQ(1, config::vt::drain_from_view("-1"));
}

/**
 * @brief Cadences beyond the useful range clamp instead of overflowing the accumulator.
 */
TEST(VideotoolboxDrainTest, ClampsVeryLargeCadences) {
  EXPECT_EQ(16, config::vt::drain_from_view("17"));
  EXPECT_EQ(16, config::vt::drain_from_view("999999999999999999999"));
}

using VideotoolboxDrainConfigParam = std::pair<std::string_view, int>;  ///< Configuration text and the cadence it must produce.

/**
 * @brief Coverage for the `vt_drain` option as it is read from sunshine.conf.
 */
struct VideotoolboxDrainConfigTest: testing::TestWithParam<VideotoolboxDrainConfigParam> {
  /**
   * @brief Restore the encoder configuration that was captured before the test body ran.
   */
  void TearDown() override {
    config::video = original_video;
    config::modified_config_settings = original_modified_config_settings;
  }

  config::video_t original_video {config::video};  ///< Encoder configuration restored after each parameterized test.
  decltype(config::modified_config_settings) original_modified_config_settings {config::modified_config_settings};  ///< Change tracking restored after each test.
};

TEST_P(VideotoolboxDrainConfigTest, AppliesTheConfiguredCadence) {
  const auto &[setting, expected] = GetParam();
  config::apply_config_for_test(setting);

  EXPECT_EQ(expected, config::video.vt.vt_drain);
}

INSTANTIATE_TEST_SUITE_P(
  VideotoolboxDrainValues,
  VideotoolboxDrainConfigTest,
  testing::Values(
    VideotoolboxDrainConfigParam {"vt_drain = enabled\n"sv, 1},
    VideotoolboxDrainConfigParam {"vt_drain = disabled\n"sv, 0},
    VideotoolboxDrainConfigParam {"vt_drain = 2\n"sv, 2},
    VideotoolboxDrainConfigParam {"vt_drain = 99\n"sv, 16}
  )
);
