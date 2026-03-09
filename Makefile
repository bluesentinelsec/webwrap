BUILD_DIR ?= build
CMAKE ?= cmake
CTEST ?= ctest

.PHONY: all configure build test clean

all: build

configure:
	$(CMAKE) -S . -B $(BUILD_DIR) -DWEBWRAP_BUILD_TESTS=ON

build: configure
	$(CMAKE) --build $(BUILD_DIR)

test: build
	$(CTEST) --test-dir $(BUILD_DIR) --output-on-failure

clean:
	$(CMAKE) -E rm -rf $(BUILD_DIR)
