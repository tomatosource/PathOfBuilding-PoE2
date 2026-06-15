// macOS launcher for Path of Building
// Loads libSimpleGraphic.dylib and runs the Lua script.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>

extern "C" int RunLuaFileAsWin(int argc, char** argv);

int main(int argc, char** argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: PathOfBuilding <Launch.lua>\n");
        return 1;
    }
    // argv[0] = executable path (unused by SimpleGraphic)
    // argv[1] = Lua script path  → becomes argv[0] inside SimpleGraphic
    return RunLuaFileAsWin(argc - 1, argv + 1);
}
