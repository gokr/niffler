"""Provisioning contract: fake transports only; never creates VMs/services."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fleet", REPO / "scripts/fleet.py")
assert spec is not None and spec.loader is not None
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)


class FleetTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(dir=REPO / "var")
        self.addCleanup(self.sandbox.cleanup)
        self.path = Path(self.sandbox.name) / "profile.json"
        self.identity = {"instanceId": "a" * 32, "name": "worker", "root": "/home/ubuntu/niffler", "gitHash": "123"}
        self.calls = []
        self.vm = None

    def fakeRun(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if argv[:2] == ["multipass", "list"]:
            return json.dumps({"list": [] if self.vm is None else [self.vm]})
        if "call catalog" in kwargs.get("payload", ""):
            return json.dumps(self.identity)
        return ""

    def install(self, *extra, transport="--multipass", target="worker"):
        args = ["fleet.py", "install", "--profile", str(self.path), transport + "=" + target,
                "--root", self.identity["root"], "--revision", "b" * 40, *extra]
        with patch("sys.argv", args), patch.object(fleet, "run", self.fakeRun), patch.object(fleet, "confirm"):
            fleet.main()

    def test_create_verify_private_receipt(self):
        self.install("--cpus", "3", "--memory", "6G", "--disk", "30G")
        launch = next(argv for argv, _ in self.calls if argv[:2] == ["multipass", "launch"])
        self.assertEqual(launch, ["multipass", "launch", "24.04", "--name", "worker", "--cpus", "3", "--memory", "6G", "--disk", "30G"])
        profile = fleet.load(self.path)
        self.assertTrue(profile["createdVm"])
        self.assertEqual(profile["expect"], self.identity)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(any("mount" in argv or "delete" in argv for argv, _ in self.calls))
        scripts = [kw.get("payload", "") for _, kw in self.calls]
        self.assertTrue(any("bootstrap.sh\" --server" in script for script in scripts))
        self.assertTrue(any("git fetch" not in script and "fetch origin" in script for script in scripts))
        self.assertTrue(any("Adopting existing installation without updating" in script for script in scripts))

    def test_adopt_has_no_destruction_authority(self):
        self.vm = {"name": "worker", "state": "Running"}
        self.install()
        self.assertNotIn("createdVm", fleet.load(self.path))
        self.assertFalse(any(argv[:2] == ["multipass", "launch"] for argv, _ in self.calls))

    def test_stopped_vm_starts_separately(self):
        self.vm = {"name": "worker", "state": "Stopped"}
        self.install()
        self.assertTrue(any(argv == ["multipass", "start", "worker"] for argv, _ in self.calls))

    def test_ssh_preserves_security_defaults(self):
        self.install(transport="--ssh", target="ubuntu@worker")
        commands = [argv for argv, _ in self.calls if argv[0] == "ssh"]
        self.assertTrue(commands)
        for argv in commands:
            self.assertIn("ForwardAgent=no", argv)
            self.assertIn("BatchMode=yes", argv)
            self.assertNotIn("StrictHostKeyChecking=no", argv)
            self.assertNotIn("-A", argv)
        self.assertFalse(any(argv[0] == "multipass" for argv, _ in self.calls))

    def test_drift_refuses_before_remote_writes(self):
        self.install()
        original = self.path.read_bytes()
        self.calls.clear()
        self.vm = {"name": "worker", "state": "Running"}
        self.identity["instanceId"] = "c" * 32
        with self.assertRaisesRegex(fleet.Refusal, "identity mismatch"):
            self.install()
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(any("bootstrap.sh" in kw.get("payload", "") for _, kw in self.calls))

    def test_denial_no_mutations(self):
        args = ["fleet.py", "install", "--profile", str(self.path), "--ssh", "worker", "--root", self.identity["root"], "--revision", "b" * 40]
        with patch("sys.argv", args), patch.object(fleet, "run", self.fakeRun), patch.object(fleet, "confirm", side_effect=fleet.Refusal("denied")):
            with self.assertRaises(fleet.Refusal):
                fleet.main()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.path.exists())

    def test_probe_failure_no_receipt(self):
        self.identity["root"] = "/wrong"
        with self.assertRaisesRegex(fleet.Refusal, "root mismatch"):
            # Keep requested root distinct from returned identity.
            with patch.object(fleet, "probe", side_effect=fleet.Refusal("root mismatch")):
                self.install()
        self.assertFalse(self.path.exists())

    def test_missing_pinned_vm_not_recreated(self):
        self.install()
        self.calls.clear()
        with self.assertRaisesRegex(fleet.Refusal, "refusing to recreate"):
            self.install()
        self.assertFalse(any(argv[:2] == ["multipass", "launch"] for argv, _ in self.calls))

    def test_generated_shell_syntax_and_unrelated_root_refusal(self):
        root = self.path.parent / "unrelated"
        root.mkdir()
        marker = root / "keep"
        marker.write_text("untouched")
        script = fleet.install_script(str(root), "b" * 40)
        syntax = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + script], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing overwrite", result.stderr)
        self.assertEqual(marker.read_text(), "untouched")

    def test_command_timeout_is_failure(self):
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired("ssh", 60)):
            with self.assertRaises(fleet.Refusal):
                fleet.run(["ssh", "worker"])

    def test_invalid_target_and_revision(self):
        with self.assertRaises(fleet.Refusal):
            self.install(target="-oProxyCommand=bad")
        with self.assertRaises(fleet.Refusal):
            self.install("--revision", "main")
        self.assertEqual(self.calls, [])

    def test_existing_profile_cannot_change_target(self):
        self.install()
        self.calls.clear()
        with self.assertRaises(fleet.Refusal):
            self.install(target="other")
        self.assertEqual(self.calls, [])

    def test_symlink_profile_refuses(self):
        target = self.path.parent / "other"
        target.write_text("{}")
        self.path.symlink_to(target)
        with self.assertRaises(fleet.Refusal):
            self.install()
        self.assertEqual(target.read_text(), "{}")

    def test_server_setup_omits_optional_node(self):
        result = subprocess.run(["make", "-n", "setup", "NIF_SERVER=1"], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("install-node; do", result.stdout)
        self.assertIn("install-go ; do", result.stdout)

    def test_wrapper_remote_selection_never_boots_local_core(self):
        root = self.path.parent
        binaries = root / "var" / "bin"
        binaries.mkdir(parents=True)
        for name, body in {"tui": "exit 7", "cli": "echo forbidden-cli; exit 1", "niffler": "echo forbidden-core; exit 1"}.items():
            executable = binaries / name
            executable.write_text("#!/bin/sh\n" + body + "\n")
            executable.chmod(0o700)
        wrapper = REPO / "scripts" / "niffler-tui.in"
        env = dict(os.environ, NIF_ROOT=str(root))
        for option in ("--instance=worker", "--instance-probe=worker", "--instance-import=receipt"):
            result = subprocess.run(["bash", str(wrapper), option], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertNotIn("forbidden", result.stdout + result.stderr)

    def test_no_tty_no_automatic_consent(self):
        with patch("builtins.open", side_effect=OSError), patch.dict(os.environ, {"NIF_AUTO_APPROVE": "1", "NIF_ASSUME_YES": "1"}):
            with self.assertRaises(fleet.Refusal):
                fleet.confirm("plan")


if __name__ == "__main__":
    unittest.main()
