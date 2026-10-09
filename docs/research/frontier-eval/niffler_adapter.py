"""FrontierHarness container adapter for pinned Niffler 0.4.0.

Preparation artifact only. No trial may run without a funded request-level
budget proxy at FH_MODEL_PROXY_URL. Keep raw NDJSON and transcript evidence.
"""
import json
import os
import shlex
from pathlib import Path
from usage_mapping import extract_usage

try:
    from harbor.agents.base import BaseAgent as HarborBase
except ImportError:
    class HarborBase:  # import-path checks outside Harbor
        pass
try:
    from pier.agents.base import BaseAgent as PierBase
    from pier.models.agent.network import NetworkAllowlist
except ImportError:
    class PierBase:  # import-path checks outside Pier
        pass
    NetworkAllowlist = None

BUNDLE = Path("/work/niffler040.tar.gz")
REMOTE_ROOT = "/opt/niffler040"


class NifflerMixin:
    logs_dir: Path

    @staticmethod
    def name():
        return "niffler"

    def version(self):
        return "0.4.0"

    async def setup(self, environment):
        if not BUNDLE.is_file():
            raise RuntimeError("Pinned Niffler bundle has not been prepared")
        await environment.upload_file(BUNDLE, "/niffler040.tar.gz")
        result = await environment.exec(
            command="mkdir -p /opt/niffler040 && tar -xzf /niffler040.tar.gz -C /opt/niffler040 && rm /niffler040.tar.gz",
            user="root", timeout_sec=120,
        )
        if result.return_code:
            raise RuntimeError("Niffler bundle extraction failed: " + str(result.stderr))
        # The immutable source/binaries are shared within this task only;
        # /opt/niffler040/var is a fresh mutable store after every restore.
        result = await environment.exec(
            command="chmod -R a+rX /opt/niffler040 && chmod a+rwx /opt/niffler040/var && mkdir -p /logs/agent",
            user="root", timeout_sec=30,
        )
        if result.return_code:
            raise RuntimeError("Niffler task permissions failed")

    async def run(self, instruction, environment, context):
        endpoint = os.environ.get("FH_MODEL_PROXY_URL", "")
        if not endpoint:
            raise RuntimeError("Budget guard missing: set FH_MODEL_PROXY_URL before model execution")
        env = {
            "NIF_ROOT": REMOTE_ROOT,
            "NIF_NATS_SPAWN": "1",
            "NIF_AUTO_APPROVE": "1",
            "NIF_OPENAI_BASE_URL": endpoint,
            "NIF_OPENAI_API_KEY": "runta-secret-stub",
            "NIF_OPENAI_MODEL": "accounts/fireworks/models/kimi-k3",
        }
        command = (
            f"{REMOTE_ROOT}/var/bin/cli run {shlex.quote(instruction)} "
            f"--root {REMOTE_ROOT} --cwd \"$PWD\" "
            "--thinking high --approvals auto "
            "--export=/logs/agent/niffler-transcript.json "
            "> /logs/agent/niffler.ndjson 2> /logs/agent/niffler.stderr"
        )
        result = await environment.exec(command=command, env=env, timeout_sec=1200)
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        for filename in ("niffler.ndjson", "niffler.stderr", "niffler-transcript.json"):
            try:
                await environment.download_file(f"/logs/agent/{filename}", self.logs_dir / filename)
            except Exception:
                if filename == "niffler.ndjson":
                    raise
        frames = []
        for line in (self.logs_dir / "niffler.ndjson").read_text().splitlines():
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        raw_lines = (self.logs_dir / "niffler.ndjson").read_text().splitlines()
        try:
            values = extract_usage(raw_lines)
        except ValueError as exc:
            # No single authoritative result: the harness never proved a turn.
            raise RuntimeError(f"Niffler produced no authoritative result: {exc}; raw evidence retained")
        if not values['metadata'].get('provider_responses'):
            # FrontierHarness validity: with zero provider responses nothing
            # executed — that is infra_invalid, never a task failure.
            raise RuntimeError(f"no provider response (unproven execution): {values['metadata'].get('turn_error')}; raw evidence retained")
        for key in ("n_input_tokens", "n_cache_tokens", "n_output_tokens"):
            setattr(context, key, values[key])
        context.metadata = dict(values['metadata'], harness_version="0.4.0",
                                exit_code=result.return_code, frames=len(frames),
                                usage_mapping_validated=True)
        # A completed turn with an error outcome is a VALID failed run: let the
        # verifier score it. Only unproven execution (above) is an exception.


class HarborNiffler(NifflerMixin, HarborBase):
    pass


class PierNiffler(NifflerMixin, PierBase):
    def network_allowlist(self):
        # Populated after the guard endpoint/network topology is finalized.
        return NetworkAllowlist()
