# Niffler — build without knowing Go, Nim or Wails.
#
#   make all    build core + components (default)
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
# choosenim and Nimble-installed helpers.
export PATH := $(HOME)/.nimble/bin:$(PATH)
WAILS   ?= $(shell command -v wails 2>/dev/null || echo "$(HOME)/go/bin/wails")

# platform detection for the setup/doctor targets
UNAME_S := $(shell uname -s)
IS_MAC  := $(filter Darwin,$(UNAME_S))
IS_LNX  := $(filter Linux,$(UNAME_S))
SUDO    := $(if $(filter 0,$(shell id -u)),,sudo)

ifneq ($(IS_MAC),)
# libclang needs the SDK headers; the linker needs Homebrew's native libraries.
export SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null)
BREW_PREFIX := $(shell brew --prefix 2>/dev/null)
export LIBRARY_PATH := $(BREW_PREFIX)/lib$(if $(LIBRARY_PATH),:$(LIBRARY_PATH))
endif

# per-binary sources: a change in one component rebuilds only that binary;
# a change in the SDK rebuilds everything that imports it
SDK_NIM  := $(wildcard sdk/*.nim sdk/niffler/*.nim)
CORE_NIM := $(wildcard core/*.nim)
SDK_GO   := $(filter-out %_test.go,$(wildcard sdk/go/*.go)) sdk/go/go.mod sdk/go/go.sum
NIM_CONF := config.nims niffler.nimble

# Multi-file component source sets. Wildcards, not hand-written lists: a
# prerequisite list that misses one file ships the PREVIOUS binary while the
# tree and the tests look current (it happened — components/lsp/roots.nim was
# absent from var/bin/lsp, so `make test-lsp` ran a build without the change,
# and `make` called the target up to date). `_test.*` is filtered out: only
# `go build`/`nim c` of the test target compiles it, so a test-only edit must
# not rebuild the component.
NIM_SRCS = $(filter-out %_test.nim,$(wildcard components/$(1)/*.nim))
GO_SRCS  = $(filter-out %_test.go,$(wildcard components/$(1)/*.go)) components/$(1)/go.mod components/$(1)/go.sum

# Build mode: `make build` compiles debug (fast, runtime checks on) — right
# for development and CI. `make release` rebuilds into var/bin with
# -d:release (optimized) for benching and production; `make build` swaps
# the debug binaries back. Go components are unaffected (I/O-bound).
# make tracks timestamps, not build modes — a mode flip is stamped in
# var/bin/.mode and wipes var/bin so nothing stale survives the switch.
NIMFLAGS ?=
MODE := var/bin/.mode

# The desktop UI is a separate interactive plugin (gokr/niffler-ui), built
# with `make install-ui`; it is intentionally not part of `make all`/`make build`.
# The harness keeps only the installed client artifact in var/bin.
UI_BIN := var/bin/niffler-ui
BUILD_LOCK := bash scripts/with-build-lock.sh
TEST_LOCK  := bash scripts/with-build-lock.sh -s
# Per-file recipes lock themselves unless a held lock is already active
# (the `components` aggregate holds one exclusive lock around the whole
# build generation and exports this marker to the inner sub-make).
BUILD_WRAP = $(if $(NIF_LOCK_HELD),,$(BUILD_LOCK))

.DEFAULT_GOAL := all

.PHONY: help all build components components-inner run down down-here \
        test test-server test-bash test-store test-store-sqlite test-store-tidb test-builder test-console test-plugins test-skills test-fetch \
        test-models test-provider test-observe test-logfile test-hooks test-core test-discover test-cli \
        test-systemprompt test-grep test-git test-edit test-expert test-mcp test-uireg \
        test-retry-unit test-ctx-accounting test-compaction \
        test-autostart test-smoke smoke dev clean gotest \
        install uninstall install-ui install-tui \
        setup doctor recover install-go install-nim install-nats \
        install-node install-wails install-ui-deps install-native-deps install-nim-deps \
        install-natscli install-jq install-zenity

help:
	@echo 'make all       build core + components (default)'
	@echo 'make build     same, explicit target (no UI — the UI lives in gokr/niffler-ui)'
	@echo 'make install-ui   build + install the desktop UI (gokr/niffler-ui) and the'
	@echo '                  launcher that boots this harness on demand'
	@echo 'make install    put niffler/niffler-cli (+ niffler-tui on request) on PATH'
	@echo 'make install-tui  same, installing the niffler-tui client without asking'
	@echo 'make uninstall  remove those PATH entries again (WITH_TUI=1 to preinstall)'
	@echo '                overrides: NIF_BIN_DIR=~/bin  WITH_TUI=1  FORCE=1'
	@echo 'make run       run the harness in the terminal (admin shell)'
	@echo 'make ram       RAM of running niffler stacks (harness + components + nats + clients)'
	@echo 'make down      stop any running harness, components and nats-server'
	@echo 'make down-here stop only THIS checkout's harness, components and bus'
	@echo 'make test      full gate: the bus-contract suite (frontend tests are in'
	@echo '               gokr/niffler-ui: make test / make typecheck there)'
	@echo 'make test-server  bus-contract suite only (no node/UI toolchain)'
	@echo 'make dev       Svelte dev server in a browser (bridge stubbed; needs the'
	@echo '               niffler-ui checkout: make dev there)'
	@echo 'make setup     install prerequisites for this platform'
	@echo 'make doctor    check prerequisites and report what is missing'
	@echo 'make clean     remove all build artifacts'
	@echo 'make recover   stop everything, rebuild shipped binaries, wipe spawned'
	@echo '               component records, restart interactively (--recover)'

all: build

# ---------------------------------------------------------------------------
# core + components

var/bin:
	@mkdir -p var/bin

var/bin/niffler: $(CORE_NIM) $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) -o:$@ core/niffler.nim

var/bin/session: $(CORE_NIM) $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) -o:$@ core/session.nim

var/bin/store: components/store/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/store/main.nim

# store-sqlite — the SQLite engine of the store contract (docs/research/
# STORE_V2.md M3). Same component name/tools; the DEFAULT engine, selected
# at boot via NIF_STORE_BACKEND=sqlite (unset means sqlite). Pure-Go driver:
# no cgo, no build prerequisites.
var/bin/store-sqlite: components/store-sqlite/main.go components/store-sqlite/go.mod components/store-sqlite/go.sum \
    $(wildcard components/store-sqlite/migrations/*.sql) $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/store-sqlite && go build -o ../../var/bin/store-sqlite .'

# store-tidb — the TiDB/MySQL engine of the store contract (M4): a network-
# shared store, many harnesses can serve from one cluster. Selected at boot
# via NIF_STORE_BACKEND=tidb; needs NIF_STORE_TIDB_DSN. Pure Go, no cgo.
var/bin/store-tidb: components/store-tidb/main.go components/store-tidb/go.mod components/store-tidb/go.sum \
    $(wildcard components/store-tidb/migrations/*.sql) $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/store-tidb && go build -o ../../var/bin/store-tidb .'

# store migration: copy a root's data between engines (barrel -> sqlite).
# A separate offline binary: it starts its own bus and store processes, so
# no harness needs to be running. See docs/research/COMPACTION.md §2.
var/bin/niffler-store-migrate: tools/store_migrate.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ tools/store_migrate.nim

var/bin/bash: components/bash/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/bash/main.nim

var/bin/edit: components/edit/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/edit/main.nim

# Language-server seam (docs/OCTOFRIEND-STEAL.md): one `lsp` tool over any
# configured stdio server; the registry is data, languages are never code.
var/bin/lsp: $(call NIM_SRCS,lsp) $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/lsp/main.nim

# Repomap (docs/research/REPOMAP.md): ranked workspace map; the C in csrc/
# is pulled in by ts.nim's {.compile.} pragmas (this list is rebuild
# tracking only).
REPOMAP_CSRC := $(wildcard components/repomap/csrc/tree_sitter/lib/src/*.c) \
  $(wildcard components/repomap/csrc/tree_sitter/lib/src/unicode/*.h) \
  components/repomap/csrc/go/parser.c \
  components/repomap/csrc/python/parser.c components/repomap/csrc/python/scanner.c \
  components/repomap/csrc/typescript/parser.c components/repomap/csrc/typescript/scanner.c \
  components/repomap/csrc/javascript/parser.c components/repomap/csrc/javascript/scanner.c \
  components/repomap/csrc/c/parser.c \
  components/repomap/csrc/cpp/parser.c components/repomap/csrc/cpp/scanner.c \
  components/repomap/csrc/rust/parser.c components/repomap/csrc/rust/scanner.c \
  components/repomap/csrc/ruby/parser.c components/repomap/csrc/ruby/scanner.c
var/bin/repomap: components/repomap/main.nim components/repomap/tags.nim \
    components/repomap/score.nim components/repomap/repomap.nim \
    components/repomap/ts.nim $(REPOMAP_CSRC) $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/repomap/main.nim

# Repomap tags seam (docs/research/REPOMAP.md): tree-sitter C runtime + 3
# grammars vendored under csrc/ (wasm excluded); the {.compile.} pragmas in
# ts.nim pull the C in and headers resolve via --cincludes. Queries live in
# components/repomap/queries. The native Nim tier needs no C.
var/bin/test_t_repomap_tags: tests/t_repomap_tags.nim components/repomap/tags.nim \
    components/repomap/score.nim components/repomap/repomap.nim \
    components/repomap/ts.nim $(REPOMAP_CSRC) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk \
	  -o:$@ tests/t_repomap_tags.nim

var/bin/test_t_repomap_score: tests/t_repomap_score.nim components/repomap/tags.nim \
    components/repomap/score.nim components/repomap/repomap.nim $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk \
	  -o:$@ tests/t_repomap_score.nim

var/bin/test_t_repomap: tests/t_repomap.nim components/repomap/main.nim \
    components/repomap/tags.nim components/repomap/score.nim \
    components/repomap/repomap.nim components/repomap/ts.nim $(REPOMAP_CSRC) \
    $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ tests/t_repomap.nim

# A test that imports a component's source (here: the pure root/marker seam)
# must rebuild when that source changes, exactly like the component itself.
var/bin/test_t_lsp: $(call NIM_SRCS,lsp)

# Background processes with an owner: start once, poll incremental output,
# kill explicitly (docs/OCTOFRIEND-STEAL.md, "Steal 5 follow-up").
var/bin/processes: components/processes/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/processes/main.nim

var/bin/grep: components/grep/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/grep/main.nim

var/bin/git: components/git/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/git/main.nim

var/bin/mcp: $(wildcard components/mcp/*.go) components/mcp/go.mod components/mcp/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/mcp && go build -o ../../var/bin/mcp .'

var/bin/mcp-bridge: $(wildcard components/mcp-bridge/*.go) components/mcp-bridge/go.mod components/mcp-bridge/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/mcp-bridge && go build -o ../../var/bin/mcp-bridge .'

var/bin/builder: components/builder/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/builder/main.nim

var/bin/plugins: $(call NIM_SRCS,plugins) $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/plugins/main.nim

var/bin/skills: components/skills/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/skills/main.nim

var/bin/systemprompt: components/systemprompt/main.nim \
    components/systemprompt/baseprompt.txt $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/systemprompt/main.nim

var/bin/recall: components/recall/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/recall/main.nim

var/bin/compaction: components/compaction/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/compaction/main.nim

var/bin/fetch: components/fetch/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/fetch/main.nim

var/bin/observe: components/observe/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/observe/main.nim

var/bin/logfile: components/logfile/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/logfile/main.nim

var/bin/console: components/console/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/console/main.nim

var/bin/cli: components/cli/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/cli/main.nim

var/bin/llm-openai: components/llm-openai/main.go components/llm-openai/go.mod components/llm-openai/go.sum $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/llm-openai && go build -o ../../var/bin/llm-openai .'

# nats-server — the bus itself as a first-class component: a faithful rebuild
# of the official binary (in-process server library), so `make build` alone
# satisfies the NATS dependency (core prefers it over PATH, core/niffler.nim).
var/bin/nats-server: $(wildcard components/nats/*.go) components/nats/go.mod components/nats/go.sum | var/bin
	$(BUILD_WRAP) bash -c 'cd components/nats && go build -o ../../var/bin/nats-server .'

var/bin/models: $(call GO_SRCS,models) components/models/seed.json $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/models && go build -o ../../var/bin/models .'

var/bin/provider: $(call GO_SRCS,provider) $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/provider && go build -o ../../var/bin/provider .'

var/bin/llm: $(call GO_SRCS,llm) $(SDK_GO) | var/bin
	$(BUILD_WRAP) bash -c 'cd components/llm && go build -o ../../var/bin/llm .'

var/bin/agent: components/agent/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/agent/main.nim

# hooks — operator shell commands on selected bus events (off by default in
# the runtime manifest, but built and tested: t_hooks needs the binary).
var/bin/hooks: components/hooks/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/hooks/main.nim

# expert — advisory peer (docs/research/EXPERT.md): follows one session, LLM-judged,
# turn-bound steer. Inert until expert_follow names a target.
var/bin/expert: components/expert/main.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/expert/main.nim

# Native guest compiler/supervisor: no embedded VM/compiler-source dependency.
var/bin/fabric-exec: components/fabric/executor.nim components/fabric/fabricguest/fabricguest.nim components/fabric/fabricguest/fabricmeta.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/fabric/executor.nim

var/bin/fabric: components/fabric/fabric.nim components/fabric/framing.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ components/fabric/fabric.nim

# dialog is a component written entirely in bash (nats CLI + jq — no SDK,
# no compile step). Copy it, don't compile it.
var/bin/dialog: components/dialog/dialog.sh | var/bin
	cp $< $@ && chmod +x $@

components:
	$(BUILD_LOCK) env NIF_LOCK_HELD=1 $(MAKE) --no-print-directory components-inner

components-inner: var/bin/niffler var/bin/session var/bin/store var/bin/store-sqlite var/bin/store-tidb var/bin/niffler-store-migrate var/bin/bash \
	var/bin/edit var/bin/lsp var/bin/repomap var/bin/processes var/bin/grep var/bin/git \
	var/bin/builder var/bin/plugins var/bin/skills var/bin/fetch \
	var/bin/observe var/bin/logfile var/bin/console \
	var/bin/cli var/bin/llm-openai var/bin/models var/bin/provider var/bin/llm \
	var/bin/agent var/bin/expert var/bin/fabric var/bin/fabric-exec var/bin/systemprompt \
	var/bin/recall var/bin/compaction \
	var/bin/hooks var/bin/dialog var/bin/nats-server \
	var/bin/mcp var/bin/mcp-bridge

build:
	@mkdir -p var/bin; if [ "$$(cat $(MODE) 2>/dev/null)" = "release" ]; then \
		echo debug > $(MODE); rm -f var/bin/*; \
		echo "release binaries detected — wiped var/bin for a debug rebuild"; fi
	@$(MAKE) --no-print-directory components

release:
	@mkdir -p var/bin; if [ "$$(cat $(MODE) 2>/dev/null)" != "release" ]; then \
		echo release > $(MODE); rm -f var/bin/*; \
		echo "debug binaries detected — wiped var/bin for a release rebuild"; fi
	$(BUILD_LOCK) env NIF_LOCK_HELD=1 $(MAKE) --no-print-directory NIMFLAGS=-d:release components-inner
	@echo "release binaries in var/bin (-d:release) — 'make build' swaps debug back"

# ---------------------------------------------------------------------------
# desktop UI (separate repository: gokr/niffler-ui)
#
# This clone keeps no UI source. install-ui clones that repo at its latest
# release tag, builds it against THIS harness (writing an untracked go.work so
# the SDK comes from here), drops the binary in var/bin and writes the
# launcher — the same shape as install-tui for the terminal client.
install-ui:
	bash ./scripts/install-ui.sh

# CLI/terminal integration: niffler-prefixed symlinks + the on-demand
# niffler-tui wrapper in a user bin dir (see scripts/install.sh — never
# component binaries, so PATH cannot be shadowed by grep/git/edit/...).
install: build
	./scripts/install.sh

uninstall:
	./scripts/install.sh --uninstall

# The README names these aliases so the desktop and terminal entry points
# read in the same direction: install-ui builds the UI repo against this
# harness (above), install-tui = install WITH_TUI=1.
install-tui:
	$(MAKE) --no-print-directory install WITH_TUI=1

# ---------------------------------------------------------------------------
# run / test

run: build
	./var/bin/niffler

# ram: how much memory is a running Niffler stack? harness + nats + every
# spawned component + session runners + clients (tui/cli/console/ui),
# grouped per stack (dev clone vs nifflerprod vs bench private harnesses).
# See scripts/niffler-ram.sh for the membership rule (exe under var/bin —
# a PPID walk would miss the tui parent and the bench driver's bus).
ram:
	bash scripts/niffler-ram.sh

# down: stop every harness/component of this repo plus the bus. Needed when
# a stray detached core (e.g. one autostarted by a UI whose terminal is gone)
# keeps var/barrel-db.lock and a fresh harness's store refuses to start.
# Bracketed patterns avoid pkill matching this recipe's own shell; killing
# all nats-server instances is intentional: orphaned buses outlive their
# harness (see AGENTS.md) and cannot be matched by path.
down:
	@pkill -f "var/bin/[n]iffler" 2>/dev/null; \
	 pkill -f "niffler/var/[b]in" 2>/dev/null; \
	 pkill -f "niffler-[u]i" 2>/dev/null; \
	 pkill -x nats-server 2>/dev/null; \
	 sleep 1; echo "down: harnesses, components and nats-server stopped"

# down-here: the scoped variant — kills only processes whose executable
# lives under this root's var/bin (plus this root's spawned bus via
# var/nats-pid), so bench worktrees, other clones and their private buses
# survive. See scripts/down-here.sh for the pinning rules; the global
# `down` above stays for the stray-everything case.
down-here:
	@bash scripts/down-here.sh "$(ROOT)"

# The env every test binary runs under. NIF_REPO_ROOT/NIF_ROOT are what the
# Makefile has always passed; the `env -u` prefix is hygiene: a shell that
# EXPORTED .env (a harness-spawned shell, or anyone who `set -a`'d it) leaks
# NIF_OPENAI_* into every sandbox, where t_provider then legitimately finds a
# complete environment provider and fails two checks that assert a clean one.
# Tests that want a provider env set it themselves per component (see
# tests/t_provider.nim's environment cases).
TEST_ENV := env -u NIF_OPENAI_API_KEY -u NIF_OPENAI_BASE_URL \
                -u NIF_OPENAI_MODEL -u NIF_OPENAI_PROTOCOL -u NIF_PROVIDER \
                "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)"

# Bus-contract suite parallelism: a bounded pool over the isolated test
# binaries (each owns its NATS server + temp root). Override per run:
#   make test-server TEST_JOBS=1      # sequential (old behavior)
#   make test-server TEST_JOBS=6      # deeper pool
TEST_JOBS ?= $(shell (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) | head -1)

var/bin/smoke: tests/smoke.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ tests/smoke.nim

# ---------------------------------------------------------------------------
# tests: one binary per tests/*.nim; `make test-server` runs the whole suite
# through scripts/run-tests.sh in a bounded pool (TEST_JOBS, default one per
# core). Runtime state and NATS are isolated per test, so individual test
# targets may run concurrently with each other and a live harness.
# Individual: make test-bash, test-store, test-store-sqlite, test-store-tidb,
# test-builder, test-console, test-plugins, test-skills, test-fetch,
# test-core, test-discover, test-cli, test-systemprompt,
# test-observe, test-logfile, test-models, test-grep,
# test-git, test-mcp, test-controls, test-smoke.

TEST_NIM  := tests/smoke.nim $(wildcard tests/t_*.nim)
TEST_BINS := $(patsubst tests/%.nim,var/bin/test_%,$(TEST_NIM))

var/bin/test_%: tests/%.nim tests/helpers.nim $(SDK_NIM) $(NIM_CONF) | var/bin
	$(BUILD_WRAP) nim c --hints:off $(NIMFLAGS) --path:sdk -o:$@ tests/$*.nim

var/bin/test_t_schema_validation: core/schema_validation.nim

var/bin/test_t_catalog: core/catalog.nim core/schema_validation.nim

var/bin/test_t_core_requests: $(wildcard core/*.nim)

var/bin/test_t_approval_manifest: core/approval.nim core/catalog.nim

var/bin/test_t_retry_unit: core/retry.nim

var/bin/test_t_supervisor_backoff: core/supervisor.nim core/catalog.nim

var/bin/test_t_ctx_accounting: core/conversation.nim

# The full gate. The frontend half (lib unit tests + typecheck) lives in the
# UI's own repository now (gokr/niffler-ui: make test / make typecheck) — its
# toolchain, generated Wails bindings and node_modules are that repo's
# business, which is what let this suite go back to being self-contained.
test: test-server

# The bus-contract suite: one test per component + smoke + the Go unit tests.
test-server: build $(TEST_BINS) gotest
	$(TEST_LOCK) $(TEST_ENV) NIF_TEST_JOBS=$(TEST_JOBS) \
		bash scripts/run-tests.sh -- $(TEST_BINS)

test-bash:    build var/bin/test_t_bash    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_bash
test-store:   build var/bin/test_t_store   ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_store
# Same bus-contract test against the SQLite engine (t_store picks the binary
# up from NIF_STORE_BIN; `make test-store` runs the default engine, sqlite).
test-store-sqlite: build var/bin/test_t_store ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" NIF_STORE_BIN="$(ROOT)/var/bin/store-sqlite" ./var/bin/test_t_store
# Same bus-contract test against the TiDB engine — needs a live server:
# NIF_STORE_TIDB_DSN=root@tcp(127.0.0.1:4000)/test (docker run -p 4000:4000 pingcap/tidb).
test-store-tidb: build var/bin/test_t_store
	@if [ -z "$$NIF_STORE_TIDB_DSN" ]; then \
		echo "SKIP: test-store-tidb — set NIF_STORE_TIDB_DSN (e.g. \"root@tcp(127.0.0.1:4000)/test\")"; \
	else \
		$(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" \
			NIF_STORE_BIN="$(ROOT)/var/bin/store-tidb" ./var/bin/test_t_store; \
	fi
test-builder: build var/bin/test_t_builder ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_builder
test-console: build var/bin/test_t_console ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_console
test-plugins: build var/bin/test_t_plugins ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_plugins
test-skills:  build var/bin/test_t_skills  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_skills
test-fetch:   build var/bin/test_t_fetch   ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_fetch
test-core:    build var/bin/test_t_core    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_core
test-systemprompt: build var/bin/test_t_systemprompt ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_systemprompt
test-discover: build var/bin/test_t_discover ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_discover
test-profile: build var/bin/test_t_profile ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_profile
test-observe: build var/bin/test_t_observe ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_observe
test-logfile: build var/bin/test_t_logfile ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_logfile
test-recall:  build var/bin/test_t_recall  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_recall
test-workspaces: build var/bin/test_t_workspaces ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_workspaces
test-hooks:  build var/bin/test_t_hooks  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_hooks
test-uireg:  build var/bin/test_t_uireg  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_uireg
test-models:  build var/bin/test_t_models  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_models
test-provider: build var/bin/test_t_provider ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_provider
test-cli: build var/bin/test_t_cli var/bin/test_t_cli_catalog
	$(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_cli
	$(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_cli_catalog
test-grep:    build var/bin/test_t_grep    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_grep
test-git:     build var/bin/test_t_git     ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_git
# The fixture MCP server (tests/fixtures/mcp_server.nim) is compiled by the
# test itself into the sandbox; t_mcp needs the mcp manager + bridge binaries.
test-mcp:     build var/bin/test_t_mcp     ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_mcp
test-edit:    build var/bin/test_t_edit    ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_edit
test-lsp:     build var/bin/test_t_lsp     ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_lsp
test-repomap: build var/bin/test_t_repomap_tags var/bin/test_t_repomap_score \
    var/bin/test_t_repomap ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_repomap_tags && env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_repomap_score && env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_repomap
test-processes: build var/bin/test_t_processes ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_processes
test-expert:  build var/bin/test_t_expert  ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_expert
test-parallel: build var/bin/test_t_parallel ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_parallel
test-smoke:   build var/bin/test_smoke     ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_smoke
test-autostart: build var/bin/test_t_autostart ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_autostart
test-fabric: build var/bin/test_t_fabric var/bin/test_t_fabric_frames var/bin/test_t_fabric_cancel ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_fabric_frames && env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" python3 tests/t_fabric_native.py && env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_fabric && env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_fabric_cancel
test-nested: build var/bin/test_t_nested var/bin/test_t_schema_validation ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_schema_validation && env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_nested
test-approval: build var/bin/test_t_approval_manifest ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_approval_manifest
test-controls: build var/bin/test_t_controls ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_controls
test-retry-unit: build var/bin/test_t_retry_unit ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_retry_unit
test-ctx-accounting: build var/bin/test_t_ctx_accounting ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_ctx_accounting
test-compaction: build var/bin/test_t_compaction ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_compaction
# §8.7 conformance runner: suite run proves the shipped component; point
# third-party implementations at it with
#   ./var/bin/test_t_compaction_conformance --bin:PATH --tool:NAME
test-conformance: build var/bin/test_t_compaction_conformance ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_t_compaction_conformance
# §8 live gate: real provider, real summarization, continuity + recall +
# latency measured end to end. Not in the CI suite — spends tokens:
#   SYNTHETIC_API_KEY=... make live-smoke
live-smoke: build var/bin/test_compaction_live_smoke ; $(TEST_LOCK) env "NIF_REPO_ROOT=$(ROOT)" "NIF_ROOT=$(ROOT)" ./var/bin/test_compaction_live_smoke

smoke: test-smoke  # legacy alias

# Go unit tests (models, provider, both llm adapters, sdk) — no shared runtime
# state, part of `make test`.
gotest:
	cd sdk/go && go test -race ./... && go vet ./...
	cd components/mcp && go test -race ./... && go vet ./...
	cd components/mcp-bridge && go test -race ./... && go vet ./...
	cd components/models && go test ./... && go vet ./...
	cd components/provider && go test ./... && go vet ./...
	cd components/llm && go test ./... && go vet ./...
	cd components/llm-openai && go test ./... && go vet ./...
	cd components/store-sqlite && go test ./... && go vet ./...
	cd components/store-tidb && go test ./... && go vet ./...
	cd components/nats && go test ./... && go vet ./...

# recover: back to factory shape. The repo is the snapshot; var/ is
# disposable build output. Core's --recover rebuilds binaries from source
# and wipes store component records (conversations survive).
recover: build
	@pkill -f "niffler-ui" 2>/dev/null; \
	 pkill -f "$(ROOT)/var/bin/niffler$$" 2>/dev/null; sleep 1; true
	./var/bin/niffler --recover

dev:
	@echo "the SPA dev server lives with the UI now:"
	@echo "  git clone https://github.com/gokr/niffler-ui && cd niffler-ui && make dev"
	@exit 1

clean:
	$(BUILD_LOCK) rm -rf var nimcache

# ---------------------------------------------------------------------------
# prerequisites

# Keep package-manager writes serial, including under make -j. Native headers
# and Clang must exist before Nimble builds Futhark and BitBarrel.
setup:
	@set -e; for target in install-native-deps install-nim install-nim-deps \
		install-go install-node install-wails install-ui-deps \
		install-natscli install-jq install-zenity; do \
		$(MAKE) --no-print-directory $$target; \
	done
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
	@bash scripts/check-nim-toolchain.sh || true
	$(call check_tool,nimble,install-nim)
	$(call check_tool,clang,install-native-deps)
		@if pkg-config --exists liblz4 libpcre 2>/dev/null; then \
		echo "  LZ4 + PCRE development libraries: OK"; \
	else echo "  LZ4/PCRE: MISSING — run 'make install-native-deps'"; fi
	@# Probe the LIBRARY, not just the clang binary: a machine can have clang on
	@# PATH and still fail to build futhark's opir (the observed CI failure), which
	@# reports 'clang: OK' above while `make install-nim-deps` dies.
	@if [ -n "$(IS_MAC)" ]; then \
		echo "  libclang (futhark's opir): from the Xcode command-line tools"; \
	else \
		ldir=$$(ls -d /usr/lib/llvm-*/lib 2>/dev/null | tail -1); \
		if ldconfig -p 2>/dev/null | grep -q libclang || \
		   { [ -n "$$ldir" ] && [ -e "$$ldir/libclang.so" ]; }; then \
			echo "  libclang (futhark, a transitive build dep): OK"; \
		else echo "  libclang: MISSING — run 'make install-native-deps' (futhark fails to build without it)"; fi; \
	fi
	@missing=""; for pkg in yaml htmlparser checksums natsnim bitbarrel; do \
		p=$$(nimble path $$pkg 2>/dev/null | tail -1); \
		[ -d "$$p" ] || missing="$$missing $$pkg"; \
	done; \
	if [ -z "$$missing" ]; then echo "  Nim packages: OK"; \
	else echo "  Nim packages MISSING:$$missing — run 'make install-nim-deps'"; fi
	$(call check_tool,go,install-go)
	@if [ -x var/bin/nats-server ] || command -v nats-server >/dev/null 2>&1; then \
		echo "  nats-server: OK"; \
	else \
		echo "  nats-server: built from source by 'make build' (components/nats)"; \
	fi
	@if node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' 2>/dev/null; then \
		echo "  node (20+): OK"; \
	else echo "  node: MISSING or too old — run 'make install-node'"; fi
	$(call check_tool,npm,install-node)
	@echo "Optional (bash-written dialog component):"
	$(call check_tool,jq,install-jq)
	@if command -v nats >/dev/null 2>&1 || [ -x "$(HOME)/go/bin/nats" ]; then \
		echo "  nats CLI: OK"; \
	else \
		echo "  nats CLI: MISSING — run 'make install-natscli'"; \
	fi
	@if command -v zenity >/dev/null 2>&1 || command -v notify-send >/dev/null 2>&1; then \
		echo "  dialog display (zenity/notify-send): OK"; \
	else \
		echo "  dialog display: MISSING — run 'make install-zenity'"; \
	fi
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
	@echo "                  npm registry access needed for TS source/package recipes"
	@echo "Then: make — and launch niffler-ui or ./var/bin/niffler"

