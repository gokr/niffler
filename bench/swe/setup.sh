#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
venv="$root/var/bench/swe/.venv"

command -v uv >/dev/null || {
  echo "error: uv is required (https://docs.astral.sh/uv/)" >&2
  exit 1
}
command -v docker >/dev/null || {
  echo "error: docker is required" >&2
  exit 1
}
docker info >/dev/null || {
  echo "error: docker daemon is not reachable" >&2
  exit 1
}

if [[ ! -x "$venv/bin/python" ]]; then
  uv venv --python 3.12 "$venv"
fi
uv pip install --python "$venv/bin/python" -r "$root/bench/swe/requirements.txt"
"$venv/bin/python" - <<'PY'
import swebench
from importlib.metadata import version
print(f"SWE-bench harness {version('swebench')} ready")
PY
