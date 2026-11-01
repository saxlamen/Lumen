/**
 * @file src/platform/macos/permissions.h
 * @brief Guided macOS permission checklist for the `permissions` command.
 */
#pragma once

// standard includes
#include <string>
#include <vector>

namespace platf {
  namespace macos {
    /**
     * @brief One macOS permission as the user needs to see it.
     *
     * Deliberately plain data (no callbacks): the web UI turns this straight into
     * its onboarding banner, and a header full of `std::function` would make the
     * platform boundary wider than it needs to be.
     */
    struct permission_state_t {
      std::string key;  ///< Stable identifier, also the `--report` name.
      std::string purpose;  ///< What Lumen needs the permission for.
      std::string action;  ///< What the user has to do, which is not always a switch.
      std::string pane;  ///< System Settings deep link for the matching list.
      bool granted;  ///< What macOS says right now.
    };

    /**
     * @brief Report the macOS permissions Lumen needs, live.
     *
     * The checks have to run in Lumen's own process, and they are re-read on every
     * call so a guide can notice the user flipping a switch.
     *
     * @return One entry per required permission, in the order a guide should present them.
     */
    std::vector<permission_state_t> permission_status();

    /**
     * @brief Ask for one permission, and take the user to the pane that governs it.
     *
     * macOS shows its prompt only the first time a permission is requested, so this
     * also opens the pane: without it a user who already answered "Don't Allow" once
     * has nowhere to go. Full Disk Access additionally reveals the bundle in Finder,
     * because that list has no add button.
     *
     * @param key A key from `permission_status()`; anything else is ignored.
     * @return True when the key was recognized.
     */
    bool request_permission(const std::string &key);

    /**
     * @brief Report and optionally request the macOS permissions Lumen needs.
     *
     * The checks have to run in Lumen's own process because macOS attributes a
     * permission to whichever process asks for it, not to the installation the
     * user is configuring: a probe run from a shell script reports the terminal's
     * permissions instead.
     *
     * @param argc Number of arguments following the command name.
     * @param argv Arguments following the command name: `--grant`, `--wait <s>`,
     *             `--report <path>`.
     * @return 0 when every required permission is granted, 1 otherwise.
     */
    int permission_guide(int argc, char *argv[]);
  }  // namespace macos
}  // namespace platf
