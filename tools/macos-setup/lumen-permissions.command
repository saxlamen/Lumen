#!/bin/bash
# Lumen macOS 授权引导（四项 TCC 授权 + 引导开启）
#
# 为什么要这个工具：macOS 把权限给「提出要求的那个程序」，不是给你想配置的那个安装。
# 所以外面写的脚本读到的都是它自己（或 Terminal）的权限，只有 Lumen 自己跑出来的
# 结果才算数。这个工具负责挑出正确的安装、以正确身份启动检查、把系统设置面板
# 一个个开出来，并且每秒重读状态，等你把开关打开。
#
# 用法：双击，或在终端里执行本文件。

set -u

APP="/Applications/Sunshine.app"
BREW="/opt/homebrew/opt/lumen/bin/lumen"
REPORT="$(mktemp /tmp/lumen-permissions.XXXXXX)"
trap 'rm -f "$REPORT" "$REPORT.tmp"' EXIT

# 检查项目的顺序与 key，要和 src/platform/macos/permissions.mm 里的 key 一致
KEYS=(screen_capture accessibility input_monitoring full_disk_access)
NAMES=(
  "屏幕录制    用来截取桌面画面（视频流）"
  "辅助功能    用来送出键盘、鼠标、滚动事件"
  "输入监视器  用来建立虚拟键盘/鼠标/手柄"
  "完全磁盘访问 用来列出显示器；不给的话显示器清单会是空的"
)
PANES=(
  "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
)

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }
bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# ── 工作階段檢查 ───────────────────────────────────────────────────────────
# 授权窗、系统设置面板、Finder 里选中的 app 都只在「已登录的桌面」（Aqua）里存在。
# 从 SSH（Background 工作階段）跑，这些会全被丢进一个没人看的会话：引导进程照常
# 轮询、状态档照常更新，但屏幕上什么都不会出现，看起来就像工具没跑。
SESSION="$(launchctl managername 2>/dev/null || echo unknown)"
if [ "$SESSION" != "Aqua" ]; then
  bold "现在的位置不是登录桌面（工作階段：${SESSION}）"
  dim "请双击本档案，或在你自己登录的桌面里开「终端机」执行它。"
  dim "从 SSH 跑的话系统设置和授权窗都不会出现，引导会白等好几分钟。"
  exit 1
fi

# ── 挑出要检查的安装 ────────────────────────────────────────────────────────
TARGET=""
if [ -d "$APP" ]; then
  TARGET="app"
  bold "要检查的安装：$APP"
  dim "（以 app 自己的身份跑检查，权限才会归给 app）"
elif [ -x "$BREW" ]; then
  TARGET="brew"
  bold "要检查的安装：$BREW"
  dim "注意：从终端机跑，权限会归给终端机（不是 LaunchAgent 里的服务）。"
  dim "服务自己缺什么会在 ~/.config/sunshine/sunshine.log 里写出来。"
else
  bold "找不到 Lumen 安装。"
  dim "先装 DMG（拖进「应用程序」），或先 brew 安装。"
  exit 1
fi
echo

# 跑一次检查，结果写进 ${REPORT}（key=granted / key=missing）
probe() {
  : > "$REPORT"
  if [ "$TARGET" = "app" ]; then
    # app 没有终端机可印东西，所以要它把状态写进档案
    open -na "$APP" --args --permissions --report "$REPORT" "$@"
  else
    "$BREW" --permissions --report "$REPORT" "$@" >/dev/null 2>&1
  fi

  # 等档案出现（app 启动要一点时间）
  for _ in $(seq 1 60); do
    [ -s "$REPORT" ] && return 0
    sleep 0.5
  done
  return 1
}

# 把 $REPORT 读成一张中文表格
show() {
  local i missing=0
  for i in "${!KEYS[@]}"; do
    if grep -q "^${KEYS[$i]}=granted\$" "$REPORT" 2>/dev/null; then
      green "  ✅ ${NAMES[$i]}"
    else
      red "  ❌ ${NAMES[$i]}"
      missing=$((missing + 1))
    fi
  done
  echo -n "  缺 $missing 项"
  echo
  MISSING=$missing
}

# ── 第一轮：只看状态 ───────────────────────────────────────────────────────
bold "第 1 步：看现在的状态"
if ! probe; then
  bold "❌ 检查没跑起来。"
  dim "如果 Lumen 是刚装好的，先开过一次 app（或在终端机跑一次 lumen --permissions）再试。"
  exit 1
fi
show
echo

if [ "${MISSING:-0}" -eq 0 ]; then
  green "全部都已经给了，不用动作。"
  dim "换版本（brew upgrade / 重装 DMG / 换签名）之后权限会重置，那时候再跑本工具。"
  exit 0
fi

bold "第 2 步：开始引导"
dim "接下来会：弹出系统的授权窗、把每一项对应的系统设置面板开出来、"
dim "然后每秒重读状态，你每打开一个开关这里就会多一个 ✅。"
dim "（完全磁盘访问没法弹窗，工具会在 Finder 里选中要拖进列表的那个 app。）"
echo
if [ -t 0 ]; then
  read -r -p "按 Enter 开始（Ctrl+C 离开）..." _
else
  sleep 1
fi
echo

# ── 第二轮：要求 + 等 ──────────────────────────────────────────────────────
bold "第 3 步：跟着点，这边等你自己打开开关（最久 4 分钟）"
probe --grant --wait 240 || true

previous="$(cat "$REPORT" 2>/dev/null)"
deadline=$(( $(date +%s) + 245 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  current="$(cat "$REPORT" 2>/dev/null)"
  if [ "$current" != "$previous" ]; then
    for i in "${!KEYS[@]}"; do
      k="${KEYS[$i]}"
      was="$(printf '%s' "$previous" | grep "^$k=" | cut -d= -f2)"
      now="$(printf '%s' "$current" | grep "^$k=" | cut -d= -f2)"
      if [ "$was" = "missing" ] && [ "$now" = "granted" ]; then
        green "  ✅ ${NAMES[$i]} 好了"
      fi
    done
    previous="$current"
  fi
  # app 那边的引导进程结束时会写进最后的状态，这边用 report 的完整性判断结束
  if [ -n "$current" ] && [ "$(printf '%s' "$current" | grep -c '=granted')" -eq "${#KEYS[@]}" ]; then
    break
  fi
  sleep 1
done
echo

probe
show
echo

if [ "${MISSING:-0}" -eq 0 ]; then
  green "✅ 四项授权都给了。"
  bold "  最后一步：重启 Lumen 才会生效（跑起来的程序只保留启动时拿到的权限）。"
  if [ "$TARGET" = "app" ]; then
    echo "     菜单栏图标 → 结束，再开一次 app。"
  else
    echo "     launchctl kickstart -k \"gui/$(id -u)/sh.brew.lumen\""
  fi
else
  red "❌ 还有缺的。"
  echo "     每一项的面板：（也可以双击本工具，或直接开这些连结）"
  for i in "${!KEYS[@]}"; do
    grep -q "^${KEYS[$i]}=granted\$" "$REPORT" 2>/dev/null && continue
    echo "       ${NAMES[$i]}"
    echo "         $PANES[$i]"
  done
  echo
  dim "如果列表里已经有 Sunshine/Lumen 但开关是关的：把它打开，macOS 可能会要求先结束"
  dim "Lumen，就照它做，然后再开一次开关并重启 Lumen。"
  dim "如果列表里出现的是「bash」或「Terminal」：那是之前从别的身份跑造成的，"
  dim "用本工具（app 那条路）重跑一次，就会列出 Sunshine。"
  exit 1
fi
