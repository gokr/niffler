# syntax=docker/dockerfile:1.7

# niffler-bench — base image for bench jobs (full17 / SWE-bench Verified /
# DeepSWE). Toolchains and harness CLIs only; the Niffler code under test is
# NOT baked in. bench/container/entrypoint.sh checks out NIFFLER_REF at job
# start, runs `make build` against a cached volume, and then execs the bench
# command from that same checkout — so bench code and Niffler version always
# match. Rebuild this image only when toolchains/harness versions change.
FROM node:22-bookworm

ARG DOCKER_VERSION=29.7.2
ARG GO_VERSION=1.26.2
ARG NIM_VERSION=2.2.10
ARG NATS_SERVER_VERSION=2.11.6
ARG SWEBENCH_VERSION=4.1.0
ARG UV_VERSION=0.9.8

# Base tools. python3.11 (bookworm) provides stdlib tomllib used by
# bench/deepswe/import.mjs. clang/libclang are needed by futhark (natswrapper's
# FFI generator) and its opir helper at Nimble-install time; libnats-dev /
# liblz4-dev / libssl-dev / libpcre3-dev to link the Nim binaries.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq ripgrep xz-utils python3 python3-venv \
    openssh-client procps tini \
    clang libclang-dev libnats-dev liblz4-dev libssl-dev libpcre3-dev \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (verification talks to the host daemon via the mounted socket).
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
    | tar -C /usr/local/bin --strip-components=1 -xzf - docker/docker

# Go toolchain (sdk/go + Go components need >= 1.24; nats/store need 1.26).
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
    | tar -C /usr/local -xzf - && ln -s /usr/local/go/bin/go /usr/local/bin/go

# Nim toolchain (niffler.nimble requires >= 2.2.10) — official prebuilt tarball.
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
    | tar -C /opt -xJf - && ln -s /opt/nim-${NIM_VERSION}/bin/nim /usr/local/bin/nim \
    && ln -s /opt/nim-${NIM_VERSION}/bin/nimble /usr/local/bin/nimble \
    && /opt/nim-${NIM_VERSION}/bin/nim --version > /dev/null

# nats-server (the bench's private Niffler harness spawns its own bus).
RUN curl -fsSL "https://github.com/nats-io/nats-server/releases/download/v${NATS_SERVER_VERSION}/nats-server-v${NATS_SERVER_VERSION}-linux-amd64.tar.gz" \
    | tar -C /tmp -xzf - && mv /tmp/nats-server-v${NATS_SERVER_VERSION}-linux-amd64/nats-server /usr/local/bin/nats-server

# uv + the pinned official SWE-bench harness venv (bench/swe verify path).
# NIF_SWEBENCH_PYTHON points verify.mjs at it; the venv is image-owned so a
# host-built .venv never leaks architecture/python mismatches into the job.
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-musl.tar.gz" \
    | tar -C /tmp -xzf - && mv /tmp/uv-x86_64-unknown-linux-musl/uv /usr/local/bin/uv \
    && uv venv /opt/swebench --python 3.11 \
    && uv pip install --python /opt/swebench/bin/python "swebench==${SWEBENCH_VERSION}"
ENV NIF_SWEBENCH_PYTHON=/opt/swebench/bin/python

# Harness CLIs for the comparison lanes (pi, opencode, codewhale).
RUN npm install -g --silent \
    @earendil-works/pi-coding-agent \
    opencode-ai \
    codewhale

# All mutable caches live under HOME=/cache (volume-backed): nimble pkgs,
# nim cache, go modules/build cache, git config, deepswe/swe hidden cards.
# ~/.nimble/bin (opir, nimble-installed binaries) must be on PATH for futhark.
ENV HOME=/cache
ENV PATH=/cache/.nimble/bin:${PATH}
RUN mkdir -p /cache /work && git config --system --add safe.directory '*' \
    && git config --global init.defaultBranch main

COPY entrypoint.sh /usr/local/bin/bench-entrypoint
RUN chmod 0755 /usr/local/bin/bench-entrypoint

WORKDIR /work/niffler
ENTRYPOINT ["/usr/local/bin/bench-entrypoint"]
CMD ["node", "bench/run.mjs", "--help"]
