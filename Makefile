# Niffler — build without knowing Go, Nim or Wails.
#
#   make all    build core + components + desktop UI (default)
#   make setup  install all prerequisites for this platform (Ubuntu/macOS)
#   make doctor check prerequisites and report what is missing
#
# Starting/stopping is not make's job: launch niffler-ui (any UI autostarts
# core, the last UI stops it) or ./var/bin/niffler in a terminal (admin shell).
#
# Every binary target tracks its sources, so `make all` is a no-op
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
SDK_GO   := $(filter-out %_test.go,$(wildcard sdk/go/*.go)) sdk/go/go.mod sdk/go/go.sum
NIM_CONF := config.nims niffler.nimble

# UI sources, excluding generated/installed trees (wailsjs, dist, build, deps)
UI_INPUTS := $(shell find ui \( -path ui/build -o -path ui/frontend/node_modules \
             -o -path ui/frontend/dist -o -path ui/frontend/wailsjs \
             -o -name package.json.md5 \) -prune -o -type f -print)

UI_BIN := ui/build/bin/niffler-ui
BUILD_LOCK := bash scripts/with-build-lock.sh
TEST_LOCK  := bash scripts/with-build-lock.sh -s
# Per-file recipes lock themselves unless a held lock is already active
# (the `components` aggregate holds one exclusive lock around the whole
# build generation and exports this marker to the inner sub-make).
BUILD_WRAP = $(if $(NIF_LOCK_HELD),,$(BUILD_LOCK))

# Commit hash shown in the About dialog (injected via -ldflags; the SPA no
# longer embeds it — the header chip moved into the native About dialog).
UI_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

.DEFAULT_GOAL := all

.PHONY: help all build components components-inner ui ui-install ui-uninstall run \
        test test-bash test-store test-builder test-console test-plugins test-skills test-fetch \
        test-models test-provider test-observe test-logfile test-core test-cli test-hashline \
        test-grep test-write \
        test-autostart test-smoke smoke dev clean gotest \
        setup doctor recover install-go install-nim install-nats \
        install-node install-wails install-ui-deps

help:
	@echo 'make all       build core + components + desktop UI (default)'
	@echo 'make build     build core + components only (no UI)'
	@echo 'make ui        build the Wails desktop UI'
	@echo 'make ui-install   install the launcher entry + app icon (Linux)'
	@echo 'make ui-uninstall remove the launcher entry + app icon (Linux)'
	@echo 'make run       run the harness in the terminal (admin shell)'
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
	$(BUILD_WRAP) nim c --hints:off -o:$@ core/niffler.nim

var/bin/session: $(CORE_NIM) $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off -o:$@ core/session.nim

var/bin/store: components/store/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/store/main.nim

var/bin/bash: components/bash/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/bash/main.nim

var/bin/hashline-edit: components/hashline-edit/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/hashline-edit/main.nim

var/bin/grep: components/grep/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/grep/main.nim

var/bin/write: components/write/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/write/main.nim

var/bin/builder: components/builder/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/builder/main.nim

var/bin/plugins: components/plugins/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/plugins/main.nim

var/bin/observe: components/observe/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/observe/main.nim

var/bin/logfile: components/logfile/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/logfile/main.nim

var/bin/console: components/console/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/console/main.nim

var/bin/cli: components/cli/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ components/cli/main.nim

var/bin/llm-openai: components/llm-openai/main.go components/llm-openai/go.mod components/llm-openai/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/llm-openai && go build -o ../../var/bin/llm-openai .'

var/bin/models: components/models/main.go components/models/catalog.go components/models/seed.json components/models/go.mod components/models/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/models && go build -o ../../var/bin/models .'

var/bin/provider: components/provider/main.go components/provider/go.mod components/provider/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/provider && go build -o ../../var/bin/provider .'

var/bin/llm: components/llm/main.go components/llm/go.mod components/llm/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/llm && go build -o ../../var/bin/llm .'

components:
	$(BUILD_LOCK) env NIF_LOCK_HELD=1 $(MAKE) --no-print-directory components-inner

components-inner: var/bin/niffler var/bin/session var/bin/store var/bin/bash var/bin/hashline-edit \
	var/bin/grep var/bin/write \
	var/bin/builder var/bin/plugins var/bin/observe var/bin/logfile var/bin/console \
	var/bin/cli var/bin/llm-openai var/bin/models var/bin/provider var/bin/llm

build: components

# ---------------------------------------------------------------------------
# desktop UI

ui: $(UI_BIN)

$(UI_BIN): $(UI_INPUTS)
	@if [ ! -x "$(WAILS)" ]; then \
		echo "wails CLI not found (looked at $(WAILS))."; \
		echo "Install: make install-wails"; \
		exit 1; fi
	$(BUILD_WRAP) bash -c 'cd ui && "$(WAILS)" build $(UI_TAGS) -nopackage \
		-ldflags "-X main.buildCommit=$(UI_COMMIT) -X main.nifRoot=$(ROOT)"'

# Desktop integration (Linux): the appicon the window shows comes from the
# embedded icon in main.go, but the launcher/taskbar icon needs a desktop
# entry + hicolor icons — the same pattern as flatout's install-desktop.
BIN_DIR      := $(HOME)/.local/bin
DESKTOP_DIR  := $(HOME)/.local/share/applications
ICON_DIR     := $(HOME)/.local/share/icons/hicolor
DESKTOP_DST  := $(DESKTOP_DIR)/niffler.desktop

ui-install: ui
	@echo "Installing Niffler desktop integration..."
	@mkdir -p $(BIN_DIR) $(DESKTOP_DIR) $(ICON_DIR)/48x48/apps $(ICON_DIR)/256x256/apps
	cp $(UI_BIN) $(BIN_DIR)/niffler-ui
	chmod +x $(BIN_DIR)/niffler-ui
	sed 's|Exec=.*|Exec=$(BIN_DIR)/niffler-ui|' ui/niffler.desktop > $(DESKTOP_DST)
	cp ui/appicon-48.png $(ICON_DIR)/48x48/apps/niffler.png
	cp ui/appicon-256.png $(ICON_DIR)/256x256/apps/niffler.png
	-update-desktop-database $(DESKTOP_DIR) 2>/dev/null || true
	-gtk-update-icon-cache -f $(ICON_DIR) 2>/dev/null || true
	@echo "Launcher 'Niffler' installed (executable: $(BIN_DIR)/niffler-ui)."
	@echo "You may need to log out and back in for the icon to appear."

ui-uninstall:
	@echo "Removing Niffler desktop integration..."
	rm -f $(BIN_DIR)/niffler-ui
	rm -f $(DESKTOP_DST)
	rm -f $(ICON_DIR)/48x48/apps/niffler.png
	rm -f $(ICON_DIR)/256x256/apps/niffler.png
	-update-desktop-database $(DESKTOP_DIR) 2>/dev/null || true
	@echo "Done."

# ---------------------------------------------------------------------------
# run / test

run: build
	./var/bin/niffler

var/bin/smoke: tests/smoke.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ tests/smoke.nim

# ---------------------------------------------------------------------------
# tests: one binary per tests/*.nim; `make test` runs the whole suite
# sequentially. Runtime state and NATS are isolated per test, so individual
# test targets may run concurrently with each other and a live harness.
# Individual: make test-bash, test-store,
# test-builder, test-console, test-plugins, test-skills, test-fetch,
# test-core, test-cli,
# test-observe, test-logfile, test-models, test-hashline, test-grep,
# test-write, test-smoke.

TEST_NIM  := tests/smoke.nim $(wildcard tests/t_*.nim)
TEST_BINS := $(patsubst tests/%.nim,var/bin/test_%,$(TEST_NIM))

var/bin/test_%: tests/%.nim tests/helpers.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off --path:sdk -o:$@ tests/$*.nim

test: build $(TEST_BINS) gotest
	$(TEST_LOCK) bash -c 'for t in $(TEST_BINS); do \
		echo "== $$t"; \
		env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./$$t || exit 1; \
	done'

test-bash:    build var/bin/test_t_bash    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_bash
test-store:   build var/bin/test_t_store   ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_store
test-builder: build var/bin/test_t_builder ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_builder
test-console: build var/bin/test_t_console ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_console
test-plugins: build var/bin/test_t_plugins ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_plugins
test-skills:  build var/bin/test_t_skills  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_skills
test-fetch:   build var/bin/test_t_fetch   ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_fetch
test-core:    build var/bin/test_t_core    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_core
test-observe: build var/bin/test_t_observe ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_observe
test-logfile: build var/bin/test_t_logfile ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_logfile
test-models:  build var/bin/test_t_models  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_models
test-provider: build var/bin/test_t_provider ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_provider
test-cli:     build var/bin/test_t_cli     ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_cli
test-hashline: build var/bin/test_t_hashline ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_hashline
test-grep:    build var/bin/test_t_grep    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_grep
test-write:   build var/bin/test_t_write   ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_write
test-smoke:   build var/bin/test_smoke     ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_smoke
test-autostart: build var/bin/test_t_autostart ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_autostart

smoke: test-smoke  # legacy alias

# Go unit tests (models, provider, llm, sdk) — no shared runtime state, part of `make test`.
gotest:
	cd sdk/go && go test ./... && go vet ./...
	cd components/models && go test ./... && go vet ./...
	cd components/provider && go test ./... && go vet ./...
	cd components/llm && go test ./... && go vet ./...

# recover: back to factory shape. The repo is the snapshot; var/ is
# disposable build output. Core's --recover rebuilds binaries from source
# and wipes store component records (conversations survive).
recover: build
	@pkill -f "niffler-ui" 2>/dev/null; \
	 pkill -f "$(ROOT)/var/bin/niffler$$" 2>/dev/null; sleep 1; true
	./var/bin/niffler --recover

dev:
	cd ui/frontend && npm run dev

clean:
	$(BUILD_LOCK) rm -rf var nimcache ui/build ui/frontend/node_modules ui/frontend/dist

# ---------------------------------------------------------------------------
# prerequisites

setup: install-go install-nim install-nats install-node install-wails install-ui-deps
	@echo "setup done — verify with 'make doctor', then 'make'"

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
	@echo "  ts components: node + npm (above) — typescript comes from npm per build;"
	@echo "                  npm registry access needed for 'builder.build {lang: \"ts\"}'"
	@echo "Then: make — and launch niffler-ui or ./var/bin/niffler"

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
		$(SUDO) apt-get install -y libwebkit2gtk-4.1-dev libgtk-3-dev build-essential pkg-config libssl-dev; fi

# note: Ubuntu 24.04 ships node 18 (fine for Vite 5). Older Ubuntu needs
# NodeSource/nvm — see docs/MANUAL.md.
