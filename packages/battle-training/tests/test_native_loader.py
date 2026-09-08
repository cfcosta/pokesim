from __future__ import annotations

import ctypes
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training import rmplus_native


class NativeLibraryCompatibilityTest(unittest.TestCase):
    @staticmethod
    def library(*, anchored: bool = True):
        library = SimpleNamespace(
            battle_rmplus_solve_cold_v1=SimpleNamespace(),
            battle_rmplus_solve_warm_v1=SimpleNamespace(),
        )
        if anchored:
            library.battle_rmplus_solve_anchored_v1 = SimpleNamespace()
        return library

    def test_incompatible_installed_library_is_skipped_for_compatible_local_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            stale = Path(temporary) / "installed.so"
            current = Path(temporary) / "local-build.so"
            stale.touch()
            current.touch()
            incompatible = self.library(anchored=False)
            compatible = self.library()
            with (
                mock.patch.object(
                    rmplus_native, "_library_candidates", return_value=[stale, current]
                ),
                mock.patch.object(
                    rmplus_native.ctypes, "CDLL", side_effect=[incompatible, compatible]
                ) as opened,
            ):
                library, path = rmplus_native._load_library()
            self.assertIs(library, compatible)
            self.assertEqual(path, current.resolve())
            self.assertEqual(
                opened.call_args_list, [mock.call(str(stale)), mock.call(str(current))]
            )
            self.assertIs(
                library.battle_rmplus_solve_anchored_v1.restype, ctypes.c_int32
            )
            self.assertEqual(len(library.battle_rmplus_solve_anchored_v1.argtypes), 14)

    def test_exhausted_candidates_report_path_and_missing_abi_symbol(self):
        with tempfile.TemporaryDirectory() as temporary:
            stale = Path(temporary) / "old-library.so"
            stale.touch()
            with (
                mock.patch.object(
                    rmplus_native, "_library_candidates", return_value=[stale]
                ),
                mock.patch.object(
                    rmplus_native.ctypes,
                    "CDLL",
                    return_value=self.library(anchored=False),
                ),
                self.assertRaises(rmplus_native.NativeRmplusError) as raised,
            ):
                rmplus_native._load_library()
            message = str(raised.exception)
            self.assertIn(str(stale), message)
            self.assertIn("incompatible ABI", message)
            self.assertIn("battle_rmplus_solve_anchored_v1", message)


if __name__ == "__main__":
    unittest.main()
