SHELL := /bin/bash
export PATH := $(HOME)/.cargo/bin:$(PATH)

HOST_APP_DIR      := apps/host-desktop
HOST_CORE_DIR     := $(HOST_APP_DIR)/src-tauri
APPLE_CLIENT_DIR  := apps/watch-ios
TOOLS_LATENCY_DIR := tools/latency-tester

# macOS .app produced by `tauri:build` (see tauri.conf productName)
HOST_APP_BUNDLE := TrackBall Watch.app
HOST_APP_SRC    := $(HOST_CORE_DIR)/target/release/bundle/macos/$(HOST_APP_BUNDLE)
HOST_APP_DEST   := /Applications/$(HOST_APP_BUNDLE)
APPLE_DERIVED_DATA := $(CURDIR)/.codex-derived/xcode

XCODE_FLAGS  := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
# Use rustup's cargo when present; fall back to PATH (Windows make often has no HOME)
ifneq ($(wildcard $(HOME)/.cargo/bin/cargo),)
  CARGO := $(HOME)/.cargo/bin/cargo
else
  CARGO := cargo
endif

# Prefer the first available Watch simulator (UUID only)
WATCH_SIM    := $(shell xcrun simctl list devices available 2>/dev/null | \
                  grep 'Apple Watch' | head -1 | grep -oE '[A-F0-9-]{36}')

.PHONY: all install build build-desktop build-windows install-host build-ios build-watch build-tools install-ios \
        build-apple build-apple-watch build-apple-mobile install-mobile install-mobile-clean verify verify-windows \
        dev test test-rust test-swift lint fmt check xcodegen clean help

# ── Main targets ──────────────────────────────────────────────────────────────

all: install build ## Build everything

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Install ───────────────────────────────────────────────────────────────────

install: ## Install npm dependencies
	cd $(HOST_APP_DIR) && npm install

# ── Build ─────────────────────────────────────────────────────────────────────

build: build-desktop build-apple build-tools ## Build all targets

build-desktop: install ## Build desktop host (Tauri release)
	cd $(HOST_APP_DIR) && CI=false npm run build && CI=false npm run tauri:build

# Same as build-desktop but named for clarity on Windows/Linux (no Xcode; works with Git Bash make or WSL)
build-windows: install ## Build desktop host only (Rust + Vite + Tauri; skip Apple targets)
	cd $(HOST_APP_DIR) && CI=false npm run build && CI=false npm run tauri:build

build-apple: build-apple-mobile build-apple-watch ## Build Apple client targets

