#!/usr/bin/env bash
## @file build.sh
## @brief Build and package/deploy Lumen on macOS (DMG or Homebrew).
## @details Supports two distribution targets:
## - `--dmg`: Build and package a macOS `.app` / `.dmg` via `tools/macos-dmg/lumen-dmg.command`.
## - `--homebrew`: Build with the macOS system tray enabled and deploy to the Homebrew `lumen` prefix.
##
## In `--homebrew` mode, FFmpeg is chosen explicitly: the frame drain latency fix lives in a patched
## FFmpeg, so silently linking the published dependency archive would undo it. Set
## LUMEN_FFMPEG_BUNDLE to a bundle directory, or to "auto" to build one, see
## third-party/ffmpeg-patches/README.md.
##
## @par Usage
## `./build.sh [--dmg|--homebrew] [--no-bump|-n] [--full] [--unsigned] [--help|-h]`
## By default each run increments the patch part of LUMEN_VERSION and writes it back. `--no-bump`
## builds at the version already recorded without touching the file. `--full` and `--unsigned`
## are forwarded to `lumen-dmg.command` in `--dmg` mode. If neither `--dmg` nor `--homebrew` is
## given in an interactive terminal, the script prompts you to choose.
## Environment knobs: BUILD_DIR, LUMEN_FFMPEG_BUNDLE, APPLE_CODESIGN_IDENTITY.
set -euo pipefail

mode=""
version_bump=true
dmg_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      mode="dmg"
      ;;
    --homebrew | --brew)
      mode="homebrew"
      ;;
    --full | --unsigned)
      dmg_args+=("$1")
      ;;
    -n | --no-bump)
      version_bump=false
      ;;
    -h | --help)
      sed -n '2,19p' "$0" | sed 's/^## \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1 (try --help)" >&2
      exit 2
      ;;
  esac
  shift
done

find_installed_apps() {
  local candidate
  for candidate in \
    "/Applications/Sunshine.app" \
    "/Applications/Lumen.app" \
    "/Applications/Lumax.app" \
    "$HOME/Applications/Sunshine.app" \
    "$HOME/Applications/Lumen.app" \
    "$HOME/Applications/Lumax.app"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
    fi
  done
}

if [[ -z "$mode" ]]; then
  if [[ -t 0 ]]; then
    brew_status="not installed"
    if brew list --formula lumen >/dev/null 2>&1; then
      brew_status="installed ($(brew --prefix lumen))"
    fi
    app_list="$(find_installed_apps | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    app_status="${app_list:-not installed}"

    echo "Current installations:"
    echo "  - Homebrew lumen: $brew_status"
    echo "  - Applications:   $app_status"
    echo ""
    echo "Select build target:"
    echo "  1) DMG (.app / .dmg via tools/macos-dmg/lumen-dmg.command)"
    echo "  2) Homebrew (deploy to brew prefix & restart service)"
    read -r -p "Choice [1/2]: " choice
    case "$choice" in
      1 | dmg)
        mode="dmg"
        ;;
      2 | homebrew | brew)
        mode="homebrew"
        ;;
      *)
        echo "Invalid choice: $choice" >&2
        exit 2
        ;;
    esac
  else
    echo "Missing build mode: specify --dmg or --homebrew (try --help)" >&2
    exit 2
  fi
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LUMEN_VERSION_FILE="$REPO_DIR/LUMEN_VERSION"

cd "$REPO_DIR"

