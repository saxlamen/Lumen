#!/usr/bin/env bash
## @file build.sh
## @brief Build and deploy Lumen with the macOS system tray enabled by default.
## @details Initialize macOS application dependencies without recursive documentation,
## test, or FFmpeg source downloads. This script builds with documentation and tests disabled.
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

echo "==> Checking build directory: $BUILD_DIR"
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" || ! -f "$BUILD_DIR/Makefile" ]]; then
  cmake -S . -B "$BUILD_DIR" -G "Unix Makefiles" \
    -DCMAKE_CXX_STANDARD=23 \
    -DHOMEBREW_ALLOW_FETCHCONTENT=ON \
    -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
    -DSUNSHINE_ASSETS_DIR="$(brew --prefix lumen)/lumen/assets" \
    -DSUNSHINE_BUILD_HOMEBREW=ON \
    -DSUNSHINE_ENABLE_TRAY=ON \
    -DBUILD_TESTS=OFF \
    -DBUILD_DOCS=OFF \
    -DBOOST_USE_STATIC=OFF
fi

echo "==> Performing incremental compile..."
cmake --build "$BUILD_DIR" --target lumen -j"$(sysctl -n hw.ncpu)"

echo "==> Deploying binary to $LUMEN_BIN..."
brew services stop lumen 2>/dev/null || true
install -m 755 "$BUILD_DIR/lumen" "$LUMEN_BIN"

echo "==> Signing binary..."
SIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '["]' '/Apple Development:/ {print $2; exit}')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign -s "$SIGN_IDENTITY" --identifier "com.saxlamen.lumen" --force "$LUMEN_BIN"
else
  echo "    Warning: Developer certificate not found, using ad-hoc signing."
  codesign -s - --identifier "com.saxlamen.lumen" --force "$LUMEN_BIN"
fi

echo "==> Restarting lumen service..."
brew services start lumen
echo "==> Done."
