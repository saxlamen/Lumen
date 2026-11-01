#!/bin/bash
# 產正式版 DMG（簽名 + 公證），並在最後自己驗一遍。
#
#   雙擊                              用現成的建置重新打包成簽名 DMG（最快，幾分鐘）
#   ./lumen-dmg.command --full        重跑 cmake + build + dmg（改過程式碼之後）
#   ./lumen-dmg.command --unsigned    不簽名不公證（先驗證管線能不能跑通）
#
# 為什麼要從桌面雙擊、不能在 SSH 裡跑：
# CPack 的最後一步會用 osascript 驅動 Finder 排 DMG 的視窗樣式
# （src_assets/macos/build/dmg-finder-layout.applescript）。背景 session 裡沒有可互動的
# Finder，AppleScript 就永遠等不到回應——實測過：temp.dmg 已經寫好 117MB，osascript
# 挂在那裡五分鐘不動。判據是 `launchctl managername`，Aqua 才是桌面 session。
#
# 為什麼 --step=dmg 就夠：簽名不是編譯期做的，而是在 install/CPack 的腳本裡，由環境變數
# SHOULD_SIGN 開關（macos_build.sh 的 dmg 步驟會設它）。所以同一份 build 目錄可以反覆
# 打包成「未簽名」或「Developer ID 簽名 + 公證」兩種 DMG。
set -uo pipefail

REPO="$HOME/Scripts/Lumen"
BUILD_DIR="$REPO/cmake-build-macos-app"
DMG="$BUILD_DIR/cpack_artifacts/Sunshine.dmg"
IDENTITY="${APPLE_CODESIGN_IDENTITY:-}"
STEP="dmg"
SIGN="yes"

for a in "$@"; do
  case "$a" in
    --full) STEP="all" ;;
    --unsigned) SIGN="" ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "不認識的參數：${a}（可用：--full --unsigned）"; exit 1 ;;
  esac
done

echo "──────────────────────────────────────────────"
echo "  Lumen 正式版 DMG"
echo "──────────────────────────────────────────────"

# 1) session 必須是 Aqua，否則會卡在 Finder 排版
SESSION="$(launchctl managername 2>/dev/null || echo '?')"
if [ "$SESSION" != "Aqua" ]; then
  echo "❌ 目前的 launchd session 是「${SESSION}」，不是 Aqua。"
  echo "   請在 Mac Studio 的登入桌面開終端機（或雙擊本檔案），SSH 裡打包會卡死。"
  exit 1
fi
echo "✅ session：$SESSION"

# 2) 公證需要 Developer ID（Apple Development / Apple Distribution 都不行）
if [ -n "$SIGN" ]; then
  # 要的是引號裡的憑證名稱。find-identity 的第 2 欄是 SHA-1，拿去 --sign 只會得到一個看不見的身分。
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
  fi
  if [ -z "$IDENTITY" ]; then
    echo "❌ keychain 裡沒有「Developer ID Application」憑證。要準備的是：(Account Holder 才能建)"
    echo "   1) 鑰匙空間存取 → 憑證輔助 → 向我憑證伺服器要求憑證（CA 信箱留空、勾「讓鑰匙空間產生金鑰對」→ 存成 .certSigningRequest）"
    echo "   2) developer.apple.com → Certificates, IDs & Profiles → Certificates → + → 選 Developer ID Application → 上傳 CSR → 下載後雙擊安裝"
    echo "   3) 公證还要一把 app-specific password（appleid.apple.com → 登入與安全性 → App 专用密碼）"
    echo "      然後存成鑰匙圈设定檔（名字是寫死的）："
    echo "      xcrun notarytool store-credentials \"notarytool-password\" \\"
    echo "        --apple-id 你的AppleID --team-id 團隊ID --password xxxx-xxxx-xxxx-xxxx"
    echo "   （先想看看管線就跑 ./lumen-dmg.command --unsigned）"
    exit 1
  fi
  TEAM="${IDENTITY##*(}"; TEAM="${TEAM%%)}"
  echo "✅ 簽名身分：${IDENTITY}"
  # 別去猜 notarytool 把設定檔存成哪個鑰匙圈項目，那是實作細節、查錯會誤報沒有；
  # 直接叫 notarytool 用這個 profile 打一次 API，能不能用由它說。
  if xcrun notarytool history --keychain-profile notarytool-password >/dev/null 2>&1; then
    NOTARIZE="yes"
    echo "✅ 公證设定檔：notarytool-password（team ${TEAM}）"
  else
    NOTARIZE=""
    echo "⚠️  notarytool-password 這個 profile 不能用（沒存或認證失敗），這次只簽名、不送公證。"
    echo "    補法：xcrun notarytool store-credentials notarytool-password --apple-id ... --team-id ${TEAM} --password xxxx-xxxx-xxxx-xxxx"
  fi
  export APPLE_CODESIGN_IDENTITY="$IDENTITY"
