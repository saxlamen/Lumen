#!/bin/bash
#
# Put the notarized release build back into /Applications after testing a development build there. Copies it, then confirms the CDHash and Gatekeeper result.
#
# Run it from a terminal in your GUI session (the ones that touch menus or System Settings
# need that; a background or ssh session gets no window server and the clicks silently do
# nothing). Paths can be overridden with the environment variables listed below.
#
# Overridable: DMG=~/Desktop/Lumen-*.dmg  APP=/Applications/Sunshine.app
# Restore the notarized release build into /Applications after a test run removed it.
set -u
APP=/Applications/Sunshine.app
DMG=$(ls -t "$HOME"/Desktop/Lumen-*.dmg 2>/dev/null | head -1)
[ -n "${DMG:-}" ] || { echo "  找不到 DMG"; exit 1; }

for V in $(ls -d /Volumes/Sunshine* 2>/dev/null); do hdiutil detach "$V" >/dev/null 2>&1; done
MP=$(hdiutil attach -nobrowse -readonly "$DMG" 2>/dev/null | grep -oE '/Volumes/.*$' | tail -1 | sed 's/^[[:space:]]*//')
echo "  掛載點: ${MP:-失敗}"
SRC=$(find "$MP" -maxdepth 1 -name "Sunshine.app" 2>/dev/null | head -1)
echo "  來源: ${SRC:-找不到}"
[ -n "${SRC:-}" ] || { echo "  放棄還原（DMG 還掛著，手動處理）"; exit 1; }

pkill -TERM -f "[S]unshine.app/Contents/MacOS" 2>/dev/null; sleep 3
pkill -9 -f "[S]unshine.app/Contents/MacOS" 2>/dev/null; sleep 1
rm -rf "$APP"
cp -R "$SRC" "$APP"
hdiutil detach "$MP" >/dev/null 2>&1
echo "  簽章: $(codesign --verify --strict "$APP" 2>&1 | tail -1)"
echo "  Gatekeeper: $(spctl -a -vv "$APP" 2>&1 | tail -1)"
echo "  CDHash: $(codesign -dvvv "$APP" 2>&1 | grep '^CDHash' | cut -d= -f2)"
echo "  frame_drain: $(strings "$APP/Contents/MacOS/Sunshine" 2>/dev/null | grep -cx frame_drain)   四個修正: $(strings "$APP/Contents/MacOS/Sunshine" 2>/dev/null | grep -icE 'Now answering quit requests|relaunching the bundle|First run with a missing')"
rm -f ~/.config/sunshine/autostart.stamp
open -n "$APP"; sleep 9
P=$(pgrep -x Sunshine | head -1)
echo "  啟動: pid=${P:-失敗}  端口=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$9 ~ /47984|47989|48010/ {print $2}' | sort -u | tr '\n' ' ')"
[ -n "${P:-}" ] && echo "  狀態項目: $(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to return count of menu bar items of menu bar 2" 2>&1 | head -1)"
echo "  權限: $(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service || '=' || auth_value from access where client='dev.lizardbyte.app.Sunshine';" 2>/dev/null | tr '\n' ' ')"
echo "  登入項目: $(osascript -e 'tell application "System Events" to get the name of every login item' 2>&1 | tr ',' '\n' | sed 's/^ *//' | tr '\n' ' ')"
