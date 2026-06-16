#!/usr/bin/env bash
# Build script for Path of Building on macOS.
# First run downloads/builds all dependencies and may take 30-90 minutes.
# Subsequent runs are fast (only recompiles changed files).
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SG_DIR="$REPO_ROOT/SimpleGraphic-src"
MACOS_DIR="$REPO_ROOT/macos"
BUILD_DIR="$REPO_ROOT/build-mac"
INSTALL_DIR="$BUILD_DIR/install"
VCPKG_DIR="$SG_DIR/vcpkg"
TRIPLET="arm64-osx-dynamic"
NCPU="$(sysctl -n hw.ncpu)"

# ── Helpers ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[PoB]${NC} $*"; }
warn() { echo -e "${YELLOW}[PoB]${NC} $*"; }
die()  { echo -e "${RED}[PoB]${NC} $*" >&2; exit 1; }

# ── Check prerequisites ───────────────────────────────────────────────────────
command -v cmake  >/dev/null 2>&1 || die "cmake not found. Install with: brew install cmake"
command -v git    >/dev/null 2>&1 || die "git not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."

# LuaJIT via Homebrew is required (the vcpkg custom portfile crashes on ARM64)
if [ ! -f "/opt/homebrew/opt/luajit/lib/libluajit-5.1.a" ]; then
    die "Homebrew LuaJIT not found. Install with: brew install luajit"
fi
log "Found Homebrew LuaJIT at /opt/homebrew/opt/luajit"

# ── 1. Clone/verify SimpleGraphic ────────────────────────────────────────────
if [ ! -f "$SG_DIR/CMakeLists.txt" ]; then
    # Source not present — clone from upstream.
    log "Cloning SimpleGraphic (this may take a few minutes)..."
    git clone --recursive \
        "https://github.com/PathOfBuildingCommunity/PathOfBuilding-SimpleGraphic.git" \
        "$SG_DIR"
elif [ -d "$SG_DIR/.git" ]; then
    log "SimpleGraphic already cloned at $SG_DIR"
    # Ensure submodules are populated (vcpkg, dep/, libs/)
    (cd "$SG_DIR" && git submodule update --init --recursive --quiet)
else
    log "SimpleGraphic inlined in repo at $SG_DIR"
fi

# ── 2. Apply macOS patches ────────────────────────────────────────────────────
log "Applying macOS patches to SimpleGraphic..."
python3 "$MACOS_DIR/patches/fix-luasocket-macos.py" "$SG_DIR/CMakeLists.txt"

# vcpkg custom LuaJIT portfile ships a 'configure' script that loses
# execute permissions when stored in git (git doesn't track +x for blobs).
find "$SG_DIR/vcpkg-ports/ports/luajit" -name "configure" -exec chmod +x {} \;

