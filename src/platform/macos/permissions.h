/**
 * @file src/platform/macos/permissions.h
 * @brief Guided macOS permission checklist for the `permissions` command.
 */
#pragma once

namespace platf {
  namespace macos {
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
