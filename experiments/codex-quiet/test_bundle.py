import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('quiet_bundle', ROOT / 'scripts/quiet_codex_bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BundleTests(unittest.TestCase):
    def test_reuses_only_a_complete_frontend_only_descendant(self):
        native, frontend = '1' * 40, '2' * 40
        comparison = dict(status='ahead', merge_base_commit={'sha': native},
                          files=[{'filename': 'experiments/codex-quiet/orchestration.patch'}])
        bundle.validate_native_reuse(native, frontend, comparison)
        bundle.validate_native_reuse(native, native, {})
        for changed in [dict(status='diverged'), dict(merge_base_commit={'sha': frontend}),
                        dict(files=[{'filename': 'CLI/cmux.swift'}]),
                        dict(files=[{'filename': 'experiments/codex-quiet/new.patch', 'previous_filename': 'Sources/AppDelegate.swift'}]),
                        dict(files=[{'filename': 'experiments/codex-quiet/../../Sources/AppDelegate.swift'}]),
                        dict(files=[{'filename': 'experiments/codex-quiet/a.patch'}] * 300),
                        dict(files=None)]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                bundle.validate_native_reuse(native, frontend, dict(comparison, **changed))

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.artifact = Path(self.directory.name) / 'artifact'
        self.artifact.mkdir()
        (self.artifact / 'cmux-codex-quiet').write_bytes(b'fake signed binary fixture')
        (self.artifact / 'LICENSE').write_text('fixture license')
        self.manifest = dict(json.loads((bundle.PROOF / 'source.json').read_text()),
            platform='Darwin', architecture='arm64', attach_only=True,
            binary_sha256=hashlib.sha256((self.artifact / 'cmux-codex-quiet').read_bytes()).hexdigest(),
            patches={name: hashlib.sha256((bundle.PROOF / name).read_bytes()).hexdigest()
                     for name in json.loads((bundle.PROOF / 'source.json').read_text())['patches']})
        self.write_manifest()

    def write_manifest(self):
        (self.artifact / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_checks_pinned_provenance_and_binary_bytes(self):
        self.assertEqual(bundle.validate_artifact(self.artifact).name, 'cmux-codex-quiet')
        for key, value in [('commit', 'other'), ('platform', 'Linux'), ('architecture', 'x86_64'),
                           ('attach_only', False), ('patches', {}), ('binary_sha256', 'bad')]:
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = value
                self.write_manifest()
                with self.assertRaises(ValueError): bundle.validate_artifact(self.artifact)
                self.manifest[key] = original
        self.write_manifest()
        (self.artifact / 'cmux-codex-quiet').write_bytes(b'tampered')
        with self.assertRaises(ValueError): bundle.validate_artifact(self.artifact)

    def test_stages_only_after_native_verification(self):
        resources = Path(self.directory.name) / 'candidate/Contents/Resources'
        observed = []
        bundle.stage_artifact(self.artifact, resources, verify_binary=lambda path: observed.append(path))
        self.assertEqual(observed, [self.artifact / 'cmux-codex-quiet'])
        self.assertTrue((resources / 'bin/cmux-codex-quiet').stat().st_mode & 0o111)
        self.assertEqual((resources / 'licenses/codex-quiet/LICENSE').read_text(), 'fixture license')

    def test_rejects_linked_executable(self):
        binary = self.artifact / 'cmux-codex-quiet'
        binary.unlink()
        binary.symlink_to(self.artifact / 'LICENSE')
        with self.assertRaises(ValueError): bundle.validate_artifact(self.artifact)


if __name__ == '__main__': unittest.main()
