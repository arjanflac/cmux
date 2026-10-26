"""Exercise busy-process cleanup only on the isolated GitHub churn fixture."""
import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('churn_cleanup_fixture', Path(__file__).with_name('test_workspace_churn_up_arrow_lag.py'))
churn = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = churn
spec.loader.exec_module(churn)


class BusyFixture:
    def __init__(self, socket_path):
        self.socket_path = socket_path
        self.rows = [(0, 'keep', 'Baseline', True), (1, 'busy', 'Prior fixture', False)]
        self.closed = []

    def list_workspaces(self):
        return list(self.rows)

    def select_workspace(self, _workspace):
        pass

    def close_workspace(self, workspace, force=False):
        if not force:
            raise churn.cmuxError('Workspace has a running process; retry with --force')
        self.closed.append(workspace)
        self.rows = [row for row in self.rows if row[1] != workspace]


class ChurnFixtureCleanupTests(unittest.TestCase):
    def test_busy_isolated_github_fixture_can_reach_measurement(self):
        client = BusyFixture('/tmp/cmux-debug-ci-lag.sock')
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}):
            self.assertEqual(churn.keep_only_first_workspace(client), 'keep')
        self.assertEqual(client.closed, ['busy'])
        self.assertEqual([row[1] for row in client.rows], ['keep'])

    def test_other_sockets_and_local_runs_retain_busy_process_protection(self):
        for socket_path, github in [('/tmp/cmux-debug-workspace-icons.sock', 'true'),
                                    ('/tmp/cmux-debug-ci-lag.sock', 'false')]:
            with self.subTest(socket_path=socket_path, github=github):
                client = BusyFixture(socket_path)
                with patch.dict(os.environ, {'GITHUB_ACTIONS': github}), self.assertRaises(churn.cmuxError):
                    churn.keep_only_first_workspace(client)
                self.assertEqual(client.closed, [])


if __name__ == '__main__':
    unittest.main()
