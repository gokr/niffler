#!/usr/bin/env bash
# scripts/install-lsp.sh — install the language servers behind Niffler's lsp
# component defaults. Idempotent per language; failures are non-fatal (a
# missing server only means the lsp tool skips that language, with a clear
# E_LSP_UNAVAILABLE error).
#
# Three languages are mandatory — Niffler itself is built from them:
#   Go (gopls), Nim (nimtortoise, built from source), TS/JS
#   (typescript-language-server + a classic tsserver bridge — TS7 dropped
#   the classic server the language server bridges over).
# Every other language is a y/n prompt (empty answer = yes): Python
# (pyright), C/C++ (clangd), Bash (bash-language-server), Rust
# (rust-analyzer), Java (jdtls + a user-local JRE when none is present),
# PHP (intelephense), Ruby (solargraph), C# (csharp-ls).
#   --all    install every optional language unattended (CI)
#   no TTY   optional languages are skipped with a note
#
# The script never uses sudo and only writes under $HOME. Where a server
# needs a runtime we do not ship (JDK, .NET SDK, rustup), the failure names
# the exact command — runtimes are deliberately not auto-installed.
set -uo pipefail

BIN="${NIF_LSP_BIN-$HOME/.local/bin}"
SHARE="$HOME/.local/share/niffler-lsp"
mkdir -p "$BIN" "$SHARE"
ARCH=$(uname -m)
installed=0
ALL=0
[ "${1:-}" = "--all" ] && ALL=1

ok()   { echo "ok   $1"; installed=$((installed+1)); }
skip() { echo "skip $1 — $2"; }
fail() { echo "FAIL $1 — $2"; }

have() { command -v "$1" >/dev/null 2>&1 \
  || [ -x "$HOME/go/bin/$1" ] || [ -x "$BIN/$1" ] || [ -x "$HOME/.dotnet/tools/$1" ]; }

want() {
  # want <label> — y/n gate for the optional languages; default yes
  if [ "$ALL" = 1 ]; then return 0; fi
  if [ ! -t 0 ]; then
    skip "$1" "no tty (re-run with --all to install the optional languages)"
    return 1
  fi
  local a
  printf "install %s? [Y/n] " "$1"
  read -r a
  [ -z "$a" ] || [ "$a" = "y" ] || [ "$a" = "Y" ]
}

# ---- Go: gopls (mandatory) --------------------------------------------------
if have gopls; then ok "gopls"
elif have go;   then go install golang.org/x/tools/gopls@latest && ok "gopls" \
  || fail "gopls" "go install failed"; \
else fail "gopls" "no go toolchain (make install-go)"; fi

# ---- TS/JS: typescript-language-server + classic tsserver (mandatory) -------
if have typescript-language-server && have tsserver; then
  ok "typescript-language-server"
else
  if have npm; then
    npm install -g typescript-language-server >/dev/null 2>&1 \
      || fail "typescript-language-server" "npm install failed"
    # TS7 dropped the classic tsserver; the language server bridges over it,
    # so install a classic typescript@5 tree out of the way and symlink.
    if ! have tsserver; then
      mkdir -p "$HOME/.local/ts5"
      npm install --prefix "$HOME/.local/ts5" typescript@5 >/dev/null 2>&1 \
        && ln -sf "$HOME/.local/ts5/node_modules/.bin/tsserver" "$BIN/tsserver" \
        && ok "tsserver (classic TS5 bridge)" \
        || fail "tsserver" "npm install failed"
      # Pin the classic tsserver into the user registry: the language server
      # resolves typescript from the workspace, then tsserver.path, then the
      # global module — and a global TS7 (tsgo) install has a layout it
      # cannot load, so every plain workspace would fail initialize.
      if [ -x "$HOME/.local/ts5/node_modules/typescript/lib/tsserver.js" ]; then
        python3 - "${XDG_CONFIG_HOME-$HOME/.config}/niffler-lsp/servers.json" <<'PYEOF' 2>/dev/null \
          && ok "tsserver.path pinned in the user registry"
