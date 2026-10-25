#!/usr/bin/env python3
"""Behavioral checks for the opt-in shared-server observer experiment."""
import importlib.util
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location(
    "observer", Path(__file__).resolve().parents[1]/"scripts/codex-shared-observer.py")
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class ObserverTests(unittest.TestCase):
    def make_cmux(self):
        cmux = observer.Cmux("cmux", "/tmp/test.sock", "surface", "workspace", 1234)
        calls = []
        def rpc(method, params):
            calls.append((method, params))
            if method == "system.top":
                return {"processes": [{"pid": 1234, "cmux_surface_id": "surface", "cmux_workspace_id": "workspace"}]}
            if method == "agent.message.claim":
                return {"lease_id": "lease", "text": "[cmux agent message] review please"}
            return {}
        cmux.rpc = rpc
        return cmux, calls

    def test_attention_does_not_confuse_waiting_with_work(self):
        self.assertEqual(observer.attention({"type": "active", "activeFlags": []}), "working")
        self.assertEqual(observer.attention({"type": "active", "activeFlags": ["waitingOnApproval"]}), "permission")
        self.assertEqual(observer.attention({"type": "active", "activeFlags": ["waitingOnUserInput"]}), "question")
        self.assertEqual(observer.attention({"type": "notLoaded"}), "notLoaded")

    def test_observer_cannot_resume_or_start_threads(self):
        reader = object.__new__(observer.CodexReader)
        for method in ["thread/resume", "thread/start", "turn/start", "turn/interrupt"]:
            with self.assertRaises(ValueError):
                reader.call(method, {})

    def test_only_exact_ids_are_accepted(self):
        with self.assertRaises(ValueError):
            observer.identifier("project name")

    def test_success_queues_exact_thread_then_acknowledges_lease(self):
        cmux, calls = self.make_cmux()
        submitted = []
        def run(args, **kwargs):
            submitted.append(args)
            return subprocess.CompletedProcess(args, 0)
        self.assertTrue(cmux.deliver("codex", "thread-exact", {"status": "current", "queued": 1}, run))
        self.assertEqual(submitted[0][1:4], ["queue", "--thread", "thread-exact"])
        self.assertEqual([x[0] for x in calls], ["system.top", "agent.message.claim", "agent.message.ack"])
        self.assertEqual(calls[-1][1]["lease_id"], "lease")

    def test_failed_queue_never_acknowledges_delivery(self):
        cmux, calls = self.make_cmux()
        def fail(args, **kwargs):
            return subprocess.CompletedProcess(args, 1)
        with self.assertRaises(RuntimeError):
            cmux.deliver("codex", "exact", {"status": "current", "queued": 1}, fail)
        self.assertEqual([x[0] for x in calls], ["system.top", "agent.message.claim"])

    def test_timeout_does_not_retry_or_acknowledge(self):
        cmux, calls = self.make_cmux()
        attempts = []
        def fail(args, **kwargs):
            attempts.append(args)
            raise subprocess.TimeoutExpired(args, 15)
        with self.assertRaises(subprocess.TimeoutExpired):
            cmux.deliver("codex", "exact", {"status": "current", "queued": 1}, fail)
        self.assertEqual(len(attempts), 1)
        self.assertEqual([x[0] for x in calls], ["system.top", "agent.message.claim"])

    def test_held_and_superseded_messages_are_not_claimed(self):
        for poll in [{"status": "current", "queued": 1, "held": True},
                     {"status": "superseded", "queued": 1},
                     {"status": "current", "queued": 0}]:
            cmux, calls = self.make_cmux()
            self.assertFalse(cmux.deliver("codex", "exact", poll))
            self.assertEqual(calls, [])

    def test_missing_surface_stops_delivery(self):
        cmux, _ = self.make_cmux()
        cmux.command = lambda *args: '{"surfaces":[{"id":"different","type":"terminal"}]}'
        with self.assertRaises(RuntimeError):
            cmux.validate_surface()

    def test_another_terminals_process_cannot_receive_messages(self):
        cmux, calls = self.make_cmux()
        cmux.rpc = lambda method, params: {"processes": [{"pid": 1234, "cmux_surface_id": "other", "cmux_workspace_id": "workspace"}]}
        with self.assertRaises(RuntimeError):
            cmux.deliver("codex", "exact", {"status": "current", "queued": 1})


if __name__ == "__main__":
    unittest.main()