install-go:
	@if command -v go >/dev/null 2>&1; then echo "go: already installed"; \
	elif [ -n "$(IS_MAC)" ]; then brew install go; \
	elif command -v snap >/dev/null 2>&1; then $(SUDO) snap install go --classic; \
	else echo "Install Go from https://go.dev/dl (or use your package manager)"; fi

install-lsp:
	@# Language servers behind the lsp component defaults (gopls, nimtortoise,
	@# typescript-language-server, pyright, rust-analyzer, clangd,
	@# bash-language-server, jdtls, csharp-ls). Go/Nim/TS mandatory, rest y/n;
	@# `make install-lsp ALL=1` installs everything unattended.
	@bash scripts/install-lsp.sh $(if $(filter 1,$(ALL)),--all,)

install-native-deps:
	@if [ -n "$(IS_MAC)" ]; then \
		xcode-select -p >/dev/null 2>&1 || { echo "Install Xcode command-line tools: xcode-select --install"; exit 1; }; \
		brew install pkg-config lz4 pcre; \
	else \
		$(SUDO) apt-get update && \
		$(SUDO) apt-get install -y build-essential curl ca-certificates git \
			pkg-config libssl-dev liblz4-dev libpcre3-dev libclang-dev; fi
	@# libclang-dev is a BUILD prerequisite, not an editor nicety: futhark (a
	@# transitive Nim dependency: bitbarrel -> lz4wrapper -> futhark) builds its
	@# `opir` generator with a link to libclang, and `make install-nim-deps`
	@# builds it. Without the dev package that step dies with
	@# 'Build failed for the package: futhark' before any test runs; on macOS
	@# libclang comes with the Xcode command-line tools checked above.