import json, os, sys
p = sys.argv[1]
os.makedirs(os.path.dirname(p), exist_ok=True)
try: doc = json.load(open(p))
except Exception: doc = {}
if not isinstance(doc, dict): doc = {}
ts5 = os.path.expanduser("~/.local/ts5/node_modules/typescript/lib/tsserver.js")
if not os.path.exists(ts5): sys.exit(1)
e = doc.get("typescript-language-server") or {}
if not isinstance(e, dict): e = {}
e.setdefault("command", ["typescript-language-server", "--stdio"])
e.setdefault("extensions", {".ts": "typescript", ".tsx": "typescriptreact",
  ".mts": "typescript", ".cts": "typescript", ".js": "javascript",
  ".jsx": "javascriptreact", ".mjs": "javascript", ".cjs": "javascript"})
e["initializationOptions"] = {"tsserver": {"path": ts5}}
doc["typescript-language-server"] = e
json.dump(doc, open(p, "w"), indent=2)
PYEOF
      fi
    else ok "tsserver"; fi
    have typescript-language-server && ok "typescript-language-server"
  else fail "typescript-language-server" "no npm"; fi
fi

# ---- Nim: nimtortoise (mandatory — Niffler is written in Nim) ---------------
if have nimtortoise; then ok "nimtortoise"
elif have nimble; then
  # not packaged on nimble yet: build from source (shallow clone, ~1 min)
  if [ ! -d "$SHARE/nimtortoise" ]; then
    git clone --quiet --depth 1 https://github.com/music-theories/nimtortoise \
      "$SHARE/nimtortoise" || fail "nimtortoise" "clone failed"
  fi
  if [ -d "$SHARE/nimtortoise/langserver" ] \
     && (cd "$SHARE/nimtortoise/langserver" && nimble build -y >/dev/null 2>&1) \
     && ln -sf "$SHARE/nimtortoise/langserver/bin/nimtortoise" "$BIN/nimtortoise"; then
    ok "nimtortoise (built from source)"
  else
    fail "nimtortoise" "build failed — falling back to nimlangserver"
    if nimble install nimlangserver -y >/dev/null 2>&1; then
      ok "nimlangserver (fallback — select via servers.json / lsp_registry)"
    else fail "nimlangserver" "nimble install failed"; fi
  fi
else fail "nimtortoise" "no nimble (make install-nim)"; fi

# ---- Python: pyright (optional) ---------------------------------------------
if want "Python (pyright)"; then
if have pyright; then ok "pyright"
elif have npm;   then npm install -g pyright >/dev/null 2>&1 && ok "pyright" \
  || fail "pyright" "npm install failed"; \
else skip "pyright" "no npm"; fi
fi

