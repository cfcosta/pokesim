"""Python extension ownership and checked argument boundaries."""

from __future__ import annotations

import gc
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from battle_training.search_native import _library


class PyO3SearchTests(unittest.TestCase):
    def engine(self, **changes):
        arguments = {
            "actions": 2,
            "configs": [(0, 1, 2, 2, 2, 1, 1, 0)],
            "roots": [(10, 3, 3, 0, 0)],
            "evaluations": [0.5, 0.5, 0.5, 0.5, 0.25],
            "seeds": [7, 9],
        }
        return _library().Engine(**(arguments | changes))

    def test_owned_views_survive_mutation_close_and_collection(self):
        engine = self.engine()
        before = engine.node(0, True)
        stage, requests = engine.view()
        self.assertEqual(stage, 1)
        engine.steps([(11, 3, 3, 1, 0)] * len(requests))
        engine.values([0.9, -0.5, 0.9, -0.5, 0.1, 0.1, 0.1, 0.1])
        after = engine.node(0, True)
        engine.close()
        engine.close()
        del engine
        gc.collect()
        self.assertEqual(requests[0], (10, 0, 0, 7))
        self.assertEqual(after["payoff"], [[0.2, 0.2], [0.1, 0.1]])
        self.assertNotEqual(before["payoff"], after["payoff"])
        after["payoff"][0][0] = 999
        self.assertNotEqual(before["payoff"][0][0], 999)

    def test_closed_engine_rejects_all_access(self):
        engine = self.engine()
        engine.close()
        for method, args in [
            ("view", ()),
            ("node", (0,)),
            ("root", (0,)),
            ("steps", ([],)),
            ("values", ([],)),
            ("solutions", ([],)),
            ("evaluations", ([], [])),
        ]:
            with (
                self.subTest(method=method),
                self.assertRaisesRegex(RuntimeError, "closed"),
            ):
                getattr(engine, method)(*args)

    def test_invalid_phase_poisoning_is_preserved(self):
        engine = self.engine()
        with self.assertRaises(RuntimeError):
            engine.values([1.0])
        for method, args in [
            ("view", ()),
            ("node", (0,)),
            ("root", (0,)),
            ("steps", ([(11, 3, 3, 1, 0)] * 8,)),
        ]:
            with self.subTest(method=method), self.assertRaises(RuntimeError):
                getattr(engine, method)(*args)
        engine.close()

    def test_bad_python_arguments_cannot_corrupt_native_state(self):
        engine = self.engine()
        original = engine.view()
        for rows in [[(1, 2)], [(1, 2, 3, 0, -1)], [(2**64, 2, 3, 0, 0)]]:
            with (
                self.subTest(rows=rows),
                self.assertRaises((ValueError, TypeError, OverflowError)),
            ):
                engine.steps(rows)
            self.assertEqual(engine.view(), original)
        for value in [float("nan"), float("inf")]:
            with self.assertRaises(RuntimeError):
                self.engine(evaluations=[0.5, 0.5, 0.5, 0.5, value])
        engine.close()

    def test_installed_package_metadata_hashes_extension_binary(self):
        library_path = Path(_library().__file__).resolve()
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / "battle_search"
            package.mkdir()
            (package / "__init__.py").write_text("from .battle_search import *\n")
            (package / "battle_search.abi3.so").symlink_to(library_path)
            env = os.environ.copy()
            env.pop("BATTLE_SEARCH_LIB", None)
            env["PYTHONPATH"] = (
                temporary + os.pathsep + str(Path(__file__).resolve().parents[1])
            )
            process = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "from battle_training.search_native import orchestration_metadata; from pathlib import Path; import sys; m = orchestration_metadata('rust'); assert Path(m['library']).samefile(sys.argv[1]); assert m['bridge'] == 'pyo3'",
                    str(library_path),
                ],
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(process.returncode, 0, process.stderr)

    def test_explicit_non_extension_fails_without_build_or_fallback(self):
        env = os.environ | {"BATTLE_SEARCH_LIB": "/does/not/exist/libbattle_search.so"}
        process = subprocess.run(
            [
                sys.executable,
                "-c",
                """
from unittest.mock import patch
from battle_training.search_native import _library, NativeSearchError
with patch('subprocess.Popen', side_effect=AssertionError('runtime must not build')):
    try:
        _library()
    except NativeSearchError:
        pass
    else:
        raise AssertionError('silently fell back')
""",
            ],
            check=False,
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(process.returncode, 0, process.stderr)


if __name__ == "__main__":
    unittest.main()
