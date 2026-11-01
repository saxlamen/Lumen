/**
 * @file src/platform/macos/permissions.mm
 * @brief Guided macOS permission checklist for the `permissions` command.
 */

// standard includes
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <fstream>
#include <functional>
#include <iostream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

// system includes
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>

// local includes
#include "src/logging.h"
#include "src/platform/common.h"
#include "src/platform/macos/misc.h"
#include "src/platform/macos/permissions.h"

using namespace std::literals;

namespace platf {
  namespace macos {
    namespace {
      // The permission lists are addressed by their security preference anchors,
      // which is the only supported way to land the user on the right one.
      constexpr std::string_view k_pane_screen_capture {"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"};
      constexpr std::string_view k_pane_accessibility {"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"};
      constexpr std::string_view k_pane_full_disk_access {"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"};

      /**
       * @brief Full Disk Access has no query API, so probe a protected file.
       *
       * The system TCC database lives outside this process's container: without
       * the permission the kernel answers EPERM rather than ENOENT, and with it the
       * file opens normally. Anything else is reported as missing, because a
       * permission we did not observe is not one worth claiming.
       *
       * @return True when this process can read files outside its container.
       */
      bool full_disk_access_allowed() {
        int fd = ::open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
          ::close(fd);
          return true;
        }

        return false;
      }

      /**
       * @brief Ask macOS for Accessibility, which is what CGEvent posting needs.
       *
       * The prompt option both shows the dialog and registers this executable in
       * the list, which is what makes the entry appear for the user to switch on.
       */
      void request_accessibility() {
        const void *keys[] {kAXTrustedCheckOptionPrompt};
        const void *values[] {kCFBooleanTrue};
        auto options = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (options != nullptr) {
          AXIsProcessTrustedWithOptions(options);
          CFRelease(options);
        }
      }

      /**
       * @brief Reveal the app bundle, or the bare binary, in Finder.
       *
       * Full Disk Access has no add button, so the only way to register an app is
       * to drag it into the list; this selects the thing to drag. A bundle's
       * executable is not the thing, so the enclosing .app is selected instead.
       *
       * @param executable Path of the running executable.
       */
      void reveal_installation(const std::string &executable) {
        if (executable.empty()) {
          return;
        }

        std::string target {executable};
        auto macos_dir = target.rfind("/Contents/MacOS/");
        if (macos_dir != std::string::npos) {
          auto bundle_end = target.rfind('/', macos_dir);
          if (bundle_end != std::string::npos) {
            target.resize(bundle_end);
          }
        }

        auto *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:target.c_str()]];
        if (url != nullptr) {
          [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
        }
      }

