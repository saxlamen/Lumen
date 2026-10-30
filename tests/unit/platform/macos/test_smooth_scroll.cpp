/**
 * @file tests/unit/platform/macos/test_smooth_scroll.cpp
 * @brief Unit tests for macOS smooth-scrolling velocity and burst clamping.
 */
#ifdef __APPLE__
  #include "../../../tests_common.h"
  #include "src/platform/macos/smooth_scroll.h"

/**
 * @brief Verify that the first sample of a gesture uses a conservative initial velocity.
 */
TEST(MacosSmoothScroll, FreshGestureInitialVelocityIsConservative) {
  const double v_down = platf::macos::update_scroll_velocity(0.0, -22, 0.00002, false);
  EXPECT_LT(v_down, 0.0);
  EXPECT_GT(v_down, -600.0);

  const double v_up = platf::macos::update_scroll_velocity(500.0, 22, 0.12, true);
  EXPECT_GT(v_up, 0.0);
  EXPECT_LT(v_up, 600.0);
}

/**
 * @brief Verify that zero-pixel events preserve velocity during an active gesture and reset on fresh gestures.
 */
TEST(MacosSmoothScroll, ZeroDeltaPreservesActiveAxisVelocity) {
  EXPECT_DOUBLE_EQ(platf::macos::update_scroll_velocity(420.0, 0, 0.008, true), 420.0);
  EXPECT_DOUBLE_EQ(platf::macos::update_scroll_velocity(420.0, 0, 0.0, false), 0.0);
  EXPECT_DOUBLE_EQ(platf::macos::update_scroll_velocity(420.0, 0, 0.2, true), 0.0);
}

/**
 * @brief Verify that microsecond packet bursts do not cause runaway inertia velocity spikes.
 */
TEST(MacosSmoothScroll, MicrosecondPacketBurstsDoNotExplodeVelocity) {
  double velocity = platf::macos::update_scroll_velocity(0.0, -20, 0.0, false);
  for (int i = 0; i < 10; ++i) {
    // Simulate coalesced packets arriving 20 microseconds apart.
    velocity = platf::macos::update_scroll_velocity(velocity, -20, 0.00002, true);
  }
  EXPECT_LT(velocity, 0.0);
  EXPECT_GE(velocity, -2800.0);
  EXPECT_GT(velocity, -800.0);
}

/**
 * @brief Verify that reversing scroll direction cancels opposing momentum immediately.
 */
TEST(MacosSmoothScroll, DirectionReversalCancelsOpposingMomentum) {
  const double downward = platf::macos::update_scroll_velocity(-1200.0, -24, 0.008, true);
  EXPECT_LT(downward, -1200.0);

  const double reversed_up = platf::macos::update_scroll_velocity(downward, 16, 0.008, true);
  EXPECT_GT(reversed_up, 0.0);

  const double reversed_down = platf::macos::update_scroll_velocity(reversed_up, -16, 0.008, true);
  EXPECT_LT(reversed_down, 0.0);
}

/**
 * @brief Verify that continuous high-speed flicks are clamped to the maximum inertia ceiling.
 */
TEST(MacosSmoothScroll, HighSpeedContinuousScrollingClampsAtCeiling) {
  double velocity_pos = 0.0;
  double velocity_neg = 0.0;
  for (int i = 0; i < 20; ++i) {
    velocity_pos = platf::macos::update_scroll_velocity(velocity_pos, 120, 0.008, i > 0);
    velocity_neg = platf::macos::update_scroll_velocity(velocity_neg, -120, 0.008, i > 0);
  }
  EXPECT_DOUBLE_EQ(velocity_pos, 2800.0);
  EXPECT_DOUBLE_EQ(velocity_neg, -2800.0);
}
#endif
