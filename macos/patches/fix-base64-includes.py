#!/usr/bin/env python3
"""
Patch SimpleGraphic's base64.h to add missing <stddef.h> and <string.h> includes.
Without these, clang on macOS reports 'unknown type name size_t' and implicit
function declarations for strlen/memset/memcpy.
"""
import sys, os

def patch(path):
    if not os.path.exists(path):
        print(f"  Skipping (not found): {path}", flush=True)
        return

    with open(path, "r") as f:
        text = f.read()

    if "<stddef.h>" in text:
        print(f"  Already patched: {path}", flush=True)
        return

    text = text.replace(
        "#include <stdbool.h>",
        "#include <stdbool.h>\n#include <stddef.h>\n#include <string.h>"
    )

    with open(path, "w") as f:
        f.write(text)
    print(f"  Patched: {path}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: fix-base64-includes.py <base64.h>")
        sys.exit(1)
    patch(sys.argv[1])
