#!/bin/bash
# Lumen macOS 授权引导（四项 TCC 授权 + 引导开启）
#
# 为什么要这个工具：macOS 把权限给「提出要求的那个程序」，不是给你想配置的那个安装。
# 所以外面写的脚本读到的都是它自己（或 Terminal）的权限，只有 Lumen 自己跑出来的
# 结果才算数。分工是：
#   app（lumen --permissions）：查询 + 向系统要求 + 决定顺序，一次一项
#   这个脚本：你看到的一切（中文说明、现在该开哪个面板、进度、结束后的动作）
# 两者靠 report 档案沟通：引导进程会在里面写 active=<key> 表示「现在这项」。
#
# 用法：双击，或在终端机里执行本文件。

set -u

APP="/Applications/Sunshine.app"
BREW="/opt/homebrew/opt/lumen/bin/lumen"
REPORT="$(mktemp /tmp/lumen-permissions.XXXXXX)"
trap 'rm -f "$REPORT" "$REPORT.tmp"' EXIT

# key 的顺序与内容要和 src/platform/macos/permissions.mm 里的 key 一致
KEYS=(screen_capture accessibility input_monitoring full_disk_access)
NAMES=(
  "屏幕录制      截取桌面画面（视频流）"
  "辅助功能      送出键盘、鼠标、滚动事件"
  "输入监视器    建立虚拟键盘/鼠标/手柄"
  "完全磁盘访问  列出显示器；不给的话显示器清单会是空的"
)
ACTIONS=(
  "在列表里把 Sunshine 的开关打开"
  "在列表里把 Sunshine 的开关打开（若 macOS 要求先退出 Sunshine，同意，之后再开一次）"
  "在列表里把 Sunshine 的开关打开"
  "把 Finder 里选中的 Sunshine.app 拖进右边列表，再打开开关（这列表没有 + 按钮）"
)

# 每一项最多等 5 分钟（完全磁盘访问要拖档案）
WAIT_PER_ITEM="${LUMEN_PERMS_WAIT:-300}"   # 测试时可以缩短

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }
bold() { printf '\033[1m%s\033[0m\n' "$1"; }

# 找 key 在数组里的索引，找不到回 -1
index_of() {
  local i
  for i in "${!KEYS[@]}"; do
    [ "${KEYS[$i]}" = "$1" ] && { echo "$i"; return; }
  done
  echo "-1"
}

# ── 工作階段检查 ───────────────────────────────────────────────────────────
# 授权窗、系统设置面板、Finder 里选中的 app 都只在「已登录的桌面」（Aqua）里存在。
# 从 SSH（Background 工作階段）跑，这些会全被丢进一个没人看的会话：引导进程照常
# 轮询、状态档照常更新，但屏幕上什么都不会出现，看起来就像工具没跑。
# 测试脚本逻辑时可以用 LUMEN_PERMS_ALLOW_ANY_SESSION=1 跳过（屏幕上不会有东西）。
SESSION="$(launchctl managername 2>/dev/null || echo unknown)"
if [ "$SESSION" != "Aqua" ] && [ "${LUMEN_PERMS_ALLOW_ANY_SESSION:-0}" != "1" ]; then
  bold "现在的位置不是登录桌面（工作階段：${SESSION}）"
  dim "请双击本档案，或在你自己登录的桌面里开「终端机」执行它。"
  dim "从 SSH 跑的话系统设置和授权窗都不会出现，引导会一直等。"
  exit 1
fi

# ── 收掉残留的引导实例 ─────────────────────────────────────────────────────
# 上一次跑到一半没结束的引导实例会把 TCC 要求握在那里没人答复，超时后 macOS 把它
# 结算成「已拒绝」；之后不但不会再弹窗，连面板清单里都不会列出 Sunshine。
stale="$(pgrep -f -- '-[-]permissions --report' | tr '\n' ' ')"
if [ -n "$stale" ]; then
  dim "发现上次没结束的引导实例（pid: ${stale}），先收掉——不然它们会把授权要求握在手里。"
  pkill -f -- '-[-]permissions --report' 2>/dev/null
  sleep 1
fi
echo

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

# 跑一次检查/引导，状态写进 $REPORT（active=<key> 与 key=granted / key=missing）
probe() {
  : > "$REPORT"
  if [ "$TARGET" = "app" ]; then
    # app 没有终端机可印东西，所以要它把状态写进档案；-n 表示另开一个实例，
    # 它打印完/引导完就退出，不会占着 app 身份（-na 会立刻返回）
    open -na "$APP" --args --permissions --report "$REPORT" "$@"
  else
    "$BREW" --permissions --report "$REPORT" "$@" >/dev/null 2>&1 &
  fi

  # 等档案出现（app 启动要一点时间）
  local _
  for _ in $(seq 1 60); do
    [ -s "$REPORT" ] && return 0
    sleep 0.5
  done
  return 1
}

