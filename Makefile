APP_DIR := apps/macos
DERIVED := $(APP_DIR)/.derivedData
XCODEBUILD := xcodebuild -project $(APP_DIR)/Boltty.xcodeproj -scheme Boltty \
	-configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED)

.DEFAULT_GOAL := help
.PHONY: help build run design install dmg check test test-all lint clean

help:
	@echo "make build      Debug build"
	@echo "make run        Debug build, then open it"
	@echo "make design     Boltty Design: the elements, live (needs XcodeGen)"
	@echo "make install    build what's on disk and put it in /Applications"
	@echo "make dmg        release DMG of the last commit (publishes nothing)"
	@echo "make check      before a push: linters, then tests covering what main lacks"
	@echo "make test       tests covering your uncommitted changes"
	@echo "make test-all   every unit test"
	@echo "make lint       architecture and design linters"
	@echo "make clean      remove the Debug build"

build:
	$(XCODEBUILD) build

run: build
	open $(DERIVED)/Build/Products/Debug/Boltty.app

design:
	$(APP_DIR)/Design/run.sh

install:
	$(APP_DIR)/scripts/release.sh --local

dmg:
	$(APP_DIR)/scripts/release.sh

check: lint
	cd $(APP_DIR) && ./scripts/test.sh --since origin/main

test:
	cd $(APP_DIR) && ./scripts/test.sh

test-all:
	cd $(APP_DIR) && ./scripts/test.sh --all

lint:
	$(APP_DIR)/scripts/lint-architecture.sh
	$(APP_DIR)/scripts/lint-design.sh

clean:
	rm -rf $(DERIVED)
