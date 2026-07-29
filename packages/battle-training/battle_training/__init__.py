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

GENERATED_PARTY_SCHEDULE = "minimum-25pct-6v6-all-others-v2"
GENERATED_LEVEL_SCHEDULE = "quarter-of-6v6-pairs-both-level100-v1"
_NON_6V6_MATCHUPS = tuple(
    (player, enemy)
    for player in range(1, FULL_PARTY_SIZE + 1)
    for enemy in range(1, FULL_PARTY_SIZE + 1)
    if (player, enemy) != (FULL_PARTY_SIZE, FULL_PARTY_SIZE)
)


def generated_party_sizes(index: int) -> tuple[int, int]:
    """Reserve every fourth generated match for 6v6 and cycle all others."""
    if index < 0:
        raise ValueError("generated match index must be nonnegative")
    block, offset = divmod(index, 4)
    if offset == 0:
        return FULL_PARTY_SIZE, FULL_PARTY_SIZE
    return _NON_6V6_MATCHUPS[(block * 3 + offset - 1) % len(_NON_6V6_MATCHUPS)]


def generated_level100(index: int) -> bool:
    """Make exactly one quarter of scheduled 6v6 pairs fully level 100."""
    player_size, enemy_size = generated_party_sizes(index)
    if (player_size, enemy_size) != (FULL_PARTY_SIZE, FULL_PARTY_SIZE):
        return False
    six_vs_six_index = index // 4
    return six_vs_six_index % 4 == 0
