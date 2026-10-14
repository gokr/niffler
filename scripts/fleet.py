#!/usr/bin/env python3
"""Client-local provisioning; no harness required, no credentials inherited.

Profiles are verified provisioning receipts, not yet a TUI connection registry.
SSH uses ordinary config/known_hosts; Multipass uses exec, never host mounts.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time


class Refusal(Exception):
    pass


def run(argv, *, payload=None, capture=True, timeout=60):
    try:
        result = subprocess.run(argv, input=payload, text=True,
                                stdout=subprocess.PIPE if capture else None,
                                check=True, timeout=timeout)
        return result.stdout if capture else ""
    except (subprocess.SubprocessError, OSError) as error:
        raise Refusal(f"command failed ({argv[0]}): {error}") from error


def remote(profile, script, *, capture=True, timeout=60):
    if profile["transport"] == "ssh":
        argv = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ForwardAgent=no",
                "-o", "ConnectTimeout=15", "--", profile["target"], "bash -s"]
    else:
        argv = ["multipass", "exec", profile["target"], "--", "bash", "-s"]
    return run(argv, payload="set -euo pipefail\n" + script, capture=capture, timeout=timeout)


def safe(value, pattern, label):
    if not re.fullmatch(pattern, value):
        raise Refusal(f"invalid {label}: {value!r}")
    return value


def confirm(plan):
    print(plan, flush=True)
    # Never accept a global auto-approval variable or a pipe as consent.
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write("Proceed? Type yes: ")
            tty.flush()
            accepted = tty.readline().strip() == "yes"
    except OSError:
        accepted = False
    if not accepted:
        raise Refusal("not approved; no mutation performed")


def load(path):
    if path.is_symlink():
        raise Refusal("profile must not be a symlink")
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        if data["version"] != 1 or data["transport"] not in ("ssh", "multipass"):
            raise ValueError("unsupported profile")
        safe(data["root"], r"/[A-Za-z0-9_./-]+", "root")
        safe(data["target"], r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", "target")
        if data["transport"] == "multipass":
            safe(data["target"], r"[A-Za-z][A-Za-z0-9-]*", "VM name")
        safe(data["expect"]["instanceId"], r"[0-9a-f]{32}", "instance identity")
        return data
    except (ValueError, KeyError, TypeError) as error:
        raise Refusal(f"malformed profile: {path}") from error


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, staged = tempfile.mkstemp(prefix=".fleet-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, indent=2)
            out.write("\n")
        os.replace(staged, path)
    finally:
        if os.path.exists(staged):
            os.unlink(staged)


def probe(profile):
    root = shlex.quote(profile["root"])
    script = f'''root={root}
url=$(< "$root/var/nats-url")
[[ "$url" =~ ^nats://127\\.0\\.0\\.1:[0-9]+$ ]] || {{ echo 'not a loopback endpoint' >&2; exit 1; }}
"$root/var/bin/cli" --bus "$url" call catalog '{{"op":"list"}}'
'''
    try:
        reply = json.loads(remote(profile, script))
        # Accept cli's result data (and an envelope for compatible adapters).
        identity = reply.get("args", reply)
        safe(identity["instanceId"], r"[0-9a-f]{32}", "catalog identity")
        if identity["root"] != profile["root"]:
            raise Refusal("catalog root mismatch; refusing adoption")
        if profile.get("expect") and identity["instanceId"] != profile["expect"]["instanceId"]:
            raise Refusal("instance identity mismatch; refusing remote writes")
        return {key: identity[key] for key in ("instanceId", "name", "root", "gitHash")}
    except (ValueError, KeyError, TypeError) as error:
        raise Refusal("invalid catalog response; profile not saved") from error


def install_script(root, revision):
    # Arguments restricted before interpolation. Existing installations never pull,
    # rebuild, seed .env, or change revision. Incomplete roots refuse explicitly.
    return f'''root={shlex.quote(root)}
revision={revision}
export PATH="$HOME/.nimble/bin:/usr/local/bin:$PATH"
[[ ! -L "$root" ]] || {{ echo 'symlinked root: refusing' >&2; exit 1; }}
if [[ -e "$root" ]]; then
  [[ -f "$root/niffler.nimble" && -x "$root/var/bin/niffler" && -f "$root/scripts/server.sh" ]] || {{ echo 'existing incomplete/unrelated root: refusing overwrite' >&2; exit 1; }}
  echo 'Adopting existing installation without updating' >&2
else
  command -v git >/dev/null || {{ echo 'Install git on target first (requires target administrator)' >&2; exit 1; }}
  git clone --no-checkout https://github.com/gokr/niffler.git "$root"
  git -C "$root" fetch origin "$revision"
  git -C "$root" checkout --detach "$revision"
  [[ "$(git -C "$root" rev-parse HEAD)" == "$revision" ]] || exit 1
  # Enter through the explicit-target path so bootstrap installs git/make/Go
  # on a pristine VM before make setup; cwd adoption assumes prerequisites.
  cd "$(dirname "$root")"
  bash "$root/scripts/bootstrap.sh" --server "$root"
fi
# Make Ubuntu's existing per-user manager reachable from multipass exec too.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
bash "$root/scripts/server.sh" install "$root"
bash "$root/scripts/server.sh" start "$root"
'''


def vm_info(name):
    data = json.loads(run(["multipass", "list", "--format", "json"]))
    return next((vm for vm in data["list"] if vm["name"] == name), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "probe", "status", "logs", "start", "stop", "vm-stop"])
    parser.add_argument("--profile", type=Path, required=True, help="local 0600 verified receipt")
    parser.add_argument("--ssh", help="SSH config alias or user@host")
    parser.add_argument("--multipass", help="VM name (create if absent; never mounts host)")
    parser.add_argument("--root", help="absolute target installation path")
    parser.add_argument("--revision", help="full 40-character git commit for a new installation")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--memory", default="4G")
    parser.add_argument("--disk", default="20G")
    args = parser.parse_args()
    path = args.profile.expanduser().absolute()
    previous = load(path)
    if args.action != "install":
        if not previous:
            raise Refusal("verified profile required")
        if args.action == "probe":
            print(json.dumps(probe(previous), indent=2))
            return
        if args.action == "vm-stop":
            if previous["transport"] != "multipass":
                raise Refusal("not a Multipass profile")
            confirm(f"Stop VM {previous['target']} (separate from stopping Niffler; no deletion)")
            run(["multipass", "stop", previous["target"]], capture=False)
            return
        # Only start can operate while bus is down; verify persisted identity first.
        root = shlex.quote(previous["root"])
        expected = previous["expect"]["instanceId"]
        guard = f'[[ "$(< {root}/var/instance-id)" == "{expected}" ]] || {{ echo "identity mismatch" >&2; exit 1; }}\n'
        if args.action in ("start", "stop"):
            confirm(f"{args.action} Niffler: {previous['transport']} {previous['target']} root {previous['root']} identity {expected}")
        remote(previous, guard + 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"\nexport DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"\n' +
               f'bash {root}/scripts/server.sh {args.action} {root}\n', capture=False)
        return
    if bool(args.ssh) == bool(args.multipass):
        raise Refusal("choose exactly one of --ssh or --multipass")
    target = safe(args.ssh or args.multipass, r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", "target")
    if args.multipass:
        safe(target, r"[A-Za-z][A-Za-z0-9-]*", "VM name")
    root = safe(args.root or "", r"/[A-Za-z0-9_./-]+", "root")
    if any(part in (".", "..", "") for part in root.split("/")[1:]) or root == "/":
        raise Refusal("root must be a dedicated canonical installation path")
    revision = safe(args.revision or "", r"[0-9a-f]{40}", "pinned revision")
    profile = {"version": 1, "transport": "ssh" if args.ssh else "multipass", "target": target, "root": root}
    if previous:
        if any(profile[key] != previous[key] for key in ("transport", "target", "root")):
            raise Refusal("profile already belongs to a different target; use another path")
        profile = previous
    vm = vm_info(target) if args.multipass else None
    if previous and args.multipass and vm is None:
        raise Refusal("pinned VM is missing; refusing to recreate a different instance")
    if args.cpus < 1 or args.cpus > 64:
        raise Refusal("CPUs must be 1..64")
    for resource in (args.memory, args.disk):
        safe(resource, r"[1-9][0-9]*[MG]", "VM resource size")
    plan = f"Install/adopt {profile['transport']} {target}, root {root}, new-install revision {revision}.\n"
    plan += "Existing installs are adopted, never updated. New installs run make setup/release (may need sudo on target).\nNo credentials, agent forwarding or mounts. Provider setup and linger are explicit.\n"
    if args.multipass:
        plan += (f"Create Ubuntu 24.04 VM: CPUs={args.cpus}, RAM={args.memory}, disk={args.disk}.\n" if vm is None else
                 f"Adopt existing VM ({vm['state']}); no deletion authority is acquired.\n")
    confirm(plan)
    if args.multipass:
        if vm is None:
            run(["multipass", "launch", "24.04", "--name", target, "--cpus", str(args.cpus),
                 "--memory", args.memory, "--disk", args.disk], capture=False, timeout=600)
            profile["createdVm"] = True
        elif vm["state"] != "Running":
            run(["multipass", "start", target], capture=False, timeout=180)
    if previous:
        # A stopped service still has durable identity; check it before writes.
        remote(previous, f'[[ "$(< {shlex.quote(root)}/var/instance-id)" == "{previous["expect"]["instanceId"]}" ]] || {{ echo "identity mismatch" >&2; exit 1; }}\n')
        # Also check an answering catalog when available. An unreachable bus is
        # not an identity change; starting its verified service is legitimate.
        try:
            probe(previous)
        except Refusal as error:
            if "mismatch" in str(error) or "invalid catalog" in str(error):
                raise
    remote(profile, install_script(root, revision), capture=False, timeout=3600)
    # The service may still be starting. Read-only bounded retries; never reinstall.
    last = None
    for _ in range(30):
        try:
            profile["expect"] = probe(profile)
            break
        except Refusal as error:
            last = error
            if "mismatch" in str(error):
                raise
            time.sleep(1)
    else:
        raise Refusal(f"service did not verify; profile not saved: {last}")
    save(path, profile)
    print(f"Verified profile saved: {path}; provider configuration remains explicit.")


if __name__ == "__main__":
    try:
        main()
    except (Refusal, ValueError) as error:
        print(f"niffler-fleet: {error}", file=sys.stderr)
        sys.exit(1)
