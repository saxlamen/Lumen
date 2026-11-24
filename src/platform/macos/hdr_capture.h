/**
 * @file src/platform/macos/hdr_capture.h
 * @brief Declarations for the macOS HDR capture decision and the synthesised HDR10 metadata.
 * @details macOS has no public API that puts a display into HDR mode, so the HDR state of a stream is
 *          decided by a configuration switch plus what the captured screen reports. Everything here is
 *          free of Objective-C and of ScreenCaptureKit so the decision can be unit tested; the callers
 *          in `display.mm` and `sc_capture.m` are the only places that touch the frameworks. The
 *          measurements behind the thresholds and the 100 cd/m2 white level are section 10 of
 *          `docs/macos_hdr.md`.
 */
#pragma once

// standard includes
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <string_view>

namespace platf::macos_hdr {

  /**
   * @brief The dynamic range ScreenCaptureKit is asked to capture.
   */
  enum class capture_dynamic_range_e {
    /**
     * @brief ScreenCaptureKit's own default: an SDR picture whatever the display is capable of.
     */
    sdr,

    /**
     * @brief `.hdrLocalDisplay`: a picture tuned to the host panel.
     */
    hdr_local,

    /**
     * @brief `.hdrCanonicalDisplay`: the Rec.2100 PQ reference, which is what a remote client wants.
     */
    hdr_canonical,
  };

  /**
   * @brief The configuration spelling of `capture_dynamic_range_e::sdr`.
   */
  inline constexpr std::string_view kSdrName = "sdr";

  /**
   * @brief The configuration spelling of `capture_dynamic_range_e::hdr_local`.
   */
  inline constexpr std::string_view kHdrLocalName = "hdr_local";

  /**
   * @brief The configuration spelling of `capture_dynamic_range_e::hdr_canonical`.
   */
  inline constexpr std::string_view kHdrCanonicalName = "hdr_canonical";

  /**
   * @brief BT.2020 and D65 chromaticity coordinates, unscaled.
   *
   * macOS publishes no mastering display metadata for a screen, measured in section 10.2 of
   * `docs/macos_hdr.md`, so the HDR10 mastering block has to be written from the specification instead.
   * @{
   */
  inline constexpr double kBt2020RedX = 0.708;  ///< BT.2020 red primary x.
  inline constexpr double kBt2020RedY = 0.292;  ///< BT.2020 red primary y.
  inline constexpr double kBt2020GreenX = 0.170;  ///< BT.2020 green primary x.
  inline constexpr double kBt2020GreenY = 0.797;  ///< BT.2020 green primary y.
  inline constexpr double kBt2020BlueX = 0.131;  ///< BT.2020 blue primary x.
  inline constexpr double kBt2020BlueY = 0.046;  ///< BT.2020 blue primary y.
  inline constexpr double kWhitePointX = 0.3127;  ///< D65 white point x.
  inline constexpr double kWhitePointY = 0.3290;  ///< D65 white point y.
  /**
   * @}
   */

  /**
   * @brief The denominator `SS_HDR_METADATA` chromaticity fields are normalised to.
   */
  inline constexpr double kChromaticityScale = 50000.0;

  /**
   * @brief The EDR headroom above which a screen counts as HDR capable.
   *
   * Apple reports 1.0 for a display that cannot do HDR at all, measured in section 10.1 of
   * `docs/macos_hdr.md`, so anything strictly above it is a screen that can carry HDR content.
   */
  inline constexpr double kHdrCapabilityThreshold = 1.0;

  /**
   * @brief The SDR white level a macOS screen renders, in cd/m2.
   *
   * Section 10.3 of `docs/macos_hdr.md` measures 99.9 cd/m2 for a screen with 1.0 of EDR headroom, which
   * is the 100 cd/m2 this platform is built around. It is the base of the derived mastering peak.
   */
  inline constexpr double kSdrWhiteNits = 100.0;

  /**
   * @brief The black level declared when nothing else names one, in cd/m2.
   */
  inline constexpr double kDefaultMasterBlackNits = 0.005;

  /**
   * @brief The configured value that means "not set, derive it".
   */
  inline constexpr double kUnsetMasteringValue = -1.0;

  /**
   * @brief The luminance tunables used when there is no real mastering metadata to read.
   */
  struct mastering_defaults_t {
    double max_luminance_nits;  ///< Peak luminance the content is assumed to reach, in cd/m2.
    double min_luminance_nits;  ///< Black luminance the content is assumed to reach, in cd/m2.
    std::uint16_t max_cll_nits;  ///< Maximum content light level in cd/m2; 0 suppresses the side data.
    std::uint16_t max_fall_nits;  ///< Maximum frame average light level in cd/m2; 0 suppresses it too.
  };

