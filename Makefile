SHELL := /bin/bash
export PATH := $(HOME)/.cargo/bin:$(PATH)

DESKTOP   := apps/host-desktop
TAURI_DIR := $(DESKTOP)/src-tauri
WATCH_DIR := apps/watch-ios
TOOL_DIR  := tools/latency-tester

# macOS .app produced by `tauri:build` (see tauri.conf productName)
HOST_APP_BUNDLE := TrackBall Watch.app
HOST_APP_SRC    := $(TAURI_DIR)/target/release/bundle/macos/$(HOST_APP_BUNDLE)
HOST_APP_DEST   := /Applications/$(HOST_APP_BUNDLE)

XCODE_FLAGS  := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
CARGO        := $(HOME)/.cargo/bin/cargo

# Prefer the first available Watch simulator (UUID only)
WATCH_SIM    := $(shell xcrun simctl list devices available 2>/dev/null | \
                  grep 'Apple Watch' | head -1 | grep -oE '[A-F0-9-]{36}')

.PHONY: all install build build-desktop install-host build-ios build-watch build-tools install-ios \
        install-mobile install-mobile-clean verify \
        dev test test-rust test-swift lint fmt check xcodegen clean help

# ── Main targets ──────────────────────────────────────────────────────────────

all: install build ## Build everything

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Install ───────────────────────────────────────────────────────────────────

install: ## Install npm dependencies
	cd $(DESKTOP) && npm install

# ── Build ─────────────────────────────────────────────────────────────────────

build: build-desktop build-ios build-watch build-tools ## Build all targets

build-desktop: install ## Build desktop host (Tauri release)
	cd $(DESKTOP) && CI=false npm run build && CI=false npm run tauri:build

install-host: build-desktop ## Build desktop and install .app into /Applications (macOS only)
	@if [[ "$$(uname -s)" != Darwin ]]; then \
		echo "install-host: only supported on macOS"; exit 1; \
	fi
	@test -d "$(HOST_APP_SRC)" || { echo "Missing bundle: $(HOST_APP_SRC) — run build-desktop first"; exit 1; }
	ditto "$(HOST_APP_SRC)" "$(HOST_APP_DEST)"
	@echo "Installed $(HOST_APP_DEST)"

build-ios: ## Build iOS companion + embedded Watch app (debug)
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		$(XCODE_FLAGS)

build-watch: ## Build watchOS app standalone (debug)
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'generic/platform=watchOS' \
		-configuration Debug \
		$(XCODE_FLAGS)

build-tools: ## Build latency-tester
	cd $(TOOL_DIR) && cargo build --release

install-desktop: build-desktop ## Build, copy to /Applications, deep-sign (fixes Accessibility TCC)
	@APP="TrackBall Watch.app"; \
	SRC=$$(find $(DESKTOP)/src-tauri/target/release/bundle/macos -maxdepth 1 -name "$$APP" 2>/dev/null | head -1); \
	if [ -z "$$SRC" ]; then echo "error: app not found after build"; exit 1; fi; \
	echo "==> Copying to /Applications..."; \
	rm -rf "/Applications/$$APP"; \
	cp -R "$$SRC" "/Applications/$$APP"; \
	echo "==> Deep-signing (ad-hoc) so macOS TCC identifies the bundle consistently..."; \
	codesign --force --deep --sign - --entitlements $(DESKTOP)/src-tauri/entitlements.plist "/Applications/$$APP"; \
	echo "==> Installed. If Accessibility prompt does not appear, run:"; \
	echo "    tccutil reset Accessibility com.trackballwatch.host"

install-ios: ## Build & install iOS+Watch app on connected device (requires signed identity)
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		-allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration
	@IPHONE_ID=$$(xcrun devicectl list devices 2>/dev/null \
		| awk 'NR>2 && /connected/ && /iPhone/{print $$3}' | head -1); \
	APP=$$(find ~/Library/Developer/Xcode/DerivedData/TrackBallWatch-*/Build/Products/Debug-iphoneos \
		-maxdepth 1 -name "TrackBallCompanion-iOS.app" 2>/dev/null | head -1); \
	echo "Installing $$APP on $$IPHONE_ID"; \
	xcrun devicectl device install app --device "$$IPHONE_ID" "$$APP"

# iPhone + paired Apple Watch: one build, install .app on phone then watch bundle on watch.
#   make install-mobile              — incremental build + install both devices
#   make install-mobile CLEAN=1      — xcodebuild clean, then build + install
#   make install-mobile-clean        — same as CLEAN=1
install-mobile: ## Build & install on iPhone + paired Watch (CLEAN=1 for clean build first)
	CLEAN=$(or $(CLEAN),0) bash "$(CURDIR)/tools/install_mobile_devices.sh"

install-mobile-clean: ## Xcode clean, then build & install iPhone + Watch
	$(MAKE) install-mobile CLEAN=1

# ── Dev ───────────────────────────────────────────────────────────────────────

dev: install ## Run desktop host in dev mode (hot-reload)
	cd $(DESKTOP) && npm run tauri dev

# ── Test ──────────────────────────────────────────────────────────────────────

test: test-rust test-swift ## Run all tests

test-rust: ## Run Rust tests (desktop host)
	cd $(TAURI_DIR) && $(CARGO) test 2>&1 | grep -E "^test result|^error"

test-swift: ## Build & test watchOS unit tests (uses first available Watch simulator)
	@echo "==> Watch simulator: $(WATCH_SIM)"
	xcodebuild test \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'platform=watchOS Simulator,id=$(WATCH_SIM)' \
		$(XCODE_FLAGS) 2>&1 | grep -E "error:|Test Suite|PASSED|FAILED|BUILD" | tail -20 || true

verify: ## Fast CI-style check: cargo check + Rust tests + iOS build
	@echo "==> cargo check"
	cd $(TAURI_DIR) && $(CARGO) check --all-features 2>&1 | tail -3
	@echo "==> cargo test"
	cd $(TAURI_DIR) && $(CARGO) test 2>&1 | grep -E "^test result|^error"
	@echo "==> xcodebuild (watchOS)"
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'generic/platform=watchOS' \
		-configuration Debug \
		$(XCODE_FLAGS) 2>&1 | grep -E "error:|BUILD "
	@echo "==> xcodebuild (iOS)"
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		$(XCODE_FLAGS) 2>&1 | grep -E "error:|BUILD "

# ── Lint & Format ─────────────────────────────────────────────────────────────

lint: ## Run clippy + fmt check
	cd $(TAURI_DIR) && $(CARGO) fmt -- --check
	cd $(TAURI_DIR) && $(CARGO) clippy --all-features -- -D warnings

fmt: ## Auto-format Rust code
	cd $(TAURI_DIR) && $(CARGO) fmt

check: ## Quick compilation check (no link)
	cd $(TAURI_DIR) && $(CARGO) check --all-features 2>&1 | tail -3
	cd $(TOOL_DIR) && $(CARGO) check 2>&1 | tail -2

# ── XcodeGen ──────────────────────────────────────────────────────────────────

xcodegen: ## Regenerate Xcode project from project.yml
	cd $(WATCH_DIR) && xcodegen generate

# ── Clean ─────────────────────────────────────────────────────────────────────

clean: ## Remove build artifacts
	cd $(TAURI_DIR) && cargo clean
	cd $(TOOL_DIR) && cargo clean
	rm -rf $(DESKTOP)/dist $(DESKTOP)/node_modules
	xcodebuild clean -project $(WATCH_DIR)/TrackBallWatch.xcodeproj -alltargets 2>/dev/null || true
