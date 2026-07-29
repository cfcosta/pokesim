"""Cartridge-trainer AI projections for the link-training action space.

The exact stateful trainer controller lives in Lean.  These policies project its
47 class rows into the 13-action link profile used by self-play: move-scoring
layers, biased move-slot selection, and representable switch branches are
preserved.  Trainer items and the per-send-out action counter are absent from
that profile, so item decisions project to ordinary move selection.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

_ACTION_COUNT = 13
_FIGHT_ACTIONS = range(4)
_SWITCH_ACTIONS = range(4, 10)
_MOVE_SLOT_BUCKETS = (63.0, 64.0, 63.0, 66.0)

# Stable offsets in full-link-party-state-v4.  Each side occupies 181 fields;
# move-policy descriptors begin after both sides and have six fields per move.
_OWN_ACTIVE = 133
_TARGET_ACTIVE = 314
_OWN_MOVE_POLICY = 362
_AI_LAYER2_ENCOURAGEMENT = 468

_STATUS_EFFECTS = frozenset((0x01, 0x20, 0x42, 0x43))
_BETTER_ALTERNATIVE_EFFECTS = frozenset((0x28, 0x29, 0x2B))

# Ordered TypeEffects rows used by AIGetTypeEffectiveness.  Its first match
# against either defender type is intentional and differs from damage's fold.
_AI_TYPE_EFFECTS: tuple[tuple[int, int, int], ...] = (
    (0x15, 0x14, 20),
    (0x14, 0x16, 20),
    (0x14, 0x19, 20),
    (0x16, 0x15, 20),
    (0x17, 0x15, 20),
    (0x15, 0x05, 20),
    (0x04, 0x02, 0),
    (0x15, 0x15, 5),
    (0x14, 0x14, 5),
    (0x17, 0x17, 5),
    (0x19, 0x19, 5),
    (0x16, 0x16, 5),
    (0x18, 0x18, 5),
    (0x14, 0x15, 5),
    (0x16, 0x14, 5),
    (0x15, 0x16, 5),
    (0x17, 0x16, 5),
    (0x00, 0x05, 5),
    (0x00, 0x08, 0),
    (0x08, 0x08, 20),
    (0x14, 0x07, 20),
    (0x14, 0x05, 5),
    (0x15, 0x04, 20),
    (0x17, 0x04, 0),
    (0x17, 0x02, 20),
    (0x16, 0x04, 20),
    (0x16, 0x07, 5),
    (0x16, 0x03, 5),
    (0x16, 0x05, 20),
    (0x16, 0x02, 5),
    (0x19, 0x15, 5),
    (0x19, 0x16, 20),
    (0x19, 0x04, 20),
    (0x19, 0x02, 20),
    (0x01, 0x00, 20),
    (0x01, 0x03, 5),
    (0x01, 0x02, 5),
    (0x01, 0x18, 5),
    (0x01, 0x07, 5),
    (0x01, 0x05, 20),
    (0x01, 0x19, 20),
    (0x01, 0x08, 0),
    (0x03, 0x16, 20),
    (0x03, 0x03, 5),
    (0x03, 0x04, 5),
    (0x03, 0x07, 20),
    (0x03, 0x05, 5),
    (0x03, 0x08, 5),
    (0x04, 0x14, 20),
    (0x04, 0x17, 20),
    (0x04, 0x16, 5),
    (0x04, 0x07, 5),
    (0x04, 0x05, 20),
    (0x04, 0x03, 20),
    (0x02, 0x17, 5),
    (0x02, 0x01, 20),
    (0x02, 0x07, 20),
    (0x02, 0x16, 20),
    (0x02, 0x05, 5),
    (0x18, 0x01, 20),
    (0x18, 0x03, 20),
    (0x07, 0x14, 5),
    (0x07, 0x16, 20),
    (0x07, 0x01, 5),
    (0x07, 0x02, 5),
    (0x07, 0x18, 20),
    (0x07, 0x08, 5),
    (0x07, 0x03, 20),
    (0x05, 0x14, 20),
    (0x05, 0x01, 5),
    (0x05, 0x04, 5),
    (0x05, 0x02, 20),
    (0x05, 0x07, 20),
    (0x05, 0x19, 20),
    (0x08, 0x00, 0),
    (0x08, 0x18, 0),
    (0x14, 0x1A, 5),
    (0x15, 0x1A, 5),
    (0x17, 0x1A, 5),
    (0x16, 0x1A, 5),
    (0x19, 0x1A, 20),
    (0x1A, 0x1A, 20),
)


@dataclass(frozen=True)
class TrainerClassProfile:
    """One canonical class row from IDs ``$01..$2f``."""

    class_id: int
    slug: str
    layers: tuple[int, ...]
    initial_actions: int
    routine: str = "generic"

    @property
    def style(self) -> str:
        return f"red-trainer-{self.class_id:02d}-{self.slug}"

    @property
    def identity(self) -> str:
        return f"heuristic-{self.style}-v1"


TRAINER_CLASS_PROFILES: tuple[TrainerClassProfile, ...] = (
    TrainerClassProfile(1, "youngster", (), 3),
    TrainerClassProfile(2, "bug-catcher", (1,), 3),
    TrainerClassProfile(3, "lass", (1,), 3),
    TrainerClassProfile(4, "sailor", (1, 3), 3),
    TrainerClassProfile(5, "jr-trainer-m", (1,), 3),
    TrainerClassProfile(6, "jr-trainer-f", (1,), 3),
    TrainerClassProfile(7, "pokemaniac", (1, 2, 3), 3),
    TrainerClassProfile(8, "super-nerd", (1, 2), 3),
    TrainerClassProfile(9, "hiker", (1,), 3),
    TrainerClassProfile(10, "biker", (1,), 3),
    TrainerClassProfile(11, "burglar", (1, 3), 3),
    TrainerClassProfile(12, "engineer", (1,), 3),
    TrainerClassProfile(13, "unused-juggler", (1, 2), 3, "juggler"),
    TrainerClassProfile(14, "fisher", (1, 3), 3),
    TrainerClassProfile(15, "swimmer", (1, 3), 3),
    TrainerClassProfile(16, "cue-ball", (), 3),
    TrainerClassProfile(17, "gambler", (1,), 3),
    TrainerClassProfile(18, "beauty", (1, 3), 3),
    TrainerClassProfile(19, "psychic-tr", (1, 2), 3),
    TrainerClassProfile(20, "rocker", (1, 3), 3),
    TrainerClassProfile(21, "juggler", (1,), 3, "juggler"),
    TrainerClassProfile(22, "tamer", (1,), 3),
    TrainerClassProfile(23, "bird-keeper", (1,), 3),
    TrainerClassProfile(24, "blackbelt", (1,), 2, "blackbelt"),
    TrainerClassProfile(25, "rival1", (1,), 3),
    TrainerClassProfile(26, "prof-oak", (1, 3), 3),
    TrainerClassProfile(27, "chief", (1, 2), 1),
    TrainerClassProfile(28, "scientist", (1, 2), 3),
    TrainerClassProfile(29, "giovanni", (1, 3), 1, "giovanni"),
    TrainerClassProfile(30, "rocket", (1,), 3),
    TrainerClassProfile(31, "cooltrainer-m", (1, 3), 2, "cooltrainer-m"),
    TrainerClassProfile(32, "cooltrainer-f", (1, 3), 1, "cooltrainer-f"),
    TrainerClassProfile(33, "bruno", (1,), 2, "bruno"),
    TrainerClassProfile(34, "brock", (1,), 5, "brock"),
    TrainerClassProfile(35, "misty", (1, 3), 1, "misty"),
    TrainerClassProfile(36, "lt-surge", (1, 3), 1, "surge"),
    TrainerClassProfile(37, "erika", (1, 3), 1, "erika"),
    TrainerClassProfile(38, "koga", (1, 3), 2, "koga"),
    TrainerClassProfile(39, "blaine", (1, 3), 2, "blaine"),
    TrainerClassProfile(40, "sabrina", (1, 3), 1, "sabrina"),
    TrainerClassProfile(41, "gentleman", (1, 2), 3),
    TrainerClassProfile(42, "rival2", (1, 3), 1, "rival2"),
    TrainerClassProfile(43, "rival3", (1, 3), 1, "rival3"),
    TrainerClassProfile(44, "lorelei", (1, 2, 3), 2, "lorelei"),
    TrainerClassProfile(45, "channeler", (1,), 3),
    TrainerClassProfile(46, "agatha", (1,), 2, "agatha"),
    TrainerClassProfile(47, "lance", (1, 3), 1, "lance"),
)

_PROFILE_BY_STYLE = {profile.style: profile for profile in TRAINER_CLASS_PROFILES}


def trainer_profile_for_style(style: str) -> TrainerClassProfile | None:
    """Return the canonical class row represented by a heuristic style."""

    return _PROFILE_BY_STYLE.get(style)


def _descriptor(features: Sequence[int], slot: int) -> tuple[int, int, int]:
    base = _OWN_MOVE_POLICY + slot * 6
    return int(features[base]), int(features[base + 1]), int(features[base + 2])


def _ai_type_effectiveness(move_type: int, target_type1: int, target_type2: int) -> int:
    for attacker, defender, factor in _AI_TYPE_EFFECTS:
        if attacker == move_type and defender in (target_type1, target_type2):
            return factor
    return 0x10


def _has_better_alternative(
    moves: tuple[int, ...],
    descriptors: tuple[tuple[int, int, int], ...],
    current_type: int,
) -> bool:
    for move, (effect, power, move_type) in zip(moves, descriptors, strict=True):
        if move == 0:
            return False
        if effect in _BETTER_ALTERNATIVE_EFFECTS or (
            move_type != current_type and power != 0
        ):
            return True
    return False


def _move_scores(
    features: Sequence[int], profile: TrainerClassProfile
) -> tuple[int, ...]:
    moves = tuple(int(features[_OWN_ACTIVE + 7 + slot]) for slot in _FIGHT_ACTIONS)
    descriptors = tuple(_descriptor(features, slot) for slot in _FIGHT_ACTIONS)
    target_status = int(features[_TARGET_ACTIVE + 3])
    target_type1 = int(features[_TARGET_ACTIVE + 4])
    target_type2 = int(features[_TARGET_ACTIVE + 5])
    encouragement = int(features[_AI_LAYER2_ENCOURAGEMENT])
    prefix: list[int] = []
    for slot, move in enumerate(moves):
        if move == 0:
            break
        prefix.append(slot)
    scores = [10, 10, 10, 10]
    for layer in profile.layers:
        for slot in prefix:
            effect, power, move_type = descriptors[slot]
            if layer == 1:
                if target_status != 0 and power == 0 and effect in _STATUS_EFFECTS:
                    scores[slot] += 5
            elif layer == 2:
                if encouragement == 1 and (
                    0x0A <= effect <= 0x19 or 0x32 <= effect <= 0x41
                ):
                    scores[slot] = max(0, scores[slot] - 1)
            else:
                effectiveness = _ai_type_effectiveness(
                    move_type, target_type1, target_type2
                )
                if effectiveness > 0x10:
                    scores[slot] = max(0, scores[slot] - 1)
                elif effectiveness < 0x10 and _has_better_alternative(
                    moves, descriptors, move_type
                ):
                    scores[slot] += 1
    return tuple(scores)


def _below_fraction(current_hp: int, max_hp: int, divisor: int) -> bool:
    return divisor != 0 and current_hp < max_hp // divisor


def _switch_probability(
    features: Sequence[int], profile: TrainerClassProfile, has_reserve: bool
) -> float:
    if not has_reserve:
        return 0.0
    if profile.routine == "juggler":
        return 64.0 / 256.0
    if profile.routine == "cooltrainer-f":
        current_hp = int(features[_OWN_ACTIVE + 1])
        max_hp = int(features[_OWN_ACTIVE + 13])
        if _below_fraction(current_hp, max_hp, 10):
            return 0.0  # Hyper Potion is unavailable in the link action profile.
        return float(_below_fraction(current_hp, max_hp, 5))
    if profile.routine == "agatha":
        return 20.0 / 256.0
    return 0.0


def _fallback_weights(mask: int) -> list[float]:
    weights = [0.0] * _ACTION_COUNT
    legal = [action for action in range(_ACTION_COUNT) if mask & (1 << action)]
    if legal:
        weights[legal[0]] = 1.0
    return weights


def trainer_class_weights(
    features: Sequence[int], mask: int, profile: TrainerClassProfile
) -> list[float]:
    """Return unnormalized legal weights for one trainer-class projection."""

    weights = [0.0] * _ACTION_COUNT
    legal_fights = [action for action in _FIGHT_ACTIONS if mask & (1 << action)]
    legal_switches = [action for action in _SWITCH_ACTIONS if mask & (1 << action)]
    if not legal_fights:
        if legal_switches:
            weights[legal_switches[0]] = 1.0
            return weights
        return _fallback_weights(mask)

    scores = _move_scores(features, profile)
    minimum = min(scores[action] for action in legal_fights)
    for action in legal_fights:
        if scores[action] == minimum:
            weights[action] = _MOVE_SLOT_BUCKETS[action]

    switch_probability = _switch_probability(features, profile, bool(legal_switches))
    if switch_probability >= 1.0:
        for action in legal_fights:
            weights[action] = 0.0
        weights[legal_switches[0]] = 1.0
    elif switch_probability > 0.0:
        move_total = sum(weights)
        weights[legal_switches[0]] = (
            move_total * switch_probability / (1.0 - switch_probability)
        )
    return weights


def normalized_trainer_policy(
    features: Sequence[int], mask: int, profile: TrainerClassProfile
) -> list[float]:
    """Return the normalized policy used by the heuristic network adapter."""

    weights = trainer_class_weights(features, mask, profile)
    total = sum(weights)
    if total <= 0.0:
        weights = _fallback_weights(mask)
        total = sum(weights)
    return [weight / total for weight in weights]
