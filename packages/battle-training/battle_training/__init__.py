"""External training pipeline for the native Lean battle worker."""

PROFILE = "ordinary-link-1v1-perfect-v1"
SCHEMA = "ordinary-link-1v1-state-v1"
ENTROPY = "splitmix64-stock-link-v1"
MOVE_COUNT = 166
FEATURE_COUNT = 100

FULL_PROFILE = "full-link-party-1to6-perfect-v2"
FULL_SCHEMA = "full-link-party-state-v4"
FULL_PARTY_SIZE = 6
FULL_ACTION_COUNT = 13
FULL_FEATURE_COUNT = 492
FULL_CAMPAIGN_COUNT = 9

GENERATED_PARTY_SCHEDULE = "half-6v6-quarter-equal-capped-deficit-v4"
GENERATED_LEVEL_SCHEDULE = "one-third-of-6v6-pairs-both-level100-v3"

_SCHEDULE_NAMES = {
    2: (
        "minimum-25pct-6v6-all-others-v2",
        "quarter-of-6v6-pairs-both-level100-v1",
    ),
    3: (
        "one-third-6v6-all-others-v3",
        "one-third-of-6v6-pairs-both-level100-v2",
    ),
    4: (GENERATED_PARTY_SCHEDULE, GENERATED_LEVEL_SCHEDULE),
}


def _known_schedule_version(schedule_version: int) -> int:
    if schedule_version not in _SCHEDULE_NAMES:
        raise ValueError("generated party schedule version must be 2, 3 or 4")
    return schedule_version


def generated_schedule_names(schedule_version: int = 4) -> tuple[str, str]:
    return _SCHEDULE_NAMES[_known_schedule_version(schedule_version)]


_NON_6V6_MATCHUPS = tuple(
    (player, enemy)
    for player in range(1, FULL_PARTY_SIZE + 1)
    for enemy in range(1, FULL_PARTY_SIZE + 1)
    if (player, enemy) != (FULL_PARTY_SIZE, FULL_PARTY_SIZE)
)

# Version 4 splits that flat pool by how far apart the two rosters are, because
# the distance is what decides whether a battle is worth playing.  Versions 2
# and 3 drew from `_NON_6V6_MATCHUPS` uniformly, so 38% of every corpus opened
# at least two Pokemon down and the value head learned to read party size
# instead of position.
_EVEN_MATCHUPS = tuple((size, size) for size in range(1, FULL_PARTY_SIZE))
_NARROW_MATCHUPS = tuple(
    sizes for sizes in _NON_6V6_MATCHUPS if abs(sizes[0] - sizes[1]) == 1
)
_WIDE_MATCHUPS = tuple(
    sizes for sizes in _NON_6V6_MATCHUPS if abs(sizes[0] - sizes[1]) >= 2
)

# One block of sixteen: eight 6v6, four small-but-even, three one-mon deficits
# and a single wide handicap, which keeps the sweeps in the corpus as a token
# robustness slice rather than as the bulk of it.
_SCHEDULE_BLOCK = 16
_SIX_VS_SIX_SLOTS = 8
_EVEN_SLOTS = 4
_NARROW_SLOTS = 3
_LEVEL100_PERIOD = 3

# How many matches each version's block spans, which is also how far its counts
# can drift from the target before a partial block is to blame.
_SCHEDULE_BLOCKS = {2: 4, 3: 3, 4: _SCHEDULE_BLOCK}
_SIX_VS_SIX_FRACTIONS = {2: 1 / 4, 3: 1 / 3, 4: _SIX_VS_SIX_SLOTS / _SCHEDULE_BLOCK}
_LEVEL100_FRACTIONS = {2: 1 / 4, 3: 1 / 3, 4: 1 / _LEVEL100_PERIOD}


def generated_schedule_block(schedule_version: int = 4) -> int:
    """Matches per repeat of the schedule, so callers can size their tolerance."""
    return _SCHEDULE_BLOCKS[_known_schedule_version(schedule_version)]


def generated_six_vs_six_fraction(schedule_version: int = 4) -> float:
    """Share of scheduled matches that run a full party on both sides."""
    return _SIX_VS_SIX_FRACTIONS[_known_schedule_version(schedule_version)]


def generated_level100_fraction(schedule_version: int = 4) -> float:
    """Share of the 6v6 matches that run both sides at level 100."""
    return _LEVEL100_FRACTIONS[_known_schedule_version(schedule_version)]


def generated_party_sizes(index: int, schedule_version: int = 4) -> tuple[int, int]:
    """Schedule generated party sizes while preserving legacy replay profiles."""
    if index < 0:
        raise ValueError("generated match index must be nonnegative")
    if schedule_version == 2:
        block, offset = divmod(index, 4)
        if offset == 0:
            return FULL_PARTY_SIZE, FULL_PARTY_SIZE
        return _NON_6V6_MATCHUPS[(block * 3 + offset - 1) % len(_NON_6V6_MATCHUPS)]
    if schedule_version == 3:
        block, offset = divmod(index, 3)
        if offset == 0:
            return FULL_PARTY_SIZE, FULL_PARTY_SIZE
        return _NON_6V6_MATCHUPS[(block * 2 + offset - 1) % len(_NON_6V6_MATCHUPS)]
    _known_schedule_version(schedule_version)
    block, offset = divmod(index, _SCHEDULE_BLOCK)
    if offset < _SIX_VS_SIX_SLOTS:
        return FULL_PARTY_SIZE, FULL_PARTY_SIZE
    offset -= _SIX_VS_SIX_SLOTS
    # Each pool advances by its own slot count per block rather than restarting,
    # so a short run still walks the whole pool instead of the same few entries.
    if offset < _EVEN_SLOTS:
        return _EVEN_MATCHUPS[(block * _EVEN_SLOTS + offset) % len(_EVEN_MATCHUPS)]
    offset -= _EVEN_SLOTS
    if offset < _NARROW_SLOTS:
        return _NARROW_MATCHUPS[
            (block * _NARROW_SLOTS + offset) % len(_NARROW_MATCHUPS)
        ]
    return _WIDE_MATCHUPS[block % len(_WIDE_MATCHUPS)]


def generated_level100(index: int, schedule_version: int = 4) -> bool:
    """Schedule level-100 6v6 pairs while preserving the legacy quarter mix."""
    player_size, enemy_size = generated_party_sizes(index, schedule_version)
    if (player_size, enemy_size) != (FULL_PARTY_SIZE, FULL_PARTY_SIZE):
        return False
    if schedule_version == 2:
        return (index // 4) % 4 == 0
    if schedule_version == 3:
        return (index // 3) % 3 == 0
    # Counted over the 6v6 matches themselves; a block holds eight of them, so
    # indexing off `index` directly would land the third on the wrong stride.
    block, offset = divmod(index, _SCHEDULE_BLOCK)
    return (block * _SIX_VS_SIX_SLOTS + offset) % _LEVEL100_PERIOD == 0