compute_next_version() {
  local current_ver=""
  if [[ -f "$LUMEN_VERSION_FILE" ]]; then
    current_ver="$(tr -d '[:space:]' < "$LUMEN_VERSION_FILE")"
  fi
  if [[ "$version_bump" == false && "$current_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$current_ver"
  elif [[ "$current_ver" == "0.9.9" ]]; then
    echo "1.0.0"
  elif [[ "$current_ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
  else
    echo "1.0.0"
  fi
}

NEXT_LUMEN_VER="$(compute_next_version)"

if [[ "$mode" == "dmg" ]]; then
  if brew list --formula lumen >/dev/null 2>&1; then
    echo "Warning: Homebrew formula 'lumen' is currently installed ($(brew --prefix lumen))."
    echo "         Running both Homebrew lumen and the DMG .app can conflict."
    if [[ -t 0 ]]; then
      read -r -p "Stop and uninstall Homebrew 'lumen' now? [y/N]: " remove_brew
      if [[ "$remove_brew" =~ ^[Yy]$ ]]; then
        brew services stop lumen 2>/dev/null || true
        brew uninstall lumen
      fi
    fi
  fi
  while IFS= read -r app_path; do
    echo "Note: Existing app bundle found at $app_path (replace it after opening the new DMG)."
  done < <(find_installed_apps)

  prev_ver=""
  had_version_file=false
  if [[ -f "$LUMEN_VERSION_FILE" ]]; then
    had_version_file=true
    prev_ver="$(cat "$LUMEN_VERSION_FILE")"
  fi
  if [[ "$version_bump" == true ]]; then
    echo "$NEXT_LUMEN_VER" > "$LUMEN_VERSION_FILE"
  fi
  if ! bash "$REPO_DIR/tools/macos-dmg/lumen-dmg.command" ${dmg_args[@]+"${dmg_args[@]}"}; then
    if [[ "$version_bump" == true ]]; then
      if [[ "$had_version_file" == true ]]; then
        printf '%s' "$prev_ver" > "$LUMEN_VERSION_FILE"
      else
        rm -f "$LUMEN_VERSION_FILE"
      fi
    fi
    exit 1
  fi
  if [[ "$version_bump" == false ]]; then
    echo "==> LUMEN_VERSION left at $NEXT_LUMEN_VER, not incremented."
  fi
  exit 0
fi

BUILD_DIR="${BUILD_DIR:-cmake-build-macos}"
while IFS= read -r app_path; do
  echo "Warning: Existing app bundle found at $app_path."
  echo "         Using both the .app bundle and Homebrew 'lumen' can conflict."
  if [[ -t 0 ]]; then
    read -r -p "Remove $app_path now? [y/N]: " remove_app
    if [[ "$remove_app" =~ ^[Yy]$ ]]; then
      rm -rf "$app_path"
      echo "==> Removed $app_path"
    fi
  fi
done < <(find_installed_apps)

if ! brew list --formula lumen >/dev/null 2>&1; then
  echo "==> Homebrew formula 'lumen' is not installed, installing saxlamen/lumen-local/lumen..."
  brew install saxlamen/lumen-local/lumen
fi
LUMEN_PREFIX="$(brew --prefix lumen)"
LUMEN_BIN="$LUMEN_PREFIX/bin/lumen"

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
FFMPEG_BUNDLE="${LUMEN_FFMPEG_BUNDLE:-$HOME/Scripts/Lumen/deps/lumen-ffmpeg-bundle/bundle/ffmpeg}"
if [[ "$FFMPEG_BUNDLE" == "auto" ]]; then
  echo "==> Building the patched FFmpeg bundle (this takes a few minutes the first time)..."
  WORK="$HOME/Scripts/Lumen/deps/lumen-ffmpeg-bundle" bash "$REPO_DIR/third-party/ffmpeg-patches/build-bundle.sh"
  FFMPEG_BUNDLE="$HOME/Scripts/Lumen/deps/lumen-ffmpeg-bundle/bundle/ffmpeg"
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
if [[ ! -d "$LUMEN_PREFIX/bin" ]]; then
  echo "Error: Homebrew formula 'lumen' is not installed ($LUMEN_PREFIX/bin not found)." >&2
  echo "Install it first (e.g. 'brew install saxlamen/lumen-local/lumen') or use './build.sh --dmg'." >&2
  exit 1
fi
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
PLIST_SRC="$(brew --prefix lumen)/sh.brew.lumen.plist"
PLIST_DST="$HOME/Library/LaunchAgents/sh.brew.lumen.plist"
if ! brew services start lumen; then
  if [[ -f "$PLIST_SRC" ]]; then
    cp "$PLIST_SRC" "$PLIST_DST"
    launchctl bootout "gui/$(id -u)/sh.brew.lumen" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
  fi
fi

# launchd throttles the timers of agents that do not declare themselves interactive. Measured on
# an 8ms mach_wait_until deadline: 26ms median oversleep without this key, 2ms with it, which is
# the difference between a 30Hz and a 125Hz scroll inertia. Homebrew regenerates the plist on every
# service start and its service DSL has no ProcessType key, so it is re-added after each start.
if [[ -f "$PLIST_DST" ]] && ! /usr/libexec/PlistBuddy -c "Print :ProcessType" "$PLIST_DST" >/dev/null 2>&1; then
  echo "==> Setting ProcessType=Interactive on the LaunchAgent..."
  /usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$PLIST_DST"
  launchctl bootout "gui/$(id -u)/sh.brew.lumen" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
fi
if [[ "$version_bump" == true ]]; then
  echo "$NEXT_LUMEN_VER" > "$LUMEN_VERSION_FILE"
else
  echo "==> LUMEN_VERSION left at $NEXT_LUMEN_VER, not incremented."
fi
echo "==> Done (Lumen $NEXT_LUMEN_VER)."