  /**
   * @brief Case-insensitive equality for a configuration value, ignoring surrounding whitespace.
   *
   * @param value Configuration text as read from sunshine.conf.
   * @param name The spelling to compare against.
   * @return True when `value` names `name`.
   */
  inline bool matches_name(std::string_view value, std::string_view name) {
    auto is_space = [](char ch) {
      return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';
    };

    while (!value.empty() && is_space(value.front())) {
      value.remove_prefix(1);
    }
    while (!value.empty() && is_space(value.back())) {
      value.remove_suffix(1);
    }

    if (value.size() != name.size()) {
      return false;
    }

    for (std::size_t i = 0; i < name.size(); ++i) {
      const auto lhs = value[i] >= 'A' && value[i] <= 'Z' ? (char) (value[i] - 'A' + 'a') : value[i];
      if (lhs != name[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * @brief Map a configured value to the dynamic range to request from ScreenCaptureKit.
   *
   * @param value The configured value of `capture_dynamic_range_macos`.
   * @return The named dynamic range. Anything unrecognised becomes `capture_dynamic_range_e::sdr`, so a
   *         missing or mistyped value keeps the behaviour this platform has always had.
   */
  inline capture_dynamic_range_e dynamic_range_from_view(std::string_view value) {
    if (matches_name(value, kHdrCanonicalName)) {
      return capture_dynamic_range_e::hdr_canonical;
    }
    if (matches_name(value, kHdrLocalName)) {
      return capture_dynamic_range_e::hdr_local;
    }
    return capture_dynamic_range_e::sdr;
  }

  /**
   * @brief Name a dynamic range the way the configuration file spells it.
   *
   * @param range The dynamic range to name.
   * @return The configuration spelling of `range`.
   */
  inline std::string_view to_string(capture_dynamic_range_e range) {
    switch (range) {
      case capture_dynamic_range_e::hdr_canonical:
        return kHdrCanonicalName;
      case capture_dynamic_range_e::hdr_local:
        return kHdrLocalName;
      case capture_dynamic_range_e::sdr:
        break;
    }
    return kSdrName;
  }

  /**
   * @brief Report whether a captured screen can carry HDR at all.
   *
   * @param maximum_potential_edr `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`.
   * @return True when the screen reports more than unity of potential EDR headroom.
   */
  inline bool display_can_hdr(double maximum_potential_edr) {
    return std::isfinite(maximum_potential_edr) && maximum_potential_edr > kHdrCapabilityThreshold;
  }

  /**
   * @brief Everything the HDR capture decision needs, gathered by the caller.
   *
   * The decision cannot read any of this itself: the configuration, the session, the operating system
   * and AppKit each live in a layer this header deliberately does not include.
   */
  struct hdr_capture_request_t {
    /**
     * @brief The capture dynamic range the configuration asked for.
     */
    capture_dynamic_range_e range;

    /**
     * @brief The captured screen's potential EDR headroom, 1.0 for a screen that cannot do HDR.
     */
    double maximum_potential_edr;

    /**
     * @brief Whether the running system and CPU expose ScreenCaptureKit's HDR capture.
     */
    bool platform_supports_hdr;

    /**
     * @brief Whether the client negotiated a 10 bit dynamic range for this session.
     */
    bool session_requests_10bit;
  };

  /**
   * @brief Decide whether HDR should be captured and reported for this display.
   *
   * Every gate of decision 5 in `docs/macos_hdr.md` lives here, and all of them are needed. The
   * operator has to ask for an HDR capture range. The platform has to be able to deliver one, because
   * ScreenCaptureKit's `captureDynamicRange` only exists on Apple Silicon from macOS 15. The screen
   * has to be capable of it, because an HDR capture of a screen that cannot show one is the picture
   * macOS already tone mapped to SDR. And the session has to have negotiated 10 bits, because the
   * capture hands its pixel buffer to the encoder without conversion: PQ samples in an 8 bit stream
   * would be encoded and labelled as BT.709, which is the failure the closed upstream pull requests
   * warned about. `video.cpp` checks that last condition again through
   * `colorspace_from_client_config()`; checking it here as well is what keeps the pixels themselves
   * honest.
   *
   * @param request The configuration, screen and session state the decision is made from.
   * @return True when an HDR picture should be requested from ScreenCaptureKit and reported upstream.
   */
  inline bool hdr_capture_enabled(const hdr_capture_request_t &request) {
    return request.range != capture_dynamic_range_e::sdr && request.platform_supports_hdr && display_can_hdr(request.maximum_potential_edr) && request.session_requests_10bit;
  }

  /**
   * @brief The configured overrides for the synthesised HDR10 luminances.
   *
   * These are the four `hdr_*_macos` configuration values read verbatim, so every field carries the
   * `kUnsetMasteringValue` sentinel when the operator did not name it.
   */
  struct mastering_config_t {
    double max_luminance_nits;  ///< `hdr_max_luminance_macos`; unset derives it from the screen's headroom.
    double min_luminance_nits;  ///< `hdr_min_luminance_macos`; unset uses `kDefaultMasterBlackNits`.
    double max_cll_nits;  ///< `hdr_max_cll_macos`; unset follows the peak, 0 leaves the side data out.
    double max_fall_nits;  ///< `hdr_max_fall_macos`; unset and 0 both leave it out.
  };

  /**
   * @brief Read a positive number from the environment, falling back when it is absent or malformed.
   *
   * @param name Environment variable to read.
   * @param fallback Value to use when the variable is unset, empty or not a number.
   * @return The parsed value when it is finite and non-negative, otherwise `fallback`.
   */
  inline double env_number(std::string_view name, double fallback) {
    const auto *value = std::getenv(std::string {name}.c_str());
    if (value == nullptr) {
      return fallback;
    }

    const std::string_view text {value};
    double parsed = fallback;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), parsed);
    if (result.ec != std::errc {} || result.ptr != text.data() + text.size() || !std::isfinite(parsed) || parsed < 0.0) {
      return fallback;
    }
    return parsed;
  }

  /**
   * @brief The HDR10 numbers to synthesise for a macOS screen.
   *
   * All four are resolved from three sources, most specific first: the `LUMEN_HDR_*` environment
   * variables, then the `hdr_*_macos` configuration values, then a value derived from the captured
   * screen. The environment keeps the first word because it is the knob used while measuring a client,
   * where editing sunshine.conf and relaunching costs a session.
   *
   * The derived peak is `kSdrWhiteNits` times the screen's EDR headroom, which is the brightest picture
   * the host can render: section 10.4 of `docs/macos_hdr.md` measures the capture passing that range
   * through unchanged, and section 12 measures that a client which normalises the picture by the declared
   * peak makes the whole frame darker, SDR desktop included, when the peak is declared above what the
   * content reaches. Deriving it from the screen is what keeps that from being a constant copied from a
   * panel on another platform, and it can never over-declare.
   *
   * A content light level larger than the declared peak is content that cannot exist, so it is clamped to
   * the peak. 0 keeps its existing meaning of leaving that side data out of the stream.
   *
   * @param maximum_potential_edr The captured screen's potential EDR headroom. A screen that cannot do
   *        HDR reports 1.0 and a value that is not a number is treated the same way, so the derived peak
   *        is then the SDR white itself.
   * @param config The configured overrides, with `kUnsetMasteringValue` where nothing was set.
   * @return The luminances to declare, in cd/m2.
   */
  inline mastering_defaults_t mastering_defaults(double maximum_potential_edr, const mastering_config_t &config) {
    const double headroom = display_can_hdr(maximum_potential_edr) ? maximum_potential_edr : 1.0;

    // A whole number of nits, because this is written into a uint16_t field downstream and a fraction
    // here would only make the log line harder to read.
    const double derived_max_luminance = std::llround(kSdrWhiteNits * headroom);

    const double max_luminance = env_number("LUMEN_HDR_MAX_LUMINANCE", config.max_luminance_nits >= 0.0 ? config.max_luminance_nits : derived_max_luminance);
    const double min_luminance = env_number("LUMEN_HDR_MIN_LUMINANCE", config.min_luminance_nits >= 0.0 ? config.min_luminance_nits : kDefaultMasterBlackNits);

    // Unset content statistics follow the peak or stay out of the stream; an explicit 0 stays 0, which
    // is how the side data is suppressed for a client that handles the metadata badly.
    const double configured_cll = config.max_cll_nits >= 0.0 ? config.max_cll_nits : max_luminance;
    const double configured_fall = config.max_fall_nits >= 0.0 ? config.max_fall_nits : 0.0;

    const double max_cll = env_number("LUMEN_HDR_MAX_CLL", configured_cll);
    const double max_fall = env_number("LUMEN_HDR_MAX_FALL", configured_fall);

    auto to_level = [max_luminance](double value) {
      if (value > max_luminance) {
        value = max_luminance;
      }
      if (value > UINT16_MAX) {
        value = UINT16_MAX;
      }
      return (std::uint16_t) std::llround(value);
    };

    return mastering_defaults_t {
      .max_luminance_nits = max_luminance,
      .min_luminance_nits = min_luminance,
      .max_cll_nits = to_level(max_cll),
      .max_fall_nits = to_level(max_fall),
    };
  }

  /**
   * @brief Scale an unscaled chromaticity coordinate pair into the `SS_HDR_METADATA` form.
   *
   * @param x Chromaticity x coordinate, where BT.2020 red is 0.708.
   * @param y Chromaticity y coordinate, where BT.2020 red is 0.292.
   * @param out_x Scaled x coordinate, written on return.
   * @param out_y Scaled y coordinate, written on return.
   * @details The outputs are the coordinates multiplied by `kChromaticityScale` and rounded, clamped
   *          into the range a `uint16_t` can carry. A coordinate that is not a finite number becomes 0,
   *          which is how `video.cpp` decides there are no primaries to write and leaves the mastering
   *          block out of the stream.
   */
  inline void scale_chromaticity(double x, double y, std::uint16_t &out_x, std::uint16_t &out_y) {
    auto scale_one = [](double coordinate) {
      if (!std::isfinite(coordinate)) {
        return (std::uint16_t) 0;
      }

      const auto scaled = std::llround(coordinate * kChromaticityScale);
      if (scaled <= 0) {
        return (std::uint16_t) 0;
      }
      if (scaled > UINT16_MAX) {
        return (std::uint16_t) UINT16_MAX;
      }
      return (std::uint16_t) scaled;
    };

    out_x = scale_one(x);
    out_y = scale_one(y);
  }

}  // namespace platf::macos_hdr
