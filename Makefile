#===============================================================================
# DCX Oracle Plugin - Makefile
#===============================================================================
# Targets:
#   lint       - Run shellcheck on all .sh files
#   test       - Run test suite
#   validate   - Run lint + syntax + tests
#   install    - Install plugin to DCX
#   uninstall  - Remove plugin from DCX
#   release    - Create release tarball
#   clean      - Remove build artifacts
#===============================================================================

.PHONY: all lint test validate install uninstall release clean help

# Configuration
PLUGIN_NAME := oracle
VERSION := $(shell cat VERSION 2>/dev/null || echo "1.0.0")
DCX_PLUGIN_DIR := $(HOME)/.local/share/DCX/plugins/$(PLUGIN_NAME)

# Colors
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
CYAN := \033[0;36m
NC := \033[0m

#===============================================================================
# Default target
#===============================================================================

all: validate

#===============================================================================
# Development
#===============================================================================

lint:
	@echo -e "$(CYAN)→$(NC) Running shellcheck..."
	@shellcheck lib/*.sh commands/*.sh init.sh 2>&1 || true
	@echo -e "$(GREEN)✓$(NC) Lint complete"

syntax:
	@echo -e "$(CYAN)→$(NC) Checking bash syntax..."
	@for f in lib/*.sh commands/*.sh init.sh; do \
		bash -n "$$f" || exit 1; \
	done
	@echo -e "$(GREEN)✓$(NC) Syntax OK"

test:
	@echo -e "$(CYAN)→$(NC) Running tests..."
	@if [ -f tests/run_all_tests.sh ]; then \
		cd tests && ./run_all_tests.sh; \
	else \
		echo -e "$(YELLOW)!$(NC) No tests found"; \
	fi

validate: lint syntax test
	@echo -e "$(GREEN)✓$(NC) Validation complete"

#===============================================================================
# Installation
#===============================================================================

install:
	@echo -e "$(CYAN)→$(NC) Installing plugin to $(DCX_PLUGIN_DIR)..."
	@mkdir -p "$(DCX_PLUGIN_DIR)"
	@cp -r plugin.yaml init.sh VERSION lib commands etc "$(DCX_PLUGIN_DIR)/" 2>/dev/null || true
	@chmod +x "$(DCX_PLUGIN_DIR)/init.sh"
	@chmod +x "$(DCX_PLUGIN_DIR)"/commands/*.sh 2>/dev/null || true
	@echo -e "$(GREEN)✓$(NC) Plugin installed"
	@echo ""
	@echo "Test with: dcx plugin list"
	@echo "           dcx oracle validate"

uninstall:
	@echo -e "$(CYAN)→$(NC) Removing plugin from $(DCX_PLUGIN_DIR)..."
	@rm -rf "$(DCX_PLUGIN_DIR)"
	@echo -e "$(GREEN)✓$(NC) Plugin removed"

#===============================================================================
# Release
#===============================================================================

release:
	@echo -e "$(CYAN)→$(NC) Creating release tarball..."
	@mkdir -p release
	@tar -czf release/dcx-oracle-$(VERSION).tar.gz \
		--transform 's,^,dcx-oracle-$(VERSION)/,' \
		plugin.yaml init.sh VERSION LICENSE README.md CLAUDE.md \
		lib/ commands/ etc/ docs/ 2>/dev/null || \
	tar -czf release/dcx-oracle-$(VERSION).tar.gz \
		--transform 's,^,dcx-oracle-$(VERSION)/,' \
		plugin.yaml init.sh VERSION LICENSE README.md CLAUDE.md \
		lib/ commands/
	@echo -e "$(GREEN)✓$(NC) Created: release/dcx-oracle-$(VERSION).tar.gz"

clean:
	@echo -e "$(CYAN)→$(NC) Cleaning..."
	@rm -rf release/ *.log tests/tmp/
	@echo -e "$(GREEN)✓$(NC) Clean complete"

#===============================================================================
# Help
#===============================================================================

help:
	@echo "DCX Oracle Plugin - Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Development:"
	@echo "  lint       Run shellcheck on all .sh files"
	@echo "  syntax     Check bash syntax"
	@echo "  test       Run test suite"
	@echo "  validate   Run lint + syntax + tests"
	@echo ""
	@echo "Installation:"
	@echo "  install    Install plugin to DCX (~/.local/share/DCX/plugins/)"
	@echo "  uninstall  Remove plugin from DCX"
	@echo ""
	@echo "Release:"
	@echo "  release    Create release tarball"
	@echo "  clean      Remove build artifacts"
	@echo ""
	@echo "Version: $(VERSION)"
