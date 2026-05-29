SHELL := /bin/bash

.DEFAULT_GOAL := help

VERSION_FILE := VERSION
CURRENT_VERSION := $(shell tr -d '[:space:]' < $(VERSION_FILE) 2>/dev/null || echo 0.0.0)
RELEASE_FLAGS ?=

.PHONY: help check lint test smoke review-test version tag clean \
        release release\:patch release\:minor release\:major \
        _release_patch _release_minor _release_major

help: ## Show common repo commands
	@echo "Common targets:"
	@echo "  make check             Run lint and tests"
	@echo "  make lint              Check Lua syntax"
	@echo "  make test              Run headless Neovim tests"
	@echo "  make smoke             Run smoke test only"
	@echo "  make review-test       Run review diff tests only"
	@echo "  make version           Print current plugin version"
	@echo "  make release VERSION=0.1.0"
	@echo "  make release:patch     Bump patch, check, commit version, and tag"
	@echo "  make release:minor     Bump minor, check, commit version, and tag"
	@echo "  make release:major     Bump major, check, commit version, and tag"
	@echo "  make tag               Tag current VERSION"
	@echo ""
	@echo "Release options:"
	@echo "  RELEASE_FLAGS=--dry-run"
	@echo "  RELEASE_FLAGS=--push-tag"

lint: ## Check Lua syntax
	luac -p lua/piovim/*.lua scripts/smoke.lua scripts/review_diff_tests.lua

smoke: ## Run smoke test only
	nvim --headless -u NONE \
		-c 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
		-S scripts/smoke.lua \
		-c qa

review-test: ## Run review diff tests only
	nvim --headless -u NONE \
		-c 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
		-S scripts/review_diff_tests.lua \
		-c qa

test: smoke review-test ## Run headless Neovim tests
	nvim --headless -u NONE \
		-c 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
		-c 'lua require("piovim").setup({ keys = {} })' \
		-c qa

check: lint test ## Run all local checks
	git diff --check
	@echo "All checks passed"

version: ## Print current plugin version
	@printf '%s\n' '$(CURRENT_VERSION)'

release: ## Release VERSION=<semver>
	@test -n "$(VERSION)" || { echo "Usage: make release VERSION=0.1.0" >&2; exit 1; }
	scripts/release.sh "$(VERSION)" $(RELEASE_FLAGS)

release\:patch: ## Bump patch, check, commit version, and tag
	@$(MAKE) _release_patch RELEASE_FLAGS="$(RELEASE_FLAGS)"

release\:minor: ## Bump minor, check, commit version, and tag
	@$(MAKE) _release_minor RELEASE_FLAGS="$(RELEASE_FLAGS)"

release\:major: ## Bump major, check, commit version, and tag
	@$(MAKE) _release_major RELEASE_FLAGS="$(RELEASE_FLAGS)"

_release_patch:
	@scripts/release.sh "$$(scripts/next-version.sh patch)" $(RELEASE_FLAGS)

_release_minor:
	@scripts/release.sh "$$(scripts/next-version.sh minor)" $(RELEASE_FLAGS)

_release_major:
	@scripts/release.sh "$$(scripts/next-version.sh major)" $(RELEASE_FLAGS)

tag: ## Tag current VERSION
	scripts/release.sh "$(CURRENT_VERSION)" $(RELEASE_FLAGS)

clean: ## Remove transient local output
	rm -rf .tmp tmp
