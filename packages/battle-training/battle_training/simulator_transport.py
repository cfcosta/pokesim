"""PyO3 batch I/O and decoding for the unchanged Lean simulator.

Rust releases the GIL during I/O and decoding. Python retains process lifecycle,
lineage dedup and Snapshot objects. NumPy views share immutable Python bytes;
no raw native pointers or manual frees cross this boundary.
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np


@lru_cache(maxsize=1)
def library():
    from .search_native import _library

    lib = _library()
    if getattr(lib, "TRANSPORT_API_VERSION", None) != 1:
        raise RuntimeError(
            "Rust library lacks compatible simulator transport; rebuild battle-search"
        )
    return lib


class TransportTimeout(RuntimeError):
    pass


def unpack(decoded):
    from .native import Snapshot

    features, rows = decoded
    snapshots = []
    for row in rows:
        dtype = np.dtype("<u2" if row.feature_kind else "<i8")

        def array(span, dtype=dtype):
            offset, length = span
            return np.frombuffer(
                features, dtype=dtype, count=length // dtype.itemsize, offset=offset
            )

        snapshots.append(
            Snapshot(
                handle=row.handle,
                player_features=array(row.player_features),
                enemy_features=array(row.enemy_features),
                player_mask=row.player_mask,
                enemy_mask=row.enemy_mask,
                player_hash=row.player_hash,
                enemy_hash=row.enemy_hash,
                turn=row.turn,
                terminal=row.terminal,
                done=row.done,
                terminal_return=row.terminal_return,
                request=row.request,
                divergence=row.divergence,
                player_popular=row.player_popular,
                enemy_popular=row.enemy_popular,
            )
        )
    return snapshots


def batch(input_fd, output_fd, request_id, episode, requests, feature_count, timeout):
    try:
        decoded = library().batch(
            input_fd, output_fd, request_id, episode, requests, feature_count, timeout
        )
    except TimeoutError as error:
        raise TransportTimeout(str(error)) from error
    return unpack(decoded)


def decode(data: bytes, request_id: int, count: int, feature_count: int):
    """Decode-only entrypoint for protocol differential tests and profiling."""
    return unpack(library().decode(data, request_id, count, feature_count))
