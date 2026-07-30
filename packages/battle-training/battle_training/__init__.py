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

GENERATED_PARTY_SCHEDULE = "one-third-6v6-all-others-v3"
GENERATED_LEVEL_SCHEDULE = "one-third-of-6v6-pairs-both-level100-v2"
LEGACY_GENERATED_PARTY_SCHEDULE = "minimum-25pct-6v6-all-others-v2"
LEGACY_GENERATED_LEVEL_SCHEDULE = "quarter-of-6v6-pairs-both-level100-v1"


def generated_schedule_names(schedule_version: int = 3) -> tuple[str, str]:
    if schedule_version == 2:
        return LEGACY_GENERATED_PARTY_SCHEDULE, LEGACY_GENERATED_LEVEL_SCHEDULE
    if schedule_version == 3:
        return GENERATED_PARTY_SCHEDULE, GENERATED_LEVEL_SCHEDULE
    raise ValueError("generated party schedule version must be 2 or 3")
_NON_6V6_MATCHUPS = tuple(
    (player, enemy)
    for player in range(1, FULL_PARTY_SIZE + 1)
    for enemy in range(1, FULL_PARTY_SIZE + 1)
    if (player, enemy) != (FULL_PARTY_SIZE, FULL_PARTY_SIZE)
)


def generated_party_sizes(index: int, schedule_version: int = 3) -> tuple[int, int]:
    """Schedule generated party sizes while preserving legacy replay profiles."""
    if index < 0:
        raise ValueError("generated match index must be nonnegative")
    if schedule_version == 2:
        block, offset = divmod(index, 4)
        if offset == 0:
            return FULL_PARTY_SIZE, FULL_PARTY_SIZE
        return _NON_6V6_MATCHUPS[
            (block * 3 + offset - 1) % len(_NON_6V6_MATCHUPS)
        ]
    if schedule_version != 3:
        raise ValueError("generated party schedule version must be 2 or 3")
    block, offset = divmod(index, 3)
    if offset == 0:
        return FULL_PARTY_SIZE, FULL_PARTY_SIZE
    return _NON_6V6_MATCHUPS[(block * 2 + offset - 1) % len(_NON_6V6_MATCHUPS)]


def generated_level100(index: int, schedule_version: int = 3) -> bool:
    """Schedule level-100 6v6 pairs while preserving the legacy quarter mix."""
    player_size, enemy_size = generated_party_sizes(index, schedule_version)
    if (player_size, enemy_size) != (FULL_PARTY_SIZE, FULL_PARTY_SIZE):
        return False
    if schedule_version == 2:
        return (index // 4) % 4 == 0
    return (index // 3) % 3 == 0
