REPO_ROOT   := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
SG_DIR      := $(REPO_ROOT)/SimpleGraphic-src
BUILD_DIR   := $(REPO_ROOT)/build-mac
INSTALL_DIR := $(BUILD_DIR)/install
BINARY      := $(INSTALL_DIR)/PathOfBuilding
SCRIPT      := $(REPO_ROOT)/src/Launch.lua

.PHONY: run build clean clean-all

run: build
	@echo "Starting Path of Building..."
	DYLD_LIBRARY_PATH="$(INSTALL_DIR)" \
	LUA_CPATH="$(INSTALL_DIR)/?.dylib;$(INSTALL_DIR)/?.so;;" \
	LUA_PATH="./?.lua;./lua/?.lua;./lua/?/init.lua;;" \
	"$(BINARY)" "$(SCRIPT)"

build:
	@bash "$(REPO_ROOT)/macos/build.sh"

clean:
	rm -rf "$(BUILD_DIR)"

clean-all: clean
	rm -rf "$(SG_DIR)"
