"""Exercise the dependency gate without compiling Rust or resolving dependencies."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("quiet_proof_check", Path(__file__).with_name("check.py"))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class ReleaseLockTests(unittest.TestCase):
    def exercise(self, *, change_external=False):
        with tempfile.TemporaryDirectory(prefix="quiet-release-gate-") as temporary:
            source = Path(temporary)
            root = source / "codex-rs"
            logs = source / "logs"
            logs.mkdir()
            for name in ("explicit", "implicit"):
                (root / name).mkdir(parents=True)
                (root / name / "Cargo.toml").write_text(
                    f'[package]\nname = "{name}"\nversion.workspace = true\n')
            (root / "Cargo.toml").write_text(
                '[workspace]\nmembers = ["explicit"]\n[workspace.package]\nversion = "0.164.0"\n')
            original = 'version = 4\n'
            for name in ("explicit", "implicit"):
                original += f'[[package]]\nname = "{name}"\nversion = "0.0.0"\n'
            original += ('[[package]]\nname = "external"\nversion = "1.0.0"\n'
                         'source = "registry+https://example.invalid"\nchecksum = "unchanged"\n')
            (root / "Cargo.lock").write_text(original)
            metadata = {"workspace_members": ["explicit-id", "implicit-id"], "packages": [
                {"id": name + "-id", "name": name, "version": "0.164.0", "source": None}
                for name in ("explicit", "implicit")
            ]}

            def cargo(arguments, **kwargs):
                if arguments[1] == "metadata":
                    return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps(metadata))
                self.assertEqual(arguments, ["cargo", "update", "--workspace"])
                normalized = original.replace('version = "0.0.0"', 'version = "0.164.0"')
                if change_external:
                    normalized = normalized.replace('checksum = "unchanged"', 'checksum = "changed"')
                (root / "Cargo.lock").write_text(normalized)
                return subprocess.CompletedProcess(arguments, 0)

            with patch.object(check.subprocess, "run", cargo), patch.object(check, "run", return_value="fixture diff"), contextlib.redirect_stdout(io.StringIO()):
                check.prepare_release_lock(source, logs)

    def test_accepts_implicit_workspace_member_release_labels(self):
        self.exercise()

    def test_rejects_external_checksum_changes(self):
        with self.assertRaisesRegex(RuntimeError, "more than local workspace"):
            self.exercise(change_external=True)


class WorkingTipProofTests(unittest.TestCase):
    def test_requires_rendered_failure_then_derived_and_stock_passes(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["workingTipTestCount"]
        applied = False
        features = []

        def git(arguments, directory):
            nonlocal applied
            if arguments[:2] == ["git", "apply"]:
                self.assertEqual(Path(arguments[-1]).name, "working-tip.patch")
                if "--check" not in arguments:
                    applied = True
            return ""

        def cargo(arguments, **kwargs):
            self.assertEqual(arguments[:6], ["cargo", "test", "--locked", "-p", "codex-tui", "--lib"])
            self.assertIn("cmux_working_tip_", arguments)
            feature = "--features" in arguments
            features.append(feature)
            failed = int(feature and not applied)
            kwargs["stdout"].write(
                f"test result: {'FAILED' if failed else 'ok'}. {count - failed} passed; {failed} failed; 0 ignored;\n")
            return subprocess.CompletedProcess(arguments, failed)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(check, "run", git), \
                patch.object(check.subprocess, "run", cargo), \
                contextlib.redirect_stdout(io.StringIO()):
            check.working_tip_proof(Path(directory), Path(directory), manifest)
        self.assertEqual(features, [True, True, False])
        self.assertTrue(applied)

    def test_setup_or_zero_test_failure_cannot_apply_the_fix(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        for output in ["error: compilation failed\n",
                       "test result: FAILED. 0 passed; 0 failed; 0 ignored;\n"]:
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                def cargo(arguments, **kwargs):
                    kwargs["stdout"].write(output)
                    return subprocess.CompletedProcess(arguments, 1)

                with patch.object(check, "run") as git, \
                        patch.object(check.subprocess, "run", cargo), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaisesRegex(RuntimeError, "Expected"):
                    check.working_tip_proof(Path(directory), Path(directory), manifest)
                git.assert_not_called()


class OrchestrationProofTests(unittest.TestCase):
    def test_requires_executed_failure_then_feature_on_and_stock_pass(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["orchestrationTestCount"]
        applied = False
        features = []

        def git(arguments, directory):
            nonlocal applied
            if arguments[:2] == ["git", "apply"]:
                self.assertEqual(Path(arguments[-1]).name, "orchestration.patch")
                if "--check" not in arguments:
                    applied = True
            return ""

        def cargo(arguments, **kwargs):
            self.assertIn("cmux_orchestration_", arguments)
            self.assertIn("--lib", arguments)
            self.assertIn("--test-threads=1", arguments)
            features.append("--features" in arguments)
            failed = int(features[-1] and not applied)
            kwargs["stdout"].write(
                f"test result: {'FAILED' if failed else 'ok'}. {count - failed} passed; {failed} failed; 0 ignored;\n")
            return subprocess.CompletedProcess(arguments, failed)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(check, "run", git), \
                patch.object(check.subprocess, "run", cargo), \
                contextlib.redirect_stdout(io.StringIO()):
            check.orchestration_proof(Path(directory), Path(directory), manifest)
        self.assertEqual(features, [True, True, False])
        self.assertTrue(applied)

    def test_invalid_before_evidence_never_applies_implementation(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["orchestrationTestCount"]
        for output in ["error: compilation failed\n",
                       "test result: FAILED. 0 passed; 0 failed; 0 ignored;\n",
                       f"test result: ok. {count} passed; 0 failed; 0 ignored;\n",
                       f"test result: FAILED. 0 passed; {count-1} failed; 1 ignored;\n"]:
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                def cargo(arguments, **kwargs):
                    kwargs["stdout"].write(output)
                    return subprocess.CompletedProcess(arguments, int("FAILED" in output))

                with patch.object(check, "run") as git, \
                        patch.object(check.subprocess, "run", cargo), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(RuntimeError):
                    check.orchestration_proof(Path(directory), Path(directory), manifest)
                git.assert_not_called()


class ResumeCompatProofTests(unittest.TestCase):
    def test_requires_failure_then_feature_on_and_feature_off_passes(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["resumeCompatTestCount"]
        applied = []
        features = []

        def git(arguments, directory):
            if arguments[:2] == ["git", "apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""

        def cargo(arguments, **kwargs):
            self.assertIn("cmux_resume_compat_", arguments)
            self.assertIn("--lib", arguments)
            self.assertIn("--test-threads=1", arguments)
            self.assertIn("resume-compat-tests.patch", applied)
            features.append("--features" in arguments)
            failed = int("resume-compat.patch" not in applied)
            kwargs["stdout"].write(
                f"test result: {'FAILED' if failed else 'ok'}. {count - failed} passed; {failed} failed; 0 ignored;\n")
            return subprocess.CompletedProcess(arguments, failed)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(check, "run", git), \
                patch.object(check.subprocess, "run", cargo), \
                contextlib.redirect_stdout(io.StringIO()):
            check.resume_compat_proof(Path(directory), Path(directory), manifest)
        self.assertEqual(features, [True, True, False])
        self.assertEqual(applied, ["resume-compat-tests.patch", "resume-compat.patch"])

    def test_invalid_before_evidence_never_applies_fix(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["resumeCompatTestCount"]
        for output in ["error: compilation failed\n",
                       "test result: FAILED. 0 passed; 0 failed; 0 ignored;\n",
                       f"test result: ok. {count} passed; 0 failed; 0 ignored;\n",
                       f"test result: FAILED. 0 passed; {count-1} failed; 1 ignored;\n"]:
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                def cargo(arguments, **kwargs):
                    kwargs["stdout"].write(output)
                    return subprocess.CompletedProcess(arguments, int("FAILED" in output))

                with patch.object(check, "run") as git, \
                        patch.object(check.subprocess, "run", cargo), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(RuntimeError):
                    check.resume_compat_proof(Path(directory), Path(directory), manifest)
                applied = [Path(call.args[0][-1]).name for call in git.call_args_list
                           if call.args[0][:2] == ["git", "apply"] and "--check" not in call.args[0]]
                self.assertEqual(applied, ["resume-compat-tests.patch"])

    def test_post_fix_or_feature_off_failure_rejects_proof(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["resumeCompatTestCount"]
        for failed_call in (2, 3):
            with self.subTest(failed_call=failed_call), tempfile.TemporaryDirectory() as directory:
                calls = 0

                def cargo(arguments, **kwargs):
                    nonlocal calls
                    calls += 1
                    failed = int(calls in (1, failed_call))
                    kwargs["stdout"].write(
                        f"test result: {'FAILED' if failed else 'ok'}. {count-failed} passed; {failed} failed; 0 ignored;\n")
                    return subprocess.CompletedProcess(arguments, failed)

                with patch.object(check, "run"), \
                        patch.object(check.subprocess, "run", cargo), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaises(RuntimeError):
                    check.resume_compat_proof(Path(directory), Path(directory), manifest)
                self.assertEqual(calls, failed_call)

    def test_main_applies_compatibility_only_after_all_prior_patches(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        applied = []

        def git(arguments, directory):
            if arguments[1] == "rev-parse":
                return manifest["commit"]
            if arguments[:2] == ["git", "apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""

        def tests(source, log, expected_count, **kwargs):
            if kwargs.get("selector") == "cmux_resume_compat_":
                self.assertTrue(set(manifest["patches"][:10]).issubset(applied))
                self.assertIn("resume-compat-tests.patch", applied)
                self.assertEqual("resume-compat.patch" in applied, not kwargs["should_fail"])

        with tempfile.TemporaryDirectory() as directory, \
                patch("sys.argv", ["check.py", "--source", directory, "--logs", directory]), \
                patch.object(check, "prepare_release_lock"), \
                patch.object(check, "run", git), patch.object(check, "test", tests), \
                contextlib.redirect_stdout(io.StringIO()):
            check.main()
        self.assertEqual(len(applied), len(set(applied)))
        self.assertEqual(applied[-6:-4], ["resume-compat-tests.patch", "resume-compat.patch"])
        self.assertEqual(set(applied), set(manifest["patches"]))

    def test_manifest_appends_compatibility_and_counts_all_fixtures(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        self.assertEqual(manifest["patches"], [
            "regression-tests.patch", "quiet-fullscreen.patch", "attach-only.patch", "session-binding.patch",
            "focus-tests.patch", "focus-mode.patch", "working-tip-tests.patch", "working-tip.patch",
            "orchestration-tests.patch", "orchestration.patch", "resume-compat-tests.patch", "resume-compat.patch",
            "tool-coverage-tests.patch", "tool-coverage.patch",
            "aggregate-tests.patch", "aggregate.patch",
        ])
        source = (check.HERE / "resume-compat-tests.patch").read_text()
        count = len(re.findall(r'^\+\s*fn cmux_resume_compat_\w+\(', source, re.M))
        self.assertEqual(count, manifest["resumeCompatTestCount"])


class ToolCoverageProofTests(unittest.TestCase):
    def exercise(self, outputs=None):
        manifest = json.loads((check.HERE / "source.json").read_text())
        count = manifest["toolCoverageTestCount"]
        applied, features = [], []

        def git(arguments, directory):
            if arguments[:2] == ["git", "apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""

        def cargo(arguments, **kwargs):
            self.assertIn("cmux_tool_coverage_", arguments)
            self.assertIn("--lib", arguments)
            self.assertIn("--test-threads=1", arguments)
            self.assertEqual(applied[0], "tool-coverage-tests.patch")
            features.append("--features" in arguments)
            if len(features) == 1:
                self.assertNotIn("tool-coverage.patch", applied)
            else:
                self.assertIn("tool-coverage.patch", applied)
            failed = int(len(features) == 1)
            text = f"test result: {'FAILED' if failed else 'ok'}. {count-failed} passed; {failed} failed; 0 ignored;\n"
            if outputs is not None:
                text = outputs[len(features)-1]
                failed = int("FAILED" in text or "error:" in text)
            kwargs["stdout"].write(text)
            return subprocess.CompletedProcess(arguments, failed)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(check, "run", git), \
                patch.object(check.subprocess, "run", cargo), \
                contextlib.redirect_stdout(io.StringIO()):
            try:
                check.tool_coverage_proof(Path(directory), Path(directory), manifest)
            finally:
                self.applied, self.features = applied, features

    def test_requires_executed_red_green_and_feature_off_control(self):
        self.exercise()
        self.assertEqual(self.applied, ["tool-coverage-tests.patch", "tool-coverage.patch"])
        self.assertEqual(self.features, [True, True, False])

    def test_invalid_before_evidence_cannot_apply_fix(self):
        count = json.loads((check.HERE / "source.json").read_text())["toolCoverageTestCount"]
        for output in ["error: compilation failed\n", "test result: FAILED. 0 passed; 0 failed; 0 ignored;\n",
                       f"test result: ok. {count} passed; 0 failed; 0 ignored;\n",
                       f"test result: FAILED. 0 passed; {count-1} failed; 1 ignored;\n"]:
            with self.subTest(output=output), self.assertRaises(RuntimeError):
                self.exercise([output])
            self.assertEqual(self.applied, ["tool-coverage-tests.patch"])

    def test_after_and_feature_off_failure_reject_proof(self):
        count = json.loads((check.HERE / "source.json").read_text())["toolCoverageTestCount"]
        red = f"test result: FAILED. {count-1} passed; 1 failed; 0 ignored;\n"
        green = f"test result: ok. {count} passed; 0 failed; 0 ignored;\n"
        for outputs in [[red, red], [red, green, red]]:
            with self.subTest(outputs=outputs), self.assertRaises(RuntimeError):
                self.exercise(outputs)
            self.assertEqual(len(self.features), len(outputs))

    def test_check_applies_coverage_only_after_all_twelve_prior_patches(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        applied = []

        def git(arguments, directory):
            if arguments[1] == "rev-parse":
                return manifest["commit"]
            if arguments[:2] == ["git", "apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""

        def tests(source, log, expected_count, **kwargs):
            if kwargs.get("selector") == "cmux_tool_coverage_" and "aggregate.patch" not in applied:
                self.assertEqual(set(applied[:12]), set(manifest["patches"][:12]))
                self.assertEqual(applied[12], "tool-coverage-tests.patch")
                self.assertEqual("tool-coverage.patch" in applied, not kwargs["should_fail"])

        with tempfile.TemporaryDirectory() as directory, \
                patch("sys.argv", ["check.py", "--source", directory, "--logs", directory]), \
                patch.object(check, "prepare_release_lock"), patch.object(check, "run", git), \
                patch.object(check, "test", tests), contextlib.redirect_stdout(io.StringIO()):
            check.main()
        self.assertEqual(applied[-4:-2], ["tool-coverage-tests.patch", "tool-coverage.patch"])
        self.assertEqual(len(applied), len(set(applied)))

    def test_build_runs_coverage_proof_before_compilation_and_manifest(self):
        build_spec = importlib.util.spec_from_file_location("quiet_coverage_build", check.HERE / "build.py")
        build = importlib.util.module_from_spec(build_spec)
        with patch.dict(sys.modules, {"check": check}):
            build_spec.loader.exec_module(build)
        manifest = json.loads((check.HERE / "source.json").read_text())
        applied, stages = [], []

        def git(arguments, directory):
            if arguments[1] == "rev-parse":
                return manifest["commit"]
            if arguments[:2] == ["git", "apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""

        def cargo(arguments, **kwargs):
            if arguments[1] == "build":
                self.assertEqual(stages, ["red", "green", "stock", "aggregate-red", "aggregate-green", "aggregate-stock"])
                stages.append("build")
                return subprocess.CompletedProcess(arguments, 0)
            selectors = {"cmux_quiet_": 7, "cmux_attach_": 2 if "--bin" in arguments else 3,
                         "cmux_binding_": manifest["bindingTestCount"], "cmux_focus_": manifest["focusTestCount"],
                         "cmux_working_tip_": manifest["workingTipTestCount"],
                         "cmux_orchestration_": manifest["orchestrationTestCount"],
                         "cmux_resume_compat_": manifest["resumeCompatTestCount"],
                         "cmux_tool_coverage_": manifest["toolCoverageTestCount"],
                         "cmux_activity_summary_": manifest["aggregateTestCount"]}
            selector = next(key for key in selectors if key in arguments)
            implementation = {"cmux_focus_": "focus-mode.patch", "cmux_working_tip_": "working-tip.patch",
                              "cmux_orchestration_": "orchestration.patch", "cmux_resume_compat_": "resume-compat.patch",
                              "cmux_tool_coverage_": "tool-coverage.patch",
                              "cmux_activity_summary_": "aggregate.patch"}.get(selector)
            failed = int(implementation is not None and implementation not in applied)
            if selector == "cmux_tool_coverage_" and "aggregate.patch" not in applied:
                self.assertEqual(set(applied[:12]), set(manifest["patches"][:12]))
                self.assertEqual(applied[12], "tool-coverage-tests.patch")
                stages.append("red" if failed else "green" if "--features" in arguments else "stock")
            if selector == "cmux_activity_summary_":
                self.assertEqual(applied[14], "aggregate-tests.patch")
                stages.append("aggregate-red" if failed else "aggregate-green" if "--features" in arguments else "aggregate-stock")
            kwargs["stdout"].write(f"test result: {'FAILED' if failed else 'ok'}. {selectors[selector]-failed} passed; {failed} failed; 0 ignored;\n")
            return subprocess.CompletedProcess(arguments, failed)

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            target = source / "codex-rs/target/release"
            target.mkdir(parents=True)
            (target / "cmux-codex-quiet").write_bytes(b"compiler fixture")
            output = Path(directory) / "output"
            with patch("sys.argv", ["build.py", "--source", str(source), "--output", str(output)]), \
                    patch.dict("os.environ", {"CARGO_TARGET_DIR": str(target.parent)}), \
                    patch.object(build, "prepare_release_lock"), patch.object(build, "run", git), \
                    patch.object(check, "run", git), patch.object(build.subprocess, "run", cargo), \
                    patch.object(build.source_mtimes, "restore", return_value=0), \
                    patch.object(build.source_mtimes, "save", return_value=0), \
                    patch.object(build.platform, "system", return_value="Linux"), \
                    contextlib.redirect_stdout(io.StringIO()):
                build.main()
            produced = json.loads((output / "manifest.json").read_text())
        self.assertEqual(stages, ["red", "green", "stock", "aggregate-red", "aggregate-green", "aggregate-stock", "build"])
        self.assertEqual(applied[-4:-2], ["tool-coverage-tests.patch", "tool-coverage.patch"])
        self.assertEqual(len(applied), len(set(applied)))
        self.assertEqual(list(produced["patches"]), manifest["patches"])
        self.assertEqual(produced["toolCoverageTestCount"], manifest["toolCoverageTestCount"])

    def test_manifest_counts_all_dedicated_rust_fixtures(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        source = (check.HERE / "tool-coverage-tests.patch").read_text()
        count = len(re.findall(r'^\+\s*(?:async )?fn cmux_tool_coverage_\w+\(', source, re.M))
        self.assertEqual(count, manifest["toolCoverageTestCount"])


class AggregateProofTests(unittest.TestCase):
    def test_manifest_counts_all_rendered_fixtures(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        source = (check.HERE / "aggregate-tests.patch").read_text()
        count = len(re.findall(r'^\+\s*(?:async )?fn cmux_activity_summary_\w+\(', source, re.M))
        self.assertEqual(count, manifest["aggregateTestCount"])
        self.assertEqual(manifest["patches"][-2:], ["aggregate-tests.patch", "aggregate.patch"])

    def test_proof_requires_red_green_stock_then_prior_suite_controls(self):
        manifest = json.loads((check.HERE / "source.json").read_text())
        applied, stages = [], []
        def git(arguments, directory):
            if arguments[:2] == ["git", "apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""
        def tests(source, log, expected_count, **kwargs):
            if not stages:
                self.assertEqual(applied, ["aggregate-tests.patch"])
            else:
                self.assertEqual(applied, ["aggregate-tests.patch", "aggregate.patch"])
            stages.append((kwargs["selector"], kwargs["feature"], kwargs["should_fail"], expected_count))
        with tempfile.TemporaryDirectory() as directory, patch.object(check,"run",git), patch.object(check,"test",tests), contextlib.redirect_stdout(io.StringIO()):
            check.aggregate_proof(Path(directory),Path(directory),manifest)
        self.assertEqual(stages, [
            ("cmux_activity_summary_",True,True,manifest["aggregateTestCount"]),
            ("cmux_activity_summary_",True,False,manifest["aggregateTestCount"]),
            ("cmux_activity_summary_",False,False,manifest["aggregateTestCount"]),
            ("cmux_focus_",True,False,manifest["focusTestCount"]),
            ("cmux_tool_coverage_",True,False,manifest["toolCoverageTestCount"]),
            ("cmux_tool_coverage_",False,False,manifest["toolCoverageTestCount"]),
        ])

    def test_failed_discriminator_cannot_apply_aggregate_fix(self):
        applied=[]
        def git(arguments,directory):
            if arguments[:2] == ["git","apply"] and "--check" not in arguments:
                applied.append(Path(arguments[-1]).name)
            return ""
        with tempfile.TemporaryDirectory() as directory, patch.object(check,"run",git), patch.object(check,"test",side_effect=RuntimeError("missing regression")), self.assertRaises(RuntimeError):
            check.aggregate_proof(Path(directory),Path(directory),json.loads((check.HERE / "source.json").read_text()))
        self.assertEqual(applied,["aggregate-tests.patch"])


class OrchestrationBrokerFixtureTests(unittest.TestCase):
    """Execute the owned Python brokers embedded in the Rust fixtures, without Rust."""

    def script(self, name, **values):
        source = "\n".join(line[1:] for line in
                           (check.HERE / "orchestration-tests.patch").read_text().splitlines()
                           if line.startswith("+") and not line.startswith("+++"))
        script = re.search(rf'const {name}:&str=r#"(.*?)"#;', source, re.S).group(1)
        for key, value in values.items():
            script = script.replace(key, repr(value))
        return script

    def broker(self, drop_designated):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "broker.json"
            script = self.script("OWNED_BROKER_FIXTURE", SESSION="actual-thread",
                                 STABLE_ID="00000000-0000-4000-8000-000000000001",
                                 BROKER=str(state), DROP_DESIGNATED=drop_designated)
            envelope = {"caller_session_id": "actual-thread", "provider_turn_id": "turn-real",
                        "provider_call_id": "call-real", "request_id": "call-real",
                        "arguments": {"action": "start", "body": {
                            "request_id": "00000000-0000-4000-8000-000000000001",
                            "caller_session_id": "forged-thread"}}}
            replies = []
            # Same registration replay retains response ownership; another
            # frontend/native backend can forward but cannot take over replying.
            for registration in ("frontend-first", "frontend-second", "frontend-first"):
                outcome = subprocess.run(
                    ["python3", "-c", script, "--socket", "/fixture.sock", "task", "bridge",
                     "--scope-file", registration], input=json.dumps(envelope), text=True,
                    capture_output=True, timeout=5)
                expected_drop = drop_designated and registration == "frontend-first"
                self.assertEqual(outcome.returncode, int(expected_drop), outcome.stderr)
                replies.append(None if expected_drop else json.loads(outcome.stdout))
            recorded = json.loads(state.read_text())
            self.assertEqual(recorded["effects"], 1)
            self.assertEqual(recorded["forwards"], 3)
            self.assertEqual(recorded["key"], ["actual-thread", "turn-real", "call-real"])
            self.assertFalse(replies[1]["_cmux_should_respond"])
            if not drop_designated:
                self.assertTrue(replies[0].pop("_cmux_should_respond"))
                self.assertTrue(replies[2].pop("_cmux_should_respond"))
                replies[1].pop("_cmux_should_respond")
                self.assertEqual(replies[0], replies[1])
                self.assertEqual(replies[0], replies[2])

    def test_two_forwarders_keep_one_owned_responder_and_one_effect(self):
        self.broker(False)

    def test_designated_loss_does_not_transfer_response_ownership(self):
        self.broker(True)

    def test_registration_fixture_waits_for_binding_or_stays_closed(self):
        for failures in (2, 9):
            with self.subTest(failures=failures), tempfile.TemporaryDirectory() as directory:
                counter = Path(directory) / "reads"
                script = self.script("PANEL_RETRY_FIXTURE", WORKSPACE="workspace",
                                     SURFACE="surface", SESSION="session", PID="123",
                                     COUNTER=str(counter), FAILURES=failures)
                outcomes = []
                for _ in range(3):
                    outcome = subprocess.run(
                        ["python3", "-c", script, "--socket", "/fixture.sock", "task", "panel",
                         "--workspace", "workspace", "--surface", "surface", "--session", "session",
                         "--frontend-pid", "123", "--invocation", "fresh-invocation"],
                        text=True, capture_output=True, timeout=5)
                    outcomes.append(outcome.returncode)
                self.assertEqual(outcomes, [1, 1, int(failures > 2)])
                self.assertEqual(counter.read_text(), "3")
                if failures == 2:
                    self.assertEqual(json.loads(outcome.stdout), {
                        "snapshot_path": "/private/snapshot.json", "scope_file": "/private/scope.json"})

    def test_manifest_counts_all_rust_orchestration_fixtures(self):
        source = (check.HERE / "orchestration-tests.patch").read_text()
        count = len(re.findall(r'^\+\s*(?:async )?fn cmux_orchestration_\w+\(', source, re.M))
        manifest = json.loads((check.HERE / "source.json").read_text())
        self.assertEqual(count, manifest["orchestrationTestCount"])


if __name__ == "__main__":
    unittest.main()
