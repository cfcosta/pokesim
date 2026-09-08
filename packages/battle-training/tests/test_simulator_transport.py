from __future__ import annotations

import base64
import gc
import json
import os
import subprocess
import sys
import threading
import time
import unittest
from dataclasses import fields
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from battle_training.native import NativeRequestTimeout, SearchServer, Snapshot
from battle_training.simulator_transport import TransportTimeout, batch, decode, library


def row(**changes):
    value = {
        "handle": 2,
        "player_features": [0, 65535, 42],
        "enemy_features": [3, 2, 1],
        "player_mask": 3,
        "enemy_mask": 1024,
        "player_hash": "abc",
        "enemy_hash": "def",
        "turn": 9,
        "terminal": False,
        "done": False,
        "request": "mimic-player",
        "divergence": None,
        "player_popular": True,
        "enemy_popular": False,
    }
    value["return"] = None
    value.update(changes)
    return value


def payload(rows, **changes):
    value = {"id": "7", "ok": True, "snapshots": rows}
    value.update(changes)
    return json.dumps(value).encode() + b"\n"


class TransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        library()  # Required; a missing build must not silently skip coverage.

    def assert_snapshot_equal(self, left, right):
        for field in fields(Snapshot):
            a, b = getattr(left, field.name), getattr(right, field.name)
            if isinstance(a, np.ndarray):
                np.testing.assert_array_equal(a, b)
                self.assertEqual(a.dtype, b.dtype)
                self.assertFalse(b.flags.writeable)
            else:
                self.assertEqual(a, b, field.name)

    def test_both_feature_encodings_and_snapshot_fields_match_python(self):
        examples = [
            row(),
            row(done=True, terminal=True, divergence='雪\n"reason"', **{"return": -1}),
        ]
        packed = row(feature_encoding="u16le-base64")
        for side in ["player", "enemy"]:
            packed[side + "_features"] = base64.b64encode(
                np.array(packed[side + "_features"], dtype="<u2").tobytes()
            ).decode()
        examples.append(packed)
        decoded = decode(payload(examples), 7, len(examples), 3)
        for a, b in zip(examples, decoded):
            self.assert_snapshot_equal(Snapshot.from_response(a), b)
        gc.collect()  # Rust batch has already been freed; views must retain data.
        np.testing.assert_array_equal(decoded[-1].player_features, [0, 65535, 42])
        with self.assertRaises(ValueError):
            decoded[-1].player_features.setflags(write=True)

    def test_missing_optional_fields_and_large_legacy_values(self):
        value = row(player_features=[2**40, -1, 5])
        for name in ["divergence", "player_popular", "enemy_popular"]:
            del value[name]
        self.assert_snapshot_equal(
            Snapshot.from_response(value), decode(payload([value]), 7, 1, 3)[0]
        )

    def test_empty_divergence_remains_distinct_from_none(self):
        result = decode(payload([row(divergence="")]), 7, 1, 3)[0]
        self.assertEqual(result.divergence, "")

    def test_json_escaped_base64_has_the_same_decoded_features(self):
        data = payload(
            [
                row(
                    feature_encoding="u16le-base64",
                    player_features="AAAAAAAA",
                    enemy_features="AAAAAAAA",
                )
            ]
        )
        escaped = data.replace(b'"AAAAAAAA"', b'"\\u0041AAAAAAA"')
        expected = Snapshot.from_response(json.loads(escaped)["snapshots"][0])
        self.assert_snapshot_equal(expected, decode(escaped, 7, 1, 3)[0])

    def test_errors_are_reported_without_partial_results(self):
        cases = [
            (b"{", "invalid native response"),
            (payload([row()], id="8"), "ID mismatch"),
            (payload([], ok=False, error="bad handle"), "bad handle"),
            (payload([]), "length mismatch"),
            (payload([row(player_features=[1])]), "feature count"),
            (payload([row(feature_encoding="other")]), "unsupported"),
            (
                payload([row(feature_encoding="u16le-base64", player_features="@@@@")]),
                "packed",
            ),
            (
                payload([row(feature_encoding="u16le-base64", player_features="AA==")]),
                "odd byte",
            ),
        ]
        for data, message in cases:
            with (
                self.subTest(message=message),
                self.assertRaisesRegex(RuntimeError, message),
            ):
                decode(data, 7, 1, 3)

    def test_missing_required_return_is_rejected(self):
        value = row()
        del value["return"]
        with self.assertRaisesRegex(RuntimeError, "return"):
            decode(payload([value]), 7, 1, 3)

    def exchange(self, response, *, delay=0, episode=False, requests=None):
        read_request, write_request = os.pipe()
        read_response, write_response = os.pipe()
        commands, errors = [], []

        def server():
            try:
                with os.fdopen(read_request, "rb") as source:
                    commands.append(source.readline())
                for part in response:
                    if delay:
                        time.sleep(delay)
                    os.write(write_response, part)
            except BrokenPipeError:
                pass
            except OSError as error:
                errors.append(error)
            finally:
                os.close(write_response)

        worker = threading.Thread(target=server)
        worker.start()
        try:
            result = batch(
                write_request,
                read_response,
                7,
                episode,
                requests or [(1, 2, 3, 2**64 - 1)],
                3,
                0.05 if delay else 2,
            )
            return commands, result
        finally:
            os.close(write_request)
            os.close(read_response)
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertFalse(errors, errors)

    def test_fragmented_response_and_unsigned_seed_wire(self):
        data = payload([row()])
        commands, result = self.exchange([data[:13], data[13:101], data[101:]])
        self.assertEqual(commands, [b"batch|7|1,2,3,18446744073709551615\n"])
        self.assert_snapshot_equal(Snapshot.from_response(row()), result[0])

    def test_episode_batch_uses_zero_seed_and_preserves_order(self):
        commands, result = self.exchange(
            [payload([row(handle=4), row(handle=3)])],
            episode=True,
            requests=[(9, 2, 1, 8), (7, 1, 0, 9)],
        )
        self.assertEqual(commands, [b"batch-episode|7|9,2,1,0;7,1,0,0\n"])
        self.assertEqual([s.handle for s in result], [4, 3])

    def test_deadline_covers_partial_response_after_initial_readiness(self):
        start = time.monotonic()
        with self.assertRaises(TransportTimeout):
            self.exchange([b"{", b'"unfinished"'], delay=0.035)
        self.assertLess(time.monotonic() - start, 0.3)

    def test_eof_and_truncated_json_fail(self):
        with self.assertRaisesRegex(RuntimeError, "EOF"):
            self.exchange([b"{"])
        with self.assertRaisesRegex(RuntimeError, "invalid native response"):
            self.exchange([b"{\n"])

    def test_write_deadline_when_child_does_not_read(self):
        r, w = os.pipe()
        rr, ww = os.pipe()
        try:
            with self.assertRaises(TransportTimeout):
                batch(w, rr, 7, False, [(1, 2, 3, 4)] * 10000, 3, 0.02)
        finally:
            for fd in (r, w, rr, ww):
                os.close(fd)

    def test_timeout_kills_and_reaps_real_child_and_closes_streams(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(20)"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        server = SearchServer.__new__(SearchServer)
        server.process = process
        server._request_lock = threading.Lock()
        server._request_id = 0
        server.request_timeout = 0.03
        server.feature_count = 3
        try:
            with self.assertRaises(NativeRequestTimeout):
                server._rust_batch([(1, 0, 0, 0)], episode=False)
            self.assertIsNotNone(process.poll())
            self.assertTrue(
                all(s.closed for s in (process.stdin, process.stdout, process.stderr))
            )
        finally:
            server.close()

    def test_real_lean_interleaving_search_episode_inspection_and_compaction(self):
        with (
            SearchServer(transport_backend="python") as python,
            SearchServer(transport_backend="rust") as rust,
        ):
            roots = [s.reset(98765, 2, 2, 2, level100=True) for s in (python, rust)]
            self.assert_snapshot_equal(*roots)
            for _ in range(4):
                actions = [
                    (mask & -mask).bit_length() - 1
                    for mask in (roots[0].player_mask, roots[0].enemy_mask)
                ]
                calls = [
                    [(root.handle, *actions, seed) for seed in [0, 1, 2, 2]]
                    for root in roots
                ]
                left, right = [s.search_steps(c) for s, c in zip((python, rust), calls)]
                for a, b in zip(left, right):
                    self.assert_snapshot_equal(a, b)
                self.assertIs(right[2], right[3])
                roots = [
                    s.episode_step(root.handle, *actions)
                    for s, root in zip((python, rust), roots)
                ]
                self.assert_snapshot_equal(*roots)
                self.assertEqual(
                    python.inspect(roots[0].handle), rust.inspect(roots[1].handle)
                )
                roots = [s.compact(root) for s, root in zip((python, rust), roots)]
                if roots[0].done:
                    break
            self.assertEqual(python.search_rows_requested, rust.search_rows_requested)
            self.assertEqual(
                python.search_rows_deduplicated, rust.search_rows_deduplicated
            )

    def test_protocol_failure_reaps_child_even_if_it_keeps_running(self):
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys,time; sys.stdin.readline(); print('{}',flush=True); time.sleep(20)",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        server = SearchServer.__new__(SearchServer)
        server.process = process
        server._request_lock = threading.Lock()
        server._request_id = 0
        server.request_timeout = 2
        server.feature_count = 3
        try:
            with self.assertRaisesRegex(RuntimeError, "invalid native response"):
                server._rust_batch([(0, 0, 0, 0)], episode=False)
            self.assertIsNotNone(process.poll())
            self.assertTrue(
                all(s.closed for s in (process.stdin, process.stdout, process.stderr))
            )
        finally:
            server.close()

    def test_stale_rust_library_fails_before_spawning_simulator(self):
        with (
            patch(
                "battle_training.simulator_transport.library",
                side_effect=RuntimeError("stale library"),
            ),
            patch("battle_training.native.subprocess.Popen") as spawn,
            self.assertRaisesRegex(RuntimeError, "stale library"),
        ):
            SearchServer(transport_backend="rust")
        spawn.assert_not_called()

    def test_rust_batches_bypass_python_json_and_base64_decoders(self):
        with SearchServer(transport_backend="rust") as server:
            root = server.reset(1, 0, 1, 1)
            p = (root.player_mask & -root.player_mask).bit_length() - 1
            e = (root.enemy_mask & -root.enemy_mask).bit_length() - 1
            with (
                patch(
                    "battle_training.native.json.loads",
                    side_effect=AssertionError("Python JSON"),
                ),
                patch(
                    "battle_training.native.base64.b64decode",
                    side_effect=AssertionError("Python base64"),
                ),
            ):
                self.assertEqual(len(server.search_steps([(root.handle, p, e, 0)])), 1)
                self.assertEqual(len(server.episode_steps([(root.handle, p, e)])), 1)


if __name__ == "__main__":
    unittest.main()
