#!/usr/bin/env bash
#
# build.sh — compile the Swift supertoroid renderer and wrap it in a .app bundle.
#
# Usage:
#   ./build.sh            # build build/Supertoroid and build/Supertoroid.app
#   ./build.sh --run      # build, then launch the app
#
# Put this script next to main.swift. Make it executable once: chmod +x build.sh
#
set -euo pipefail

APP_NAME="Supertoroid"
BUNDLE_ID="com.nightmarez.supertoroid"
SRC="main.swift"
BUILD_DIR="build"
BIN="$BUILD_DIR/$APP_NAME"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# --- sanity checks ---------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
    echo "error: swiftc not found. Install Xcode or the Command Line Tools:" >&2
    echo "       xcode-select --install" >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "error: $SRC not found in $(pwd)" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

# --- compile ---------------------------------------------------------------
# -O               : optimize
# -suppress-warnings: hide the (expected) OpenGL deprecation spam.
#                    Remove it the first time if you want to see everything.
echo "Compiling $SRC ..."
swiftc "$SRC" \
    -O \
    -o "$BIN" \
    -framework Cocoa \
    -framework OpenGL \
    -suppress-warnings

echo "  -> $BIN"

# --- wrap into a .app bundle ----------------------------------------------
echo "Building app bundle ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>         <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>          <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleVersion</key>             <string>1.0</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>LSMinimumSystemVersion</key>      <string>10.14</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "  -> $APP_BUNDLE"
echo "Done."

# --- optional run ----------------------------------------------------------
if [ "${1:-}" = "--run" ]; then
    echo "Launching ..."
    open "$APP_BUNDLE"
fi