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


def test(source, log, expected_count, *, should_fail, selector="cmux_quiet_", feature=False):
    command = ["cargo", "test", "--locked", "-p", "codex-tui", "--lib"]
    if feature:
        command += ["--features", "cmux-quiet"]
    command += [selector, "--", "--test-threads=1", "--color=never"]
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
    # Use the complete derived presentation for the Working-tip discriminator;
    # preserve the independent original rendering proof above.
    for patch_name in manifest["patches"]:
        if patch_name in ("regression-tests.patch", "quiet-fullscreen.patch", "working-tip.patch", "orchestration.patch",
                          "resume-compat-tests.patch", "resume-compat.patch",
                          "tool-coverage-tests.patch", "tool-coverage.patch",
                          "aggregate-tests.patch", "aggregate.patch"):
            continue
        run(["git", "apply", "--check", str(HERE / patch_name)], source)
        run(["git", "apply", str(HERE / patch_name)], source)
    working_tip_proof(source, logs, manifest)
    orchestration_proof(source, logs, manifest)
    resume_compat_proof(source, logs, manifest)
    tool_coverage_proof(source, logs, manifest)
    aggregate_proof(source, logs, manifest)


def working_tip_proof(source, logs, manifest):
    """Require a rendered failure, then feature-on and stock feature-off passes."""
    arguments = dict(selector="cmux_working_tip_", expected_count=manifest["workingTipTestCount"])
    test(source, logs / "working-tip-before.log", feature=True, should_fail=True, **arguments)
    run(["git", "apply", "--check", str(HERE / "working-tip.patch")], source)
    run(["git", "apply", str(HERE / "working-tip.patch")], source)
    run(["git", "diff", "--check"], source)
    test(source, logs / "working-tip-after.log", feature=True, should_fail=False, **arguments)
    test(source, logs / "working-tip-stock.log", feature=False, should_fail=False, **arguments)
    print("PASS: Working tips hidden only in the derived frontend; completion tips and stock rendering retained")


def orchestration_proof(source, logs, manifest):
    """Run private-file/CLI fixtures and actual rendering before and after activation.

    The tests patch wires inert transport/presentation seams into the pinned TUI.
    A setup failure or a missing test cannot satisfy the behavioral discriminator.
    These fixtures never connect to a socket or submit provider work.
    """
    arguments = dict(selector="cmux_orchestration_", expected_count=manifest["orchestrationTestCount"])
    test(source, logs / "orchestration-before.log", feature=True, should_fail=True, **arguments)
    run(["git", "apply", "--check", str(HERE / "orchestration.patch")], source)
    run(["git", "apply", str(HERE / "orchestration.patch")], source)
    run(["git", "diff", "--check"], source)
    test(source, logs / "orchestration-after.log", feature=True, should_fail=False, **arguments)
    test(source, logs / "orchestration-stock.log", feature=False, should_fail=False, **arguments)
    print("PASS: scoped cmux worker presentation and native bridge; feature-off stock control retained")


def resume_compat_proof(source, logs, manifest):
    """Exercise restore eligibility after all prior patches, without connecting.

    Move the unchanged binary parser into a shared test seam, require an
    executed pre-fix failure, then check the fix and the stock feature controls.
    """
    run(["git", "apply", "--check", str(HERE / "resume-compat-tests.patch")], source)
    run(["git", "apply", str(HERE / "resume-compat-tests.patch")], source)
    run(["git", "diff", "--check"], source)
    arguments = dict(selector="cmux_resume_compat_", expected_count=manifest["resumeCompatTestCount"])
    test(source, logs / "resume-compat-before.log", feature=True, should_fail=True, **arguments)
    run(["git", "apply", "--check", str(HERE / "resume-compat.patch")], source)
    run(["git", "apply", str(HERE / "resume-compat.patch")], source)
    run(["git", "diff", "--check"], source)
    test(source, logs / "resume-compat-after.log", feature=True, should_fail=False, **arguments)
    test(source, logs / "resume-compat-stock.log", feature=False, should_fail=False, **arguments)
    print("PASS: exact native restore argv eligible; permission flags and stock feature controls retained")


def tool_coverage_proof(source, logs, manifest):
    """Require actual quiet/compact rendering failures after the original twelve patches.

    Fixtures exercise retained and live cells, native computer screenshots, nested
    groups, search and detailed backing content without provider or socket work.
    """
    run(["git", "apply", "--check", str(HERE / "tool-coverage-tests.patch")], source)
    run(["git", "apply", str(HERE / "tool-coverage-tests.patch")], source)
    run(["git", "diff", "--check"], source)
    arguments = dict(selector="cmux_tool_coverage_", expected_count=manifest["toolCoverageTestCount"])
    test(source, logs / "tool-coverage-before.log", feature=True, should_fail=True, **arguments)
    run(["git", "apply", "--check", str(HERE / "tool-coverage.patch")], source)
    run(["git", "apply", str(HERE / "tool-coverage.patch")], source)
    run(["git", "diff", "--check"], source)
    test(source, logs / "tool-coverage-after.log", feature=True, should_fail=False, **arguments)
    test(source, logs / "tool-coverage-stock.log", feature=False, should_fail=False, **arguments)
    print("PASS: known routine cells hidden; protected content, compact/details/search and stock controls retained")


def aggregate_proof(source, logs, manifest):
    """Rendered batch coalescing after all fourteen immutable prior patches.

    Require an executed pre-fix failure, then feature-on and feature-off passes.
    Re-run earlier presentation fixtures on the final source after their precise
    zero-row expectations have migrated to the new one-row batch contract.
    """
    run(["git", "apply", "--check", str(HERE / "aggregate-tests.patch")], source)
    run(["git", "apply", str(HERE / "aggregate-tests.patch")], source)
    run(["git", "diff", "--check"], source)
    arguments = dict(selector="cmux_activity_summary_", expected_count=manifest["aggregateTestCount"])
    test(source, logs / "aggregate-before.log", feature=True, should_fail=True, **arguments)
    run(["git", "apply", "--check", str(HERE / "aggregate.patch")], source)
    run(["git", "apply", str(HERE / "aggregate.patch")], source)
    run(["git", "diff", "--check"], source)
    test(source, logs / "aggregate-after.log", feature=True, should_fail=False, **arguments)
    test(source, logs / "aggregate-stock.log", feature=False, should_fail=False, **arguments)
    test(source, logs / "aggregate-final-focus.log", selector="cmux_focus_",
         expected_count=manifest["focusTestCount"], feature=True, should_fail=False)
    for feature in (True, False):
        test(source, logs / ("aggregate-final-coverage.log" if feature else "aggregate-final-coverage-stock.log"),
             selector="cmux_tool_coverage_", expected_count=manifest["toolCoverageTestCount"],
             feature=feature, should_fail=False)
    print("PASS: stable quiet activity batches; prose/attention boundaries, live coalescing, details and stock controls retained")


if __name__ == "__main__":
    main()