build-apple-mobile: ## Build iPhone companion + embedded Watch app (debug)
	xcodebuild build \
		-project $(APPLE_CLIENT_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		-derivedDataPath '$(APPLE_DERIVED_DATA)' \
		$(XCODE_FLAGS)

build-apple-watch: ## Build watchOS app standalone (debug)
	xcodebuild build \
		-project $(APPLE_CLIENT_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'generic/platform=watchOS' \
		-configuration Debug \
		-derivedDataPath '$(APPLE_DERIVED_DATA)' \
		$(XCODE_FLAGS)

install-host: build-desktop ## Build desktop and install .app into /Applications (macOS only)
	@if [[ "$$(uname -s)" != Darwin ]]; then \
		echo "install-host: only supported on macOS"; exit 1; \
	fi
	@test -d "$(HOST_APP_SRC)" || { echo "Missing bundle: $(HOST_APP_SRC) — run build-desktop first"; exit 1; }
	ditto "$(HOST_APP_SRC)" "$(HOST_APP_DEST)"
	@echo "Installed $(HOST_APP_DEST)"

build-ios: build-apple-mobile ## Backward-compatible alias

build-watch: build-apple-watch ## Backward-compatible alias

build-tools: ## Build latency-tester
	cd $(TOOLS_LATENCY_DIR) && cargo build --release

install-desktop: build-desktop ## Build, copy to /Applications, deep-sign, reset TCC (fixes Accessibility)
	@APP="TrackBall Watch.app"; \
	BUNDLE_ID="com.trackballwatch.host"; \
	SRC=$$(find $(HOST_APP_DIR)/src-tauri/target/release/bundle/macos -maxdepth 1 -name "$$APP" 2>/dev/null | head -1); \
	if [ -z "$$SRC" ]; then echo "error: app not found after build"; exit 1; fi; \
	echo "==> Stopping any running instance..."; \
	pkill -x TrackBallWatch 2>/dev/null || true; \
	sleep 0.5; \
	echo "==> Copying to /Applications..."; \
	rm -rf "/Applications/$$APP"; \
	cp -R "$$SRC" "/Applications/$$APP"; \
	echo "==> Deep-signing (ad-hoc) for consistent TCC identity..."; \
	codesign --force --deep --sign - \
		--identifier "$$BUNDLE_ID" \
		--entitlements $(HOST_APP_DIR)/src-tauri/entitlements.plist \
		"/Applications/$$APP"; \
	echo "==> Resetting Accessibility TCC entry (stale after binary change)..."; \
	tccutil reset Accessibility "$$BUNDLE_ID" 2>/dev/null \
		&& echo "    TCC reset OK" \
		|| echo "    tccutil reset skipped (try: sudo tccutil reset Accessibility $$BUNDLE_ID)"; \
	echo "==> Launching app (system Accessibility prompt should appear)..."; \
	open -a "/Applications/$$APP"; \
	echo "==> Done. Grant Accessibility in the system dialog or via:"; \
	echo "    System Settings → Privacy & Security → Accessibility → TrackBall Watch"

install-ios: install-mobile ## Alias for install-mobile (builds + installs iOS; Watch gets pushed via companion)

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
	cd $(HOST_APP_DIR) && npm run tauri dev

# ── Test ──────────────────────────────────────────────────────────────────────

test: test-rust test-swift ## Run all tests

test-rust: ## Run Rust tests (desktop host)
	cd $(HOST_CORE_DIR) && $(CARGO) test 2>&1 | grep -E "^test result|^error"

test-swift: ## Build & test watchOS unit tests (uses first available Watch simulator)
	@echo "==> Watch simulator: $(WATCH_SIM)"
	xcodebuild test \
		-project $(APPLE_CLIENT_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'platform=watchOS Simulator,id=$(WATCH_SIM)' \
		-derivedDataPath '$(APPLE_DERIVED_DATA)' \
		$(XCODE_FLAGS) 2>&1 | grep -E "error:|Test Suite|PASSED|FAILED|BUILD" | tail -20 || true

verify: ## Fast CI-style check: cargo check + Rust tests + iOS build
	@echo "==> cargo check"
	cd $(HOST_CORE_DIR) && $(CARGO) check --all-features 2>&1 | tail -3
	@echo "==> cargo test"
	cd $(HOST_CORE_DIR) && $(CARGO) test 2>&1 | grep -E "^test result|^error"
	@echo "==> xcodebuild (Apple mobile)"
	$(MAKE) build-apple-mobile
	@echo "==> xcodebuild (Apple watch)"
	$(MAKE) build-apple-watch

# Use on Windows/Linux CI agents without Xcode (Rust + latency-tester only)
verify-windows: ## cargo check + Rust tests + tools check (no Apple builds)
	@echo "==> cargo check (host)"
	cd $(HOST_CORE_DIR) && $(CARGO) check --all-features
	@echo "==> cargo test (host)"
	cd $(HOST_CORE_DIR) && $(CARGO) test --all-features
	@echo "==> cargo check (latency-tester)"
	cd $(TOOLS_LATENCY_DIR) && $(CARGO) check

# ── Lint & Format ─────────────────────────────────────────────────────────────

lint: ## Run clippy + fmt check
	cd $(HOST_CORE_DIR) && $(CARGO) fmt -- --check
	cd $(HOST_CORE_DIR) && $(CARGO) clippy --all-features -- -D warnings

fmt: ## Auto-format Rust code
	cd $(HOST_CORE_DIR) && $(CARGO) fmt

check: ## Quick compilation check (no link)
	cd $(HOST_CORE_DIR) && $(CARGO) check --all-features 2>&1 | tail -3
	cd $(TOOLS_LATENCY_DIR) && $(CARGO) check 2>&1 | tail -2

# ── XcodeGen ──────────────────────────────────────────────────────────────────

xcodegen: ## Regenerate Xcode project from project.yml
	cd $(APPLE_CLIENT_DIR) && xcodegen generate

# ── Clean ─────────────────────────────────────────────────────────────────────

clean: ## Remove build artifacts
	cd $(HOST_CORE_DIR) && cargo clean
	cd $(TOOLS_LATENCY_DIR) && cargo clean
	rm -rf $(HOST_APP_DIR)/dist $(HOST_APP_DIR)/node_modules
	xcodebuild clean -project $(APPLE_CLIENT_DIR)/TrackBallWatch.xcodeproj -alltargets 2>/dev/null || true
