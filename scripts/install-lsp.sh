#!/usr/bin/env bash
# scripts/install-lsp.sh — install the language servers behind Niffler's lsp
# component defaults. Idempotent per language; failures are non-fatal (a
# missing server only means the lsp tool skips that language, with a clear
# E_LSP_UNAVAILABLE error). Covers the "major languages we know":
#   Go (gopls), Python (pyright), TS/JS (typescript-language-server +
#   classic tsserver), Rust (rust-analyzer), C/C++ (clangd),
#   Nim (nimlangserver).
set -uo pipefail

BIN="${NIF_LSP_BIN-$HOME/.local/bin}"
mkdir -p "$BIN"
ARCH=$(uname -m)
installed=0
ok()   { echo "ok   $1"; installed=$((installed+1)); }
skip() { echo "skip $1 — $2"; }
fail() { echo "FAIL $1 — $2"; }

have() { command -v "$1" >/dev/null 2>&1 \
  || [ -x "$HOME/go/bin/$1" ] || [ -x "$BIN/$1" ]; }

# ---- Go: gopls -------------------------------------------------------------
if have gopls; then ok "gopls"
elif have go;   then go install golang.org/x/tools/gopls@latest && ok "gopls" \
  || fail "gopls" "go install failed"; \
else skip "gopls" "no go toolchain (make install-go)"; fi

# ---- Python: pyright -------------------------------------------------------
if have pyright; then ok "pyright"
elif have npm;   then npm install -g pyright >/dev/null 2>&1 && ok "pyright" \
  || fail "pyright" "npm install failed"; \
else skip "pyright" "no npm"; fi

# ---- TS/JS: typescript-language-server + classic tsserver ------------------
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
    else ok "tsserver"; fi
    have typescript-language-server && ok "typescript-language-server"
  else skip "typescript-language-server" "no npm"; fi
fi

# ---- Shell: bash-language-server -------------------------------------------
if have bash-language-server; then ok "bash-language-server"
elif have npm; then npm install -g bash-language-server >/dev/null 2>&1 \
  && ok "bash-language-server" || fail "bash-language-server" "npm install failed"; \
else skip "bash-language-server" "no npm"; fi

# ---- Rust: rust-analyzer ---------------------------------------------------
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
      ok "rust-analyzer (standalone — install rustup for full diagnostics)"
    else fail "rust-analyzer" "release download failed"; fi
  fi
fi

# ---- C/C++: clangd ----------------------------------------------------------
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

# ---- Nim: nimlangserver -----------------------------------------------------
if have nimlangserver; then ok "nimlangserver"
elif have nimble; then nimble install nimlangserver -y >/dev/null 2>&1 \
  && ok "nimlangserver" || fail "nimlangserver" "nimble install failed"; \
else skip "nimlangserver" "no nimble (make install-nim)"; fi

echo "---"
echo "$installed language server(s) newly installed; total available:"
for s in gopls pyright typescript-language-server tsserver bash-language-server rust-analyzer clangd nimlangserver; do
  if have "$s"; then
    p=$(command -v "$s" || true)
    [ -z "$p" ] && for d in "$HOME/go/bin" "$BIN"; do
      [ -x "$d/$s" ] && p="$d/$s" && break
    done
    echo "  $s: $p"
  fi
done
exit 0