# Fix circular-symlink bug in LuaJIT portfile configure script.
# Also disable JIT (required on macOS ARM64 without JIT entitlement).
for configure in "$SG_DIR/vcpkg-ports/ports/luajit"/*/configure; do
    python3 "$MACOS_DIR/patches/fix-luajit-install.py" "$configure"
    python3 "$MACOS_DIR/patches/fix-luajit-macos-arm64.py" "$configure"
done

# Fix duplicate symbol 'luaL_setfuncs' in Lua-cURLv3 l52util.c when building
# against LuaJIT static library (which already provides the function).
python3 "$MACOS_DIR/patches/fix-lcurl-luajit-compat.py" \
    "$SG_DIR/libs/Lua-cURLv3/src/l52util.c"

# Fix missing stddef.h/string.h includes in base64.h (clang strict mode).
python3 "$MACOS_DIR/patches/fix-base64-includes.py" \
    "$SG_DIR/engine/common/base64.h"

# Fix macOS-specific issues in SimpleGraphic rendering sources.
python3 "$MACOS_DIR/patches/fix-simplegraphic-macos.py" "$SG_DIR"

# ── 3. Bootstrap vcpkg ───────────────────────────────────────────────────────
if [ ! -f "$VCPKG_DIR/vcpkg" ]; then
    log "Bootstrapping vcpkg (this takes a couple of minutes)..."
    (cd "$VCPKG_DIR" && ./bootstrap-vcpkg.sh -disableMetrics)
fi

# ── 4. Generate vcpkg-configuration.json with absolute path to custom ports ──
# This must be in the same directory as vcpkg.json (macos/) so vcpkg picks it up.
log "Generating vcpkg-configuration.json..."
cat > "$MACOS_DIR/vcpkg-configuration.json" <<EOF
{
  "default-registry": {
    "kind": "builtin",
    "baseline": "66c0373dc7fca549e5803087b9487edfe3aca0a1"
  },
  "registries": [
    {
      "kind": "filesystem",
      "path": "${SG_DIR}/vcpkg-ports",
      "baseline": "2025-10-07",
      "packages": ["glfw3", "gli"]
    }
  ]
}
EOF
# Note: luajit is intentionally excluded from vcpkg-ports here.
# We use Homebrew's LuaJIT (brew install luajit) instead, because the custom
# vcpkg portfile patches cause crashes on macOS ARM64 (Apple Silicon).

# ── 5. Configure ─────────────────────────────────────────────────────────────
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

log "Configuring (first run installs vcpkg deps — may take 30-90 min for ANGLE+Metal)..."
cmake -B "$BUILD_DIR" -S "$MACOS_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$VCPKG_DIR/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET="$TRIPLET" \
    -DVCPKG_DEFAULT_TRIPLET="$TRIPLET" \
    -DVCPKG_INSTALLED_DIR="$BUILD_DIR/vcpkg_installed" \
    -DVCPKG_OVERLAY_TRIPLETS="$MACOS_DIR/triplets" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSG_DIR="$SG_DIR" \
    -DREPO_ROOT="$REPO_ROOT"

# ── 6. Build ──────────────────────────────────────────────────────────────────
log "Building (using $NCPU cores)..."
cmake --build "$BUILD_DIR" --config Release --parallel "$NCPU"

# ── 7. Install ───────────────────────────────────────────────────────────────
log "Installing to $INSTALL_DIR..."
cmake --build "$BUILD_DIR" --config Release --target install

# ── 8. Flatten lib/ → root install dir ──────────────────────────────────────
# cmake LIBRARY DESTINATION may land in a lib/ subdirectory on some platforms.
# Copy everything up to the root so DYLD_LIBRARY_PATH and symlinks work.
if [ -d "$INSTALL_DIR/lib" ]; then
    find "$INSTALL_DIR/lib" -name "*.dylib" -exec cp -n {} "$INSTALL_DIR/" \; 2>/dev/null || true
fi

# ── Collect ANGLE dylibs (EGL/GLESv2) ─────────────────────────────────────
# ANGLE's libEGL and libGLESv2 need to be beside the launcher.
VCPKG_LIB="$BUILD_DIR/vcpkg_installed/$TRIPLET/lib"
VCPKG_BIN="$BUILD_DIR/vcpkg_installed/$TRIPLET/bin"
for dir in "$VCPKG_LIB" "$VCPKG_BIN"; do
    if [ -d "$dir" ]; then
        find "$dir" -name "*.dylib" ! -name "*debug*" -exec cp -n {} "$INSTALL_DIR/" \; 2>/dev/null || true
    fi
done

# ── 9. Create Lua C-module symlinks ──────────────────────────────────────────
# Lua's require() searches package.cpath with '?', replacing dots with '/'.
# Our dylibs have 'lib' prefixes that Lua doesn't expect.  Create symlinks
# with the exact names Lua searches for.
#
# Also: the hyphen in module names like "lua-utf8" is LUA_IGMARK — Lua
# splits on it to get the function name (after '-') and file name (full).
#
# require("lcurl.safe")   → file lcurl/safe.dylib, function luaopen_lcurl_safe
# require("lua-utf8")     → file lua-utf8.dylib,   function luaopen_utf8
# require("socket.core")  → file socket/core.dylib, function luaopen_socket_core
# require("lzip")         → file lzip.dylib,        function luaopen_lzip
# require("lcurl")        → file lcurl.dylib,        function luaopen_lcurl

mkdir -p "$INSTALL_DIR/lcurl" "$INSTALL_DIR/socket"

# lcurl.dylib and lcurl/safe.dylib -> liblcurl.dylib
[ -f "$INSTALL_DIR/liblcurl.dylib" ] && \
    ln -sf "liblcurl.dylib"  "$INSTALL_DIR/lcurl.dylib" && \
    ln -sf "../liblcurl.dylib" "$INSTALL_DIR/lcurl/safe.dylib"

# lua-utf8.dylib -> liblua-utf8.dylib
[ -f "$INSTALL_DIR/liblua-utf8.dylib" ] && \
    ln -sf "liblua-utf8.dylib" "$INSTALL_DIR/lua-utf8.dylib"

# socket/core.dylib -> libsocket.dylib
[ -f "$INSTALL_DIR/libsocket.dylib" ] && \
    ln -sf "../libsocket.dylib" "$INSTALL_DIR/socket/core.dylib"

# lzip.dylib -> liblzip.dylib
[ -f "$INSTALL_DIR/liblzip.dylib" ] && \
    ln -sf "liblzip.dylib" "$INSTALL_DIR/lzip.dylib"

# ── Create EGL symlinks (GLFW dynamically loads "libEGL.dylib" by name) ───
# vcpkg's ANGLE port uses non-standard names (liblibEGL_angle.dylib).
# Create the symlinks that GLFW expects.
for angle_egl in "$INSTALL_DIR"/liblibEGL_angle*.dylib; do
    if [ -f "$angle_egl" ]; then
        ln -sf "$(basename "$angle_egl")" "$INSTALL_DIR/libEGL.dylib"
    fi
done
for angle_gles in "$INSTALL_DIR"/liblibGLESv2_angle*.dylib; do
    if [ -f "$angle_gles" ]; then
        ln -sf "$(basename "$angle_gles")" "$INSTALL_DIR/libGLESv2.dylib"
    fi
done

log "Build complete!"
log "Binary: $INSTALL_DIR/PathOfBuilding"
log "Run with: make run"