# 把 $REPORT 读成一张中文表格；$1=1 时不印「缺 N 项」
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
  if [ "${1:-}" != "quiet" ]; then
    echo -n "  缺 $missing 项"
    echo
  fi
  MISSING=$missing
}

# ── 第 1 步：只看状态 ──────────────────────────────────────────────────────
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
dim "一次只处理一项，也只开那一项的系统设置面板（macOS 同时只会显示一个面板）。"
dim "没弹授权窗是正常的：macOS 对同一项只弹一次，直接在面板里把开关打开就好。"
dim "每项最多等 ${WAIT_PER_ITEM} 秒，你打开开关这边就会多一个 ✅，然后才进下一项。"
echo
if [ -t 0 ]; then
  read -r -p "按 Enter 开始（Ctrl+C 离开）..." _
else
  sleep 1
fi
echo

# ── 第 3 步：跟着引导走 ────────────────────────────────────────────────────
bold "第 3 步：现在照画面做（系统设置会一项一项开给你）"
probe --grant --wait "$WAIT_PER_ITEM" || true

active=""
previous="$(cat "$REPORT" 2>/dev/null)"
while pgrep -f "[-]-permissions --report" >/dev/null 2>&1; do   # 字元类别避开 pgrep 找到自己
  current="$(cat "$REPORT" 2>/dev/null)"

  # 现在轮到哪一项 → 提示该开哪个面板
  new_active="$(printf '%s\n' "$current" | sed -n 's/^active=//p')"
  if [ "$new_active" != "$active" ]; then
    idx="$(index_of "$new_active")"
    if [ "$idx" != "-1" ]; then
      echo
      bold "  → 现在：${NAMES[$idx]}"
      dim "     ${ACTIONS[$idx]}"
    fi
    active="$new_active"
  fi

  # 翻绿的瞬间
  for i in "${!KEYS[@]}"; do
    k="${KEYS[$i]}"
    was="$(printf '%s\n' "$previous" | sed -n "s/^$k=//p")"
    now="$(printf '%s\n' "$current" | sed -n "s/^$k=//p")"
    [ "$was" = "missing" ] && [ "$now" = "granted" ] && green "  ✅ ${NAMES[$i]} 好了"
  done

  previous="$current"
  sleep 1
done
echo

# 引导进程结束后再查一次，当作结论（它可能中途被 macOS 要求退出）
probe
show
echo

if [ "${MISSING:-0}" -eq 0 ]; then
  green "✅ 四项授权都给了。"
  bold "  现在请正式启动 Sunshine：到「应用程序」双击 Sunshine（或 Spotlight 搜 Sunshine）。"
  dim "菜单栏图标只有正式跑起来才会出现；如果它已经在跑，先「结束」再开一次，"
  dim "因为跑着的进程只保留启动时拿到的权限。"
  exit 0
fi

dim "如果菜单栏出现两个 Sunshine 图标：绑 port 的那个才是真的在服务，另一个是某个"
dim "实例退出后残留的图画（引导必须用 open -n 才能把参数传给 app，所以过程中会短暂"
dim "出现第二个实例）。结束 Sunshine 再开一次就干净。"
echo
red "❌ 还有缺的（上面列的名字）。"
echo "     手动开：系统设置 → 隐私与安全性 →"
for i in "${!KEYS[@]}"; do
  grep -q "^${KEYS[$i]}=granted\$" "$REPORT" 2>/dev/null && continue
  echo "       ${NAMES[$i]}"
  dim "         ${ACTIONS[$i]}"
done
echo
dim "如果列表里已经有 Sunshine 但开关是关的：打开它；macOS 可能要求先结束 Sunshine，"
dim "就照它做，然后再开一次开关并重启 Sunshine，接着重跑本工具。"
dim "如果面板里连 Sunshine 都看不到：它被记成「已拒绝」了（要求没被答复就会这样结算，"
dim "比如引导实例跑到一半没结束）。已拒绝的状态 macOS 不再弹窗、清单也不列出来，要这样清："
echo
echo "       1. 菜单栏 Sunshine 图标 → Quit"
echo "       2. tccutil reset All dev.lizardbyte.app.Sunshine"
dim "          （只想清一项就换服务名：ScreenCapture / Accessibility / ListenEvent /"
dim "            SystemPolicyAllFiles，例如 tccutil reset Accessibility dev.lizardbyte.app.Sunshine）"
echo "       3. 到「应用程序」双击 Sunshine —— 它会重新提出要求，这时弹窗才会出现 → 按【允许】"
dim "          （屏幕录制也可以在面板里按左下角「+」手动选 Sunshine.app）"
echo "       4. 再跑本工具"
echo
dim "如果列表里出现的是「bash」或「Terminal」：那是以前从别的身份跑造成的，"
dim "选中它按「−」删掉，再用本工具（app 那条路）重跑。"
exit 1
