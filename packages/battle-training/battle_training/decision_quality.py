"""Observational decision-quality probes and non-excluding prior shaping."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

_PARTY_MON_WIDTH = 22
_FULL_SIDE_WIDTH = 181
_PARTY_SIZE = 6
_ACTIVE_MON_OFFSET = _PARTY_MON_WIDTH * _PARTY_SIZE + 1
_ACTIVE_STAGE_OFFSET = _ACTIVE_MON_OFFSET + _PARTY_MON_WIDTH + 4

# Pure opponent major-status moves. Damaging side effects remain ordinary attacks.
_MAJOR_STATUS_MOVES = {
    45: "sleep",  # Sing
    77: "poison",  # Poison Powder
    78: "paralysis",  # Stun Spore
    79: "sleep",  # Sleep Powder
    86: "paralysis",  # Thunder Wave
    92: "poison",  # Toxic
    95: "sleep",  # Hypnosis
    137: "paralysis",  # Glare
    139: "poison",  # Poison Gas
    142: "sleep",  # Lovely Kiss
    147: "sleep",  # Spore
}

# Move ID -> active StatStages index. Neutral is 7 and +6 is 13.
_STAGE_SETUP_MOVES = {
    14: 0,  # Swords Dance
    74: 3,  # Growth
    96: 0,  # Meditate
    97: 2,  # Agility
    104: 5,  # Double Team
    106: 1,  # Harden
    107: 5,  # Minimize
    110: 1,  # Withdraw
    111: 1,  # Defense Curl
    112: 1,  # Barrier
    133: 3,  # Amnesia
    151: 1,  # Acid Armor
    159: 0,  # Sharpen
}

_OHKO_MOVES = {12, 32, 90}  # Guillotine, Horn Drill, Fissure


@dataclass(frozen=True)
class DecisionQualityFlags:
    move_id: int = 0
    major_status_attempt: bool = False
    redundant_status_same: bool = False
    redundant_status_other: bool = False
    stat_setup_attempt: bool = False
    capped_stat_setup: bool = False
    ohko_attempt: bool = False
    ohko_into_faster: bool = False

    @property
    def statically_redundant(self) -> bool:
        return (
            self.redundant_status_same
            or self.redundant_status_other
            or self.capped_stat_setup
            or self.ohko_into_faster
        )

    def labels(self) -> list[str]:
        labels = []
        if self.redundant_status_same:
            labels.append("major-status-already-present")
        if self.redundant_status_other:
            labels.append("major-status-slot-occupied")
        if self.capped_stat_setup:
            labels.append("stat-stage-already-plus-six")
        if self.ohko_into_faster:
            labels.append("ohko-target-currently-faster")
        return labels


@dataclass
class DecisionQualityMetrics:
    major_status_attempts: int = 0
    redundant_status_same: int = 0
    redundant_status_other: int = 0
    stat_setup_attempts: int = 0
    capped_stat_setup: int = 0
    ohko_attempts: int = 0
    ohko_into_faster: int = 0

    def observe(self, flags: DecisionQualityFlags) -> None:
        self.major_status_attempts += int(flags.major_status_attempt)
        self.redundant_status_same += int(flags.redundant_status_same)
        self.redundant_status_other += int(flags.redundant_status_other)
        self.stat_setup_attempts += int(flags.stat_setup_attempt)
        self.capped_stat_setup += int(flags.capped_stat_setup)
        self.ohko_attempts += int(flags.ohko_attempt)
        self.ohko_into_faster += int(flags.ohko_into_faster)

    def merge(self, other: DecisionQualityMetrics) -> None:
        for name in (
            "major_status_attempts",
            "redundant_status_same",
            "redundant_status_other",
            "stat_setup_attempts",
            "capped_stat_setup",
            "ohko_attempts",
            "ohko_into_faster",
        ):
            setattr(self, name, getattr(self, name) + getattr(other, name))

    def report(self) -> dict[str, int | float]:
        redundant_status = self.redundant_status_same + self.redundant_status_other
        return {
            "major_status_attempts": self.major_status_attempts,
            "redundant_status_same": self.redundant_status_same,
            "redundant_status_other": self.redundant_status_other,
            "redundant_status_rate": redundant_status
            / max(1, self.major_status_attempts),
            "stat_setup_attempts": self.stat_setup_attempts,
            "capped_stat_setup": self.capped_stat_setup,
            "capped_stat_setup_rate": self.capped_stat_setup
            / max(1, self.stat_setup_attempts),
            "ohko_attempts": self.ohko_attempts,
            "ohko_into_faster": self.ohko_into_faster,
            "ohko_into_faster_rate": self.ohko_into_faster / max(1, self.ohko_attempts),
        }


def _has_major_status(status: int, desired: str) -> bool:
    if desired == "sleep":
        return bool(status & 0x07)
    if desired == "poison":
        return bool(status & 0x08)
    if desired == "paralysis":
        return bool(status & 0x40)
    raise ValueError(f"unknown major status {desired}")


def classify_move_decision(
    move_id: int,
    target_status: int,
    own_stages: Sequence[int],
    own_speed: int,
    target_speed: int,
) -> DecisionQualityFlags:
    desired_status = _MAJOR_STATUS_MOVES.get(move_id)
    major_status_attempt = desired_status is not None
    redundant_status_same = bool(
        desired_status is not None and _has_major_status(target_status, desired_status)
    )
    redundant_status_other = bool(
        desired_status is not None and target_status != 0 and not redundant_status_same
    )
    setup_stat = _STAGE_SETUP_MOVES.get(move_id)
    stat_setup_attempt = setup_stat is not None
    capped_stat_setup = bool(
        setup_stat is not None
        and setup_stat < len(own_stages)
        and int(own_stages[setup_stat]) >= 13
    )
    ohko_attempt = move_id in _OHKO_MOVES
    return DecisionQualityFlags(
        move_id=move_id,
        major_status_attempt=major_status_attempt,
        redundant_status_same=redundant_status_same,
        redundant_status_other=redundant_status_other,
        stat_setup_attempt=stat_setup_attempt,
        capped_stat_setup=capped_stat_setup,
        ohko_attempt=ohko_attempt,
        ohko_into_faster=ohko_attempt and own_speed < target_speed,
    )


def classify_feature_decision(
    features: Sequence[int], action: int
) -> DecisionQualityFlags:
    """Classify one side-canonical ordinary move choice from the 492-field schema."""
    if not 0 <= action < 4 or len(features) < 2 * _FULL_SIDE_WIDTH:
        return DecisionQualityFlags()
    move_id = int(features[_ACTIVE_MON_OFFSET + 7 + action])
    own_stages = features[_ACTIVE_STAGE_OFFSET : _ACTIVE_STAGE_OFFSET + 6]
    own_speed = int(features[_ACTIVE_MON_OFFSET + 16])
    target_active = _FULL_SIDE_WIDTH + _ACTIVE_MON_OFFSET
    target_status = int(features[target_active + 3])
    target_speed = int(features[target_active + 16])
    return classify_move_decision(
        move_id, target_status, own_stages, own_speed, target_speed
    )


def _statically_redundant_move(
    move_id: int,
    target_status: int,
    own_stages: Sequence[int],
    own_speed: int,
    target_speed: int,
) -> bool:
    """Mirror DecisionQualityFlags.statically_redundant without building flags.

    A major-status move is redundant against any already-statused target, so
    the same/other split collapses to a nonzero status check here.
    """
    if move_id in _MAJOR_STATUS_MOVES and target_status != 0:
        return True
    setup_stat = _STAGE_SETUP_MOVES.get(move_id)
    if (
        setup_stat is not None
        and setup_stat < len(own_stages)
        and int(own_stages[setup_stat]) >= 13
    ):
        return True
    return move_id in _OHKO_MOVES and own_speed < target_speed


def shape_redundant_action_priors(
    policy: list[float],
    features: Sequence[int],
    legal_mask: int,
    scale: float,
) -> list[float]:
    """Downweight static redundancies without removing any legal action.

    A simultaneous switch can make a currently redundant status or OHKO choice
    useful against the incoming target, so this is deliberately a prior only.
    Exact joint payoffs and regret updates remain authoritative.
    """
    if not 0.0 < scale <= 1.0:
        raise ValueError("redundant action prior scale must be in (0, 1]")
    if scale == 1.0:
        return policy
    result = list(policy)
    if len(features) >= 2 * _FULL_SIDE_WIDTH:
        own_stages = features[_ACTIVE_STAGE_OFFSET : _ACTIVE_STAGE_OFFSET + 6]
        own_speed = int(features[_ACTIVE_MON_OFFSET + 16])
        target_active = _FULL_SIDE_WIDTH + _ACTIVE_MON_OFFSET
        target_status = int(features[target_active + 3])
        target_speed = int(features[target_active + 16])
        for action in range(min(4, len(result))):
            if legal_mask & (1 << action) and _statically_redundant_move(
                int(features[_ACTIVE_MON_OFFSET + 7 + action]),
                target_status,
                own_stages,
                own_speed,
                target_speed,
            ):
                result[action] *= scale
    legal = [action for action in range(len(result)) if legal_mask & (1 << action)]
    total = sum(result[action] for action in legal)
    if total <= 0.0:
        return policy
    for action in legal:
        result[action] /= total
    return result
