# niffler-bench container

Packages the bench (full27, SWE-bench Verified, DeepSWE) as a Docker job you
can run on any Docker host — laptop, wowbagger (Arcane), CI. Design goal:
**the base image is stable; the code under test is fetched per job.**

## Why build Niffler inside the container

Rebuilding the whole image on every Niffler change would redo toolchains,
swebench venv and harness CLIs (gigabytes, minutes) for a ~2–4 minute Nim/Go
build. Instead:

- The image holds **only stable layers**: Node 22, git, docker CLI, Go 1.26,
  Nim 2.2.10, nats-server, uv + pinned `swebench==4.1.0` venv, and the
  comparison harness CLIs (pi, opencode, codewhale).
- At job start the entrypoint checks out `NIFFLER_REF` (tag, branch, or SHA —
  default `main`) and runs `make build` against a **cached volume**
  (`/cache`): per-commit builds are reused (`/cache/builds/<sha>/var`),
  nimble/go/nim caches persist in `/cache/home`.
- `bench/` lives in the Niffler repo, so bench code (adapters, config,
  importers) is **always in lockstep** with the harness version being
  measured — cloning at a tag reproduces exactly what that tag's bench
  expected.

Rebuild the base image only when toolchains/harness versions change (the
ARG pins in the Dockerfile). Provenance: the entrypoint logs
`niffler ref=<ref> sha=<sha>` and writes `.niffler-built-sha` into the
checkout; encode the ref in your `--run-id`.

## Inputs

| Variable | Default | Meaning |
|---|---|---|
| `NIFFLER_REF` | `main` | git ref to build (tag / branch / SHA) |
| `NIFFLER_REPO_URL` | `https://github.com/gokr/niffler.git` | clone URL |
| `GITHUB_TOKEN` | — | optional, for private-repo HTTPS clones |
| `NIFFLER_SRC` | — | build from a mounted checkout instead (dev loop) |

Keys come from the environment or the repo's gitignored `.env`
(`DEEPSEEK_API_KEY` falls back to `NIF_OPENAI_API_KEY`, as on the host).
`NIF_AUTO_APPROVE=1` is set because gated tools must not deny with no human
reachable in a headless job — same as the bench's private Niffler harnesses.

## Volumes / mounts

- `/var/run/docker.sock` — verification (SWE + DeepSWE) drives the **host**
  docker daemon; images and verifier containers live on the host.
- `bench-cache:/cache` — toolchain caches + per-commit build stamps.
- `/data/results`, `/data/deepswe`, `/data/swe` — neutral paths the
  entrypoint symlinks into the checkout at `var/bench/*` (volumes cannot
  mount into a directory git creates later). Map them to the host checkout's
  `var/bench/*` so results and task roots survive jobs and stay visible to
  host-side `bench/report.mjs`.

## Usage (laptop)

```bash
docker build -t niffler-bench:latest bench/container
NIFFLER_REF=main docker compose -f bench/container/compose.yaml run --rm bench \
  node bench/run.mjs --task-root var/bench/deepswe/tasks-pilot --task all \
    --harness niffler,pi,opencode --model deepseek-v4-flash --rounds 1 --jobs 2 \
    --turn-timeout-min 185 --task-timeout-min 200 --test-timeout-sec 2000 \
    --run-id deepswe-pilot-$(git rev-parse --short HEAD)
node bench/report.mjs --run deepswe-pilot-<sha>   # host-side reporting
```

## Usage (wowbagger / Arcane)

wowbagger: Netcup vServer, Ubuntu 24.04, ~500 GB disk, **15 GB RAM**,
Docker 29.7, Arcane 2.6 + arcane-cli (see `../wowbagger/AGENTS.md`). RAM is
the constraint: verifier containers allow up to 8 GB, so run one verifier at
a time (`--jobs 2` is fine — verify steps serialize behind agent lanes) and
pull DeepSWE images per wave with pruning.

