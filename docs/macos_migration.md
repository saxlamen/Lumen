/**
 * @file docs/macos_migration.md
 * @brief macOS migration and validation notes for the updated Lumen streaming host.
 */

# Migrating Lumen on macOS

Use macOS 14.2 or newer. Keep a copy of your existing binary and
`~/.config/sunshine` before replacing an installation. Pairing state, credentials,
`apps.json`, and `sunshine.conf` remain in that configuration directory.
Stop the existing Lumen process or its login service before starting another build.

## Audio and desktop input

An empty `audio_sink`, or the legacy case-insensitive aliases `system`, `desktop`,
and `screencapturekit`, selects system audio. The host first tries Core Audio's
system tap, then ScreenCaptureKit if tap initialization fails. Explicit device
names still select an AVFoundation input, such as BlackHole.

Core Audio honors the client's host-audio playback setting. ScreenCaptureKit
fallback cannot mute the Mac's speakers and logs that limitation when muting was
requested. Neither backend succeeding leaves audio unavailable and reports an error.

The captured cursor is visible by default, matching the previous Lumen release.
An explicit `show_cursor = false` remains supported. Smooth scrolling is enabled
by default; set `macos_smooth_scrolling = disabled` to use the regular input backend.
Scroll packets do not distinguish a trackpad from a mouse wheel and do not carry
finger-contact notifications. Host-generated inertia is consequently shared across
scroll devices; client-generated inertia still needs a real-device compatibility check.

## Controllers

The `auto` controller mode attempts the existing native Xbox-style virtual HID
implementation. macOS may deny virtual HID creation depending on system permissions
and entitlements. In that case Lumen falls back to the previous keyboard/mouse
emulation and explicitly logs the selected mode. The fallback does not appear as a
real controller in games; it maps controller input to keyboard and mouse events.
No system security settings are changed by Lumen.

Native reports carry buttons, d-pad, sticks and triggers. Rumble, controller touch,
motion and battery reporting are not implemented by this backend. Disconnecting an
emulated controller releases held keys and mouse buttons.

## Building and installing

The old `install.sh` and repository-local formula are replaced by the macOS build
script and CMake install rules. From the repository root, build a local unsigned
app and DMG using:

```sh
./scripts/macos_build.sh --skip-codesign
```

The script uses `cmake-build-macos-app`. Signing a distributable build still requires
your own Developer ID and notarization credentials; a local build is not notarized.
Do not reuse an old launch service's executable path without checking the new layout.

For a CLI/Homebrew-style CMake build, keep `SUNSHINE_BUILD_HOMEBREW=ON` and install
with your chosen prefix. Both `lumen` and `vd_helper` are installed in its `bin`
directory. The `.app` layout keeps `vd_helper` in `Contents/MacOS` beside the host
executable. Bundle builds copy the helper into the build-tree app too, and signed
packages sign the helper before signing the enclosing app.

After changing the executable or app bundle, check Screen Recording and
Accessibility permissions for the new installation in macOS System Settings.

## First-run permissions

macOS gates four things Lumen needs, and grants them per process rather than per installation:
Screen Recording (the video stream), Accessibility (posting keyboard, mouse and scroll events),
Input Monitoring (creating the virtual HID devices) and Full Disk Access (enumerating displays -
without it the display list comes back empty and nothing explains why).

    lumen --permissions                 # report
    lumen --permissions --grant         # ask, open the right pane, wait for you
    lumen --permissions --report <path> # key=granted|missing, for scripts

Note the leading dashes. The argument parser reads a bare word as a configuration file path, so
`lumen permissions` creates an empty file called `permissions` - inside an app bundle that file lands
in `Contents/MacOS/`, and the next code-signing step refuses to sign the bundle because of it.

The check has to run inside Lumen's own process, because macOS attributes a permission to whichever
process asked for it. A probe written in a shell script reports the shell's permissions, which is the
same effect the service log used to show when it printed `TCC permission granted to the calling
process: /opt/homebrew/bin/bash`. `--grant` asks each missing permission of the system, opens the
matching System Settings pane, and re-reads the states once a second until they flip or `--wait`
expires. Full Disk Access is the odd one out: it has no query API (the probe opens the system TCC
database and reads the EPERM) and no request API, so the guide reveals the app in Finder to be dragged
into a list that has no add button. `--report` exists because an app started with `open -na` has no
stdout for a script to read.

