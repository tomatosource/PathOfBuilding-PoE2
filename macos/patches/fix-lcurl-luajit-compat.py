#!/usr/bin/env python3
"""
Patch Lua-cURLv3's l52util.c to avoid duplicate symbol 'luaL_setfuncs' when
linking against LuaJIT 2.1 (which provides this function in its static lib).

Only luaL_setfuncs is guarded; lua_rawgetp and lua_rawsetp are NOT provided
by LuaJIT 2.1 and must remain compiled.
"""
import sys, os, re

def patch(path):
    if not os.path.exists(path):
        print(f"  Skipping (not found): {path}", flush=True)
        return

    with open(path, "r") as f:
        text = f.read()

    if "luaL_setfuncs is provided by LuaJIT" in text:
        print(f"  Already patched: {path}", flush=True)
        return

    # Guard ONLY luaL_setfuncs; close the ifndef right after its closing brace.
    # The original else block has the form:
    #   void luaL_setfuncs (...) { ... }
    #   void lua_rawgetp (...) { ... }
    #   void lua_rawsetp (...) { ... }
    old = (
        "void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup){\n"
        "  luaL_checkstack(L, nup, \"too many upvalues\");\n"
        "  for (; l->name != NULL; l++) {  /* fill the table with given functions */\n"
        "    int i;\n"
        "    for (i = 0; i < nup; i++)  /* copy upvalues to the top */\n"
        "      lua_pushvalue(L, -nup);\n"
        "    lua_pushcclosure(L, l->func, nup);  /* closure with those upvalues */\n"
        "    lua_setfield(L, -(nup + 2), l->name);\n"
        "  }\n"
        "  lua_pop(L, nup);  /* remove upvalues */\n"
        "}\n"
        "\n"
        "void lua_rawgetp"
    )
    new = (
        "/* luaL_setfuncs is provided by LuaJIT 2.1 static library; guard to avoid dup */\n"
        "#ifndef LUAJIT_VERSION\n"
        "void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup){\n"
        "  luaL_checkstack(L, nup, \"too many upvalues\");\n"
        "  for (; l->name != NULL; l++) {  /* fill the table with given functions */\n"
        "    int i;\n"
        "    for (i = 0; i < nup; i++)  /* copy upvalues to the top */\n"
        "      lua_pushvalue(L, -nup);\n"
        "    lua_pushcclosure(L, l->func, nup);  /* closure with those upvalues */\n"
        "    lua_setfield(L, -(nup + 2), l->name);\n"
        "  }\n"
        "  lua_pop(L, nup);  /* remove upvalues */\n"
        "}\n"
        "#endif /* LUAJIT_VERSION */\n"
        "\n"
        "/* lua_rawgetp / lua_rawsetp: NOT in LuaJIT 2.1; always need these */\n"
        "void lua_rawgetp"
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
        print("Usage: fix-lcurl-luajit-compat.py <l52util.c>")
        sys.exit(1)
    patch(sys.argv[1])
