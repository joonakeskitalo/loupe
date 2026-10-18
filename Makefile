# Loupe — common development commands.
#
# This wraps the existing Swift Package Manager workflow and the project's
# shell scripts (build-app.sh / make-icon.sh) so day-to-day tasks are a single
# `make <target>` away. Run `make help` to list everything.

APP_NAME := Loupe
BUNDLE   := $(APP_NAME).app
CONFIG   ?= release

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

## build: Compile the package (debug). Fast; for quick iteration.
.PHONY: build
build:
	swift build

## release: Compile the package in release configuration.
.PHONY: release
release:
	swift build -c release

## app: Build and package the signed Loupe.app bundle (set CONFIG=debug for a debug build).
.PHONY: app
app:
	./build-app.sh $(CONFIG)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

## run: Quick-iterate with `swift run` (no .app bundle; some sandboxed features behave best in the bundle).
.PHONY: run
run:
	swift run

## open: Build the .app bundle and launch it.
.PHONY: open
open: app
	open $(BUNDLE)

# ---------------------------------------------------------------------------
# Quality
# ---------------------------------------------------------------------------

## test: Run the test suite (no tests exist yet; this is a no-op until Tests/ is added).
.PHONY: test
test:
	swift test

# ---------------------------------------------------------------------------
# Assets
# ---------------------------------------------------------------------------

## icon: Regenerate Resources/AppIcon.icns from AppIcon.svg (needs rsvg-convert).
.PHONY: icon
icon:
	./make-icon.sh

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

## clean: Remove the SPM build directory.
.PHONY: clean
clean:
	swift package clean
	rm -rf .build

## distclean: Remove build artifacts and the packaged .app bundle.
.PHONY: distclean
distclean: clean
	rm -rf $(BUNDLE)

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

## help: Show this list of targets.
.PHONY: help
help:
	@echo "Loupe — available make targets:"
	@echo
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -E 's/^## ([a-zA-Z_-]+): /\1\t/' | \
		awk -F'\t' '{ printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }'
	@echo
	@echo "Variables: CONFIG=$(CONFIG) (used by \`make app\`)"
