cmake_minimum_required(VERSION 3.20)
project(PathOfBuilding C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

# SG_DIR must be passed from the build script via -DSG_DIR=...
if(NOT DEFINED SG_DIR OR NOT EXISTS "${SG_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "SG_DIR must point to a cloned PathOfBuilding-SimpleGraphic repo.")
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Pre-set LuaJIT find variables for macOS.
#
# SimpleGraphic's FindLuaJIT.cmake looks for a library named "lua51" and an
# include suffix "luajit".  On macOS via the custom vcpkg portfile, the library
# is installed as "libluajit-5.1.a" and headers are in "include/luajit-2.1/".
# Setting the find-result cache variables before the subdirectory bypasses the
# incorrect search and points cmake at the real paths.
# ──────────────────────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────────────────────
# Use Homebrew's LuaJIT instead of the custom vcpkg portfile.
# The vcpkg portfile's custom patches cause crashes on macOS ARM64; the
# Homebrew binary is known to work (brew install luajit).
# ──────────────────────────────────────────────────────────────────────────────
if(APPLE)
    find_program(BREW_CMD brew)
    if(BREW_CMD)
        execute_process(COMMAND ${BREW_CMD} --prefix luajit
            OUTPUT_VARIABLE BREW_LJ_PREFIX
            OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    endif()
    if(NOT BREW_LJ_PREFIX OR NOT EXISTS "${BREW_LJ_PREFIX}/lib/libluajit-5.1.a")
        # Fallback to standard Homebrew paths
        set(BREW_LJ_PREFIX "/opt/homebrew/opt/luajit")
    endif()
    if(EXISTS "${BREW_LJ_PREFIX}/include/luajit-2.1")
        set(LuaJIT_INCLUDE_DIR "${BREW_LJ_PREFIX}/include/luajit-2.1"
            CACHE PATH "LuaJIT include directory (Homebrew)" FORCE)
        message(STATUS "LuaJIT: using Homebrew at ${BREW_LJ_PREFIX}")
    endif()
    if(EXISTS "${BREW_LJ_PREFIX}/lib/libluajit-5.1.a")
        set(LuaJIT_LIBRARY_RELEASE "${BREW_LJ_PREFIX}/lib/libluajit-5.1.a"
            CACHE FILEPATH "LuaJIT release library (Homebrew)" FORCE)
        set(LuaJIT_LIBRARY_DEBUG "${BREW_LJ_PREFIX}/lib/libluajit-5.1.a"
            CACHE FILEPATH "LuaJIT debug library (Homebrew)" FORCE)
    endif()
else()
    # vcpkg LuaJIT for non-Apple platforms
    if(DEFINED VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
        set(_lj "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}")
        if(EXISTS "${_lj}/include/luajit-2.1")
            set(LuaJIT_INCLUDE_DIR "${_lj}/include/luajit-2.1"
                CACHE PATH "LuaJIT include directory" FORCE)
        endif()
        if(EXISTS "${_lj}/lib/libluajit-5.1.a")
            set(LuaJIT_LIBRARY_RELEASE "${_lj}/lib/libluajit-5.1.a"
                CACHE FILEPATH "LuaJIT release library" FORCE)
        endif()
        if(EXISTS "${_lj}/debug/lib/libluajit-5.1.a")
            set(LuaJIT_LIBRARY_DEBUG "${_lj}/debug/lib/libluajit-5.1.a"
                CACHE FILEPATH "LuaJIT debug library" FORCE)
        endif()
        unset(_lj)
    endif()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Shim: the arm64-osx triplet builds zstd as a static library, which provides
# only the "zstd::libzstd_static" target.  SimpleGraphic's CMakeLists links
# "zstd::libzstd_shared".  Pre-find zstd here and create the alias so the
# subdirectory build succeeds.
# ──────────────────────────────────────────────────────────────────────────────
find_package(zstd CONFIG REQUIRED)
# Dynamic triplet provides zstd::libzstd_shared; static provides zstd::libzstd_static.
# Create the alias in case the static variant is present (e.g. fallback arm64-osx).
if(TARGET zstd::libzstd_static AND NOT TARGET zstd::libzstd_shared)
    add_library(zstd::libzstd_shared ALIAS zstd::libzstd_static)
    message(STATUS "zstd: aliased libzstd_shared -> libzstd_static (static triplet)")
endif()
# With dynamic triplet, zstd::libzstd provides the shared target via zstd::libzstd_shared.
if(TARGET zstd::libzstd AND NOT TARGET zstd::libzstd_shared)
    add_library(zstd::libzstd_shared ALIAS zstd::libzstd)
    message(STATUS "zstd: aliased libzstd_shared -> libzstd (dynamic triplet)")
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Build SimpleGraphic and all Lua extension modules as a subdirectory.
# The SimpleGraphic CMakeLists.txt was designed as a root-level project but
# works under add_subdirectory because vcpkg was already loaded via the
# CMAKE_TOOLCHAIN_FILE argument and its include_guard prevents double init.
# ──────────────────────────────────────────────────────────────────────────────
add_subdirectory(${SG_DIR} SimpleGraphic-build)

# ──────────────────────────────────────────────────────────────────────────────
# SimpleGraphic's CMakeLists sets SIMPLEGRAPHIC_PLATFORM_SOURCES for APPLE
# (to include sys_macos.mm) but then immediately OVERWRITES it in the
# WIN32/non-WIN32 block.  Add sys_macos.mm explicitly here as a workaround.
# ──────────────────────────────────────────────────────────────────────────────
if(APPLE)
    target_sources(SimpleGraphic PRIVATE
        "${SG_DIR}/engine/system/win/sys_macos.mm")
    message(STATUS "Added sys_macos.mm to SimpleGraphic (workaround for CMakeLists overwrite)")
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Lua module fixes for macOS.
#
# 1. lcurl: l52util.c guards Lua 5.1 compat functions with #ifndef LUAJIT_VERSION
#    but that macro is only in luajit.h, which l52util.c never includes.
#    Force-define it so the guard fires and avoids duplicate symbols from
#    the LuaJIT static library.
#
# 2. lua-utf8: LUA_BUILD_AS_DLL (set by SimpleGraphic's CMakeLists) triggers
#    __declspec(dllexport) in LuaJIT's luaconf.h, which is Windows-only.
#    Remove it on non-Windows; shared library symbols are visible by default.
# ──────────────────────────────────────────────────────────────────────────────
if(APPLE OR UNIX)
    foreach(_tgt lcurl lua-utf8 lzip luasocket)
        if(TARGET ${_tgt})
            target_compile_definitions(${_tgt} PRIVATE LUAJIT_VERSION=1)
        endif()
    endforeach()
    if(TARGET lua-utf8)
        get_target_property(_defs lua-utf8 COMPILE_DEFINITIONS)
        if(_defs)
            list(REMOVE_ITEM _defs "LUA_BUILD_AS_DLL")
            set_target_properties(lua-utf8 PROPERTIES COMPILE_DEFINITIONS "${_defs}")
        endif()
    endif()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Fix luasocket for macOS/Unix.
# SimpleGraphic's CMakeLists unconditionally uses wsocket.c and links ws2_32.
# The Python patch script handles this at clone time, but as a safety net we
# also mark wsocket.c as header-only (no-compile) here and add usocket.c.
# ──────────────────────────────────────────────────────────────────────────────
if(APPLE OR UNIX)
    get_target_property(_sock_srcs luasocket SOURCES)
    foreach(_src IN LISTS _sock_srcs)
        if(_src MATCHES "wsocket\\.c$")
            set_source_files_properties("${_src}"
                DIRECTORY "${SG_DIR}"
                PROPERTIES HEADER_FILE_ONLY TRUE)
        endif()
    endforeach()
    # Add unix socket implementation if not already there
    get_target_property(_sock_srcs2 luasocket SOURCES)
    set(_has_usocket FALSE)
    foreach(_src IN LISTS _sock_srcs2)
        if(_src MATCHES "usocket\\.c$")
            set(_has_usocket TRUE)
        endif()
    endforeach()
    if(NOT _has_usocket)
        target_sources(luasocket PRIVATE
            "${SG_DIR}/libs/luasocket/src/usocket.c")
    endif()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# macOS launcher executable
# Links directly against libSimpleGraphic.dylib so RunLuaFileAsWin is found
# at link time rather than via dlopen.
# ──────────────────────────────────────────────────────────────────────────────
add_executable(PathOfBuilding ${CMAKE_CURRENT_SOURCE_DIR}/launcher.cpp)

target_link_libraries(PathOfBuilding PRIVATE SimpleGraphic)

# Tell dyld to search the executable's own directory for dylibs at runtime.
set_target_properties(PathOfBuilding PROPERTIES
    INSTALL_RPATH "@executable_path"
    BUILD_WITH_INSTALL_RPATH TRUE
    MACOSX_RPATH TRUE
)

install(TARGETS PathOfBuilding RUNTIME DESTINATION ".")

# ──────────────────────────────────────────────────────────────────────────────
# On macOS/Unix, shared libraries are LIBRARY type, not RUNTIME.
# SimpleGraphic's CMakeLists.txt uses RUNTIME DESTINATION (correct for Windows
# DLLs) but that doesn't install dylibs on macOS.  Add LIBRARY rules here.
# ──────────────────────────────────────────────────────────────────────────────
if(APPLE OR UNIX)
    foreach(_tgt SimpleGraphic lcurl lua-utf8 lzip luasocket)
        if(TARGET ${_tgt})
            install(TARGETS ${_tgt} LIBRARY DESTINATION ".")
        endif()
    endforeach()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Copy vcpkg shared-library dependencies to the install prefix so the app is
# self-contained in install/.
# ──────────────────────────────────────────────────────────────────────────────
if(DEFINED VCPKG_INSTALLED_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
    set(_vcpkg_lib "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib")
    set(_vcpkg_bin "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin")
    foreach(_dir "${_vcpkg_lib}" "${_vcpkg_bin}")
        if(EXISTS "${_dir}")
            install(DIRECTORY "${_dir}/"
                DESTINATION "."
                FILES_MATCHING
                PATTERN "*.dylib"
                PATTERN "pkgconfig" EXCLUDE
            )
        endif()
    endforeach()
endif()

# ──────────────────────────────────────────────────────────────────────────────
# Install SimpleGraphic data files (fonts) and Lua standard library modules.
#
# SimpleGraphic loads fonts from SimpleGraphic/Fonts/ relative to the
# executable directory (basePath).
#
# LuaJIT loads modules from package.path which includes "lua/?.lua" relative
# to the *current working directory* at the time require() is called.
# SimpleGraphic's ScriptInit sets CWD=basePath before initialising Lua, so
# the install dir must contain a "lua/" sub-directory with the Lua stdlib
# modules (base64.lua, xml.lua, socket.lua, etc.).
#
# We also install the Lua source tree under "src/" so Launch.lua can be
# invoked as "./src/Launch.lua" with the install dir as the working directory.
# ──────────────────────────────────────────────────────────────────────────────
if(DEFINED REPO_ROOT)
    if(EXISTS "${REPO_ROOT}/runtime/SimpleGraphic")
        install(DIRECTORY "${REPO_ROOT}/runtime/SimpleGraphic"
            DESTINATION ".")
    endif()
    if(EXISTS "${REPO_ROOT}/runtime/lua")
        install(DIRECTORY "${REPO_ROOT}/runtime/lua"
            DESTINATION ".")
    endif()
    # Install the PoB Lua source tree so it is accessible relative to install/.
    if(EXISTS "${REPO_ROOT}/src")
        install(DIRECTORY "${REPO_ROOT}/src"
            DESTINATION ".")
    endif()
    # manifest.xml lives at the repo root; Launch.lua looks for ../manifest.xml
    if(EXISTS "${REPO_ROOT}/manifest.xml")
        install(FILES "${REPO_ROOT}/manifest.xml"
            DESTINATION ".")
    endif()
endif()
