#!/usr/bin/env python3
"""Run synthetic rendering regressions on a disposable, pinned Codex checkout.

This lane never builds an installable frontend or launches a Codex conversation.
Its compilation belongs on CI, not the memory-constrained workstation.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import tomllib


HERE = Path(__file__).resolve().parent


def run(arguments, directory):
    return subprocess.run(arguments, cwd=directory, text=True, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def prepare_release_lock(source, logs):
    root = source / "codex-rs"
    before = tomllib.loads((root / "Cargo.lock").read_text())
    # Cargo includes local path packages that are absent from the explicit members list.
    discovery = subprocess.run(["cargo", "metadata", "--no-deps", "--format-version", "1"],
                               cwd=root, text=True, capture_output=True, check=True, timeout=600)
    (logs / "workspace-metadata.json").write_text(discovery.stdout)
    metadata = json.loads(discovery.stdout)
    members = set(metadata["workspace_members"])
    versions = {package["name"]: package["version"] for package in metadata["packages"]
                if package["id"] in members and package["source"] is None}
    expected = json.loads(json.dumps(before))
    updates = {entry["name"]: (entry["version"], versions[entry["name"]]) for entry in before["package"]
               if "source" not in entry and entry["name"] in versions
               and entry["version"] != versions[entry["name"]]}
    for entry in expected["package"]:
        if "source" not in entry and entry["name"] in updates:
            entry["version"] = updates[entry["name"]][1]
        dependencies = entry.get("dependencies", [])
        for index, dependency in enumerate(dependencies):
            for name, (old_version, version) in updates.items():
                old = f"{name} {old_version}"
                if dependency == old or dependency.startswith(old + " "):
                    dependencies[index] = f"{name} {version}" + dependency[len(old):]
    with (logs / "release-lock-setup.log").open("w") as stream:
        subprocess.run(["cargo", "update", "--workspace"], cwd=root, check=True,
                       stdout=stream, stderr=subprocess.STDOUT, timeout=600)
    after = tomllib.loads((root / "Cargo.lock").read_text())
    for document in (expected, after):
        document["package"].sort(key=lambda entry: (entry["name"], entry["version"], entry.get("source", "")))
        for entry in document["package"]:
            if "dependencies" in entry:
                entry["dependencies"].sort()
    (logs / "release-lock.diff").write_text(run(["git", "diff", "--", "codex-rs/Cargo.lock"], source))
    if after != expected:
        raise RuntimeError("Release lock normalization changed more than local workspace version labels")
    print(f"Normalized {len(updates)} local release labels; all external lock entries unchanged", flush=True)


def test(source, log, expected_count, *, should_fail):
    command = ["cargo", "test", "--locked", "-p", "codex-tui", "--lib",
               "cmux_quiet_", "--", "--test-threads=1", "--color=never"]
    print(f"Running {'stock regression' if should_fail else 'patched regression'}", flush=True)
    with log.open("w") as stream:
        outcome = subprocess.run(command, cwd=source / "codex-rs", text=True,
                                 stdout=stream, stderr=subprocess.STDOUT, timeout=4800)
    output = log.read_text()
    matches = re.findall(r"test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;", output)
    if len(matches) != 1:
        print(output[-8000:])
        raise RuntimeError("Expected one executed test summary; compilation/setup/zero-test failure is not a regression")
    state, passed, failed, ignored = matches[0]
    passed, failed, ignored = int(passed), int(failed), int(ignored)
    if passed + failed != expected_count or ignored:
        raise RuntimeError(f"Expected {expected_count} executed tests, observed {passed} passed / {failed} failed / {ignored} ignored")
    valid = (outcome.returncode != 0 and state == "FAILED" and failed > 0) if should_fail else (
        outcome.returncode == 0 and state == "ok" and failed == 0)
    if not valid:
        print(output[-8000:])
        raise RuntimeError("Test outcome did not match the required behavioral discriminator")
    print(f"Observed {passed} passed / {failed} failed; full output: {log}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--logs", type=Path, required=True)
    arguments = parser.parse_args()
    source = arguments.source.resolve()
    logs = arguments.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((HERE / "source.json").read_text())
    if run(["git", "rev-parse", "HEAD"], source).strip() != manifest["commit"]:
        raise RuntimeError("The source checkout does not match the pinned Codex release")
    if run(["git", "status", "--porcelain"], source).strip():
        raise RuntimeError("Use a clean disposable source checkout")
    prepare_release_lock(source, logs)
    for patch_name, should_fail in (("regression-tests.patch", True), ("quiet-fullscreen.patch", False)):
        patch = HERE / patch_name
        run(["git", "apply", "--check", str(patch)], source)
        run(["git", "apply", str(patch)], source)
        run(["git", "diff", "--check"], source)
        test(source, logs / ("stock.log" if should_fail else "quiet.log"),
             manifest["testCount"], should_fail=should_fail)
    print("PASS: the same synthetic rendering tests failed behaviorally on stock and passed after the patch")


if __name__ == "__main__":
    main()
