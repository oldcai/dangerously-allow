PREFIX ?= /usr/local
BINDIR := $(DESTDIR)$(PREFIX)/bin
BIN    := dangerously-allow
RELEASE := .build/release/$(BIN)

.PHONY: all build release test integration check install uninstall clean help

all: build

## build   — debug build
build:
	swift build

## release — optimized build
release:
	swift build -c release

## test    — unit tests (pure logic, no tmux needed)
test:
	swift test

## integration — end-to-end tests through a real tmux pane
integration: build
	./tools/integration-test.sh

## check   — everything
check: test integration

## install — build release and install the binary into $(PREFIX)/bin
install: release
	install -d "$(BINDIR)"
	install -m 755 "$(RELEASE)" "$(BINDIR)/$(BIN)"
	@echo "installed $(BINDIR)/$(BIN)"
	@command -v tmux >/dev/null 2>&1 || echo "warning: tmux is not installed — 'run' and 'watch' need it (brew install tmux)"

## uninstall — remove the installed binary
uninstall:
	rm -f "$(BINDIR)/$(BIN)"
	@echo "removed $(BINDIR)/$(BIN)"

## clean   — drop build artifacts
clean:
	swift package clean
	rm -rf .build

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
