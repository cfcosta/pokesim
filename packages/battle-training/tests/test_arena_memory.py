from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.arena import (
    ArenaConfig,
    _run_fast_arena_games,
    _run_traced_arena_batched,
)


class _Captured(Exception):
    pass


class ArenaMemoryTests(unittest.TestCase):
    def test_evaluation_dispatch_bounds_live_searches_and_preserves_every_pair(self):
        for games in [4, 288, 2048]:
            for processes in [1, 4, 12]:
                for traced in [False, True]:
                    with self.subTest(games=games, processes=processes, traced=traced):
                        test = self

                        class Pool:
                            def __init__(self, processes):
                                self.processes = processes

                            def check(self, spans, test=test, games=games):
                                test.assertLessEqual(
                                    max(end - start for start, end in spans), 16
                                )
                                test.assertEqual(
                                    [
                                        g
                                        for start, end in spans
                                        for g in range(start, end)
                                    ],
                                    list(range(games)),
                                )
                                test.assertTrue(
                                    all(
                                        start % 2 == end % 2 == 0
                                        for start, end in spans
                                    )
                                )
                                raise _Captured

                            def run_fast(
                                self, config, campaign, spans, capture_details, **kwargs
                            ):
                                self.check(spans)

                            def run_traced(self, config, replay_dir, spans, **kwargs):
                                self.check(spans)

                        with self.assertRaises(_Captured):
                            if traced:
                                _run_traced_arena_batched(
                                    None,
                                    None,
                                    ArenaConfig(games=games),
                                    None,
                                    pool=Pool(processes),
                                )
                            else:
                                _run_fast_arena_games(
                                    None,
                                    None,
                                    ArenaConfig(games=games),
                                    False,
                                    pool=Pool(processes),
                                )


if __name__ == "__main__":
    unittest.main()
