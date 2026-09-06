#!/usr/bin/env bash
# bench/container/entrypoint.sh — resolve Niffler at NIFFLER_REF, build it
# against a persistent cache volume, then exec the bench command from that
# checkout. This is what makes the container "dynamic": the base image holds
# only toolchains, and the code under test (repo + bench/ together) is fetched
# per job.
#
#   NIFFLER_REF      git ref to build (tag, branch, SHA; default "main")
#   NIFFLER_REPO_URL clone URL (default https://github.com/gokr/niffler.git)
#   GITHUB_TOKEN     optional; injected for private-repo HTTPS clones
#   NIFFLER_SRC      optional; build from this mounted checkout instead of git
#                    (local dev loop; provenance = the checkout's dirty state)
#
# Provenance: the entrypoint prints and stores the resolved commit SHA; encode
# the ref in --run-id when launching runs.
set -euo pipefail

REF="${NIFFLER_REF:-main}"
REPO_URL="${NIFFLER_REPO_URL:-https://github.com/gokr/niffler.git}"
WORK="${NIFFLER_WORK:-/work/niffler}"
CACHE="${NIFFLER_CACHE:-/cache}"
STAMPS="$CACHE/builds"

log() { echo "[niffler-bench] $*"; }

clone_url() {
  # Inject a token for private-repo HTTPS clones (github.com only).
  if [ -n "${GITHUB_TOKEN:-}" ] && [[ "$REPO_URL" == https://github.com/* ]]; then
    echo "${REPO_URL/https:\/\/github.com\//https://x-access-token:${GITHUB_TOKEN}@github.com/}"
  else
    echo "$REPO_URL"
  fi
}

# ---------------------------------------------------------------------------
# 1. Get the source.
# ---------------------------------------------------------------------------
# The image WORKDIR is $WORK; leave it before any rm -rf so git/tar children
# never start from a deleted working directory.
cd /tmp
if [ -n "${NIFFLER_SRC:-}" ]; then
  log "using mounted checkout at $NIFFLER_SRC (var/ excluded — clean build)"
  mkdir -p "$(dirname "$WORK")"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  # Exclude var/ so the job builds the checkout from source; the per-SHA
  # stamp cache below keeps repeat runs of the same commit fast.
  (cd "$NIFFLER_SRC" && tar -cf - --exclude=./var .) | (cd "$WORK" && tar -xf -)
else
  if [ -d "$WORK/.git" ]; then
    git -C "$WORK" fetch --prune origin \
      "+refs/heads/*:refs/remotes/origin/*" "+refs/tags/*:refs/tags/*"
  else
    rm -rf "$WORK"
    git clone "$(clone_url)" "$WORK"
  fi
  git -C "$WORK" checkout -q --detach "$REF" 2>/dev/null ||
    git -C "$WORK" checkout -q --detach "origin/$REF"
fi

SHA=$(git -C "$WORK" rev-parse HEAD)
DIRTY=$(git -C "$WORK" status --porcelain | head -c 1)
log "niffler ref=$REF sha=$SHA${DIRTY:+ (dirty worktree)}"

# ---------------------------------------------------------------------------
# 2. Build (or reuse a cached build of this exact commit).
# ---------------------------------------------------------------------------
mkdir -p "$STAMPS/$SHA"
if [ -x "$STAMPS/$SHA/var/bin/niffler" ]; then
  log "cache hit for $SHA — reusing var/bin"
  rm -rf "$WORK/var/bin"
  cp -a "$STAMPS/$SHA/var/bin" "$WORK/var/bin"
else
  log "building niffler at $SHA (nimble deps + make build; caches under $CACHE/home)…"
  # opir = futhark's libclang header parser (futhark is a natswrapper dep and
  # invokes it at compile time); must be on PATH ($HOME/.nimble/bin is).
  nimble install -y opir >/dev/null 2>&1 || log "warning: opir install failed"
  # Direct deps from niffler.nimble (config.nims resolves them from
  # $HOME/.nimble/pkgs2). htmlparser is stdlib-only; tolerate per-dep failures.
  (cd "$WORK" && sed -n 's/^requires "\(.*\)"$/\1/p' niffler.nimble \
      | grep -v '^nim' | while IFS= read -r dep; do \
          nimble install -y "$dep" >/dev/null 2>&1 || echo "[niffler-bench] nimble dep '$dep' unavailable (ok if stdlib)"; \
        done)
  # config.nims' pkgs2 fallback allowlist can lag transitive deps (futhark ->
  # macroutils, bitbarrel -> jwt/mummy/whisky/...). Synthesize the nimble.paths
  # file nimble would generate, covering every installed package.
  {
    echo '--noNimblePath'
    echo "--path:\"$WORK\""
    for d in "$HOME"/.nimble/pkgs2/*/; do echo "--path:\"$d\""; done
  } > "$WORK/nimble.paths"
  # Last-resort self-healing: if make still hits an unresolvable module,
  # install it and retry (bounded).
  ok=0
  for attempt in 1 2 3; do
    if out=$(cd "$WORK" && make build 2>&1); then ok=1; break; fi
    dep=$(printf '%s\n' "$out" | grep -om1 'cannot open file: [a-zA-Z0-9_./-]*' | sed 's/cannot open file: //' || true)
    if [ -z "$dep" ]; then
      printf '%s\n' "$out" | tail -25
      log "make build failed (see above)"
      exit 1
    fi
    log "installing missing nimble dep '$dep' (attempt $attempt)"
    (cd "$WORK" && nimble install -y "$dep" >/dev/null) || { printf '%s\n' "$out" | tail -25; exit 1; }
  done
  if [ "$ok" != 1 ]; then log "make build still failing after dep fixups"; exit 1; fi
  log "make build ok"
  rm -rf "$STAMPS/$SHA/var"
  cp -a "$WORK/var" "$STAMPS/$SHA/var"
  log "cached build under $STAMPS/$SHA"
fi
printf '%s\n' "$SHA" > "$WORK/.niffler-built-sha"

# ---------------------------------------------------------------------------
# 3. Wire neutral /data mounts into the checkout (volumes cannot mount into a
#    directory the entrypoint creates later, so we symlink).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/var/bench"
for pair in results:/data/results deepswe:/data/deepswe swe:/data/swe; do
  name="${pair%%:*}"; target="${pair#*:}"
  if [ -d "$target" ]; then
    rm -rf "$WORK/var/bench/$name"   # never let a copied dir shadow the mount
    ln -sfn "$target" "$WORK/var/bench/$name"
  fi
done

cd "$WORK"
exec "$@"
