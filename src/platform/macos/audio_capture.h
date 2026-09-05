/**
 * @file src/platform/macos/audio_capture.h
 * @brief Compatibility rules for macOS system audio selection.
 */
#pragma once

#include <string_view>

namespace platf::macos {
  /**
   * @brief Recognize the default system source and legacy case-insensitive aliases.
   * @param sink Configured audio sink; other values name an input device.
   * @return True for an empty sink, system, desktop or screencapturekit.
   */
  inline bool is_system_audio_sink(std::string_view sink) {
    if (sink.empty()) {
      return true;
    }
    for (const auto alias : {std::string_view {"system"}, std::string_view {"desktop"}, std::string_view {"screencapturekit"}}) {
      if (sink.size() != alias.size()) {
        continue;
      }
      bool equal = true;
      for (std::size_t i = 0; i < sink.size(); ++i) {
        const auto ch = sink[i] >= 'A' && sink[i] <= 'Z' ? sink[i] + ('a' - 'A') : sink[i];
        if (ch != alias[i]) {
          equal = false;
          break;
        }
      }
      if (equal) {
        return true;
      }
    }
    return false;
  }
}  // namespace platf::macos
