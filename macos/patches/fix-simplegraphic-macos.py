#!/usr/bin/env python3
"""
Fix a handful of macOS-specific compilation issues in SimpleGraphic source files.

r_texture.cpp: missing #include <thread>
r_main.cpp: uses Windows Sleep() without a portable wrapper
"""
import sys, os

PATCHES = [
    {
        "file": "libs/luautf8/lutf8lib.c",
        "sentinel": "#include <limits.h>",
        "find": "#include <assert.h>\n#include <string.h>",
        "replace": "#include <assert.h>\n#include <limits.h>\n#include <string.h>",
    },
    {
        "file": "engine/render/r_texture.cpp",
        "sentinel": "#include <thread>",
        "find": "#include <mutex>\n#include <vector>\n#include <atomic>\n#include \"r_local.h\"",
        "replace": "#include <mutex>\n#include <vector>\n#include <atomic>\n#include <thread>\n#include \"r_local.h\"",
    },
    {
        "file": "engine/render/r_texture.cpp",
        "sentinel": "(size_t)4, dstExtent.y",
        "find": "(std::min)(4ull, dstExtent.y - rowBase)",
        "replace": "(std::min)((size_t)4, dstExtent.y - rowBase)",
    },
    {
        "file": "engine/render/r_texture.cpp",
        "sentinel": "(size_t)4, dstExtent.x",
        "find": "(std::min)(4ull, dstExtent.x - colBase)",
        "replace": "(std::min)((size_t)4, dstExtent.x - colBase)",
    },
    {
        # common.cpp: IndexUTF8ToUTF32 and other cross-platform functions were
        # accidentally placed inside #ifdef _WIN32.  Move the closing #endif up.
        "file": "engine/common/common.cpp",
        "sentinel": "#endif /* _WIN32 */\n\nIndexedUTF32String",
        "find": (
            "char* NarrowUTF8String(const wchar_t* str)\n"
            "{\n"
            "\treturn NarrowCodepageString(str, CP_UTF8);\n"
            "}\n"
            "\n"
            "IndexedUTF32String IndexUTF8ToUTF32"
        ),
        "replace": (
            "char* NarrowUTF8String(const wchar_t* str)\n"
            "{\n"
            "\treturn NarrowCodepageString(str, CP_UTF8);\n"
            "}\n"
            "\n"
            "#endif /* _WIN32 */\n"
            "\n"
            "IndexedUTF32String IndexUTF8ToUTF32"
        ),
    },
    {
        # Also remove the now-orphaned closing #endif at the end of common.cpp
        "file": "engine/common/common.cpp",
        "sentinel": "ret.text = std::u32string(codepoints.begin(), codepoints.end());\n\treturn ret;\n}\n",
        "find": (
            "\tret.text = std::u32string(codepoints.begin(), codepoints.end());\n"
            "\treturn ret;\n"
            "}\n"
            "\n"
            "#endif\n"
        ),
        "replace": (
            "\tret.text = std::u32string(codepoints.begin(), codepoints.end());\n"
            "\treturn ret;\n"
            "}\n"
        ),
    },
    {
        "file": "engine/render/r_main.cpp",
        "sentinel": "#ifndef _WIN32",
        # Add a portable Sleep shim via a #ifndef block near the top includes
        "find": "#include \"r_local.h\"\n\n#include \"common/base64.h\"",
        "replace": (
            "#include \"r_local.h\"\n\n"
            "#ifndef _WIN32\n"
            "#include <unistd.h>\n"
            "static inline void Sleep(int ms) { usleep(ms * 1000); }\n"
            "#endif\n\n"
            "#include \"common/base64.h\""
        ),
    },
]


def patch_file(sg_dir, p):
    path = os.path.join(sg_dir, p["file"])
    if not os.path.exists(path):
        print(f"  Skipping (not found): {path}", flush=True)
        return

    with open(path, "r") as f:
        text = f.read()

    if p["sentinel"] in text:
        print(f"  Already patched: {path}", flush=True)
        return

    if p["find"] not in text:
        print(f"  Warning: pattern not found in {path} — skipping", flush=True)
        return

    text = text.replace(p["find"], p["replace"], 1)
    with open(path, "w") as f:
        f.write(text)
    print(f"  Patched: {path}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: fix-simplegraphic-macos.py <SimpleGraphic-src-dir>")
        sys.exit(1)
    sg_dir = sys.argv[1]
    for p in PATCHES:
        patch_file(sg_dir, p)