# ---- C/C++: clangd (optional) ------------------------------------------------
if want "C/C++ (clangd)"; then
if have clangd; then ok "clangd"
else
  tag=$(curl -s -m 30 "https://api.github.com/repos/clangd/clangd/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
  url="https://github.com/clangd/clangd/releases/download/$tag/clangd-linux-$tag.zip"
  if [ -n "$tag" ] && curl -sL -m 300 -o /tmp/clangd.zip "$url" \
     && python3 -c "import zipfile;zipfile.ZipFile('/tmp/clangd.zip').extractall('/tmp/clangd-x')" \
     && cp /tmp/clangd-x/clangd_*/bin/clangd "$BIN/clangd" \
     && mkdir -p "$HOME/.local/lib" \
     && cp -r /tmp/clangd-x/clangd_*/lib "$HOME/.local/" \
     && chmod +x "$BIN/clangd"; then
    ok "clangd (resource dir in ~/.local/lib/clang)"
  else fail "clangd" "release download failed (or sudo apt-get install clangd)"; fi
fi
fi

# ---- Shell: bash-language-server (optional) ----------------------------------
if want "Bash (bash-language-server)"; then
if have bash-language-server; then ok "bash-language-server"
elif have npm; then npm install -g bash-language-server >/dev/null 2>&1 \
  && ok "bash-language-server" || fail "bash-language-server" "npm install failed"; \
else skip "bash-language-server" "no npm"; fi
fi

# ---- Rust: rust-analyzer (optional) ------------------------------------------
if want "Rust (rust-analyzer)"; then
if have rust-analyzer; then ok "rust-analyzer"
else
  case "$ARCH" in x86_64) RA_ARCH="x86_64-unknown-linux-gnu";; aarch64) RA_ARCH="aarch64-unknown-linux-gnu";; *) RA_ARCH="";; esac
  if [ -z "$RA_ARCH" ]; then fail "rust-analyzer" "unsupported arch $ARCH"
  else
    url=$(curl -s -m 30 "https://api.github.com/repos/rust-lang/rust-analyzer/releases/latest" \
      | grep -o "https://[^\"]*rust-analyzer-$RA_ARCH\.gz" | head -1)
    if [ -n "$url" ] && curl -sL -m 300 -o /tmp/ra.gz "$url" \
       && gunzip -f /tmp/ra.gz && mv /tmp/ra "$BIN/rust-analyzer" \
       && chmod +x "$BIN/rust-analyzer"; then
      ok "rust-analyzer (standalone — full diagnostics need cargo: install rustup)"
    else fail "rust-analyzer" "release download failed"; fi
  fi
fi
fi

# ---- Java: JRE + jdtls (optional) --------------------------------------------
# The jdtls launcher is a python script that spawns `java`, so a present jdtls
# wrapper with no JRE on PATH is worse than no jdtls at all: it reported "ok"
# here (the java check only ran on the download path), every Java query then
# died with `FileNotFoundError: 'java'`, and because warmup pre-starts a
# workspace's most prevalent languages the dead server also held a warm slot.
# Version probe: parse only an actual `version "NN"` field. Grepping the
# first number out of `java -version` reads the *shell's* error line number
# ("line 206: java: command not found" → 206 >= 17) and reports a JRE that
# does not exist — which is how a jdtls with no runtime reported "ok".
java_major() {
  java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1
}

ensure_java() {
  local jver
  jver=$(java_major)
  if [ -n "$jver" ] && [ "$jver" -ge 17 ]; then return 0; fi
  case "$ARCH" in x86_64) A_ARCH=x64;; aarch64) A_ARCH=aarch64;; *) return 1;; esac
  # Adoptium serves a plain tar.gz, so this stays sudo-free and HOME-local
  # like every other server install here. ~/.local/bin is already on the
  # harness's PATH (it is where the other servers live).
  local url="https://api.adoptium.net/v3/binary/latest/21/ga/linux/$A_ARCH/jdk/hotspot/normal/eclipse"
  echo "installing a user-local JDK 21 (no sudo; ~/.local/share/niffler-lsp/jdk) ..."
  if curl -sL -m 900 -o /tmp/nif-jdk.tar.gz "$url" \
     && mkdir -p "$SHARE/jdk" \
     && tar -xzf /tmp/nif-jdk.tar.gz -C "$SHARE/jdk" --strip-components=1 \
     && ln -sf "$SHARE/jdk/bin/java" "$BIN/java" \
     && ln -sf "$SHARE/jdk/bin/javac" "$BIN/javac" \
     && java -version >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

if want "Java (jdtls)"; then
if ! ensure_java; then
  fail "Java runtime" "no JDK 17+ and the user-local install failed (sudo apt install openjdk-21-jdk-headless / brew install openjdk@21)"
elif have jdtls; then
  ok "jdtls (JRE $(java_major))"
elif ! command -v python3 >/dev/null 2>&1; then
  fail "jdtls" "the bundled launcher needs python3"
