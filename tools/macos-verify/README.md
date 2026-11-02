# macOS release and verification tools

These scripts are the part of the work that is easy to lose: they are how a build gets
checked before it is handed to anyone, and how a fix that was verified once stays verified.
They drive the real user interface - menus, System Settings, Apple events - so they measure
what a user would experience instead of what the code looks like.

Two of them (`verify-release.sh`, `verify-installed.sh`) are read-only. The three that click
on things need to run in your GUI login session: a background or ssh session has no window
server, and clicks there fail in ways that look like the app being broken.

| Script | What it answers |
| --- | --- |
| `verify-release.sh` | "Is this DMG safe to ship?" Signature, notarization, staple, hardened runtime, entitlements, Finder layout, the patched FFmpeg (`frame_drain`), and the presence of each macOS fix in the shipped binary. |
| `verify-installed.sh` | "Is what is in `/Applications` the artifact I built?" Compares its CDHash against the one inside the DMG, then reports version, permissions, ports, menu bar item and any startup errors. |
| `restore-release.sh` | "Put the real build back." After testing a development build in `/Applications`, copies the notarized one back from the DMG and proves it. |
| `quit-reopen-test.sh` | "Does the app obey the quit request macOS sends before relaunching it?" Sends the same Apple event the "Quit & Reopen" button sends, and reports whether the process actually exits. |
| `tray-autostart-test.sh` | "Does the start-at-login switch move both the menu label and the real login item?" Clicks it twice and checks the system's login items in between. Leaves a development build installed - run `restore-release.sh` afterwards. |
| `toggle-accessibility.applescript` | Flips the Accessibility switch for Sunshine in System Settings and prints the dialog the system shows, for walking the permission flow without hands. |

## Release checklist

1. Build and notarize: `~/Desktop/Lumen/lumen-dmg.command` (double-clicked, so it runs in the GUI
   session - the packaging step drives Finder through AppleScript and hangs in a background
   session).
2. `./verify-release.sh` - everything in its list should be `1` or a pass. A `0` for
   `frame_drain` means the bundle linked an unpatched FFmpeg, which quietly restores the old
   host latency.
3. Install it, then `./verify-installed.sh` - the CDHash must match the DMG, otherwise what is
   installed is not what was notarized.
4. `sudo /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow console` or a
   reboot only when changing startup behaviour; otherwise check login items:

       osascript -e 'tell application "System Events" to get the name of every login item'

## Things these scripts exist because of

- A permission nobody asks for is not a switch that is off; it is an empty System Settings
  list, because macOS only lists applications that have asked.
- `codesign` prints nothing on success, and `cp -R src dst` copies `src` *into* `dst` when
  `dst` already exists - which produces a bundle with unsealed contents in its root. Both
  mistakes look like a broken build; `restore-release.sh` removes the destination first for
  that reason.
- Reinstalling the app does not reset permissions while the signing identity stays the same,
  but re-signing with a different identity does.
- `stapler validate` on the app inside a mounted DMG always reports no ticket: the ticket is
  stapled to the DMG, and the mount is read-only.

## Where things live

Recordings and scratch output go to `var/scroll-data` in this repository, which is ignored by
git. `~/Desktop/scroll-data` is a symlink to it so the older habits and the desktop shortcuts
keep working.
