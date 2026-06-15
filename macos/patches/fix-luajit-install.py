#!/usr/bin/env python3
"""
Patch the custom LuaJIT vcpkg portfile's configure script to fix a circular
symlink issue on macOS.

The configure script sets INSTALL_TNAME=luajit without also setting
INSTALL_TSYM to a different value.  LuaJIT's Makefile then does:
    install -m 0755 luajit <dest>/bin/luajit    (copies the binary)
    ln -sf luajit <dest>/bin/luajit              (overwrites with self-symlink!)

Fix: add INSTALL_TSYM to a versioned name so the symlink points at the binary
rather than at itself.
"""
import sys, os

def patch(path):
    if not os.path.exists(path):
        print(f"  Skipping (not found): {path}", flush=True)
        return

    with open(path, "r") as f:
        text = f.read()

    if "INSTALL_TSYM" in text:
        print(f"  Already patched: {path}", flush=True)
        return

    # Add INSTALL_TSYM right after INSTALL_TNAME line
    text = text.replace(
        "COMMON_OPTIONS += 'INSTALL_TNAME=luajit'\n",
        "COMMON_OPTIONS += 'INSTALL_TNAME=luajit'\n"
        "COMMON_OPTIONS += 'INSTALL_TSYM=luajit-2.1'\n"
    )

    with open(path, "w") as f:
        f.write(text)
    print(f"  Patched: {path}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: fix-luajit-install.py <configure>")
        sys.exit(1)
    patch(sys.argv[1])
