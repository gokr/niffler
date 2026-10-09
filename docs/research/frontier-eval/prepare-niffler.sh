#!/usr/bin/env bash
# Preparation only: no model calls, no formal benchmark task execution.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$HOME/.nimble/bin:/usr/local/go/bin:$PATH"
apt-get update -qq
apt-get install -y -qq build-essential curl ca-certificates git pkg-config libssl-dev jq python3-venv util-linux >/dev/null
mkdir -p /work/evidence
if ! command -v go >/dev/null; then
  curl -fsSL https://go.dev/VERSION?m=text -o /work/go-version.txt
  read -r gv < /work/go-version.txt
  curl -fsSL "https://go.dev/dl/${gv}.linux-amd64.tar.gz" -o /work/go.tar.gz
  tar -C /usr/local -xzf /work/go.tar.gz
  rm /work/go.tar.gz
fi
if ! command -v nim >/dev/null; then
  curl -fsSL https://nim-lang.org/choosenim/init.sh -o /work/choosenim.sh
  sh /work/choosenim.sh -y 2.2.12
fi
command -v uv >/dev/null || { curl -fsSL https://astral.sh/uv/install.sh -o /work/uv-install.sh; sh /work/uv-install.sh; }
git clone https://github.com/gokr/niffler /work/harness
cd /work/harness
git checkout efa9836
make install-nim-deps
make build
uv tool install 'harbor==0.22.0'
uv tool install 'datacurve-pier==0.3.1'
git clone https://github.com/datacurve-ai/deep-swe /work/deep-swe
git -C /work/deep-swe checkout 435ee89ec2f2e2289f33b0da4f992f0b7b7266b9
printf 'Preparation complete; adapters and budget guard still required.\n'
