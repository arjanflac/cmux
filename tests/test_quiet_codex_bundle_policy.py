"""Verify native/frontend artifact pairings without compiling or running either app."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('quiet_bundle_policy', ROOT / 'scripts/quiet_codex_bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class NativeReuseTests(unittest.TestCase):
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


class FreshNativeFrontendTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name)
        self.git('init', '--quiet')
        for path, content in {
            'experiments/codex-quiet/source.json': '{"release": "pinned"}',
            'experiments/codex-quiet/build.py': '# compiled frontend input',
            '.github/workflows/quiet-codex-proof.yml': 'name: rendering proof',
            '.github/workflows/quiet-codex-frontend.yml': 'name: derived frontend',
            'scripts/select-ci-xcode.sh': '# pinned SDK selector',
            '.xcode-version': '27.0',
            'scripts/ci/xcode-pins.txt': '26 27.0',
            'Sources/Native.swift': '// original native input',
        }.items():
            file = self.source / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        self.frontend = self.commit()

    def git(self, *arguments):
        return subprocess.check_output([
            'git', '-c', 'user.name=Bundle fixture', '-c', 'user.email=fixture@example.invalid',
            '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', *arguments,
        ], cwd=self.source, text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '--quiet', '--allow-empty', '-m', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def test_same_commit_and_fresh_native_only_changes_use_identical_frontend(self):
        bundle.validate_fresh_native_frontend(self.frontend, self.frontend, self.source)
        (self.source / 'Sources/Native.swift').write_text('// new native behavior')
        native = self.commit()
        self.assertNotEqual(native, self.frontend)
        bundle.validate_fresh_native_frontend(native, self.frontend, self.source)
        # Comparing Git objects, not dirty worktree files, preserves immutable provenance.
        (self.source / 'experiments/codex-quiet/build.py').write_text('# uncommitted change')
        bundle.validate_fresh_native_frontend(native, self.frontend, self.source)

    def test_frontend_tree_and_both_workflows_must_match(self):
        for path in ['experiments/codex-quiet/source.json',
                     'experiments/codex-quiet/build.py',
                     '.github/workflows/quiet-codex-proof.yml',
                     '.github/workflows/quiet-codex-frontend.yml',
                     'scripts/select-ci-xcode.sh',
                     '.xcode-version',
                     'scripts/ci/xcode-pins.txt']:
            with self.subTest(path=path):
                self.git('reset', '--hard', self.frontend)
                (self.source / path).write_text('changed frontend input')
                with self.assertRaisesRegex(ValueError, 'Frontend build inputs changed'):
                    bundle.validate_fresh_native_frontend(self.commit(), self.frontend, self.source)

    def test_missing_input_or_wrong_git_object_type_fails_closed(self):
        for path in ['experiments/codex-quiet/build.py',
                     '.github/workflows/quiet-codex-proof.yml',
                     '.github/workflows/quiet-codex-frontend.yml',
                     'scripts/select-ci-xcode.sh',
                     '.xcode-version',
                     'scripts/ci/xcode-pins.txt']:
            with self.subTest(path=path):
                self.git('reset', '--hard', self.frontend)
                (self.source / path).unlink()
                with self.assertRaises(ValueError):
                    bundle.validate_fresh_native_frontend(self.commit(), self.frontend, self.source)
        tree = self.git('rev-parse', self.frontend + '^{tree}')
        with self.assertRaisesRegex(ValueError, 'must name a commit'):
            bundle.validate_fresh_native_frontend(tree, self.frontend, self.source)

    def test_unknown_or_mutable_source_identities_are_rejected(self):
        for identity in ['HEAD', '1' * 39, '1' * 41, 'G' * 40, '0' * 40, None]:
            with self.subTest(identity=identity):
                with self.assertRaises(ValueError):
                    bundle.validate_fresh_native_frontend(identity, self.frontend, self.source)
                with self.assertRaises(ValueError):
                    bundle.validate_fresh_native_frontend(self.frontend, identity, self.source)

    def test_linked_workflow_is_not_a_regular_frontend_build_input(self):
        path = self.source / '.github/workflows/quiet-codex-proof.yml'
        path.unlink()
        path.symlink_to('quiet-codex-frontend.yml')
        native = self.commit()
        with self.assertRaisesRegex(ValueError, 'Invalid frontend build input'):
            bundle.validate_fresh_native_frontend(native, native, self.source)


if __name__ == '__main__': unittest.main()