      /**
       * @brief One permission, described the same way for every output channel.
       */
      struct permission_t {
        std::string key;  ///< Stable name written to `--report` files.
        std::string name;  ///< Short menu label, using the name macOS shows for it.
        std::string purpose;  ///< What Lumen needs this permission for.
        std::string pane;  ///< System Settings deep link for the matching list.
        std::string action;  ///< What the user must do, which is not always flipping a switch.
        std::function<bool()> granted;  ///< Live check, re-read on every poll.
        std::function<void()> ask;  ///< Nudge macOS to prompt or register the entry.
      };
    }  // namespace

    namespace {
      /**
       * @brief The one list of permissions Lumen needs, shared by every caller.
       *
       * Input Monitoring is deliberately absent even though the upstream macOS notes
       * mention it: this code posts events with CGEventPost, which needs Accessibility,
       * and nothing in the tree opens an IOHID listen reference. Listing a permission
       * the app never asks for sends the user to a System Settings list with no entry in
       * it, which reads as a broken app.
       *
       *
       * The `permissions` command, the tray menu and the web UI banner all read this
       * same list, so a permission cannot be described in one place and forgotten in
       * another - and the order is the order a guide walks through.
       *
       * @return The permission list.
       */
      const std::vector<permission_t> &required_permissions() {
        static const std::vector<permission_t> permissions {
          permission_t {
            "screen_capture",
            "Screen Recording",
            "capture the desktop for the video stream",
            std::string {k_pane_screen_capture},
            "switch Sunshine/Lumen on in the list",
            [] {
              return platf::is_screen_capture_allowed();
            },
            [] {
              platf::request_screen_capture_access();
            }
          },
          permission_t {
            "accessibility",
            "Accessibility",
            "post keyboard, mouse and scroll events",
            std::string {k_pane_accessibility},
            "switch Sunshine/Lumen on in the list",
            [] {
              return AXIsProcessTrusted() != 0;
            },
            [] {
              request_accessibility();
            }
          },
          permission_t {
            "full_disk_access",
            "Full Disk Access",
            "enumerate displays; without it the display list comes back empty",
            std::string {k_pane_full_disk_access},
            "drag the app (selected in Finder) into the list, then switch it on",
            full_disk_access_allowed,
            [] {
            }
          }
        };
        return permissions;
      }

      /**
       * @brief The executable this process was started from.
       *
       * macOS attributes permissions to that path (or its bundle), and Full Disk
       * Access needs the user to drag exactly that file into a list.
       *
       * @return The path, or an empty string if the system would not say.
       */
      std::string current_executable() {
        char executable_path[PATH_MAX] {};
        uint32_t executable_size = sizeof(executable_path);
        if (_NSGetExecutablePath(executable_path, &executable_size) != 0) {
          executable_path[0] = '\0';
        }

        return std::string {executable_path};
      }

      /**
       * @brief A stamp identifying this installation of the app.
       *
       * macOS ties a permission decision to the signed identity, so rebuilding or
       * re-signing the bundle resets what has to be granted. The executable's modification
       * time is enough to tell "the guide already ran for this build" from "this is a new
       * build and the permissions underneath it changed".
       *
       * @return A stamp for the current executable, or empty if it cannot be read.
       */
      std::string installation_stamp() {
        const auto path = current_executable();
        struct stat info {};
        if (path.empty() || ::stat(path.c_str(), &info) != 0) {
          return {};
        }

        return std::format("{}:{}", path, static_cast<long long>(info.st_mtime));
      }

      /**
       * @brief Where the "the guide already ran" stamp is kept.
       *
       * Next to `sunshine.conf`, because that is the directory the user's permissions and
       * settings already live in, and removing it is a way out for anyone who wants the
       * first-run behaviour back.
       *
       * @return The path, or empty when there is no home directory to put it in.
       */
      std::string guide_stamp_path() {
        const char *xdg = std::getenv("XDG_CONFIG_HOME");
        const char *home = std::getenv("HOME");

        std::string dir;
        if (xdg != nullptr && xdg[0] != '\0') {
          dir = xdg;
        } else if (home != nullptr && home[0] != '\0') {
          dir = std::string {home} + "/.config";
        }

        return dir.empty() ? std::string {} : dir + "/sunshine/permission-guide.stamp";
      }
    }  // namespace

    void ask_missing_permissions() {
      for (const auto &entry : required_permissions()) {
        // Screen Recording is left out: asking a live server for it makes AppKit tear
        // the UI down while it waits for a relaunch the ask does not cause, and the
        // capture path already asks for it during startup, before the tray exists.
        if (entry.key == "screen_capture" || entry.granted()) {
          continue;
        }

        entry.ask();
      }
    }

    void guide_missing_permissions_on_first_run() {
      // Only the .app has a first run to guide: a Homebrew service or a terminal run
      // would otherwise throw System Settings at a headless start on every boot.
      if (current_executable().find("/Contents/MacOS/") == std::string::npos) {
        return;
      }

      std::string missing_key;
      std::string missing_pane;
      for (const auto &entry : required_permissions()) {
        if (entry.granted()) {
          continue;
        }

        missing_key = entry.key;
        missing_pane = entry.pane;
        break;
      }

      if (missing_key.empty()) {
        return;
      }

      // Once per install, because macOS only prompts the first time anyway and a pane
      // that reappears every launch stops being guidance and becomes a nag. The stamp is
      // the executable itself, so a rebuild - which resets the permissions underneath the
      // user - earns a fresh guide.
      const auto stamp = installation_stamp();
      const auto stamp_path = guide_stamp_path();
      if (!stamp.empty() && !stamp_path.empty()) {
        std::ifstream existing {stamp_path};
        std::string stored;
        if (existing && std::getline(existing, stored) && stored == stamp) {
          BOOST_LOG(info) << "macOS permissions are still missing and the guide already ran for this install, not opening System Settings again"sv;
          return;
        }
      }

      BOOST_LOG(info) << "First run with a missing macOS permission ("sv << missing_key << "), opening its settings pane";
      platf::open_url(missing_pane);
      if (missing_key == "full_disk_access") {
        reveal_installation(current_executable());
      }

      if (!stamp.empty() && !stamp_path.empty()) {
        std::error_code ec;
        std::filesystem::create_directories(std::filesystem::path {stamp_path}.parent_path(), ec);
        std::ofstream handle {stamp_path};
        if (handle) {
          handle << stamp;
        }
      }
    }

    std::vector<permission_state_t> permission_status() {
      std::vector<permission_state_t> status;
      for (const auto &entry : required_permissions()) {
        status.push_back(permission_state_t {entry.key, entry.name, entry.purpose, entry.action, entry.pane, entry.granted()});
      }

      return status;
    }

    bool request_permission(const std::string &key, const bool prompt) {
      for (const auto &entry : required_permissions()) {
        if (entry.key != key) {
          continue;
        }

        if (prompt) {
          entry.ask();
        }
        platf::open_url(entry.pane);
        if (entry.key == "full_disk_access") {
          reveal_installation(current_executable());
        }

        return true;
      }

      return false;
    }

    int permission_guide(int argc, char *argv[]) {
      bool grant = false;
      int wait_seconds = 300;  // per permission: dragging into a list takes a while
      std::string report_path;

      for (int x = 0; x < argc; ++x) {
        std::string arg {argv[x]};
        if (arg == "--grant") {
          grant = true;
        } else if (arg.rfind("--wait=", 0) == 0) {
          wait_seconds = std::atoi(arg.c_str() + 7);
        } else if (arg == "--wait" && x + 1 < argc) {
          wait_seconds = std::atoi(argv[++x]);
        } else if (arg.rfind("--report=", 0) == 0) {
          report_path = arg.substr(9);
        } else if (arg == "--report" && x + 1 < argc) {
          report_path = argv[++x];
        } else {
          std::cout << "usage: lumen --permissions [--grant] [--wait <seconds per item>] [--report <path>]"sv << std::endl;
          return 2;
        }
      }
      if (wait_seconds < 1) {
        wait_seconds = 1;
      }

      const auto &permissions = required_permissions();
      std::string executable = current_executable();

      // Everything is echoed to the log as well: `open -na Sunshine --args
      // permissions` has no terminal attached, so stdout alone would be lost.
      auto say = [](const std::string &line) {
        std::cout << line << std::endl;
        // The log mirrors stdout only when there is no terminal, because the log
        // sink also echoes to stdout: attached runs would print everything twice,
        // while `open -na` runs have no stdout to read and need the log instead.
        if (!::isatty(STDOUT_FILENO)) {
          BOOST_LOG(info) << line;
        }
      };

      auto snapshot = [&]() {
        std::vector<bool> states;
        states.reserve(permissions.size());
        for (const auto &entry : permissions) {
          states.push_back(entry.granted());
        }
        return states;
      };

      auto all_granted = [](const std::vector<bool> &states) {
        for (bool state : states) {
          if (!state) {
            return false;
          }
        }
        return true;
      };

      auto write_report = [&](const std::vector<bool> &states, const std::string &active = {}, bool finished = false) {
        if (report_path.empty()) {
          return;
        }
        std::string body;
        if (finished) {
          // The wrapper script cannot tell whether this process is still guiding by
          // looking at the process list, so the last report says so itself.
          body += "done=1\n";
        }
        if (!active.empty()) {
          // The guide is a process the user cannot see output from, while the
          // wrapper script is the thing they are watching: this line tells the
          // script which permission the user should be switching on right now.
          body += "active=" + active + "\n";
        }
        for (std::size_t x = 0; x < permissions.size(); ++x) {
          body += permissions[x].key;
          body += states[x] ? "=granted\n" : "=missing\n";
        }
        auto temp = report_path + ".tmp";
        auto *handle = std::fopen(temp.c_str(), "w");
        if (handle != nullptr) {
          std::fwrite(body.data(), 1, body.size(), handle);
          std::fclose(handle);
          std::rename(temp.c_str(), report_path.c_str());
        }
      };

      auto print = [&](const std::vector<bool> &states) {
        say("");
        say("macOS permissions for Lumen");
        for (std::size_t x = 0; x < permissions.size(); ++x) {
          say(std::string {states[x] ? "  [ok]   " : "  [need] "} + permissions[x].key + " - " + permissions[x].purpose);
        }
      };

      auto states = snapshot();
      print(states);
      say("");
      say("  attributed to: " + (executable.empty() ? std::string {"<unknown>"} : executable));
      say("  macOS attributes a permission to the process that asks for it, so this is the");
      say("  install that ran the command. A run from a terminal is attributed to the");
      say("  terminal app itself; for the .app bundle run it as the app instead:");
      say("    open -na Sunshine --args --permissions --grant");

      if (!grant) {
        for (std::size_t x = 0; x < permissions.size(); ++x) {
          if (states[x]) {
            continue;
          }
          say("");
          say("  " + permissions[x].key + ": " + permissions[x].action);
          say("    " + permissions[x].pane);
        }
        write_report(states);
        return all_granted(states) ? 0 : 1;
      }

      say("");
      say("  macOS shows the prompt only the first time a permission is asked for, so if");
      say("  no dialog appears, switch it on in the pane that opens - it opens one pane at");
      say("  a time and waits for that one before moving on.");

      for (std::size_t x = 0; x < permissions.size(); ++x) {
        states = snapshot();
        if (states[x]) {
          continue;
        }

        say("");
        say("-- " + permissions[x].key + ": " + permissions[x].purpose);
        say("   " + permissions[x].action);
        say("   " + permissions[x].pane);

        permissions[x].ask();
        platf::open_url(permissions[x].pane);
        if (permissions[x].key == "full_disk_access") {
          reveal_installation(executable);
        }

        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds {wait_seconds};
        while (!states[x] && std::chrono::steady_clock::now() < deadline) {
          std::this_thread::sleep_for(std::chrono::seconds {1});
          states = snapshot();
          write_report(states, permissions[x].key);
        }

        if (states[x]) {
          say("   [ok] granted");
        } else {
          say("   [skip] still missing after " + std::to_string(wait_seconds) + "s, moving on");
        }
      }

      states = snapshot();
      write_report(states, {}, true);
      print(states);
      say("");
      if (all_granted(states)) {
        say("all permissions granted. A running process keeps the permissions it started");
        say("with, so start Lumen now - the menu bar icon appears only once it is running,");
        say("and an instance that was already running has to be quit and opened again.");
        return 0;
      }

      say("still missing. Open System Settings > Privacy & Security for the names above;");
      say("if an entry is listed but switched off, switch it on - macOS may ask you to quit");
      say("Lumen first, in which case quit, switch, start it again and run this once more.");
      return 1;
    }
  }  // namespace macos
}  // namespace platf
