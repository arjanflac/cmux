#!/usr/bin/env python3
"""Manual, no-model regression check for a cold tagged app's task receipts.

Prepare while the tagged app is closed, launch that build, then check. Clean
removes only this fixture's known IDs after checking their ownership marker.
This never launches an agent or creates a workspace.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

MARKER = "Native task receipt regression fixture"
ANSWER = "ARCHIVED_NATIVE_SOCKET_RESULT"
NAMESPACE = uuid.UUID("9277b067-90b2-4cb4-a126-30daa870bdd5")
IDS = [str(uuid.uuid5(NAMESPACE, str(index))).upper() for index in range(104)]
ROOT = Path(__file__).resolve().parents[1]


def prepare(directory: Path, workspace: str) -> None:
    workspace = str(uuid.UUID(workspace)).upper()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if any((directory / (identity + ".json")).exists() for identity in IDS):
        raise RuntimeError("Fixture IDs already exist; clean this fixture first")
    baseline = time.time() - 10_000
    for index, identity in enumerate(IDS):
        timestamp = baseline + index
        record = {
            "id": identity,
            "provider": "codex",
            "workspaceID": workspace,
            "workingDirectory": "file:///tmp/",
            "presentation": "background",
            "title": MARKER,
            "phase": "running" if index == 1 else "completed",
            "createdAt": timestamp - 978_307_200,
            "updatedAt": timestamp - 978_307_200,
        }
        if index == 1:
            record["parentTaskID"] = IDS[0]
        else:
            record["result"] = ANSWER if index == 0 else "Newer fixture result"
        path = directory / (identity + ".json")
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(record, stream)
        os.utime(path, (timestamp, timestamp))
    print(f"Prepared {len(IDS)} private fixture receipts; no provider was started")


def check(tag: str, installed_app: str | None) -> None:
    environment = os.environ.copy()
    environment["CMUX_TAG"] = tag
    if installed_app:
        environment["CMUX_INSTALLED_APP"] = installed_app
    failures = []
    for verb in ("read", "wait"):
        response = subprocess.run(
            [str(ROOT / "scripts/cmux-debug-cli.sh"), "task", verb, IDS[0]],
            env=environment, capture_output=True, text=True, timeout=25, check=True,
        )
        record = json.loads(response.stdout)
        assert record["id"].upper() == IDS[0] and record["phase"] == "completed", record
        if record.get("result") != ANSWER:
            failures.append(verb)
    assert not failures, f"Correct archived identity/state, but missing result through: {failures}"
    print("PASS: native task read and wait preserve the archived result")


def clean(directory: Path) -> None:
    removed = 0
    for identity in IDS:
        path = directory / (identity + ".json")
        if not path.exists():
            continue
        record = json.loads(path.read_text())
        if record.get("id") != identity or record.get("title") != MARKER:
            raise RuntimeError(f"Refusing to remove a receipt without the fixture marker: {identity}")
        path.unlink()
        removed += 1
    print(f"Removed {removed} owned fixture receipts")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "check", "clean"))
    parser.add_argument("--receipt-directory", type=lambda value: Path(value).expanduser())
    parser.add_argument("--workspace")
    parser.add_argument("--tag")
    parser.add_argument("--installed-app")
    arguments = parser.parse_args()
    if arguments.mode == "prepare":
        if not arguments.receipt_directory or not arguments.workspace:
            parser.error("prepare requires --receipt-directory and --workspace")
        prepare(arguments.receipt_directory, arguments.workspace)
    elif arguments.mode == "check":
        if not arguments.tag:
            parser.error("check requires --tag")
        check(arguments.tag, arguments.installed_app)
    else:
        if not arguments.receipt_directory:
            parser.error("clean requires --receipt-directory")
        clean(arguments.receipt_directory)