install-nim:
	@if ! command -v nim >/dev/null 2>&1; then \
		echo "Installing Nim via choosenim (~/.nimble/bin) ..."; \
		set -o pipefail; curl -sSf https://nim-lang.org/choosenim/init.sh | sh -s -- -y 2.2.12; \
	fi
	@bash scripts/check-nim-toolchain.sh

install-nim-deps:
	@bash scripts/check-nim-toolchain.sh
	@# Debian/Ubuntu ship libclang.so under /usr/lib/llvm-<N>/lib, which is not on
	@# the linker's default search path, and nimble builds futhark in its own
	@# directory (~/.nimble/buildtemp) where this repo's config.nims does not
	@# reach — so hand the directory to the linker for the duration of install.
	@libclangdir=$$(ls -d /usr/lib/llvm-*/lib 2>/dev/null | tail -1); \
	 if [ -n "$$libclangdir" ] && [ -e "$$libclangdir/libclang.so" ]; then \
		echo "nimble: exposing libclang at $$libclangdir (LIBRARY_PATH)"; \
		export LIBRARY_PATH="$$libclangdir$${LIBRARY_PATH:+:$$LIBRARY_PATH}"; \
	 fi; \
	 nimble install -y --depsOnly
	@# nimble can exit 0 even when a dependency's own install failed, and
	@# 'nimble path' also
	@# exits 0 for missing packages — verify each one actually landed.
	@for pkg in yaml htmlparser checksums natsnim bitbarrel; do \
		p=$$(nimble path $$pkg 2>/dev/null | tail -1); \
		if [ ! -d "$$p" ]; then \
			echo "nimble: package '$$pkg' did not install — rerun after 'make install-native-deps'"; \
			exit 1; \
		fi; \
	done

