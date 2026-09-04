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
