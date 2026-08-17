# mini Niffler — build and run without knowing Go, Nim or Wails.
#
#   make up     single command: build everything, ensure a bus + core are
#               running, then open the desktop UI
#   make down   stop the UI, core and the bus core spawned
#   make setup  install all prerequisites for this platform (Ubuntu/macOS)
#   make doctor check prerequisites and report what is missing
#
# Full install instructions per platform: README.md.

SHELL   := /bin/bash
ROOT    := $(abspath .)
WAILS   ?= $(shell command -v wails 2>/dev/null || echo "$(HOME)/go/bin/wails")
UI_TAGS := $(if $(filter Linux,$(shell uname -s)),-tags webkit2_41,)

# platform detection for the setup/doctor targets
UNAME_S := $(shell uname -s)
IS_MAC  := $(filter Darwin,$(UNAME_S))
IS_LNX  := $(filter Linux,$(UNAME_S))
SUDO    := $(if $(filter 0,$(shell id -u)),,sudo)

.DEFAULT_GOAL := all

.PHONY: help all build ui run up down status test smoke dev clean \
        setup doctor install-go install-nim install-nats install-node \
        install-wails install-ui-deps

help:
	@echo 'make all       build core + components + desktop UI (default)'
	@echo 'make build     build core + components only (no UI)'
	@echo 'make ui        build the Wails desktop UI'
	@echo 'make run       run the harness in the terminal'
	@echo 'make up        ensure bus + core, then open the UI (one command)'
	@echo 'make down      stop UI, core and the spawned bus'
	@echo 'make status    show what is running'
	@echo 'make test      end-to-end smoke test (spawns its own bus)'
	@echo 'make dev       Svelte dev server in a browser (bridge stubbed)'
	@echo 'make setup     install prerequisites for this platform'
	@echo 'make doctor    check prerequisites and report what is missing'
	@echo 'make clean     remove all build artifacts'

all: build ui

build:
	nimble all

ui:
	@if [ ! -x "$(WAILS)" ]; then \
		echo "wails CLI not found (looked at $(WAILS))."; \
		echo "Install: make install-wails"; \
		exit 1; fi
	cd ui && "$(WAILS)" build $(UI_TAGS)

run: build
	./var/bin/niffler

up: all
	./scripts/niffler.sh up

down:
	./scripts/niffler.sh down

status:
	./scripts/niffler.sh status

test: build
	nimble smoke

dev:
	cd ui/frontend && npm run dev

clean:
	rm -rf var nimcache ui/build ui/frontend/node_modules ui/frontend/dist

# ---------------------------------------------------------------------------
# prerequisites

setup: install-go install-nim install-nats install-node install-wails install-ui-deps
	@echo "setup done — verify with 'make doctor', then 'make up'"

define check_tool
	@if command -v $(1) >/dev/null 2>&1; then \
		echo "  $(1): OK"; \
	else \
		echo "  $(1): MISSING — run 'make $(2)'"; \
	fi
endef

doctor:
	@echo "Prerequisites:"
	$(call check_tool,nim,install-nim)
	$(call check_tool,go,install-go)
	$(call check_tool,nats-server,install-nats)
	$(call check_tool,node,install-node)
	$(call check_tool,npm,install-node)
	@if command -v wails >/dev/null 2>&1 || [ -x "$(WAILS)" ]; then \
		echo "  wails: OK"; \
	else \
		echo "  wails: MISSING — run 'make install-wails'"; \
	fi
	$(if $(IS_LNX),@if pkg-config --exists webkit2gtk-4.1 2>/dev/null; then \
		echo "  webkit2gtk-4.1: OK"; \
	else \
		echo "  webkit2gtk-4.1: MISSING — run 'make install-ui-deps'"; \
	fi)
	@echo "Then: make up"

install-go:
	@if command -v go >/dev/null 2>&1; then echo "go: already installed"; \
	elif [ -n "$(IS_MAC)" ]; then brew install go; \
	elif command -v snap >/dev/null 2>&1; then $(SUDO) snap install go --classic; \
	else echo "Install Go from https://go.dev/dl (or use your package manager)"; fi

install-nim:
	@if command -v nim >/dev/null 2>&1; then echo "nim: already installed"; \
	elif [ -n "$(IS_MAC)" ]; then brew install nim; \
	else echo "Installing Nim via choosenim (~/.nimble/bin) ..."; \
		curl -sSf https://nim-lang.org/choosenim/init.sh | sh; fi

install-nats:
	@if command -v nats-server >/dev/null 2>&1; then echo "nats-server: already installed"; \
	else echo "Installing nats-server via go install ..."; \
		go install github.com/nats-io/nats-server/v2@latest; fi

install-node:
	@if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then \
		echo "node/npm: already installed"; \
	elif [ -n "$(IS_MAC)" ]; then brew install node; \
	else $(SUDO) apt-get install -y nodejs npm; fi

install-wails:
	@if command -v wails >/dev/null 2>&1 || [ -x "$(WAILS)" ]; then \
		echo "wails: already installed ($(WAILS))"; \
	else echo "Installing wails CLI ..."; \
		go install github.com/wailsapp/wails/v2/cmd/wails@latest; fi

install-ui-deps:
	@if [ -n "$(IS_MAC)" ]; then echo "UI deps: not needed on macOS"; \
	elif pkg-config --exists webkit2gtk-4.1 2>/dev/null; then \
		echo "webkit2gtk-4.1: already installed"; \
	else echo "Installing webkit2gtk 4.1 + GTK3 dev packages ..."; \
		$(SUDO) apt-get install -y libwebkit2gtk-4.1-dev libgtk-3-dev build-essential pkg-config; fi
