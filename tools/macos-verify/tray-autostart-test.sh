#!/bin/bash
#
# Exercise the tray item that toggles start at login, checking that the system login item and the menu label move together. Leaves a development build installed - run restore-release.sh afterwards.
#
# Run it from a terminal in your GUI session (the ones that touch menus or System Settings
# need that; a background or ssh session gets no window server and the clicks silently do
# nothing). Paths can be overridden with the environment variables listed below.
#
# Overridable: APP=/Applications/Sunshine.app
# Exercise the tray item that toggles start at login, then restore the release build.
set -u
APP=/Applications/Sunshine.app

sub() {  # print the permission submenu labels for a pid
  local p="$1"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $p) to click menu bar item 1 of menu bar 2" >/dev/null 2>&1
  sleep 1
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $p) to return name of every menu item of menu 1 of menu item \"Permissions\" of menu 1 of menu bar item 1 of menu bar 2" 2>&1 | tr ',' '\n' | sed 's/^ *//' | grep -v "missing value" | tr '\n' '|'
  echo
}

items() { osascript -e 'tell application "System Events" to get the name of every login item' 2>&1 | tr ',' '\n' | sed 's/^ *//' | grep -ci sunshine; }

echo "1) 裝開發版並啟動"
pkill -TERM -f "[S]unshine.app/Contents/MacOS" 2>/dev/null; sleep 3
pkill -9 -f "[S]unshine.app/Contents/MacOS" 2>/dev/null; sleep 1
(cd ~/Scripts/Lumen && SHOULD_SIGN=true cmake --install cmake-build-macos-app --prefix /Applications >/dev/null 2>&1)
open -n "$APP"; sleep 10
P=$(pgrep -x Sunshine | head -1)
echo "   pid=${P:-失敗}   登入項目筆數: $(items)"
echo "   子菜單: $(sub "$P")"

echo "2) 點「Start at login」→ 應該變 Off，系統那端也要真的消失"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to click menu bar item 1 of menu bar 2" >/dev/null 2>&1
sleep 1
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to click menu item 3 of menu 1 of menu item \"Permissions\" of menu 1 of menu bar item 1 of menu bar 2" 2>&1 | head -1 | sed 's/^/   /'
sleep 4
echo "   登入項目筆數: $(items)   狀態項目: $(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to return count of menu bar items of menu bar 2" 2>&1 | head -1)"
echo "   子菜單: $(sub "$P")"

echo "3) 再點一次 → 應該回 On"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to click menu bar item 1 of menu bar 2" >/dev/null 2>&1
sleep 1
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P) to click menu item 3 of menu 1 of menu item \"Permissions\" of menu 1 of menu bar item 1 of menu bar 2" >/dev/null 2>&1
sleep 4
echo "   登入項目筆數: $(items)"
echo "   子菜單: $(sub "$P")"
cd ~/.config/sunshine && grep -a "start at login" sunshine.log 2>/dev/null | tail -3 | cut -c1-112 | sed 's/^/   日誌: /'
