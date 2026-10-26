# Shortcuts for working on Boltty. Everything here calls the scripts in
# apps/macos/scripts or xcodebuild; see CONTRIBUTING.md for what they do.

APP_DIR := apps/macos
DERIVED := $(APP_DIR)/.derivedData
XCODEBUILD := xcodebuild -project $(APP_DIR)/Boltty.xcodeproj -scheme Boltty \
	-configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED)

.DEFAULT_GOAL := help
.PHONY: help build run install dmg test test-all lint clean

help:
	@echo "make build      Debug build"
	@echo "make run        Debug build, then open it"
	@echo "make install    build what's on disk and put it in /Applications"
	@echo "make dmg        release DMG of the last commit (publishes nothing)"
	@echo "make test       tests covering your uncommitted changes"
	@echo "make test-all   every unit test"
	@echo "make lint       architecture and design linters"
	@echo "make clean      remove the Debug build"

build:
	$(XCODEBUILD) build

run: build
	open $(DERIVED)/Build/Products/Debug/Boltty.app

install:
	$(APP_DIR)/scripts/release.sh --local

dmg:
	$(APP_DIR)/scripts/release.sh

test:
	cd $(APP_DIR) && ./scripts/test.sh

test-all:
	cd $(APP_DIR) && ./scripts/test.sh --all

lint:
	$(APP_DIR)/scripts/lint-architecture.sh
	$(APP_DIR)/scripts/lint-design.sh

clean:
	rm -rf $(DERIVED)
