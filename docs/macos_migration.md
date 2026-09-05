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
