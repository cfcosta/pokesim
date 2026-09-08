#!/usr/bin/env python3
"""Run existing training tests with search and simulator transport in Rust.

Dedicated differential tests must run separately against unmodified Python.
This runner intentionally bypasses saved backend selection to exercise existing
collection, controller and arena consumers with the native implementation.
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/battle-training"))
from battle_training.joint_search import SimultaneousTreeSearch
from battle_training.native import SearchServer
from battle_training.search_native import RustSimultaneousTreeSearch


def filtered(suite):
    result = unittest.TestSuite()
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            result.addTest(filtered(test))
        elif not test.id().startswith(
            ("test_rust_search.", "test_simulator_transport.")
        ):
            result.addTest(test)
    return result


def main():
    suite = unittest.defaultTestLoader.discover(
        str(ROOT / "packages/battle-training/tests")
    )
    SimultaneousTreeSearch.search_many = classmethod(
        RustSimultaneousTreeSearch.search_many.__func__
    )
    original_init = SearchServer.__init__

    def rust_server(self, *args, **kwargs):
        kwargs["transport_backend"] = "rust"
        original_init(self, *args, **kwargs)

    SearchServer.__init__ = rust_server
    result = unittest.TextTestRunner(verbosity=1).run(filtered(suite))
    return not result.wasSuccessful()


if __name__ == "__main__":
    raise SystemExit(main())
