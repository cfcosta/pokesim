#!/usr/bin/env python3
"""Generate minimum unobtainable/obtainable levels from canonical Pokémon Red ROM bytes.

This is a hash-gated artifact generator, not a Lean theorem. It decodes wild and
fishing records, Game Corner prizes, in-game trades, and evolution records from
the ROM. Fixed gifts and static encounters are admitted only after matching
local machine-code/object-data byte witnesses in the same ROM.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path

EXPECTED_SHA1 = "ea9bcae617fdf159b045185467ae58b2e4a48b9a"
EXPECTED_SHA256 = "5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b"

NAMES = """Bulbasaur|Ivysaur|Venusaur|Charmander|Charmeleon|Charizard|Squirtle|Wartortle|Blastoise|Caterpie|Metapod|Butterfree|Weedle|Kakuna|Beedrill|Pidgey|Pidgeotto|Pidgeot|Rattata|Raticate|Spearow|Fearow|Ekans|Arbok|Pikachu|Raichu|Sandshrew|Sandslash|Nidoran♀|Nidorina|Nidoqueen|Nidoran♂|Nidorino|Nidoking|Clefairy|Clefable|Vulpix|Ninetales|Jigglypuff|Wigglytuff|Zubat|Golbat|Oddish|Gloom|Vileplume|Paras|Parasect|Venonat|Venomoth|Diglett|Dugtrio|Meowth|Persian|Psyduck|Golduck|Mankey|Primeape|Growlithe|Arcanine|Poliwag|Poliwhirl|Poliwrath|Abra|Kadabra|Alakazam|Machop|Machoke|Machamp|Bellsprout|Weepinbell|Victreebel|Tentacool|Tentacruel|Geodude|Graveler|Golem|Ponyta|Rapidash|Slowpoke|Slowbro|Magnemite|Magneton|Farfetch’d|Doduo|Dodrio|Seel|Dewgong|Grimer|Muk|Shellder|Cloyster|Gastly|Haunter|Gengar|Onix|Drowzee|Hypno|Krabby|Kingler|Voltorb|Electrode|Exeggcute|Exeggutor|Cubone|Marowak|Hitmonlee|Hitmonchan|Lickitung|Koffing|Weezing|Rhyhorn|Rhydon|Chansey|Tangela|Kangaskhan|Horsea|Seadra|Goldeen|Seaking|Staryu|Starmie|Mr. Mime|Scyther|Jynx|Electabuzz|Magmar|Pinsir|Tauros|Magikarp|Gyarados|Lapras|Ditto|Eevee|Vaporeon|Jolteon|Flareon|Porygon|Omanyte|Omastar|Kabuto|Kabutops|Aerodactyl|Snorlax|Articuno|Zapdos|Moltres|Dratini|Dragonair|Dragonite|Mewtwo|Mew""".split("|")


@dataclass(frozen=True)
class Symbol:
    bank: int
    address: int

    @property
    def offset(self) -> int:
        return self.address if self.bank == 0 else self.bank * 0x4000 + self.address - 0x4000

    @property
    def display(self) -> str:
        return f"{self.bank:02x}:{self.address:04x}"


@dataclass(frozen=True)
class Candidate:
    level: int
    route: str
    evidence: str
    direct: bool = True


@dataclass(frozen=True)
class Evolution:
    source_dex: int
    target_dex: int
    method: str
    threshold: int
    evidence: str


class Decoder:
    def __init__(self, rom: bytes, symbols: dict[str, Symbol]):
        self.rom = rom
        self.symbols = symbols
        pokedex = self.read("PokedexOrder", 190)
        self.internal_to_dex = {index + 1: dex for index, dex in enumerate(pokedex) if 1 <= dex <= 151}
        self.dex_to_internal = {dex: internal for internal, dex in self.internal_to_dex.items()}
        if len(self.dex_to_internal) != 151:
            raise ValueError(f"PokedexOrder decoded {len(self.dex_to_internal)} real species, expected 151")

    def symbol(self, name: str) -> Symbol:
        try:
            return self.symbols[name]
        except KeyError as exc:
            raise ValueError(f"missing symbol: {name}") from exc

    def read(self, name: str, size: int, relative: int = 0) -> bytes:
        start = self.symbol(name).offset + relative
        data = self.rom[start : start + size]
        if len(data) != size:
            raise ValueError(f"short ROM read at {name}+{relative}")
        return data

    def name(self, internal: int) -> str:
        dex = self.internal_to_dex.get(internal)
        if dex is None:
            raise ValueError(f"invalid real-species internal id ${internal:02x}")
        return NAMES[dex - 1]

    def dex(self, internal: int) -> int:
        dex = self.internal_to_dex.get(internal)
        if dex is None:
            raise ValueError(f"invalid real-species internal id ${internal:02x}")
        return dex

    def internal(self, dex: int) -> int:
        return self.dex_to_internal[dex]

    def location(self, offset: int) -> str:
        bank = offset // 0x4000
        address = offset if bank == 0 else 0x4000 + offset % 0x4000
        return f"{bank:02x}:{address:04x}"

    def expect_near(self, symbol_name: str, patterns: list[bytes], window: int = 0x180) -> str:
        symbol = self.symbol(symbol_name)
        haystack = self.rom[symbol.offset : symbol.offset + window]
        locations: list[str] = []
        for pattern in patterns:
            positions = [match.start() for match in re.finditer(re.escape(pattern), haystack)]
            if len(positions) != 1:
                raise ValueError(
                    f"{symbol_name}: expected one {pattern.hex()} witness in {window} bytes, got {len(positions)}"
                )
            locations.append(self.location(symbol.offset + positions[0]))
        return f"`{symbol_name}` ({', '.join(locations)})"

    def expect_count_near(self, symbol_name: str, pattern: bytes, count: int, window: int) -> str:
        symbol = self.symbol(symbol_name)
        haystack = self.rom[symbol.offset : symbol.offset + window]
        positions = [match.start() for match in re.finditer(re.escape(pattern), haystack)]
        if len(positions) != count:
            raise ValueError(
                f"{symbol_name}: expected {count} {pattern.hex()} witnesses in {window} bytes, got {len(positions)}"
            )
        locations = ", ".join(self.location(symbol.offset + position) for position in positions)
        return f"`{symbol_name}` ({locations})"


def parse_symbols(path: Path) -> dict[str, Symbol]:
    symbols: dict[str, Symbol] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) < 2 or ":" not in fields[0]:
            continue
        bank, address = fields[0].split(":", 1)
        symbols[fields[1]] = Symbol(int(bank, 16), int(address, 16))
    return symbols


def pretty_label(label: str) -> str:
    label = re.sub(r"WildMons$", "", label)
    label = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", label)
    label = re.sub(r"(\d) F\b", r"\1F", label)
    label = re.sub(r"(?<=[a-z])(?=\d)", " ", label)
    return (
        label.replace("Pokemon", "Pokémon")
        .replace("Mt Moon", "Mt. Moon")
        .replace("Digletts Cave", "Diglett’s Cave")
    )


def add_candidate(candidates: dict[int, list[Candidate]], dex: int, candidate: Candidate) -> None:
    current = candidates.setdefault(dex, [])
    if not current or candidate.level < current[0].level:
        candidates[dex] = [candidate]
    elif candidate.level == current[0].level and candidate not in current:
        current.append(candidate)


def decode_wild(decoder: Decoder, candidates: dict[int, list[Candidate]]) -> int:
    table = decoder.symbol("WildDataPointers")
    table_end = decoder.symbol("NothingWildMons")
    pointer_bytes = decoder.rom[table.offset : table_end.offset]
    if len(pointer_bytes) % 2 != 0:
        raise ValueError("WildDataPointers has an odd byte length")
    referenced = {
        pointer_bytes[index] | pointer_bytes[index + 1] << 8
        for index in range(0, len(pointer_bytes), 2)
    }
    referenced.discard(table_end.address)
    referenced.discard(0xFFFF)  # table terminator after NUM_MAPS pointers
    labels = sorted(
        name
        for name, symbol in decoder.symbols.items()
        if name.endswith("WildMons") and name != "NothingWildMons"
        and symbol.bank == table.bank and symbol.address in referenced
    )
    decoded_addresses = {decoder.symbol(label).address for label in labels}
    if decoded_addresses != referenced:
        missing = ", ".join(f"${address:04x}" for address in sorted(referenced - decoded_addresses))
        raise ValueError(f"wild pointer targets without named encounter blocks: {missing}")
    records = 0
    for label in labels:
        position = decoder.symbol(label).offset
        for terrain in ("grass/cave", "water"):
            rate = decoder.rom[position]
            position += 1
            if rate == 0:
                continue
            for _ in range(10):
                level, internal = decoder.rom[position : position + 2]
                position += 2
                dex = decoder.dex(internal)
                add_candidate(
                    candidates,
                    dex,
                    Candidate(level, f"Wild encounter — {pretty_label(label)} ({terrain})", f"`{label}` ({decoder.symbol(label).display})"),
                )
                records += 1
    return records


def decode_fishing(decoder: Decoder, candidates: dict[int, list[Candidate]]) -> int:
    records = 0

    old = decoder.read("ItemUseOldRod", 13)
    if old[6] != 0x01:
        raise ValueError("ItemUseOldRod no longer contains the expected ld bc immediate")
    internal, level = old[7], old[8]
    add_candidate(candidates, decoder.dex(internal), Candidate(level, "Old Rod", f"`ItemUseOldRod` ({decoder.symbol('ItemUseOldRod').display})"))
    records += 1

    good = decoder.read("GoodRodMons", 4)
    for index in range(0, 4, 2):
        level, internal = good[index : index + 2]
        add_candidate(candidates, decoder.dex(internal), Candidate(level, "Good Rod", f"`GoodRodMons` ({decoder.symbol('GoodRodMons').display})"))
        records += 1

    super_table = decoder.symbol("SuperRodData")
    position = super_table.offset
    referenced_groups: set[int] = set()
    while decoder.rom[position] != 0xFF:
        referenced_groups.add(decoder.rom[position + 1] | decoder.rom[position + 2] << 8)
        position += 3
    named_groups = {decoder.symbol(f"SuperRodData.Group{group}").address for group in range(1, 11)}
    if referenced_groups != named_groups:
        raise ValueError("SuperRodData map records and named fishing groups disagree")

    for group in range(1, 11):
        label = f"SuperRodData.Group{group}"
        data = decoder.read(label, 1 + 2 * decoder.read(label, 1)[0])
        count = data[0]
        for index in range(count):
            level, internal = data[1 + index * 2 : 3 + index * 2]
            add_candidate(candidates, decoder.dex(internal), Candidate(level, f"Super Rod — group {group}", f"`{label}` ({decoder.symbol(label).display})"))
            records += 1
    return records


def add_fixed_acquisitions(decoder: Decoder, candidates: dict[int, list[Candidate]]) -> int:
    count = 0

    def add(dex: int, level: int, route: str, evidence: str) -> None:
        nonlocal count
        add_candidate(candidates, dex, Candidate(level, route, evidence))
        count += 1

    starter_level_evidence = decoder.expect_near("OaksLabMonChoiceMenu", [bytes.fromhex("3e05ea27d1")])
    starter_witnesses = [
        (4, "OaksLabCharmanderPokeBallText", bytes.fromhex("083eb1ea3dcd3e03ea3ecd3eb006021820")),
        (7, "OaksLabSquirtlePokeBallText", bytes.fromhex("083e99ea3dcd3e04ea3ecd3eb10603180f")),
        (1, "OaksLabBulbasaurPokeBallText", bytes.fromhex("083eb0ea3dcd3e02ea3ecd3e990604")),
    ]
    for dex, symbol, pattern in starter_witnesses:
        species_evidence = decoder.expect_near(symbol, [pattern], 0x20)
        add(dex, 5, "Starter choice", f"{species_evidence}; {starter_level_evidence}")

    fixed = [
        (133, 25, "Celadon Mansion gift", "CeladonMansionRoofHouseEeveePokeballText", [bytes([0x01, 25, decoder.internal(133)])]),
        (131, 15, "Silph Co. gift", "SilphCo7FSilphWorkerM1Text", [bytes([0x01, 15, decoder.internal(131)])]),
        (129, 5, "Mt. Moon Pokémon Center purchase", "MtMoonPokecenterMagikarpSalesmanText", [bytes([0x01, 5, decoder.internal(129)])]),
        (106, 30, "Fighting Dojo gift", "FightingDojoHitmonleePokeBallText", [bytes.fromhex("3e2bcd9b3421494fcd493ccdec35fa26cca7201cfa91cf470e1ecd483e")]),
        (107, 30, "Fighting Dojo gift", "FightingDojoHitmonchanPokeBallText", [bytes.fromhex("3e2ccd9b3421914fcd493ccdec35fa26cca7201cfa91cf470e1ecd483e")]),
        (143, 30, "Static encounter — Route 12", "Route12DefaultScript", [bytes([0x3E, decoder.internal(143), 0xEA, 0x59, 0xD0, 0x3E, 30, 0xEA, 0x27, 0xD1])]),
    ]
    for dex, level, route, symbol, patterns in fixed:
        add(dex, level, route, decoder.expect_near(symbol, patterns))

    fossil_map = bytes.fromhex("fe29280cfe2a280406ab180606621802065a")
    fossil_mapping_evidence = decoder.expect_near("GiveFossilToCinnabarLab", [fossil_map])
    fossil_level_evidence = decoder.expect_near("CinnabarLabFossilRoomScientist1Text", [bytes.fromhex("fa10d7470e1ecd483e")])
    for dex, fossil in ((138, "Helix Fossil revival"), (140, "Dome Fossil revival"), (142, "Old Amber revival")):
        add(dex, 30, fossil, f"{fossil_mapping_evidence}; {fossil_level_evidence}")

    static_objects = [
        (100, 40, "Static encounter — Power Plant", "PowerPlant_Object", 6),
        (101, 43, "Static encounter — Power Plant", "PowerPlant_Object", 2),
        (144, 50, "Static encounter — Seafoam Islands", "SeafoamIslandsB4F_Object", 1),
        (145, 50, "Static encounter — Power Plant", "PowerPlant_Object", 1),
        (146, 50, "Static encounter — Victory Road", "VictoryRoad2F_Object", 1),
        (150, 70, "Static encounter — Cerulean Cave", "CeruleanCaveB1F_Object", 1),
    ]
    for dex, level, route, symbol, witness_count in static_objects:
        evidence = decoder.expect_count_near(
            symbol, bytes([decoder.internal(dex), level]), witness_count, 0x100
        )
        add(dex, level, route, evidence)

    prize_levels = decoder.read("PrizeMonLevelDictionary", 12)
    menu_species = set(decoder.read("PrizeMenuMon1Entries", 3) + decoder.read("PrizeMenuMon2Entries", 3))
    for index in range(0, 12, 2):
        internal, level = prize_levels[index : index + 2]
        if internal not in menu_species:
            raise ValueError(f"prize level dictionary species ${internal:02x} is absent from Red prize menus")
        dex = decoder.dex(internal)
        add(dex, level, "Celadon Game Corner prize", f"`PrizeMonLevelDictionary` ({decoder.symbol('PrizeMonLevelDictionary').display})")

    return count


def decode_evolutions(decoder: Decoder) -> list[Evolution]:
    table = decoder.symbol("EvosMovesPointerTable")
    evolutions: list[Evolution] = []
    for internal in range(1, 191):
        source_dex = decoder.internal_to_dex.get(internal)
        if source_dex is None:
            continue
        pointer_bytes = decoder.rom[table.offset + (internal - 1) * 2 : table.offset + internal * 2]
        address = pointer_bytes[0] | pointer_bytes[1] << 8
        position = table.bank * 0x4000 + address - 0x4000
        for _ in range(16):
            tag = decoder.rom[position]
            if tag == 0:
                break
            if tag == 1:
                threshold, target = decoder.rom[position + 1 : position + 3]
                size, method = 3, "level"
            elif tag == 2:
                _item, _minimum, target = decoder.rom[position + 1 : position + 4]
                threshold, size, method = 0, 4, "item"
            elif tag == 3:
                _minimum, target = decoder.rom[position + 1 : position + 3]
                threshold, size, method = 0, 3, "trade evolution"
            else:
                raise ValueError(f"unknown evolution tag ${tag:02x} at {decoder.location(position)}")
            target_dex = decoder.dex(target)
            evolutions.append(Evolution(source_dex, target_dex, method, threshold, f"ROM {decoder.location(position)}"))
            position += size
        else:
            raise ValueError(f"unterminated evolution list for internal species ${internal:02x}")
    return evolutions


def decode_npc_trades(decoder: Decoder) -> list[Evolution]:
    data = decoder.read("TradeMons", 10 * 14)
    active_witnesses = {
        0: ("Route11Gate2FYoungsterText", bytes.fromhex("08afea3dcd3e54cd6d3e")),
        1: ("Route2TradeHouseScientistText", bytes.fromhex("083e01ea3dcd3e54cd6d3e")),
        3: ("CinnabarLabFossilRoomScientist2Text", bytes.fromhex("083e03ea3dcd3e54cd6d3e")),
        4: ("VermilionTradeHouseLittleGirlText", bytes.fromhex("083e04ea3dcd3e54cd6d3e")),
        5: ("Route18Gate2FYoungsterText", bytes.fromhex("083e05ea3dcd3e54cd6d3e")),
        6: ("CeruleanTradeHouseGrannyText", bytes.fromhex("083e06ea3dcd3e54cd6d3e")),
        7: ("CinnabarLabTradeRoomGrampsText", bytes.fromhex("083e07ea3dcd")),
        8: ("CinnabarLabTradeRoomBeautyText", bytes.fromhex("083e08ea3dcd3e54cd6d3e")),
        9: ("UndergroundPathRoute5LittleGirlText", bytes.fromhex("083e09ea3dcd3e54cd6d3e")),
    }
    trades: list[Evolution] = []
    for row, (script_symbol, script_pattern) in active_witnesses.items():
        give, receive = data[row * 14 : row * 14 + 2]
        script_evidence = decoder.expect_near(script_symbol, [script_pattern], 0x30)
        row_evidence = f"`TradeMons` row {row} ({decoder.location(decoder.symbol('TradeMons').offset + row * 14)})"
        trades.append(
            Evolution(
                decoder.dex(give), decoder.dex(receive), "in-game trade", 0,
                f"{row_evidence}; {script_evidence}",
            )
        )
    return trades


def derive(candidates: dict[int, list[Candidate]], edges: list[Evolution]) -> None:
    for _ in range(151):
        changed = False
        for edge in edges:
            source = candidates.get(edge.source_dex)
            if not source:
                continue
            source_best = source[0]
            if edge.method == "level":
                level = edge.threshold if source_best.level < edge.threshold else source_best.level + 1
                step = f"evolve {NAMES[edge.source_dex - 1]} at level {level}"
            elif edge.method == "item":
                level = source_best.level
                step = f"item-evolve {NAMES[edge.source_dex - 1]}"
            elif edge.method == "trade evolution":
                level = source_best.level
                step = f"trade-evolve {NAMES[edge.source_dex - 1]}"
            else:
                level = source_best.level
                step = f"in-game trade {NAMES[edge.source_dex - 1]} for {NAMES[edge.target_dex - 1]}"
            candidate = Candidate(level, f"{source_best.route}; {step}", f"{source_best.evidence}; {edge.evidence}", False)
            before = candidates.get(edge.target_dex)
            previous_level = before[0].level if before else None
            add_candidate(candidates, edge.target_dex, candidate)
            if previous_level is None or candidates[edge.target_dex][0].level < previous_level:
                changed = True
        if not changed:
            return
    raise ValueError("minimum-level propagation did not converge")


def compact_ties(entries: list[Candidate]) -> tuple[str, str]:
    preferred = sorted(entries, key=lambda item: (not item.direct, item.route, item.evidence))
    first = preferred[0]
    same_kind = [item for item in preferred if item.direct == first.direct]
    routes = "; or ".join(dict.fromkeys(item.route for item in same_kind))
    evidence = "; ".join(dict.fromkeys(item.evidence for item in same_kind))
    return routes, evidence


def render_lean(candidates: dict[int, list[Candidate]]) -> str:
    values = [
        f"some {candidates[dex][0].level}" if candidates.get(dex) else "none"
        for dex in range(1, 152)
    ]
    rows = []
    for start in range(0, len(values), 10):
        end = min(start + 10, len(values))
        rows.append("  " + ", ".join(values[start:end]) +
            f",  -- dex {start + 1:03d}..{end:03d}")
    body = "\n".join(rows)
    return f'''/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Data.Species

/-!
# Canonical Pokémon Red minimum obtainable levels

Generated by `tools/generate-pokered-min-levels.py` from the hash-identified
English Pokémon Red ROM. Values are in national-dex order. `none` marks species
unavailable through normal Red acquisition; team generation gives those species
the explicit fallback floor level 5.

This immutable array is runtime-generated ROM evidence. Its cartridge-byte
boundary is checked by CI and is not presented as an unconditional Lean theorem
about caller-supplied ROM bytes.
-/

namespace Battle.Data.MinimumLevels

/-- Lowest normally obtainable level in Red, in national-dex order. -/
def minimumObtainableByDex : Array (Option UInt8) := #[
{body}
]

/-- Lowest normally obtainable level for a real internal species id. -/
def minimumObtainableLevel (species : SpeciesId) : Option UInt8 :=
  let dex := Data.internalToDex species
  if dex == 0 then none else minimumObtainableByDex.getD (dex.toNat - 1) none

/-- Team-generation floor. Red-unavailable species use the explicit level-5
fallback requested by generator policy. -/
def generationFloor (species : SpeciesId) : UInt8 :=
  (minimumObtainableLevel species).getD 5

@[simp] theorem generationFloor_of_obtainable (species : SpeciesId) (level : UInt8)
    (found : minimumObtainableLevel species = some level) :
    generationFloor species = level := by
  simp [generationFloor, found]

@[simp] theorem generationFloor_of_unavailable (species : SpeciesId)
    (missing : minimumObtainableLevel species = none) :
    generationFloor species = 5 := by
  simp [generationFloor, missing]

#guard minimumObtainableByDex.size == 151
#guard (minimumObtainableByDex.filterMap id).size == 139
#guard generationFloor 0x99 == 5   -- Bulbasaur
#guard generationFloor 0x8d == 3   -- Electrode through the Raichu NPC trade
#guard generationFloor 0x83 == 70  -- Mewtwo
#guard minimumObtainableLevel 0x15 == none -- Mew
#guard generationFloor 0x15 == 5   -- explicit unavailable-species fallback

/-- Every internal byte receives a nonzero generation floor no greater than
level 100, including MissingNo/non-species bytes. -/
theorem generationFloor_bounds (species : SpeciesId) :
    1 ≤ (generationFloor species).toNat ∧ (generationFloor species).toNat ≤ 100 := by
  have checked : (List.range 256).all (fun value =>
      1 ≤ (generationFloor value.toUInt8).toNat &&
        (generationFloor value.toUInt8).toNat ≤ 100) = true := by native_decide
  have item := (List.all_eq_true.mp checked) species.toNat (List.mem_range.mpr species.toNat_lt)
  have round : species.toNat.toUInt8 = species := by
    apply UInt8.toNat.inj
    simp
  simpa only [Bool.and_eq_true, decide_eq_true_eq, round] using item

end Battle.Data.MinimumLevels
'''


def render(candidates: dict[int, list[Candidate]], counts: dict[str, int]) -> str:
    obtainable = sum(1 for dex in range(1, 152) if candidates.get(dex))
    unavailable = 151 - obtainable
    lines = [
        "# Pokémon Red minimum obtainable levels",
        "",
        "This reference lists the lowest level at which each real Generation-I species can be owned in the hash-identified English Pokémon Red cartridge. It includes wild encounters, fishing, starters, gifts, purchases, Game Corner prizes, active in-game trades, and evolution chains.",
        "",
        "## Scope and interpretation",
        "",
        "- Profile: English Pokémon Red, SHA-1 `ea9bcae617fdf159b045185467ae58b2e4a48b9a`, SHA-256 `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.",
        "- “Obtainable” is the union of legal choices across saves. Mutually exclusive starters, fossils, Hitmon gifts, and Eevee evolutions therefore all appear.",
        "- No external species trading is assumed. Cartridge trade evolutions and the nine reachable in-game NPC trades are included; the unused Butterfree-for-Beedrill table row is excluded.",
        "- Item and trade evolutions preserve the source level. A level evolution occurs at its threshold when the source can be obtained below it; an already-at/above-threshold source must gain one level before the check can run.",
        "- Event distributions, glitches, arbitrary-code execution, MissingNo., and the non-catchable Old Man tutorial encounter are excluded. Mew is therefore unavailable.",
        "- “Unavailable” means unavailable through normal play using this Red cartridge's own acquisition data. It does not mean absent from the ROM's species tables.",
        "",
        "## Byte provenance",
        "",
        "`tools/generate-pokered-min-levels.py` hash-checks a caller-supplied ROM, then decodes canonical `PokedexOrder`, every nonempty `*WildMons` block, Old/Good/Super Rod records, Red Game Corner records, `TradeMons`, and `EvosMovesPointerTable` payloads. Gifts and static encounters require local opcode/object-byte witnesses. Symbol names annotate addresses; the values come from ROM bytes, not ASM constants.",
        "",
        f"Decoded inventory: {counts['wild']} wild slots, {counts['fishing']} fishing slots, {counts['fixed']} fixed/prize acquisitions, {counts['evolutions']} evolution edges, and {counts['trades']} active NPC-trade edges. Result: **{obtainable} obtainable / {unavailable} unavailable**.",
        "",
        "This generated document is reproducible runtime evidence, not a Lean theorem and not a whole-cartridge reachability proof.",
        "",
        "## Team-generation policy",
        "",
        "`Battle.Data.MinimumLevels.minimumObtainableLevel` mirrors this table in Lean. `Battle.RL.DynamicGenerator.sampledLevel` maps one entropy byte into the inclusive interval from the species floor through level 100. The 12 unavailable species use the explicit fallback floor 5. The modulo mapping preserves its finite-byte bias rather than claiming a uniform distribution.",
        "",
        "## Minimum-level table",
        "",
        "| Dex | Pokémon | Lowest level | Minimum route | ROM evidence |",
        "|---:|---|---:|---|---|",
    ]
    for dex, name in enumerate(NAMES, 1):
        entries = candidates.get(dex)
        if not entries:
            lines.append(f"| {dex:03d} | {name} | — | Unavailable in normal Red play | — |")
            continue
        route, evidence = compact_ties(entries)
        lines.append(f"| {dex:03d} | {name} | {entries[0].level} | {route} | {evidence} |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rom", required=True, type=Path)
    parser.add_argument("--sym", type=Path, default=Path("artifacts/pokered/pokered.sym"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", type=Path)
    parser.add_argument("--output-lean", type=Path)
    parser.add_argument("--check-lean", type=Path)
    args = parser.parse_args()

    rom = args.rom.read_bytes()
    sha1 = hashlib.sha1(rom).hexdigest()
    sha256 = hashlib.sha256(rom).hexdigest()
    if sha1 != EXPECTED_SHA1 or sha256 != EXPECTED_SHA256:
        print(f"error: non-canonical ROM: sha1={sha1} sha256={sha256}", file=sys.stderr)
        return 1

    decoder = Decoder(rom, parse_symbols(args.sym))
    candidates: dict[int, list[Candidate]] = {}
    counts = {
        "wild": decode_wild(decoder, candidates),
        "fishing": decode_fishing(decoder, candidates),
        "fixed": add_fixed_acquisitions(decoder, candidates),
    }
    evolutions = decode_evolutions(decoder)
    trades = decode_npc_trades(decoder)
    counts["evolutions"] = len(evolutions)
    counts["trades"] = len(trades)
    derive(candidates, evolutions + trades)
    document = render(candidates, counts)
    lean_module = render_lean(candidates)

    if args.check:
        current = args.check.read_text(encoding="utf-8")
        if current != document:
            print(f"error: {args.check} is stale; regenerate it", file=sys.stderr)
            return 1
        print(f"PASS: {args.check} matches canonical ROM minimum-level derivation")
    if args.check_lean:
        current = args.check_lean.read_text(encoding="utf-8")
        if current != lean_module:
            print(f"error: {args.check_lean} is stale; regenerate it", file=sys.stderr)
            return 1
        print(f"PASS: {args.check_lean} matches canonical ROM minimum-level derivation")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(document, encoding="utf-8")
        print(f"wrote {args.output}")
    if args.output_lean:
        args.output_lean.parent.mkdir(parents=True, exist_ok=True)
        args.output_lean.write_text(lean_module, encoding="utf-8")
        print(f"wrote {args.output_lean}")
    if not args.check and not args.output and not args.check_lean and not args.output_lean:
        print(document)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
