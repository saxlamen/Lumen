#!/bin/bash
# 產正式版 DMG（簽名 + 公證），並在最後自己驗一遍。
#
#   雙擊                              選擇 profile 後用現成建置打包 DMG（若簽名身分變動會自動重跑 cmake + build）
#   ./lumax-dmg.command --full        重跑 cmake + build + dmg（改過程式碼之後）
#   ./lumax-dmg.command --unsigned    不簽名不公證（先驗證管線能不能跑通）
#   ./lumax-dmg.command --release     使用 Developer ID profile + 公證
#   ./lumax-dmg.command --dev         使用 Apple Development profile（本機測試 Virtual HID）
#   ./lumax-dmg.command --profile=X   指定 profile（release / dev / profiles 內檔名 / 檔案路徑）
#
# 為什麼要從桌面雙擊、不能在 SSH 裡跑：
# CPack 的最後一步會用 osascript 驅動 Finder 排 DMG 的視窗樣式
# （src_assets/macos/build/dmg-finder-layout.applescript）。背景 session 裡沒有可互動的
# Finder，AppleScript 就永遠等不到回應——實測過：temp.dmg 已經寫好 117MB，osascript
# 挂在那裡五分鐘不動。判據是 `launchctl managername`，Aqua 才是桌面 session。
#
# 為什麼 --step=dmg 就夠：簽名不是編譯期做的，而是在 install/CPack 的腳本裡，由環境變數
# SHOULD_SIGN 開關（macos_build.sh 的 dmg 步驟會設它）。只要 CMakeCache.txt 裡的
# APPLE_CODESIGN_IDENTITY 與這次相同，同一份 build 目錄就能直接重打包 DMG。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO/cmake-build-macos-app"
DMG="$BUILD_DIR/cpack_artifacts/Lumax.dmg"
PROFILES_DIR="$REPO/src_assets/macos/profiles"
PROFILE_KIND_SH="$SCRIPT_DIR/profile-kind.sh"
PROFILE_FILE=""
IDENTITY="${APPLE_CODESIGN_IDENTITY:-}"
STEP="dmg"
SIGN="yes"
NOTARIZE=""
PROFILE_ARG=""

for a in "$@"; do
  case "$a" in
    --full) STEP="all" ;;
    --unsigned) SIGN="" ;;
    --dev) PROFILE_ARG="dev" ;;
    --release) PROFILE_ARG="release" ;;
    --profile=*) PROFILE_ARG="${a#*=}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "不認識的參數：${a}（可用：--full --unsigned --dev --release --profile=...）"; exit 1 ;;
  esac
done

echo "──────────────────────────────────────────────"
echo "  Lumax 正式版 DMG"
echo "──────────────────────────────────────────────"

# 1) session 必須是 Aqua，否則會卡在 Finder 排版
SESSION="$(launchctl managername 2>/dev/null || echo '?')"
if [ "$SESSION" != "Aqua" ]; then
  echo "❌ 目前的 launchd session 是「${SESSION}」，不是 Aqua。"
  echo "   請在 Mac Studio 的登入桌面開終端機（或雙擊本檔案），SSH 裡打包會卡死。"
  exit 1
fi
echo "✅ session：$SESSION"

