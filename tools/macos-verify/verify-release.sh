#!/bin/bash
#
# Verify a built DMG end to end: signature, notarization, staple, hardened runtime, packaging layout, patched FFmpeg and every macOS fix present in the shipped binary.
#
# Run it from a terminal in your GUI session (the ones that touch menus or System Settings
# need that; a background or ssh session gets no window server and the clicks silently do
# nothing). Paths can be overridden with the environment variables listed below.
#
# Overridable: DMG=path/to/Lumen-x.y.z-arm64.dmg
# Verify a freshly built Lumen DMG end to end: signature, notarization, packaging layout,
# patched FFmpeg, and that every fix made today is inside the shipped binary.
set -u

DMG=$(ls -t "$HOME"/Desktop/Lumen-*.dmg 2>/dev/null | head -1)
[ -n "${DMG:-}" ] || { echo "  找不到 DMG"; exit 1; }

echo "  檔案: ${DMG##*/}   大小: $(du -h "$DMG" | awk '{print $1}')   時間: $(stat -f %Sm "$DMG")"
echo "  圖片校驗: $(hdiutil verify "$DMG" 2>&1 | tail -1 | grep -o 'is VALID' || echo 失敗)"
echo "  DMG 釘書: $(xcrun stapler validate "$DMG" 2>&1 | tail -1)"

for V in $(ls -d /Volumes/Sunshine* 2>/dev/null); do hdiutil detach "$V" >/dev/null 2>&1; done
MP=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | grep -oE '/Volumes/.*$' | tail -1 | sed 's/^[[:space:]]*//')
APP="$MP/Sunshine.app"
BIN="$APP/Contents/MacOS/Sunshine"
[ -d "$APP" ] || { echo "  掛載或找不到 app: ${MP:-失敗}"; exit 1; }

echo "  掛載點: $MP   頂層內容: $(ls "$MP" | tr '\n' ' ')"
echo "  簽章: $(codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1)"
echo "  Gatekeeper: $(spctl -a -vv "$APP" 2>&1 | tail -1)"
echo "  身分: $(codesign -dvvv "$APP" 2>&1 | grep -E '^Authority=Developer ID Application|^TeamIdentifier|^CDHash' | tr '\n' ' ' | cut -c1-170)"
echo "  旗標: $(codesign -dvvv "$APP" 2>&1 | grep -oE 'flags=0x[0-9a-f]+\([a-z]+\)' | head -1)"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null | tr -d '\n' | cut -c1-90 | sed 's/^/  entitlements: /'
plutil -p "$APP/Contents/Info.plist" 2>/dev/null | grep CFBundleShortVersionString | tr -d ' ' | cut -c1-58 | sed 's/^/  版本: /'

echo "  執行檔裡的東西（都應該是 1）:"
for s in '^frame_drain$' 'Now answering quit requests' 'relaunching the bundle' 'First run with a missing macOS permission' 'Enabled starting Lumen at login' 'Toggling start at login from the system tray' 'Asking for a macOS permission from the system tray'; do
  printf "    %-58s %s\n" "「${s}」" "$(strings "$BIN" 2>/dev/null | grep -icE -- "$s")"
done
echo "    $(printf '%-56s' '殘留 full_disk_access（要 0）') $(strings "$BIN" 2>/dev/null | grep -c full_disk_access)"
echo "    $(printf '%-56s' '殘留 input_monitoring（要 0）') $(strings "$BIN" 2>/dev/null | grep -c input_monitoring)"

hdiutil detach "$MP" >/dev/null 2>&1
echo "  已卸載"
