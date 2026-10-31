#!/usr/bin/env bash
## @file build.sh
## @brief Build and deploy Lumen with the macOS system tray enabled by default.
## @details Initialize macOS application dependencies without recursive documentation,
## test, or FFmpeg source downloads. This script builds with documentation and tests disabled.
## The FFmpeg dependency is chosen explicitly: the frame drain latency fix lives in a patched
## FFmpeg, so silently linking the published dependency archive would undo it. Set
## LUMEN_FFMPEG_BUNDLE to a bundle directory, or to "auto" to build one, see
## third-party/ffmpeg-patches/README.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-cmake-build-macos}"
LUMEN_BIN="$(brew --prefix lumen)/bin/lumen"

cd "$REPO_DIR"

bash "$REPO_DIR/scripts/configure-prebuilt-ffmpeg.sh"
# @brief Fetch application libraries only; their standalone docs/tests are not built here.
git submodule update --init -- \
  third-party/Simple-Web-Server \
  third-party/TPCircularBuffer \
  third-party/lizardbyte-common \
  third-party/libdisplaydevice \
  third-party/libvirtualhid \
  third-party/moonlight-common-c \
  third-party/tray
git -C third-party/moonlight-common-c submodule update --init -- enet nanors

REBASE_VERSION="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || echo '0.0.0')"

echo "==> Checking build directory: $BUILD_DIR"

# The patched bundle is what carries the frame drain improvement, and nothing about a build fails
# when it is missing, so the choice is made here and printed. grep reads a file rather than a pipe:
# grep -q exits early, which under pipefail makes a successful match look like a failed pipeline.
FFMPEG_BUNDLE="${LUMEN_FFMPEG_BUNDLE:-$HOME/lumen-ffmpeg-bundle/bundle/ffmpeg}"
if [[ "$FFMPEG_BUNDLE" == "auto" ]]; then
  echo "==> Building the patched FFmpeg bundle (this takes a few minutes the first time)..."
  WORK="$HOME/lumen-ffmpeg-bundle" bash "$REPO_DIR/third-party/ffmpeg-patches/build-bundle.sh"
  FFMPEG_BUNDLE="$HOME/lumen-ffmpeg-bundle/bundle/ffmpeg"
fi

FFMPEG_CMAKE_ARGS=()
if [[ -f "$FFMPEG_BUNDLE/lib/libavcodec.a" ]]; then
  drain_symbols="$(mktemp)"
  strings "$FFMPEG_BUNDLE/lib/libavcodec.a" > "$drain_symbols"
  if grep -q "^frame_drain$" "$drain_symbols"; then
    echo "==> FFmpeg: $FFMPEG_BUNDLE (frame drain available)"
  else
    echo "==> FFmpeg: $FFMPEG_BUNDLE (no frame_drain option, host latency stays at the old level)"
  fi
  rm -f "$drain_symbols"
  FFMPEG_CMAKE_ARGS+=(-D"FFMPEG_PREPARED_BINARIES=$FFMPEG_BUNDLE")
else
  echo "==> FFmpeg: published dependency archive (no frame_drain option, host latency stays at the"
  echo "    old level). Run third-party/ffmpeg-patches/build-bundle.sh, or set LUMEN_FFMPEG_BUNDLE=auto"
  echo "    to build it here.)"
fi

cached_ffmpeg() {
  sed -n 's/^FFMPEG_PREPARED_BINARIES:[^=]*=//p' "$BUILD_DIR/CMakeCache.txt" 2>/dev/null | head -1
}

need_configure=false
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" || ! -f "$BUILD_DIR/Makefile" ]]; then
  need_configure=true
elif ! grep -q "^SUNSHINE_REBASE_VERSION:INTERNAL=${REBASE_VERSION}$" "$BUILD_DIR/CMakeCache.txt"; then
  need_configure=true
