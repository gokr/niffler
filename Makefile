# Niffler — build and run without knowing Go, Nim or Wails.
#
#   make up     single command: build only what changed, ensure a bus + core
#               are running, then open the desktop UI
#   make down   stop the UI, core and the bus core spawned
#   make setup  install all prerequisites for this platform (Ubuntu/macOS)
#   make doctor check prerequisites and report what is missing
#
# Every binary target tracks its sources, so `make up` / `make all` are no-ops
# when nothing changed. Nim keeps its own incremental cache (nimcache/) on top.
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

# per-binary sources: a change in one component rebuilds only that binary;
# a change in the SDK rebuilds everything that imports it
SDK_NIM  := $(wildcard sdk/*.nim sdk/niffler/*.nim)
CORE_NIM := $(wildcard core/*.nim)
SDK_GO   := $(wildcard sdk/go/*.go)
NIM_CONF := config.nims niffler.nimble

# UI sources, excluding generated/installed trees (wailsjs, dist, build, deps)
UI_INPUTS := $(shell find ui \( -path ui/build -o -path ui/frontend/node_modules \
             -o -path ui/frontend/dist -o -path ui/frontend/wailsjs \
             -o -name package.json.md5 \) -prune -o -type f -print)

UI_BIN := ui/build/bin/niffler-ui

.DEFAULT_GOAL := all

.PHONY: help all build components ui run up down status test smoke dev clean \
        setup doctor recover install-go install-nim install-nats \
        install-node install-wails install-ui-deps

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
	@echo 'make recover   stop everything, rebuild shipped binaries, wipe spawned'
	@echo '               component records, restart interactively (--recover)'

all: build ui

# ---------------------------------------------------------------------------
# core + components

var/bin:
	@mkdir -p var/bin

var/bin/niffler: $(CORE_NIM) $(SDK_NIM) $(NIM_CONF) | var/bin
	nim c --hints:off -o:$@ core/core.nim

var/bin/store: components/store/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	nim c --hints:off --path:sdk -o:$@ components/store/main.nim

var/bin/bash: components/bash/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	nim c --hints:off --path:sdk -o:$@ components/bash/main.nim

var/bin/builder: components/builder/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	nim c --hints:off --path:sdk -o:$@ components/builder/main.nim

var/bin/llm-openai: components/llm-openai/main.go components/llm-openai/go.mod components/llm-openai/go.sum $(SDK_GO) | var/bin
	cd components/llm-openai && go build -o ../../var/bin/llm-openai .

components: var/bin/niffler var/bin/store var/bin/bash var/bin/builder var/bin/llm-openai

build: components

# ---------------------------------------------------------------------------
# desktop UI

ui: $(UI_BIN)

$(UI_BIN): $(UI_INPUTS)
	@if [ ! -x "$(WAILS)" ]; then \
		echo "wails CLI not found (looked at $(WAILS))."; \
		echo "Install: make install-wails"; \
		exit 1; fi
	cd ui && "$(WAILS)" build $(UI_TAGS) -nopackage

# ---------------------------------------------------------------------------
# run / test

run: build
	./var/bin/niffler

var/bin/smoke: tests/smoke.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	nim c --hints:off --path:sdk -o:$@ tests/smoke.nim

test: build var/bin/smoke
	NIF_ROOT=$(ROOT) ./var/bin/smoke

smoke: test  # alias

up: all
	./scripts/niffler.sh up

down:
	./scripts/niffler.sh down

status:
	./scripts/niffler.sh status

# recover: back to factory shape. The repo is the snapshot; var/ is
# disposable build output. Core's --recover rebuilds binaries from source
# and wipes store component records (conversations survive).
recover: build
	@./scripts/niffler.sh down 2>/dev/null || true
	./var/bin/niffler --recover

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

# note: Ubuntu 24.04 ships node 18 (fine for Vite 5). Older Ubuntu needs
# NodeSource/nvm — see docs/MANUAL.md.
