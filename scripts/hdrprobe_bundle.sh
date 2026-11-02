#!/bin/sh
# Build and code sign hdrprobe.swift as a minimal .app bundle.
#
# Screen Recording permission is granted by code signing identity, not by path, and a bare command
# line binary launched from a terminal inherits the permission of its parent process (tmux, a shell).
# Wrapping the probe in a bundle and launching it with open(1) gives it its own TCC identity, so it
# appears as "hdrprobe" in Privacy & Security -> Screen Recording and the grant survives rebuilds.
#
# Usage:
#   scripts/hdrprobe_bundle.sh [output_dir]        # default: cmake-build-vtpoc
#   open -n --stdout /tmp/hdrprobe.log --stderr /tmp/hdrprobe.err <the .app>
#
# Override the signing identity with HDRPROBE_IDENTITY="Apple Development: ..." if the Developer ID
# certificate is unavailable; TCC then keys the grant to the exact cdhash instead.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${1:-"$SCRIPT_DIR/../cmake-build-vtpoc"}
BUNDLE_ID=com.saxlamen.hdrprobe
IDENTITY=${HDRPROBE_IDENTITY:-"Developer ID Application: HSINWEI LIAO (3PNN7QU2V7)"}

APP="$OUT_DIR/hdrprobe.app"
CONTENTS="$APP/Contents"

mkdir -p "$CONTENTS/MacOS"

swiftc -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  "$SCRIPT_DIR/hdrprobe.swift" -o "$CONTENTS/MacOS/hdrprobe"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>hdrprobe</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>hdrprobe</string>
  <key>CFBundleDisplayName</key><string>hdrprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --timestamp=none keeps the build offline and the cdhash stable enough for repeated measurements.
codesign --force --timestamp=none --identifier "$BUNDLE_ID" -s "$IDENTITY" "$APP"

# Register the bundle so System Settings and tccutil can resolve the bundle identifier.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$APP"

codesign -dvv "$APP" 2>&1 | grep -E "^Identifier|^Authority|^Signature" || true
echo "built: $APP"