`tools/macos-setup/lumen-permissions.command` wraps it as a double-clickable guide for people who
should not have to remember any of the above: it prefers `/Applications/Sunshine.app` and runs the
probe as the app itself, so the answer belongs to the app.

Two properties of macOS permissions read as bugs unless they are documented, so the guide says both:

- A process keeps the set it started with, so Lumen has to be restarted after granting anything.
- TCC identifies the binary, not the display name, so `brew upgrade`, reinstalling the DMG, or
  re-signing with a different identity silently resets the grants.

## Launch service timer quality

The LaunchAgent that runs `lumen` must declare `ProcessType` = `Interactive`:

```sh
/usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" \
  ~/Library/LaunchAgents/sh.brew.lumen.plist
```

Agents that do not declare themselves interactive are treated as background jobs and macOS
coalesces their timer wakeups. Measured on an 8ms `mach_wait_until` deadline: 26ms median
oversleep without the key and 2ms with it, while the same code in a process started from a
terminal overslept by 2ms. That throttling is invisible except as stutter, because the scroll
inertia loop runs on a fixed frame schedule and simply drops to ~30Hz. Homebrew regenerates the
plist on every `brew services` call and its service DSL has no `ProcessType` key, so `build.sh`
re-adds it after each start; a manual `brew reinstall` followed by a raw `launchctl bootstrap`
without the key loses it again.

The startup log records what the process actually achieved, which is the quickest way to tell
whether the key is in effect:

```
macOS inertia timer calibration [16 x 8ms mach_wait_until, this thread] median_oversleep=2.0ms
```

A value near 2ms means the schedule is healthy. Anything above 10ms means the service lost the
key.

## Release DMG

`scripts/macos_build.sh` builds the `.app` bundle and packages it with CPack into
`cmake-build-macos-app/cpack_artifacts/Sunshine.dmg` (the archive name is hardcoded there). Four
things about it are not obvious:

- **Signing identity.** Notarization requires a `Developer ID Application` certificate; an `Apple
  Development` or `Apple Distribution` identity will not do. The keychain profile used for the
  submission is named in the script, so create it with exactly that name:

  ```sh
  xcrun notarytool store-credentials notarytool-password \
    --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
  ```

- **It must run in a GUI login session.** The DragNDrop generator drives Finder through
  `src_assets/macos/build/dmg-finder-layout.applescript` to lay out the window. In a background
  launchd session, which is what `launchctl managername` reports as `Background`, that AppleScript
  hangs after the raw image has been written: observed with a 117MB `temp.dmg` already on disk and
  `osascript` waiting forever. `tools/macos-dmg/lumen-dmg.command` checks the session first and
  prints which prerequisite is missing instead of hanging.
- **FFmpeg.** A bundle build links the patched FFmpeg from `LUMEN_FFMPEG_BUNDLE`, defaulting to
  `~/lumen-ffmpeg-bundle/bundle/ffmpeg`, which is the same rule `build.sh` uses. Falling back to the
  published build-deps archive still builds cleanly but drops the frame drain fix, which returns
  host latency to its old level; the script prints which one it picked.
- **CI does not build it for `main`.** `ci.yml` is the workflow that calls `ci-macos.yml`, and it
  triggers on `pull_request`, pushes to `master`, and `workflow_dispatch`. A repository whose
  default branch is `main` therefore builds nothing on push; dispatch it manually, or widen the
  trigger. `ci-macos.yml` also needs six secrets that a fresh fork will not have:
  `APPLE_CODESIGN_IDENTITY`, `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`,
  `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and
  `APPLE_NOTARYTOOL_PASSWORD`.

## Release validation

Automated tests cover legacy audio source selection, HID report mappings,
controller slot lifetime and emulated input release. They do not establish physical
controller recognition, capture permission behavior or streaming performance.
Before promoting a build, verify:

- Desktop streaming and reconnection with cursor visibility toggled on an idle screen.
- System sound, client-requested host muting, and an explicitly selected audio input.
- Trackpad and mouse-wheel scrolling in a browser and an editor, including short flicks.
- Native HID recognition in the games used, plus the logged fallback behavior.
- Virtual-display creation and destruction from an installed app, including a headless Mac.
- Launch after logout/login, using the intended executable and existing pairing state.
