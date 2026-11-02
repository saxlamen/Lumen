#!/bin/bash
#
# Reproduce the macOS "Quit & Reopen" flow without touching the mouse: sends the same Apple event the dialog button sends, then reports whether the process really exited.
#
# Run it from a terminal in your GUI session (the ones that touch menus or System Settings
# need that; a background or ssh session gets no window server and the clicks silently do
# nothing). Paths can be overridden with the environment variables listed below.
#
# Overridable: APP=/Applications/Sunshine.app
# Reproduce the macOS "Quit & Reopen" flow: send the same Apple event the system sends
# after a permission is granted, and watch what Lumen actually does.
APP='[S]unshine.app/Contents/MacOS/Sunshine'
CLI='[l]umen/bin/lumen'

tray_count() {
  local pid="$1"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to return count of menu bar items of menu bar 2" 2>&1 | head -1
}

alive() { pgrep -f "$APP" | wc -l | tr -d ' '; }
ports() { lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -cE '47984|47989|48010'; }

pkill -TERM -f "$CLI" 2>/dev/null
sleep 2
launchctl bootout "gui/$(id -u)/sh.brew.lumen" >/dev/null 2>&1
pkill -TERM -f "$APP" 2>/dev/null
sleep 3
echo "  起跑前 → app:$(alive) CLI:$(pgrep -f "$CLI" | wc -l | tr -d ' ') ports:$(ports)"

open -n /Applications/Sunshine.app
sleep 9
P=$(pgrep -f "$APP" | head -1)
echo "  啟動 pid=$P tray=$(tray_count "$P")"

echo "=== 送出「退出並重新打開」等效的 Apple event (kAEQuitApplication) ==="
osascript -e 'tell application id "dev.lizardbyte.app.Sunshine" to quit' 2>&1 | head -1 | sed 's/^/  osascript: /'

for i in $(seq 1 12); do
  A=$(alive)
  echo "  +${i}s app进程=$A ports=$(ports) tray=$(tray_count "$P")"
  [ "$A" = "0" ] && break
  sleep 1
done

echo "=== 退出相關日誌 ==="
grep -ahiE "quit|terminat|stopping|shut|signal" ~/.config/sunshine/sunshine.log 2>/dev/null | tail -5 | cut -c1-115 | sed 's/^/  /'
echo "=== 最終 ==="
echo "  app:$(alive) CLI:$(pgrep -f "$CLI" | wc -l | tr -d ' ') ports:$(ports)"
