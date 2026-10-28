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


class TerminalFixture:
    def __init__(self, panels, focused):
        self.panels = list(panels)
        self.focused = focused
        self.responder = None
        self.created = []
        self.focus_attempts = 0
        self.activated = False

    def list_surfaces(self):
        return [(i, sid, sid == self.focused) for i, (sid, _kind) in enumerate(self.panels)]

    def surface_health(self):
        return [{"index": i, "id": sid, "type": kind} for i, (sid, kind) in enumerate(self.panels)]

    def new_surface(self, *, panel_type):
        if panel_type != "terminal":
            raise AssertionError("latency fixture must create a terminal")
        sid = "new-terminal"
        self.panels.append((sid, panel_type))
        self.created.append(sid)
        return sid

    def activate_app(self):
        self.activated = True

    def focus_surface(self, surface):
        sid = self.panels[surface][0] if isinstance(surface, int) else surface
        if dict(self.panels).get(sid) != "terminal":
            raise churn.cmuxError("Panel is not a terminal")
        self.focused = sid
        self.focus_attempts += 1
        # The first focus can precede the attached Ghostty view's responder.
        if self.activated and self.focus_attempts >= 2:
            self.responder = sid

    def is_terminal_focused(self, panel):
        return self.responder == panel


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


class ChurnTerminalReadinessTests(unittest.TestCase):
    def test_focused_chief_does_not_masquerade_as_terminal(self):
        client = TerminalFixture([("chief", "chief"), ("shell", "terminal")], "chief")
        self.assertEqual(churn.focused_terminal_panel(client), "shell")
        self.assertTrue(client.is_terminal_focused("shell"))
        self.assertEqual(client.created, [])

    def test_nonterminal_workspace_gets_one_explicit_terminal(self):
        client = TerminalFixture([("browser", "browser")], "browser")
        self.assertEqual(churn.focused_terminal_panel(client), "new-terminal")
        self.assertEqual(client.created, ["new-terminal"])
        self.assertTrue(client.is_terminal_focused("new-terminal"))

    def test_model_focus_waits_for_actual_terminal_responder(self):
        client = TerminalFixture([("shell", "terminal")], "shell")
        self.assertEqual(churn.focused_terminal_panel(client), "shell")
        self.assertTrue(client.is_terminal_focused("shell"))
        self.assertEqual(client.created, [])


if __name__ == '__main__':
    unittest.main()
