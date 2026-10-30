#pragma once

#include <cstdint>

namespace platf::macos {
  void init_smooth_scroll();
  void shutdown_smooth_scroll();
  void scroll(int high_res_distance);
  void hscroll(int high_res_distance);
}
