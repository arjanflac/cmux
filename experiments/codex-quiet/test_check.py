"""Exercise the dependency gate without compiling Rust or resolving dependencies."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
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


if __name__ == "__main__":
    unittest.main()
