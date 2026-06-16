#!/usr/bin/env bash
# Creates PathOfBuilding.app bundle and installs it to /Applications.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$REPO_ROOT/build-mac/install"
BINARY="$INSTALL_DIR/PathOfBuilding"
SCRIPT="$REPO_ROOT/src/Launch.lua"
ICNS="$REPO_ROOT/macos/AppIcon.icns"
APP_NAME="PathOfBuilding.app"
APP_DEST="/Applications/$APP_NAME"
TMP_APP="/tmp/$APP_NAME"

# ── sanity checks ────────────────────────────────────────────────────────────
if [[ ! -f "$BINARY" ]]; then
  echo "ERROR: binary not found at $BINARY — run 'make build' first."
  exit 1
fi

if [[ ! -f "$ICNS" ]]; then
  echo "Generating icon..."
  python3 "$REPO_ROOT/macos/make_icon.py" "$ICNS"
fi

# ── build bundle in /tmp first ───────────────────────────────────────────────
rm -rf "$TMP_APP"
CONTENTS="$TMP_APP/Contents"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Launcher script — sets env vars then execs the real binary
cat > "$CONTENTS/MacOS/PathOfBuilding" << LAUNCHER
#!/usr/bin/env bash
INSTALL_DIR="$INSTALL_DIR"
SCRIPT="$SCRIPT"
export DYLD_LIBRARY_PATH="\$INSTALL_DIR"
export LUA_CPATH="\$INSTALL_DIR/?.dylib;\$INSTALL_DIR/?.so;;"
export LUA_PATH="./?.lua;./lua/?.lua;./lua/?/init.lua;;"
cd "\$INSTALL_DIR"
exec "\$INSTALL_DIR/PathOfBuilding" "\$SCRIPT" "\$@"
LAUNCHER
chmod +x "$CONTENTS/MacOS/PathOfBuilding"

# Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PathOfBuilding</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.pathofbuilding.poe2</string>
    <key>CFBundleName</key>
    <string>Path of Building</string>
    <key>CFBundleDisplayName</key>
    <string>Path of Building</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

# Icon
cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"

# ── install to /Applications ─────────────────────────────────────────────────
echo "Installing to $APP_DEST ..."
rm -rf "$APP_DEST"
cp -r "$TMP_APP" "$APP_DEST"

# Tell Spotlight / LaunchServices to index the new app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DEST" 2>/dev/null || true

echo ""
echo "Done! Launch with: open -a 'Path of Building'"
echo "Or find it in Spotlight / Launchpad."
