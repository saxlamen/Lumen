/**
 * @file src/platform/macos/misc.h
 * @brief Miscellaneous declarations for macOS platform.
 */
#pragma once

// standard includes
#include <vector>

// platform includes
#include <CoreGraphics/CoreGraphics.h>

namespace platf {
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
   * @brief Check whether macOS has granted screen-capture permission.
   *
   * @return True when Sunshine can capture the screen.
   */
  bool is_screen_capture_allowed();

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
