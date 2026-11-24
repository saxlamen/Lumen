#pragma once

#include <cstdint>

namespace platf::macos {
  /**
   * @brief Start the macOS smooth-scroll worker.
   */
  void init_smooth_scroll();

  /**
   * @brief Stop the macOS smooth-scroll worker and wait for it to exit.
   */
  void shutdown_smooth_scroll();

  /**
   * @brief Compute the updated scroll inertia velocity for one axis.
   *
   * Clamps sub-frame packet burst intervals, resets opposing momentum on
   * direction reversals or idle gaps, and bounds the maximum coasting speed.
   *
   * @param current_velocity Previous axis velocity in pixels per second.
   * @param delta_pixels Current event displacement in pixels, fraction included.
   * @param sample_dt Elapsed seconds since the previous scroll event.
   * @param had_scroll Whether an active scroll gesture was already in progress.
   * @return Updated axis velocity in pixels per second.
   */
  double update_scroll_velocity(
    double current_velocity,
    double delta_pixels,
    double sample_dt,
    bool had_scroll
  );

  /**
   * @brief Submit a vertical high-resolution scroll distance.
   * @param high_res_distance Scroll distance in protocol units.
   */
  void scroll(int high_res_distance);

  /**
   * @brief Submit a horizontal high-resolution scroll distance.
   * @param high_res_distance Scroll distance in protocol units.
   */
  void hscroll(int high_res_distance);
}
