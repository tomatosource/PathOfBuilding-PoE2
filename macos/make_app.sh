#!/usr/bin/env bash
# Builds a self-contained PathOfBuilding.app bundle and installs it to /Applications.
# The resulting .app has no dependency on the repo — copy/AirDrop it to any M-series Mac.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$REPO_ROOT/build-mac/install"
BINARY="$INSTALL_DIR/PathOfBuilding"
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

# ── scaffold bundle dirs ─────────────────────────────────────────────────────
rm -rf "$TMP_APP"
CONTENTS="$TMP_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES"

# ── copy binary (renamed so the wrapper can sit at the CFBundleExecutable name)
cp "$BINARY" "$MACOS/PathOfBuildingBin"
chmod +x "$MACOS/PathOfBuildingBin"

# ── copy all dylibs from install dir, preserving symlinks ────────────────────
# Real dylib files first
find "$INSTALL_DIR" -maxdepth 1 -name "*.dylib" ! -type l -exec cp {} "$MACOS/" \;
# Then symlinks (recreate them so they point within MacOS/)
find "$INSTALL_DIR" -maxdepth 1 -name "*.dylib" -type l | while read -r link; do
  name="$(basename "$link")"
  target="$(readlink "$link")"
  # target is always a bare filename (e.g. liblibEGL_angle.dylib) — keep as-is
  ln -sf "$target" "$MACOS/$name"
done

# ── Lua C-module subdirectory symlinks (lcurl/safe, socket/core) ─────────────
mkdir -p "$MACOS/lcurl" "$MACOS/socket"
# lcurl/safe.dylib → ../liblcurl.dylib
ln -sf "../liblcurl.dylib"  "$MACOS/lcurl/safe.dylib"
# socket/core.dylib → ../libsocket.dylib
ln -sf "../libsocket.dylib" "$MACOS/socket/core.dylib"

# ── OpenSSL modules ───────────────────────────────────────────────────────────
# libcrypto has MODULESDIR baked to the build path; OPENSSL_MODULES env var
# overrides it at runtime (set in the wrapper below).
if [[ -d "$INSTALL_DIR/ossl-modules" ]]; then
  cp -r "$INSTALL_DIR/ossl-modules" "$MACOS/ossl-modules"
fi

# ── SimpleGraphic runtime dir (fonts + default config) ───────────────────────
if [[ -d "$INSTALL_DIR/SimpleGraphic" ]]; then
  cp -r "$INSTALL_DIR/SimpleGraphic" "$MACOS/SimpleGraphic"
fi

# ── Pure-Lua modules (runtime/lua/) ──────────────────────────────────────────
cp -r "$REPO_ROOT/runtime/lua/" "$RESOURCES/lua/"

# ── Lua source tree (src/) ────────────────────────────────────────────────────
# Exclude the 'lua' symlink (replaced by Resources/lua/), user-data files,
# and the Builds dir (user builds live in ~/.local/share/ in installed mode).
rsync -a \
  --exclude=lua \
  --exclude='Settings.xml' \
  --exclude='imgui.ini' \
  --exclude='poe_api_response.json' \
  "$REPO_ROOT/src/" "$RESOURCES/src/"

# ── manifest.xml ──────────────────────────────────────────────────────────────
# Launch.lua looks for manifest.xml then ../manifest.xml relative to scriptWorkDir
# (which is Resources/src/), so put it one level up at Resources/.
cp "$INSTALL_DIR/manifest.xml" "$RESOURCES/manifest.xml"

# ── Icon ──────────────────────────────────────────────────────────────────────
cp "$ICNS" "$RESOURCES/AppIcon.icns"

# ── Wrapper launcher ──────────────────────────────────────────────────────────
# This is the CFBundleExecutable. It sets env vars and execs the real binary.
# All paths are computed at runtime relative to the bundle — no hardcoded paths.
cat > "$MACOS/PathOfBuilding" << 'LAUNCHER'
#!/usr/bin/env bash
BUNDLE="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$BUNDLE/MacOS"
RESOURCES="$BUNDLE/Resources"
export DYLD_LIBRARY_PATH="$MACOS"
export LUA_CPATH="$MACOS/?.dylib;$MACOS/?.so;;"
export LUA_PATH="$RESOURCES/lua/?.lua;$RESOURCES/lua/?/init.lua;;"
export OPENSSL_MODULES="$MACOS/ossl-modules"
exec "$MACOS/PathOfBuildingBin" "$RESOURCES/src/Launch.lua" "$@"
LAUNCHER
chmod +x "$MACOS/PathOfBuilding"

# ── Info.plist ────────────────────────────────────────────────────────────────
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
</dict>
</plist>
PLIST

# ── install to /Applications ──────────────────────────────────────────────────
echo "Installing to $APP_DEST ..."
rm -rf "$APP_DEST"
cp -r "$TMP_APP" "$APP_DEST"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DEST" 2>/dev/null || true

echo ""
echo "Bundle size: $(du -sh "$APP_DEST" | cut -f1)"
echo "Done! The .app at $APP_DEST is fully self-contained."
echo "Copy or AirDrop it to any M-series Mac running macOS 13+ — no repo needed."
