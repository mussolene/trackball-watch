SHELL := /bin/bash
export PATH := $(HOME)/.cargo/bin:$(PATH)

DESKTOP   := apps/host-desktop
TAURI_DIR := $(DESKTOP)/src-tauri
WATCH_DIR := apps/watch-ios
TOOL_DIR  := tools/latency-tester

XCODE_FLAGS := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

.PHONY: all install build build-desktop build-ios build-watch build-tools install-ios \
        install-mobile install-mobile-clean \
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
	cd $(DESKTOP) && CI=false npm run tauri build

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
	cd $(TAURI_DIR) && cargo test --all-features

test-swift: ## Build & test watchOS unit tests
	xcodebuild test \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'platform=watchOS Simulator,name=Apple Watch Series 7 (45mm)' \
		$(XCODE_FLAGS) || true

# ── Lint & Format ─────────────────────────────────────────────────────────────

lint: ## Run clippy + fmt check
	cd $(TAURI_DIR) && cargo fmt -- --check
	cd $(TAURI_DIR) && cargo clippy --all-features -- -D warnings

fmt: ## Auto-format Rust code
	cd $(TAURI_DIR) && cargo fmt

check: ## Quick compilation check (no link)
	cd $(TAURI_DIR) && cargo check --all-features
	cd $(TOOL_DIR) && cargo check

# ── XcodeGen ──────────────────────────────────────────────────────────────────

xcodegen: ## Regenerate Xcode project from project.yml
	cd $(WATCH_DIR) && xcodegen generate

# ── Clean ─────────────────────────────────────────────────────────────────────

clean: ## Remove build artifacts
	cd $(TAURI_DIR) && cargo clean
	cd $(TOOL_DIR) && cargo clean
	rm -rf $(DESKTOP)/dist $(DESKTOP)/node_modules
	xcodebuild clean -project $(WATCH_DIR)/TrackBallWatch.xcodeproj -alltargets 2>/dev/null || true