elif [[ ${#FFMPEG_CMAKE_ARGS[@]} -gt 0 && "$(cached_ffmpeg)" != "$FFMPEG_BUNDLE" ]]; then
  previous_ffmpeg="$(cached_ffmpeg)"
  echo "==> FFmpeg path changed from ${previous_ffmpeg:-the downloaded archive}, reconfiguring"
  need_configure=true
fi

if [[ "$need_configure" == true ]]; then
  cmake -S . -B "$BUILD_DIR" -G "Unix Makefiles" \
    -DCMAKE_CXX_STANDARD=23 \
    -DHOMEBREW_ALLOW_FETCHCONTENT=ON \
    -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
    -DSUNSHINE_ASSETS_DIR="$(brew --prefix lumen)/lumen/assets" \
    -DSUNSHINE_BUILD_HOMEBREW=ON \
    -DSUNSHINE_ENABLE_TRAY=ON \
    -DBUILD_TESTS=OFF \
    -DBUILD_DOCS=OFF \
    -DBOOST_USE_STATIC=OFF \
    ${FFMPEG_CMAKE_ARGS[@]+"${FFMPEG_CMAKE_ARGS[@]}"}
fi

LUMEN_VERSION_FILE="$REPO_DIR/LUMEN_VERSION"
if [[ -f "$LUMEN_VERSION_FILE" ]]; then
  CURRENT_LUMEN_VER="$(tr -d '[:space:]' < "$LUMEN_VERSION_FILE")"
  if [[ "$CURRENT_LUMEN_VER" == "0.9.9" ]]; then
    NEXT_LUMEN_VER="1.0.0"
  elif [[ "$CURRENT_LUMEN_VER" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    NEXT_LUMEN_VER="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  else
    NEXT_LUMEN_VER="1.0.0"
  fi
else
  NEXT_LUMEN_VER="1.0.0"
fi
echo "==> Lumen version: $NEXT_LUMEN_VER (base Sunshine: $REBASE_VERSION)"

cat > "$BUILD_DIR/lumen_version.h" <<EOF
/**
 * @file lumen_version.h
 * @brief Generated Lumen version header.
 */
#pragma once
#define LUMEN_VERSION "${NEXT_LUMEN_VER}"
EOF

if [[ ! -f "$BUILD_DIR/assets/web/index.html" ]] || [[ -n "$(find src_assets/common/assets/web -newer "$BUILD_DIR/assets/web/index.html" -print -quit 2>/dev/null)" ]]; then
  echo "==> Building Web UI assets..."
  if [[ ! -d "node_modules" || "package-lock.json" -nt "node_modules/.package-lock.json" ]]; then
    npm ci --ignore-scripts
  fi
  SUNSHINE_SOURCE_ASSETS_DIR="$REPO_DIR/src_assets" SUNSHINE_ASSETS_DIR="$REPO_DIR/$BUILD_DIR" npm run build
fi

echo "==> Performing incremental compile..."
cmake --build "$BUILD_DIR" --target lumen -j"$(sysctl -n hw.ncpu)"

echo "==> Deploying binary to $LUMEN_BIN..."
brew services stop lumen 2>/dev/null || true
install -m 755 "$BUILD_DIR/lumen" "$LUMEN_BIN"

echo "==> Deploying assets..."
ASSETS_DEST="$(brew --prefix lumen)/lumen/assets"
mkdir -p "$ASSETS_DEST"
if [[ -d "$BUILD_DIR/assets" ]]; then
  cp -R "$BUILD_DIR/assets/" "$ASSETS_DEST/"
fi

echo "==> Signing binary..."
SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '["]' '/Apple Development:/ {print $2; exit}')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  if ! codesign -s "$SIGN_IDENTITY" --identifier "com.saxlamen.lumen" --force "$LUMEN_BIN" 2>/dev/null; then
    echo "    Keychain is locked for codesign. Unlocking login keychain..."
    security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
    codesign -s "$SIGN_IDENTITY" --identifier "com.saxlamen.lumen" --force "$LUMEN_BIN"
  fi
else
  echo "    Warning: Developer certificate not found, using ad-hoc signing."
  codesign -s - --identifier "com.saxlamen.lumen" --force "$LUMEN_BIN"
fi

echo "==> Restarting lumen service..."
if ! brew services start lumen; then
  PLIST_SRC="$(brew --prefix lumen)/sh.brew.lumen.plist"
  PLIST_DST="$HOME/Library/LaunchAgents/sh.brew.lumen.plist"
  if [[ -f "$PLIST_SRC" ]]; then
    cp "$PLIST_SRC" "$PLIST_DST"
    launchctl bootout "gui/$(id -u)/sh.brew.lumen" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
  fi
fi
echo "$NEXT_LUMEN_VER" > "$LUMEN_VERSION_FILE"
echo "==> Done (Lumen $NEXT_LUMEN_VER)."
