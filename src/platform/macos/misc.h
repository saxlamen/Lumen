/**
 * @file src/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <vector>

// local includes
#include "src/platform/permissions.h"

namespace platf {
  /**
   * @brief Action to take when a macOS privacy permission is unavailable.
   */
  enum class permission_request_action_t {
    none,  ///< No startup action is needed after an earlier request.
    prompt,  ///< Ask macOS for the native permission.
    settings,  ///< Open the permission's settings pane.
  };

  /**
   * @brief Choose a privacy action without repeating a macOS startup prompt.
   *
   * @param granted Whether the native preflight check reports access.
   * @param previous_state Zero before a request, one after a request, or two after a grant.
   * @param startup Whether this action is part of automatic startup checks.
   * @param retry_manual_request Whether a user-initiated action should retry the native request.
   * @return The action to perform.
   */
  permission_request_action_t permission_request_action(bool granted, int previous_state, bool startup, bool retry_manual_request);

  /**
   * @brief Check whether the macOS version has Local Network privacy controls.
   *
   * @param major_version macOS major version number.
   * @return True on macOS 15 and newer.
   */
  bool supports_local_network_privacy(int major_version);

  /**
   * @brief Decide whether startup should initiate a native permission request.
   *
   * @param permission Permission status and requirement for the active configuration.
   * @param notifications_enabled Whether the system tray uses notifications.
   * @return True when a missing permission should be requested.
   */
  bool should_request_startup_permission(const permission_status_t &permission, bool notifications_enabled);

  /**
   * @brief Request missing permissions needed at startup.
   *
   * @param notifications_enabled Whether the running build shows tray notifications.
   */
  void request_startup_permissions(bool notifications_enabled);

  /**
   * @brief Probe system audio once on startup when no custom sink is configured.
   *
   * The operating system has no passive tap authorization query. Later streams
   * may request access again if the user removes permission.
   */
  void request_startup_system_audio_permission();

  /**
   * @brief Decide whether a one-time startup system audio probe is due.
   *
   * @param has_custom_sink Whether Sunshine uses a custom audio sink.
   * @param previously_requested Whether a startup probe was already attempted.
   * @return True only for the first native system audio startup probe.
   */
  bool should_request_startup_system_audio_permission(bool has_custom_sink, bool previously_requested);

  /**
   * @brief Start and stop an unmuted Core Audio tap to request system audio access.
   *
   * @return True when the temporary tap started successfully.
   */
  bool request_system_audio_permission();

  /**
   * @brief Check whether macOS has granted screen-capture permission.
   *
   * @return True when Sunshine can capture the screen.
   */
  bool is_screen_capture_allowed();

  /**
   * @brief Whether this system can register the application as a login item.
   *
   * @return True on systems with the login-item registration API, false on older macOS.
   */
  bool autostart_supported();

  /**
   * @brief Whether macOS is set to start this application at login.
   *
   * @return True when the login-item registration is enabled.
   */
  bool autostart_enabled();

  /**
   * @brief Turn the login-item registration for this application on or off.
   *
   * Only a bundle can be registered, so this does nothing for a command line build.
   *
   * @param enabled True to start at login.
   * @return True when macOS accepted the change.
   */
  bool set_autostart_enabled(bool enabled);

  /**
   * @brief Start this application at login the first time an installation runs.
   *
   * The default is on, and it is claimed once per installation so that turning it off sticks
   * until the application is reinstalled or rebuilt.
   */
  void ensure_autostart_default();

  /**
   * @brief Start answering the quit requests macOS sends before relaunching an application.
   *
   * System Settings asks for a quit right after granting a permission, then relaunches the app,
   * which is the only way Screen Recording takes effect. Left to Qt's application delegate that
   * request is cancelled, which leaves the process running with its menu bar icon already gone.
   * Must be called from the thread that owns the tray.
   */
  void handle_quit_requests();

  /**
   * @brief Ask macOS for screen-capture permission, prompting the user.
   *
   * This both shows the system dialog and registers the executable in the
   * Screen Recording list, which is what lets the user switch it on. The result
   * has to be re-read with is_screen_capture_allowed() afterwards, because the
   * user may dismiss the dialog or grant it later.
   */
  void request_screen_capture_access();
}  // namespace platf

namespace dyn {
  typedef void (*apiproc)();

  /**
   * @brief Load persisted state from its backing store.
   *
   * @param handle Native library or object handle used by the operation.
   * @param funcs Function table populated from the loaded library.
   * @param strict Whether missing functions should be treated as an error.
   * @return 0 when all required symbols are loaded; nonzero when loading fails.
   */
  int load(void *handle, const std::vector<std::tuple<apiproc *, const char *>> &funcs, bool strict = true);
  /**
   * @brief Return the native handle owned by the wrapper.
   *
   * @param libs List of libraries to probe for the requested symbol.
   * @return Native dynamic-library handle, or nullptr when no library can be opened.
   */
  void *handle(const std::vector<const char *> &libs);

}  // namespace dyn
