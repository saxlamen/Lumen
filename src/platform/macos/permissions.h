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
      std::string name;  ///< Short label for a menu, matching the name macOS uses.
      std::string purpose;  ///< What Lumen needs the permission for.
      std::string action;  ///< What the user has to do, which is not always a switch.
      std::string pane;  ///< System Settings deep link for the matching list.
      bool granted;  ///< What macOS says right now.
    };

    /**
     * @brief Ask macOS for the missing permissions that can be asked safely here.
     *
     * Called during startup, before the tray exists: asking is what puts an entry in the
     * relevant System Settings list at all, so without it a first-time user is sent
     * looking for a switch that has no reason to be there yet. macOS shows the prompt
     * only the first time, so this stays quiet on later runs while still registering the
     * app for anyone who denied it earlier.
     */
    void ask_missing_permissions();

    /**
     * @brief Open one missing permission's settings pane, once per install.
     *
     * The startup ask registers the entries, but a first-time user still has to know to
     * open System Settings at all. This opens the pane for the first permission that is
     * missing - one pane, because System Settings reuses a single window - and only for
     * the .app bundle, so a service run does not open a GUI on every boot. A stamp file
     * beside `sunshine.conf` keeps it to once per install: macOS prompts only the first
     * time anyway, and a pane that returns every launch is a nag rather than guidance.
     * The stamp is the executable, so a rebuild, which resets the permissions, earns a
     * fresh guide.
     */
    void guide_missing_permissions_on_first_run();

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
     * @param prompt Whether to ask macOS as well, or only open the pane.
     *
     *             Callers inside the running server have to pass `false` for
     *             Screen Recording: it is the one permission that only applies to a
     *             process that starts over, so asking again from a live server makes
     *             AppKit tear the UI down while it waits for a relaunch that the ask
     *             itself does not cause. Measured twice: asking it in-process took the
     *             menu bar item away and left the server running behind it, while
     *             asking Accessibility and Input Monitoring in-process was fine. The
     *             server already asks for Screen Recording on startup, so the entry is
     *             in the list by then, and the pane's "+" covers the rest.
     * @return True when the key was recognized.
     */
    bool request_permission(const std::string &key, bool prompt = true);

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