fi

# 簽名身分是在 cmake configure 時期就被展開進 cmake_install.cmake 的（實查那三行寫死成 `--sign ""`），
# 所以「只重打包」沒辦法把未簽名的 build 變成已簽名，一定要重新 configure。
if [ -n "$SIGN" ] && [ "$STEP" = "dmg" ]; then
  STEP="all"
  echo "ℹ️  要簽名 → 改跑 cmake + build + dmg：只跑 --step=dmg 會拿到 --sign \"\"，然後報 no identity found"
fi

VERSION="$(cat "$REPO/LUMEN_VERSION" 2>/dev/null || echo unknown)"
if [ -n "$SIGN" ]; then
  if [ -n "$NOTARIZE" ]; then SIGN_TEXT="是（送公證）"; else SIGN_TEXT="是（只簽名，不送公證）"; fi
else
  SIGN_TEXT="否"
fi
echo "版本：${VERSION}    步驟：${STEP}    簽名：${SIGN_TEXT}"
echo

cd "$REPO" || exit 1
ARGS=(--step="${STEP}" --skip-tests)
if [ -z "$SIGN" ]; then
  ARGS+=(--skip-codesign --skip-notarize)
elif [ -z "$NOTARIZE" ]; then
  ARGS+=(--skip-notarize)  # 沒有可用的 profile 時 notarytool 一定失敗，先別送
fi

./scripts/macos_build.sh "${ARGS[@]}"
STATUS=$?
echo
if [ $STATUS -ne 0 ]; then
  echo "❌ 打包失敗（exit ${STATUS}）。上面是原始錯誤。"
  exit $STATUS
fi

# 3) 自己驗一遍：簽名、Gatekeeper、公證是否 staple 成功
if [ ! -f "$DMG" ]; then
  echo "❌ 找不到 $DMG"
  exit 1
fi
APP="$BUILD_DIR/cpack_artifacts/_CPack_Packages/Darwin/DragNDrop/Sunshine/ALL_IN_ONE/Sunshine.app"
OUT="$HOME/Desktop/Lumen-$VERSION-$(uname -m).dmg"
cp -f "$DMG" "$OUT"

echo "── 產物 ─────────────────────────────"
ls -lh "$OUT" | awk '{print $5, $NF}'
echo "frame_drain（patched FFmpeg 有沒有進去）：$(strings "$APP/Contents/MacOS/Sunshine" 2>/dev/null | grep -c '^frame_drain$') （要 ≥1）"
if [ -n "$SIGN" ]; then
  echo "── codesign ─────────────────────────"
  codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Runtime)" | sed 's/^/  /'
  codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1 | sed 's/^/  /'
  echo "── Gatekeeper ───────────────────────"
  spctl -a -vv "$APP" 2>&1 | sed 's/^/  /'
  echo "── 公證 staple ──────────────────────"
  xcrun stapler validate "$OUT" 2>&1 | tail -2 | sed 's/^/  /'
fi
echo
echo "拿到另一台 Mac 就拖這個：$OUT"
echo "（未簽名的話，對方要用 right-click → Open，或 xattr -d com.apple.quarantine 那個 dmg）"
