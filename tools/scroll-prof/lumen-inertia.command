#!/bin/bash
# 慣性簡易檢測：20 秒、一個動作、收完自動印結論。
#
#   ./lumen-inertia.command          # 20 秒（約 6 次甩動）
#   ./lumen-inertia.command 30       # 30 秒
#
# 只需要做一件事：每 3 秒「快速滑一下然後放開」，讓它自己滑到停。
# 不需要慢速滑、不需要水平滑、不需要三份對照。
#
# 記錄的是「系統實際收到的事件」，結尾會把卡頓自動歸因給 client 或 Lumen。
# 檔案在 repo 的 tools/scroll-prof/，桌面通常放一個同名的 symlink 讓你雙擊。
set -uo pipefail

DUR="${1:-20}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

echo "──────────────────────────────────────────────"
echo "  慣性檢測（${DUR} 秒）"
echo "  動作只有一個：每 3 秒「快速滑一下放開」，做 $((DUR / 3)) 次"
echo "  每次之間等它完全停住再滑下一次"
echo "──────────────────────────────────────────────"

"$DIR/lumen-scroll-profile.command" lumen "$DUR" --free || true

NEW=$(ls -t "$DIR/scroll-data"/lumen_*.csv 2>/dev/null | head -1)
if [ -z "$NEW" ]; then
  echo "沒有找到 CSV，無法分析。"
  exit 1
fi
python3 "$DIR/lumen-inertia.py" "$NEW"
echo
echo "原始檔：$NEW"
