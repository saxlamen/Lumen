#!/bin/bash
#
# Verify what is actually installed in /Applications: whether it is the notarized artifact from the DMG (compares CDHash), what it contains, and whether the swap reset anything.
#
# Run it from a terminal in your GUI session (the ones that touch menus or System Settings
# need that; a background or ssh session gets no window server and the clicks silently do
# nothing). Paths can be overridden with the environment variables listed below.
#
# Overridable: APP=/Applications/Sunshine.app  DMG=~/Desktop/Lumen-*.dmg
# Check what is actually installed in /Applications now: is it the notarized Developer ID
# artifact, does it carry the patched FFmpeg and today's fixes, and did the swap reset TCC.
set -u
APP=/Applications/Sunshine.app
BIN=$APP/Contents/MacOS/Sunshine

echo "  檔案時間: $(stat -f %Sm "$APP")   執行檔: $(stat -f '%z bytes' "$BIN")"
echo "  簽章: $(codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1)"
echo "  Gatekeeper: $(spctl -a -vv "$APP" 2>&1 | tail -1)"
echo "  身分: $(codesign -dvvv "$APP" 2>&1 | grep -E '^Authority=Developer ID Application|^TeamIdentifier|^CDHash|flags=0x' | tr '\n' ' ' | cut -c1-190)"
echo "  釘書(包內 app): $(xcrun stapler validate "$APP" 2>&1 | tail -1)"
echo "  entitlements: $(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null | tr -d '\n' | cut -c1-90)"
echo "  版本: $(plutil -p "$APP/Contents/Info.plist" 2>/dev/null | grep CFBundleShortVersionString | tr -d ' ' | cut -c1-60)"

echo "  執行檔內容:"
for s in '^frame_drain$' 'Now answering quit requests' 'relaunching the bundle' 'First run with a missing macOS permission'; do
  echo "    「${s}」: $(strings "$BIN" 2>/dev/null | grep -icE -- "$s")"
done
echo "    殘留 full_disk_access（要 0）: $(strings "$BIN" 2>/dev/null | grep -c full_disk_access)"

DMG=$(ls -t "$HOME"/Desktop/Lumen-*.dmg 2>/dev/null | head -1)
if [ -n "${DMG:-}" ]; then
  MP=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | grep -oE '/Volumes/[^ ]*' | head -1)
  if [ -n "${MP:-}" ]; then
    A=$(codesign -dvvv "$APP" 2>&1 | grep '^CDHash' | cut -d= -f2)
    B=$(codesign -dvvv "$MP/Sunshine.app" 2>&1 | grep '^CDHash' | cut -d= -f2)
    echo "  跟 DMG 裡那份比對: 裝的=${A:-?}  DMG=${B:-?}  →  $([ -n "$A" ] && [ "$A" = "$B" ] && echo '同一個簽章成品 ✅' || echo '不是同一份 ⚠️')"
    hdiutil detach "$MP" >/dev/null 2>&1
  fi
fi

echo "=== 換檔之後的權限與執行狀態 ==="
echo "  TCC: $(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service || '=' || auth_value from access where client='dev.lizardbyte.app.Sunshine';" 2>/dev/null | tr '\n' ' ')"
P=$(pgrep -x Sunshine | head -1)
echo "  進程: ${P:-沒在跑}   起動時刻: $(ps -o lstart= -p "${P:-0}" 2>/dev/null | xargs echo)"
echo "  端口: $(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$9 ~ /47984|47989|48010/ {print $2"/"$9}' | sort -u | tr '\n' ' ')"
if [ -n "${P:-}" ]; then
  echo "  狀態項目: $(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to return count of menu bar items of menu bar 2" 2>&1 | head -1)"
  echo "  app 自己讀到的權限: $(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to return name of every menu item of menu 1 of menu item \"Permissions\" of menu 1 of menu bar item 1 of menu bar 2" 2>&1 | tr ',' '\n' | sed 's/^ *//' | grep -v "missing value" | tr '\n' ' ')"
fi
cd ~/.config/sunshine 2>/dev/null && echo "  這一輪報錯: $(grep -ahiE 'No screen capture|Platform failed|SCCapture setup failed|Encoder .* failed' sunshine.log 2>/dev/null | tail -3 | cut -c12-70 | tr '\n' ' ' || echo 無)"
echo "  登入項目: $(osascript -e 'tell application "System Events" to get the name of every login item' 2>&1 | tr ',' '\n' | sed 's/^ *//' | grep -ci sunshine) 筆 Sunshine"