One-time:

```bash
ssh gokr@wowbagger.krampe.se
git clone https://github.com/gokr/niffler.git && cd niffler   # compose + docs only
cp <local> .env                                                # keys, gitignored
docker build -t niffler-bench:latest bench/container
```

Trigger a job (from the laptop):

```bash
ssh wowbagger 'cd ~/niffler && NIFFLER_REF=<tag-or-sha> \
  docker compose -f bench/container/compose.yaml run --rm bench \
  node bench/run.mjs --task-root var/bench/deepswe/tasks-pilot --task all \
    --harness niffler --model deepseek-v4-flash --rounds 1 --jobs 2 \
    --turn-timeout-min 185 --task-timeout-min 200 --test-timeout-sec 2000 \
    --run-id deepswe-<tag>'
```

Optional Arcane integration: register `niffler` as an Arcane project
(GitOps from the repo) for image lifecycle/visibility in the UI, but keep job
runs as `compose run` one-shots — Arcane projects model long-running
services, not batch jobs. An MCP to drive runs conversationally can later be
either a small tool in chetter (already an MCP server with runner containers
on that host) or a thin stdio MCP wrapper that shells the same
`compose run` command; not built yet.

## Build pipeline (verified end-to-end)

Smoke-tested from a clean cache volume, all three modes:

1. **Mounted checkout** (`NIFFLER_SRC=/src/niffler:ro`) — tar-copies the tree
   (minus `var/`), installs deps, builds, stamps — then a second run hits the
   per-SHA cache instantly.
2. **GitHub clone** (`NIFFLER_REF=main`) — clones, builds upstream main, runs
   the bench entry (`tasks-nonexistent` probe ENOENT = reached run.mjs).

What the build step has to handle (all automated in `entrypoint.sh`):

- `opir` (futhark's libclang header parser, used by natswrapper at compile
  time) is installed via nimble and put on `PATH` (`$HOME/.nimble/bin`).
- System libs for linking: `libnats-dev`, `liblz4-dev` (futhark/lz4wrapper),
  `libssl-dev` (std/httpclient), `libpcre3-dev` (link line of recent mains —
  **hosts building upstream main need this too**; `make setup` installs it).
- `config.nims`' pkgs2 fallback allowlist can lag transitive nimble deps
  (futhark → macroutils, bitbarrel → jwt/mummy/whisky/…), so the entrypoint
  synthesizes the `nimble.paths` file nimble would generate, covering every
  installed package, plus a bounded self-healing retry for stragglers.

## Build pipeline (verified end-to-end)

Smoke-tested from a clean `/cache` volume in all three source modes:
mounted checkout (build + per-SHA cache hit), and `NIFFLER_REF=main` GitHub
clone (build of upstream main + bench entry). The build step handles:

- `opir` — futhark's libclang header parser (natswrapper dependency chain);
  nimble-installed, `$HOME/.nimble/bin` on `PATH`.
- System libs to link Nim binaries: `libnats-dev`, `liblz4-dev`
  (futhark/lz4wrapper), `libssl-dev`, `libpcre3-dev` (recent mains link
  pcre — **hosts building upstream main need it too**; `make setup` covers
  this).
- `nimble.paths` — synthesized from the installed pkgs2 set; `config.nims`'
  fallback allowlist can lag transitive deps (futhark → macroutils,
  bitbarrel → jwt/mummy/whisky).
- A bounded self-heal loop: if `make build` still hits an unresolvable
  module, nimble-installs it and retries (visible in the log).

## Caveats

- Private repo clones need `GITHUB_TOKEN` (or use `NIFFLER_SRC` with a
  mounted checkout / an ssh agent — ssh is available in the image).
- The container is x86_64 (Nim/Go tarballs pinned); wowbagger is amd64.
- `NIFFLER_SRC` builds record the dirty state as-is — prefer git refs for
  reported runs.
