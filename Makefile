SHELL := /bin/bash
export PATH := $(HOME)/.cargo/bin:$(PATH)

DESKTOP   := apps/host-desktop
TAURI_DIR := $(DESKTOP)/src-tauri
WATCH_DIR := apps/watch-ios
COMP_DIR  := apps/companion-ios
TOOL_DIR  := tools/latency-tester

XCODE_FLAGS := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

.PHONY: all install build build-desktop build-ios build-watch build-companion build-tools \
        dev test test-rust test-swift lint fmt check clean help

# ── Main targets ──────────────────────────────────────────────────────────────

all: install build ## Build everything

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Install ───────────────────────────────────────────────────────────────────

install: ## Install npm dependencies
	cd $(DESKTOP) && npm install

# ── Build ─────────────────────────────────────────────────────────────────────

build: build-desktop build-ios build-watch build-companion build-tools ## Build all targets

build-desktop: install ## Build desktop host (Tauri release)
	cd $(DESKTOP) && npm run tauri build

build-ios: ## Build iOS companion (unified project, debug)
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		$(XCODE_FLAGS)

build-watch: ## Build watchOS app (debug)
	xcodebuild build \
		-project $(WATCH_DIR)/TrackBallWatch.xcodeproj \
		-scheme TrackBallWatch-watchOS \
		-destination 'generic/platform=watchOS' \
		-configuration Debug \
		$(XCODE_FLAGS)

build-companion: ## Build standalone companion (debug)
	xcodebuild build \
		-project $(COMP_DIR)/TrackBallCompanion.xcodeproj \
		-scheme TrackBallCompanion \
		-destination 'generic/platform=iOS' \
		-configuration Debug \
		$(XCODE_FLAGS)

build-tools: ## Build latency-tester
	cd $(TOOL_DIR) && cargo build --release

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

xcodegen: ## Regenerate Xcode projects from project.yml
	cd $(WATCH_DIR) && xcodegen generate
	cd $(COMP_DIR) && xcodegen generate

# ── Clean ─────────────────────────────────────────────────────────────────────

clean: ## Remove build artifacts
	cd $(TAURI_DIR) && cargo clean
	cd $(TOOL_DIR) && cargo clean
	rm -rf $(DESKTOP)/dist $(DESKTOP)/node_modules
	xcodebuild clean -project $(WATCH_DIR)/TrackBallWatch.xcodeproj -alltargets 2>/dev/null || true
	xcodebuild clean -project $(COMP_DIR)/TrackBallCompanion.xcodeproj -alltargets 2>/dev/null || true