install-nats:
	@echo "nats-server: built from source by 'make build' (components/nats) — nothing to install"

# nats CLI + jq + zenity back the bash-written `dialog` component
# (components/dialog/dialog.sh — optional demo, not autostarted).
install-natscli:
	@if command -v nats >/dev/null 2>&1 || [ -x "$(HOME)/go/bin/nats" ]; then \
		echo "nats CLI: already installed"; \
	else echo "Installing natscli via go install ..."; \
		go install github.com/nats-io/natscli/nats@latest; fi

install-jq:
	@if command -v jq >/dev/null 2>&1; then echo "jq: already installed"; \
	elif [ -n "$(IS_MAC)" ]; then brew install jq; \
	else $(SUDO) apt-get install -y jq; fi

install-zenity:
	@if command -v zenity >/dev/null 2>&1; then echo "zenity: already installed"; \
	elif [ -n "$(IS_MAC)" ]; then echo "zenity: macOS — dialog falls back to notify-send/osascript"; \
	else $(SUDO) apt-get install -y zenity; fi

install-node:
	@if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then \
		if [ -n "$(IS_MAC)" ]; then brew install node; \
		elif command -v snap >/dev/null 2>&1; then $(SUDO) snap install node --classic --channel=22; \
		else echo "Install Node.js 20+ and npm from https://nodejs.org/ (or your version manager)"; exit 1; fi; \
	fi
	@node -e 'if (Number(process.versions.node.split(".")[0]) < 20) { console.error("Node.js 20+ required by the frontend dependencies; upgrade Node and check PATH."); process.exit(1); }'

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
		$(SUDO) apt-get install -y libwebkit2gtk-4.1-dev libgtk-3-dev; fi

# Ubuntu 24.04 apt ships Node 18; use a supported Node release for the UI.
