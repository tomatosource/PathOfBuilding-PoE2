#!/usr/bin/env python3
"""
Patch SimpleGraphic's CMakeLists.txt to support macOS/Unix luasocket build.
Replaces Windows-only wsocket.c / wsock32 / ws2_32 with Unix-portable equivalents.
"""
import sys, re

def patch(path):
    with open(path, "r") as f:
        text = f.read()

    # Already patched?
    if "LUASOCKET_PLATFORM_SOURCES" in text:
        print(f"  Already patched: {path}", flush=True)
        return

    # Replace the luasocket source list entry
    text = text.replace(
        '   "libs/luasocket/src/wsocket.c"\n)',
        '   ${LUASOCKET_PLATFORM_SOURCES}\n)'
    )

    # Replace Windows socket link libraries in luasocket target
    text = text.replace(
        'target_link_libraries(luasocket\n'
        '    PRIVATE\n'
        '    LuaJIT::LuaJIT\n'
        '    wsock32\n'
        '    ws2_32\n'
        ')',
        'target_link_libraries(luasocket\n'
        '    PRIVATE\n'
        '    LuaJIT::LuaJIT\n'
        '    ${LUASOCKET_PLATFORM_LIBS}\n'
        ')'
    )

    # Insert platform detection block before the luasocket section
    platform_block = (
        'if (WIN32)\n'
        '    set(LUASOCKET_PLATFORM_SOURCES "libs/luasocket/src/wsocket.c")\n'
        '    set(LUASOCKET_PLATFORM_LIBS wsock32 ws2_32)\n'
        'else()\n'
        '    set(LUASOCKET_PLATFORM_SOURCES "libs/luasocket/src/usocket.c")\n'
        '    set(LUASOCKET_PLATFORM_LIBS "")\n'
        'endif()\n\n'
    )
    text = text.replace(
        '# luasocket module\n\nadd_library(luasocket SHARED\n',
        '# luasocket module\n\n' + platform_block + 'add_library(luasocket SHARED\n'
    )

    with open(path, "w") as f:
        f.write(text)
    print(f"  Patched: {path}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: fix-luasocket-macos.py <CMakeLists.txt>")
        sys.exit(1)
    patch(sys.argv[1])