else
    # the milestones index is JS-rendered; snapshots/latest.txt is the
    # machine-readable pointer to the newest build
    jtar=$(curl -s -m 30 "https://download.eclipse.org/jdtls/snapshots/latest.txt")
    case "$jtar" in jdt-language-server-*.tar.gz) ;; *) jtar="";; esac
    if [ -n "$jtar" ] \
       && curl -sL -m 600 -o /tmp/jdtls.tgz "https://download.eclipse.org/jdtls/snapshots/$jtar" \
       && mkdir -p "$SHARE/jdtls" \
       && tar -xzf /tmp/jdtls.tgz -C "$SHARE/jdtls" \
       && chmod +x "$SHARE/jdtls/bin/jdtls" \
       && ln -sf "$SHARE/jdtls/bin/jdtls" "$BIN/jdtls"; then
      ok "jdtls (${jtar#jdt-language-server-} — launcher derives a per-workspace -data from cwd)"
    else fail "jdtls" "download/extract failed (https://download.eclipse.org/jdtls/snapshots/ or /milestones/)"; fi
fi
fi

# ---- PHP: intelephense (optional) ---------------------------------------------
# Node-based, so it needs no PHP runtime on the host.
if want "PHP (intelephense)"; then
if have intelephense; then ok "intelephense"
elif have npm; then npm install -g intelephense >/dev/null 2>&1 \
  && ok "intelephense" || fail "intelephense" "npm install failed"; \
else skip "intelephense" "no npm"; fi
fi

# ---- Ruby: solargraph (optional) -----------------------------------------------
# The server exists (solargraph) but needs a Ruby runtime we do not ship;
# when `gem` is missing the failure names the install, like the .NET path.
if want "Ruby (solargraph)"; then
if have solargraph; then ok "solargraph"
elif have gem; then
  if gem install --user-install solargraph >/dev/null 2>&1; then
    sgem="$(ruby -e 'print Gem.user_dir' 2>/dev/null)/bin/solargraph"
    [ -x "$sgem" ] && ln -sf "$sgem" "$BIN/solargraph"
    ok "solargraph"
  else fail "solargraph" "gem install failed"; fi
else fail "solargraph" "needs Ruby (sudo apt install ruby-full / rbenv install 3.3.6), then: gem install --user-install solargraph"; fi
fi

# ---- C#: csharp-ls (optional) --------------------------------------------------
if want "C# (csharp-ls)"; then
if have csharp-ls; then ok "csharp-ls"
elif have dotnet || [ -x "$HOME/.dotnet/dotnet" ]; then
  dotnet_bin=$(command -v dotnet || echo "$HOME/.dotnet/dotnet")
  # latest csharp-ls targets the newest .NET; an older SDK cannot even read its
  # package ("DotnetToolSettings.xml was not found"), so pin per SDK major:
  #   0.16.0 -> net8.0, 0.20.0 -> net9.0, unpinned -> net10.0
  sdk_major=$("$dotnet_bin" --version 2>/dev/null | cut -d. -f1)
  pin=""
  case "$sdk_major" in
    [0-8]) pin=0.16.0 ;;
    9)     pin=0.20.0 ;;
  esac
  err=$($dotnet_bin tool install --global csharp-ls ${pin:+--version "$pin"} 2>&1 >/dev/null)
  if [ $? -eq 0 ]; then
    ok "csharp-ls ${pin:+v$pin }(~/.dotnet/tools — covered by the lsp fallback dirs)"
  else
    fail "csharp-ls" "dotnet tool install failed: $(echo "$err" | tail -1)"
  fi
else
  fail "csharp-ls" "needs the .NET SDK 10+ (curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 — installs to ~/.dotnet; add ~/.dotnet/tools to PATH)"
fi
fi

echo "---"
echo "$installed language server(s) newly installed; total available:"
for s in gopls pyright typescript-language-server tsserver bash-language-server \
         rust-analyzer clangd nimtortoise nimlangserver jdtls csharp-ls \
         intelephense solargraph; do
  if have "$s"; then
    p=$(command -v "$s" || true)
    [ -z "$p" ] && for d in "$HOME/go/bin" "$HOME/.dotnet/tools" "$BIN"; do
      [ -x "$d/$s" ] && p="$d/$s" && break
    done
    echo "  $s: $p"
  fi
done
exit 0
