#!/usr/bin/env python3
"""Opt-in, explicitly bound shared-Codex observer. Never resumes a thread.

Run with uv run --with websockets==15.0.1 python scripts/codex-shared-observer.py.
This experiment is deliberately not installed into the normal codex launcher.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid


class CodexReader:
    """Only read-only protocol methods are admitted on this connection."""
    METHODS = {"initialize", "thread/read", "thread/turns/list", "thread/items/list"}

    def __init__(self, socket_path):
        from websockets.sync.client import unix_connect
        self.connection = unix_connect(str(socket_path), open_timeout=4,
                                       close_timeout=1, max_size=2**21,
                                       max_queue=4, compression=None)
        self.sequence = 0
        self.call("initialize", {"clientInfo": {"name": "cmux_personal_observer", "version": "0.1"},
                                 "capabilities": {}})
        self.connection.send(json.dumps({"method": "initialized", "params": {}}))

    def call(self, method, params):
        if method not in self.METHODS:
            raise ValueError("Observer cannot issue mutating Codex requests")
        self.sequence += 1
        self.connection.send(json.dumps({"id": self.sequence, "method": method, "params": params}))
        deadline = time.monotonic() + 5
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(method)
            message = json.loads(self.connection.recv(timeout=remaining))
            if message.get("id") != self.sequence:
                continue
            if "error" in message:
                raise RuntimeError(f"{method}: {message['error'].get('message', 'RPC failure')}")
            return message["result"]

    def close(self):
        self.connection.close()


def identifier(value):
    return str(uuid.UUID(value))


def process_generation(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart=,comm="],
                            capture_output=True, text=True, timeout=3)
    value = result.stdout.strip()
    if result.returncode or not value or Path(value.split()[-1]).name != "codex":
        return None
    return value


def attention(status):
    if status.get("type") == "active":
        flags = status.get("activeFlags", [])
        if "waitingOnApproval" in flags:
            return "permission"
        if "waitingOnUserInput" in flags:
            return "question"
        return "working"
    if status.get("type") == "systemError":
        return "error"
    return status.get("type", "unknown")


class Cmux:
    def __init__(self, binary, socket_path, surface, workspace, owner_pid):
        self.prefix = [str(binary), "--socket", str(socket_path)]
        self.surface, self.workspace = surface, workspace
        self.owner_pid = owner_pid
        self.poller = "personal-codex-observer-" + str(uuid.uuid4())

    def command(self, *args):
        result = subprocess.run(self.prefix + list(args), capture_output=True,
                                text=True, timeout=8)
        if result.returncode:
            raise RuntimeError(result.stderr.strip()[:240] or "cmux command failed")
        return result.stdout

    def rpc(self, method, params):
        return json.loads(self.command("rpc", method, json.dumps(params)))

    def validate_surface(self):
        data = json.loads(self.command("--json", "--id-format", "uuids", "list-panels",
                                      "--workspace", self.workspace))
        if not any(s.get("id", "").lower() == self.surface.lower()
                   and s.get("type") == "terminal" for s in data.get("surfaces", [])):
            raise RuntimeError("The bound terminal no longer exists in this workspace")

    def notify(self, subtitle, body):
        # Native OSC already delivers completions. This observer complements
        # it with attention states rather than duplicating every Done banner.
        self.validate_owner()
        self.command("notify", "--workspace", self.workspace, "--surface", self.surface,
                     "--title", "Codex", "--subtitle", subtitle, "--body", body)

    def poll(self, register=False):
        return self.rpc("agent.message.poll", {"surface_id": self.surface,
                        "poller_key": self.poller, "register": register})

    def validate_owner(self):
        def matches(value):
            if isinstance(value, dict):
                if (value.get("pid") == self.owner_pid
                    and str(value.get("cmux_surface_id", "")).lower() == self.surface.lower()
                    and str(value.get("cmux_workspace_id", "")).lower() == self.workspace.lower()):
                    return True
                return any(matches(child) for child in value.values())
            return isinstance(value, list) and any(matches(child) for child in value)
        if not matches(self.rpc("system.top", {"include_processes": True})):
            raise RuntimeError("Codex process is no longer owned by the bound terminal")

    def deliver(self, codex, thread, poll, runner=subprocess.run):
        if poll.get("status") != "current" or poll.get("held") or not poll.get("queued"):
            return False
        self.validate_owner()
        params = {"surface_id": self.surface, "poller_key": self.poller,
                  "via": "codex.shared-observer", "defer_delivery": True,
                  "mark_delivered_read": False}
        claim = self.rpc("agent.message.claim", params)
        lease, text = claim.get("lease_id"), claim.get("text")
        if not lease or not text:
            return False
        # Preserve cmux's deferred-delivery contract: acknowledge only after
        # native Codex accepts the message. A timeout is ambiguous, so stop the
        # observer for manual inspection rather than automatically retrying.
        result = runner([str(codex), "queue", "--thread", thread, "--message", text],
                        capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError("Codex did not accept the queued agent message; delivery not acknowledged")
        self.rpc("agent.message.ack", {"surface_id": self.surface, "poller_key": self.poller,
                 "lease_id": lease, "via": "codex.shared-observer"})
        return True


def watch(args):
    generation = process_generation(args.owner_pid)
    if generation is None:
        raise RuntimeError("Owner PID is not a live Codex process")
    cmux = Cmux(args.cmux, args.cmux_socket, args.surface, args.workspace, args.owner_pid)
    cmux.validate_surface()
    cmux.validate_owner()
    reader = CodexReader(args.codex_socket)
    previous = None
    if args.messages:
        cmux.poll(register=True)
    print("Observer ready: exact thread and terminal binding; no thread resume", flush=True)
    try:
        deadline = time.monotonic() + args.max_seconds
        while time.monotonic() < deadline and process_generation(args.owner_pid) == generation:
            cmux.validate_surface()
            thread = reader.call("thread/read", {"threadId": args.thread})["thread"]
            if thread.get("id") != args.thread:
                raise RuntimeError("Codex returned a different conversation")
            state = attention(thread.get("status", {}))
            if state != previous:
                print("State:", state, flush=True)
                if state in {"permission", "question", "error"}:
                    title = {"permission": "Permission required", "question": "Answer required",
                             "error": "Session error"}[state]
                    cmux.notify(title, "Open this terminal or ChatGPT to respond.")
                previous = state
            if args.messages and state == "idle":
                poll = cmux.poll()
                if poll.get("status") == "superseded":
                    return
                if cmux.deliver(args.codex, args.thread, poll):
                    print("Agent message accepted by Codex", flush=True)
            if args.once:
                return
            time.sleep(args.interval)
    finally:
        reader.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread", required=True, type=identifier)
    parser.add_argument("--surface", required=True, type=identifier)
    parser.add_argument("--workspace", required=True, type=identifier)
    parser.add_argument("--owner-pid", required=True, type=int)
    parser.add_argument("--cmux", type=Path, default=Path.home()/".local/bin/cmux")
    parser.add_argument("--codex", type=Path, default=Path.home()/".local/bin/codex")
    parser.add_argument("--cmux-socket", type=Path, required=True)
    parser.add_argument("--codex-socket", type=Path,
                        default=Path.home()/".codex/app-server-control/app-server-control.sock")
    parser.add_argument("--interval", type=float, default=2)
    parser.add_argument("--messages", action="store_true")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--max-seconds", type=float, default=1800,
                        help="finite experiment lifetime (default 30 minutes)")
    args = parser.parse_args()
    if not 1 <= args.interval <= 60:
        parser.error("interval must be between 1 and 60 seconds")
    if not 1 <= args.max_seconds <= 3600:
        parser.error("max-seconds must be between 1 and 3600")
    try:
        watch(args)
    except Exception as error:
        parser.exit(1, f"Observer stopped ({type(error).__name__}): {str(error)[:200]}\n")


if __name__ == "__main__":
    main()
