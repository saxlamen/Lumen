#!/bin/bash
# 把 var/scroll-data 裡的所有記錄放在一起比（或只比指定的幾個）。
#
#   雙擊 / 直接執行   → 比全部記錄
#   ./lumen-scroll-compare.command lumen_*.csv native_*.csv   → 只比這幾個
#   ./lumen-scroll-compare.command --gestures                → 連每個手勢的明細一起列
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DIR="${LUMEN_SCROLL_DATA:-$HOME/Scripts/Lumen/var/scroll-data}"
SCRIPT="$SCRIPT_DIR/lumen-scroll-compare.py"

if [ ! -f "$SCRIPT" ]; then
  echo "找不到 $SCRIPT"
  exit 1
fi

if [ $# -eq 0 ]; then
  if ! ls "$DIR"/*.csv >/dev/null 2>&1; then
    echo "$DIR 裡還沒有記錄。先跑 lumen-scroll-profile.command（repo: tools/scroll-prof）"
    echo "建議順序：native → lumen → rustdesk（同一個視窗、同一組動作、各 60 秒）"
    exit 1
  fi
  python3 "$SCRIPT" --gestures "$DIR"/*.csv
else
  python3 "$SCRIPT" "$@"
fi