# 1.5) 選擇 provisioning profile（src_assets/macos/profiles/）
_profile_kind() {
  if [ -x "$PROFILE_KIND_SH" ]; then
    "$PROFILE_KIND_SH" "$1" 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

_find_profile_by_kind() {
  local want="$1"
  local f
  for f in "$PROFILES_DIR"/*.provisionprofile; do
    [ -f "$f" ] || continue
    if [ "$(_profile_kind "$f")" = "$want" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

if [ -n "$SIGN" ]; then
  AVAILABLE_PROFILES=()
  if [ -d "$PROFILES_DIR" ]; then
    for f in "$PROFILES_DIR"/*.provisionprofile; do
      [ -f "$f" ] && AVAILABLE_PROFILES+=("$f")
    done
  fi

  # 預設優先選 distribution profile，其次第一個找到的，最後退回舊路徑
  DEFAULT_PROFILE="$(_find_profile_by_kind distribution || true)"
  if [ -z "$DEFAULT_PROFILE" ] && [ "${#AVAILABLE_PROFILES[@]}" -gt 0 ]; then
    DEFAULT_PROFILE="${AVAILABLE_PROFILES[0]}"
  elif [ -z "$DEFAULT_PROFILE" ] && [ -f "$REPO/src_assets/macos/Lumax.provisionprofile" ]; then
    DEFAULT_PROFILE="$REPO/src_assets/macos/Lumax.provisionprofile"
  fi

  if [ -n "$PROFILE_ARG" ]; then
    case "$PROFILE_ARG" in
      dev|development)
        PROFILE_FILE="$(_find_profile_by_kind development || true)"
        if [ -z "$PROFILE_FILE" ]; then
          echo "❌ 在 $PROFILES_DIR 找不到 Apple Development profile。"
          exit 1
        fi
        ;;
      release|dist|distribution)
        PROFILE_FILE="$(_find_profile_by_kind distribution || true)"
        if [ -z "$PROFILE_FILE" ]; then
          echo "❌ 在 $PROFILES_DIR 找不到 Developer ID（distribution）profile。"
          exit 1
        fi
        ;;
      *)
        if [ -f "$PROFILE_ARG" ]; then
          PROFILE_FILE="$PROFILE_ARG"
        elif [ -f "$PROFILES_DIR/$PROFILE_ARG" ]; then
          PROFILE_FILE="$PROFILES_DIR/$PROFILE_ARG"
        else
          echo "❌ 找不到指定的 profile：${PROFILE_ARG}"
          exit 1
        fi
        ;;
    esac
  elif [ -t 0 ] && [ "${#AVAILABLE_PROFILES[@]}" -gt 1 ]; then
    DEFAULT_NAME="$(basename "${DEFAULT_PROFILE:-none}")"
    echo "偵測到多個 provisioning profile，請選擇（直接按 Enter 預設：${DEFAULT_NAME}）："
    idx=1
    for f in "${AVAILABLE_PROFILES[@]}"; do
      kind="$(_profile_kind "$f")"
      echo "  [$idx] $(basename "$f")  (${kind})"
      idx=$((idx + 1))
    done
    printf "請輸入編號 [1-%d / Enter=預設]：" "${#AVAILABLE_PROFILES[@]}"
    read -r choice
    if [ -n "$choice" ]; then
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#AVAILABLE_PROFILES[@]}" ]; then
        PROFILE_FILE="${AVAILABLE_PROFILES[$((choice - 1))]}"
      else
        echo "❌ 無效的編號：${choice}"
        exit 1
      fi
    else
      PROFILE_FILE="$DEFAULT_PROFILE"
    fi
  else
    PROFILE_FILE="$DEFAULT_PROFILE"
  fi

  if [ -n "$PROFILE_FILE" ]; then
    export APPLE_PROVISION_PROFILE="$PROFILE_FILE"
    echo "✅ 使用 profile：$(basename "$PROFILE_FILE")"
  fi
fi

# 2) 簽名憑證：依選用的 profile 內嵌憑證類型自動選用 Apple Development 或 Developer ID
PROFILE_KIND="$(_profile_kind "${PROFILE_FILE:-}")"
if [ -n "$SIGN" ]; then
  # 要的是引號裡的憑證名稱。find-identity 的第 2 欄是 SHA-1，拿去 --sign 只會得到一個看不見的身分。
  if [ -z "$IDENTITY" ] && [ "$PROFILE_KIND" = "development" ]; then
    IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
    if [ -n "$IDENTITY" ]; then
      echo "ℹ️  偵測到 Development profile（$(basename "$PROFILE_FILE")），選用 Apple Development 憑證以啟用 Virtual HID"
    fi
  fi
  if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
  fi
  if [ -z "$IDENTITY" ]; then
    echo "❌ keychain 裡沒有「Developer ID Application」憑證。要準備的是：(Account Holder 才能建)"
    echo "   1) 鑰匙圈存取 → 憑證輔助程式 → 向憑證授權單位要求憑證（CA 電子郵件位址留空、勾「儲存到磁碟」→ 存成 .certSigningRequest）"
    echo "   2) developer.apple.com → Certificates, IDs & Profiles → Certificates → + → 選 Developer ID Application → 上傳 CSR → 下載後雙擊安裝"
    echo "   3) 公證還需要一把 App 專用密碼（account.apple.com → 登入與安全性 → App 專用密碼）"
    echo "      然後存成鑰匙圈設定檔（名字是寫死的）："
    echo "      xcrun notarytool store-credentials \"notarytool-password\" \\"
    echo "        --apple-id 你的AppleID --team-id 團隊ID --password xxxx-xxxx-xxxx-xxxx"
    echo "   （先想看看管線就跑 ./lumax-dmg.command --unsigned）"
    exit 1
  fi
  TEAM="${IDENTITY##*(}"; TEAM="${TEAM%%)}"
  echo "✅ 簽名身分：${IDENTITY}（profile 類型：${PROFILE_KIND}）"
  # 只有 Developer ID Application 才能送 Apple 公證；Apple Development 跳過公證。
  if [[ "$IDENTITY" != Developer\ ID\ Application:* ]]; then
    NOTARIZE=""
    echo "ℹ️  Apple Development 憑證不送 Apple 公證，僅做本機簽名。"
  elif xcrun notarytool history --keychain-profile notarytool-password >/dev/null 2>&1; then
    NOTARIZE="yes"
    echo "✅ 公證設定檔：notarytool-password（team ${TEAM}）"
  else
    NOTARIZE=""
    echo "⚠️  notarytool-password 這個 profile 不能用（沒存或認證失敗），這次只簽名、不送公證。"
    echo "    補法：xcrun notarytool store-credentials notarytool-password --apple-id ... --team-id ${TEAM} --password xxxx-xxxx-xxxx-xxxx"
  fi
  export APPLE_CODESIGN_IDENTITY="$IDENTITY"
fi

# 尚未 configure 過時，直接改跑 all
if [ "$STEP" = "dmg" ] && [ ! -f "$BUILD_DIR/CPackConfig.cmake" ]; then
  STEP="all"
  echo "ℹ️  尚未建置過 → 改跑 cmake + build + dmg"
fi

# 簽名身分是在 cmake configure 時期就被展開進 cmake_install.cmake 的，
# 只有當 CMakeCache.txt 裡的 APPLE_CODESIGN_IDENTITY 跟這次不同才需要重跑 all。
if [ -n "$SIGN" ] && [ "$STEP" = "dmg" ]; then
  CACHED_IDENTITY=""
  if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
    CACHED_IDENTITY="$(sed -n 's/^APPLE_CODESIGN_IDENTITY:STRING=//p' "$BUILD_DIR/CMakeCache.txt" | head -1)"
  fi
  if [ "$CACHED_IDENTITY" != "$IDENTITY" ]; then
    STEP="all"
    echo "ℹ️  簽名身分與上次 configure 不同 → 改跑 cmake + build + dmg"
  fi
fi

VERSION="$(tr -d '[:space:]' < "$REPO/LUMEN_VERSION" 2>/dev/null || echo unknown)"
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
APP="$BUILD_DIR/cpack_artifacts/_CPack_Packages/Darwin/DragNDrop/Lumax/.Lumax/Lumax.app"
OUT="$HOME/Desktop/Lumax-$VERSION-$(uname -m).dmg"
cp -f "$DMG" "$OUT"

echo "── 產物 ─────────────────────────────"
ls -lh "$OUT" | awk '{print $5, $NF}'
echo "frame_drain（patched FFmpeg 有沒有進去）：$(strings "$APP/Contents/MacOS/Lumax" 2>/dev/null | grep -c '^frame_drain$') （要 ≥1）"
if [ -n "$SIGN" ]; then
  echo "── codesign ─────────────────────────"
  codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Runtime)" | sed 's/^/  /'
  codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1 | sed 's/^/  /'
  if [ -n "$NOTARIZE" ]; then
    echo "── Gatekeeper ───────────────────────"
    spctl -a -vv "$APP" 2>&1 | sed 's/^/  /'
    echo "── 公證 staple ──────────────────────"
    xcrun stapler validate "$OUT" 2>&1 | tail -2 | sed 's/^/  /'
  else
    echo "ℹ️  本次未送 Apple 公證，略過 Gatekeeper / stapler 驗證。"
  fi
fi
echo
echo "拿到另一台 Mac 就拖這個：$OUT"
echo "（未簽名或僅 Apple Development 簽名的話，對方要用 right-click → Open，或 xattr -d com.apple.quarantine 那個 dmg）"
