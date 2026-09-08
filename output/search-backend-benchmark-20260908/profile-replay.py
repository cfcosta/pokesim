"""Profile replay-only calls in the benchmark, outside primary timing cohorts."""

import cProfile
import importlib.util
import pstats
from pathlib import Path

root = Path.cwd()
spec = importlib.util.spec_from_file_location(
    "bench", root / "tools/benchmark-search-backends.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mode = ""
counts = {}
original_reset = m.Services.reset
original_search = m.search_controllers_many
out = root / "output/search-backend-benchmark-20260908"


def reset(self, value):
    global mode
    mode = value
    return original_reset(self, value)


def search(templates, roots, **kwargs):
    backend = templates[0].config.orchestration_backend
    if mode != "replay":
        return original_search(templates, roots, **kwargs)
    counts[backend] = counts.get(backend, 0) + 1
    if counts[backend] != 2:
        return original_search(templates, roots, **kwargs)
    profile = cProfile.Profile()
    profile.enable()
    try:
        return original_search(templates, roots, **kwargs)
    finally:
        profile.disable()
        with (out / ("replay-" + backend + ".profile.txt")).open("w") as f:
            pstats.Stats(profile, stream=f).strip_dirs().sort_stats(
                "cumulative"
            ).print_stats(45)


# cProfile on this Python build also observes the sampler thread. Suppress
# sampling only in this diagnostic cohort so cumulative call trees stay useful.
# Its RSS fields are consequently zero and are not used for memory conclusions.
m.MemorySampler.__enter__ = lambda self: self
m.MemorySampler.__exit__ = lambda self, *_: None
m.Services.reset = reset
m.search_controllers_many = search
m.main()
