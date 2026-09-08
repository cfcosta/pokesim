from __future__ import annotations

import io
import subprocess
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.native import NativeRequestTimeout, SearchServer


class ProcessStub:
    def __init__(self, *, exited: bool = False, shutdown_timeout: bool = False):
        self.returncode = 0 if exited else None
        self.shutdown_timeout = shutdown_timeout
        self.waits = 0
        self.kills = 0
        self.terminations = 0
        self.reaped = False
        self.stdin = io.StringIO()
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        self.waits += 1
        if self.shutdown_timeout and self.returncode is None:
            raise subprocess.TimeoutExpired("test-server", timeout)
        self.returncode = 0 if self.returncode is None else self.returncode
        self.reaped = True
        return self.returncode

    def kill(self):
        self.kills += 1
        self.returncode = -9

    def terminate(self):
        self.terminations += 1
        self.returncode = -15


class NativeLifecycleTest(unittest.TestCase):
    @staticmethod
    def server(process: ProcessStub) -> SearchServer:
        server = SearchServer.__new__(SearchServer)
        server.process = process
        server._request = Mock(return_value={"ok": True})
        return server

    def assert_reaped_and_closed(self, process: ProcessStub) -> None:
        self.assertTrue(process.reaped)
        for stream in (process.stdin, process.stdout, process.stderr):
            self.assertTrue(stream.closed)

    def test_normal_close_is_idempotent_and_closes_all_streams_after_reaping(self):
        process = ProcessStub()
        server = self.server(process)
        original_wait = process.wait

        def wait(timeout=None):
            self.assertFalse(process.stdin.closed)
            self.assertFalse(process.stdout.closed)
            self.assertFalse(process.stderr.closed)
            return original_wait(timeout)

        with patch.object(process, "wait", side_effect=wait):
            server.close()
        self.assert_reaped_and_closed(process)
        server.close()
        server._request.assert_called_once_with("quit")
        self.assertEqual(process.kills, 0)

    def test_already_exited_child_still_closes_its_streams(self):
        process = ProcessStub(exited=True)
        server = self.server(process)
        server.close()
        server._request.assert_not_called()
        self.assert_reaped_and_closed(process)

    def test_shutdown_timeout_kills_reaps_and_closes(self):
        process = ProcessStub(shutdown_timeout=True)
        self.server(process).close()
        self.assertEqual(process.kills, 1)
        self.assertEqual(process.waits, 2)
        self.assert_reaped_and_closed(process)

    def test_invalid_shutdown_response_still_reaps_and_closes(self):
        process = ProcessStub()
        server = self.server(process)
        server._request.side_effect = ValueError("invalid shutdown response")
        with self.assertRaisesRegex(ValueError, "invalid shutdown response"):
            server.close()
        self.assert_reaped_and_closed(process)

    def test_request_timeout_closes_streams_without_requiring_context_exit(self):
        process = ProcessStub()
        server = SearchServer.__new__(SearchServer)
        server.process = process
        server._request_id = 0
        server._request_lock = threading.Lock()
        server.request_timeout = 0.001
        selector = Mock()
        selector.select.return_value = []
        with (
            patch(
                "battle_training.native.selectors.DefaultSelector",
                return_value=selector,
            ),
            self.assertRaises(NativeRequestTimeout),
        ):
            server._request("ping")
        self.assertEqual(process.kills, 1)
        selector.close.assert_called_once()
        self.assert_reaped_and_closed(process)
        server.close()

    def test_failed_handshake_reaps_and_closes_the_constructed_process(self):
        process = ProcessStub()
        with (
            patch("battle_training.native.subprocess.Popen", return_value=process),
            patch.object(
                SearchServer, "_request", side_effect=RuntimeError("handshake failed")
            ),
            self.assertRaisesRegex(RuntimeError, "handshake failed"),
        ):
            SearchServer()
        self.assertEqual(process.terminations, 1)
        self.assert_reaped_and_closed(process)

    def test_handshake_error_is_preserved_if_shutdown_also_fails(self):
        process = ProcessStub()
        with (
            patch("battle_training.native.subprocess.Popen", return_value=process),
            patch.object(
                SearchServer,
                "_request",
                side_effect=[ValueError("bad handshake"), ValueError("bad quit")],
            ),
            self.assertRaisesRegex(ValueError, "bad handshake"),
        ):
            SearchServer()
        self.assert_reaped_and_closed(process)

    def test_one_broken_pipe_on_close_does_not_leave_output_streams_open(self):
        process = ProcessStub(exited=True)
        process.stdin = Mock()
        process.stdin.closed = False
        process.stdin.close.side_effect = BrokenPipeError("child already exited")
        self.server(process).close()
        self.assertTrue(process.reaped)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)


if __name__ == "__main__":
    unittest.main()
