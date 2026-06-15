#!/usr/bin/env python3
"""
Patch the LuaJIT portfile's configure script to add XCFLAGS=-DLUAJIT_DISABLE_JIT
when building for macOS ARM64.

On macOS ARM64 (Apple Silicon), JIT compilation requires a special memory
mapping (W+X) that is blocked by default without a JIT entitlement.
Building without JIT allows the interpreter to run normally.

PoB's calculations are dominated by Lua logic, not JIT overhead, so this
has minimal practical impact.
"""
import sys, os

def patch(path):
    if not os.path.exists(path):
        print(f"  Skipping (not found): {path}", flush=True)
        return

    with open(path, "r") as f:
        text = f.read()

    if "LUAJIT_DISABLE_JIT" in text:
        print(f"  Already patched: {path}", flush=True)
        return

    # Add XCFLAGS to disable JIT in the Makefile.vcpkg generation block.
    # The configure script builds Makefile.vcpkg which drives the LuaJIT build.
    # We need to pass XCFLAGS via BUILD_OPTIONS (which feeds CFLAGS to the compiler).
    old = "BUILD_OPTIONS += 'CC=${CC}'"
    new = (
        "BUILD_OPTIONS += 'CC=${CC}'\n"
        "BUILD_OPTIONS += 'XCFLAGS=-DLUAJIT_DISABLE_JIT'"
    )
    if old not in text:
        print(f"  Warning: expected pattern not found in {path}", flush=True)
        return

    text = text.replace(old, new, 1)
    with open(path, "w") as f:
        f.write(text)
    print(f"  Patched: {path}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: fix-luajit-macos-arm64.py <configure>")
        sys.exit(1)
    patch(sys.argv[1])
