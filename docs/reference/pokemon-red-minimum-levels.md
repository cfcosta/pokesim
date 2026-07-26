# Pokémon Red minimum obtainable levels

This reference lists the lowest level at which each real Generation-I species can be owned in the hash-identified English Pokémon Red cartridge. It includes wild encounters, fishing, starters, gifts, purchases, Game Corner prizes, active in-game trades, and evolution chains.

## Scope and interpretation

- Profile: English Pokémon Red, SHA-1 `ea9bcae617fdf159b045185467ae58b2e4a48b9a`, SHA-256 `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.
- “Obtainable” is the union of legal choices across saves. Mutually exclusive starters, fossils, Hitmon gifts, and Eevee evolutions therefore all appear.
- No external species trading is assumed. Cartridge trade evolutions and the nine reachable in-game NPC trades are included; the unused Butterfree-for-Beedrill table row is excluded.
- Item and trade evolutions preserve the source level. A level evolution occurs at its threshold when the source can be obtained below it; an already-at/above-threshold source must gain one level before the check can run.
- Event distributions, glitches, arbitrary-code execution, MissingNo., and the non-catchable Old Man tutorial encounter are excluded. Mew is therefore unavailable.
- “Unavailable” means unavailable through normal play using this Red cartridge's own acquisition data. It does not mean absent from the ROM's species tables.

## Byte provenance

`tools/generate-pokered-min-levels.py` hash-checks a caller-supplied ROM, then decodes canonical `PokedexOrder`, every nonempty `*WildMons` block, Old/Good/Super Rod records, Red Game Corner records, `TradeMons`, and `EvosMovesPointerTable` payloads. Gifts and static encounters require local opcode/object-byte witnesses. Symbol names annotate addresses; the values come from ROM bytes, not ASM constants.

Decoded inventory: 570 wild slots, 34 fishing slots, 24 fixed/prize acquisitions, 72 evolution edges, and 9 active NPC-trade edges. Result: **139 obtainable / 12 unavailable**.

This generated document is reproducible runtime evidence, not a Lean theorem and not a whole-cartridge reachability proof.

## Minimum-level table

| Dex | Pokémon | Lowest level | Minimum route | ROM evidence |
|---:|---|---:|---|---|
| 001 | Bulbasaur | 5 | Starter choice | `OaksLabBulbasaurPokeBallText` (07:5124); `OaksLabMonChoiceMenu` (07:5202) |
| 002 | Ivysaur | 16 | Starter choice; evolve Bulbasaur at level 16 | `OaksLabBulbasaurPokeBallText` (07:5124); `OaksLabMonChoiceMenu` (07:5202); ROM 0e:7844 |
| 003 | Venusaur | 32 | Starter choice; evolve Bulbasaur at level 16; evolve Ivysaur at level 32 | `OaksLabBulbasaurPokeBallText` (07:5124); `OaksLabMonChoiceMenu` (07:5202); ROM 0e:7844; ROM 0e:724b |
| 004 | Charmander | 5 | Starter choice | `OaksLabCharmanderPokeBallText` (07:5102); `OaksLabMonChoiceMenu` (07:5202) |
| 005 | Charmeleon | 16 | Starter choice; evolve Charmander at level 16 | `OaksLabCharmanderPokeBallText` (07:5102); `OaksLabMonChoiceMenu` (07:5202); ROM 0e:7938 |
| 006 | Charizard | 36 | Starter choice; evolve Charmander at level 16; evolve Charmeleon at level 36 | `OaksLabCharmanderPokeBallText` (07:5102); `OaksLabMonChoiceMenu` (07:5202); ROM 0e:7938; ROM 0e:795a |
| 007 | Squirtle | 5 | Starter choice | `OaksLabSquirtlePokeBallText` (07:5113); `OaksLabMonChoiceMenu` (07:5202) |
| 008 | Wartortle | 16 | Starter choice; evolve Squirtle at level 16 | `OaksLabSquirtlePokeBallText` (07:5113); `OaksLabMonChoiceMenu` (07:5202); ROM 0e:7949 |
| 009 | Blastoise | 36 | Starter choice; evolve Squirtle at level 16; evolve Wartortle at level 36 | `OaksLabSquirtlePokeBallText` (07:5113); `OaksLabMonChoiceMenu` (07:5202); ROM 0e:7949; ROM 0e:796b |
| 010 | Caterpie | 3 | Wild encounter — Viridian Forest (grass/cave) | `ViridianForestWildMons` (03:5121) |
| 011 | Metapod | 4 | Wild encounter — Viridian Forest (grass/cave) | `ViridianForestWildMons` (03:5121) |
| 012 | Butterfree | 10 | Wild encounter — Viridian Forest (grass/cave); evolve Metapod at level 10 | `ViridianForestWildMons` (03:5121); ROM 0e:7747 |
| 013 | Weedle | 3 | Wild encounter — Route 2 (grass/cave); or Wild encounter — Viridian Forest (grass/cave) | `Route2WildMons` (03:50f5); `ViridianForestWildMons` (03:5121) |
| 014 | Kakuna | 4 | Wild encounter — Viridian Forest (grass/cave) | `ViridianForestWildMons` (03:5121) |
| 015 | Beedrill | 10 | Wild encounter — Viridian Forest (grass/cave); evolve Kakuna at level 10 | `ViridianForestWildMons` (03:5121); ROM 0e:76e9 |
| 016 | Pidgey | 2 | Wild encounter — Route 1 (grass/cave) | `Route1WildMons` (03:50df) |
| 017 | Pidgeotto | 18 | Wild encounter — Route 1 (grass/cave); evolve Pidgey at level 18 | `Route1WildMons` (03:50df); ROM 0e:739c |
| 018 | Pidgeot | 36 | Wild encounter — Route 1 (grass/cave); evolve Pidgey at level 18; evolve Pidgeotto at level 36 | `Route1WildMons` (03:50df); ROM 0e:739c; ROM 0e:7823 |
| 019 | Rattata | 2 | Wild encounter — Route 1 (grass/cave); or Wild encounter — Route 2 (grass/cave); or Wild encounter — Route 22 (grass/cave) | `Route1WildMons` (03:50df); `Route2WildMons` (03:50f5); `Route22WildMons` (03:510b) |
| 020 | Raticate | 20 | Wild encounter — Route 1 (grass/cave); evolve Rattata at level 20 | `Route1WildMons` (03:50df); ROM 0e:78c1 |
| 021 | Spearow | 3 | Wild encounter — Route 22 (grass/cave) | `Route22WildMons` (03:510b) |
| 022 | Fearow | 20 | Wild encounter — Route 22 (grass/cave); evolve Spearow at level 20 | `Route22WildMons` (03:510b); ROM 0e:7215 |
| 023 | Ekans | 6 | Wild encounter — Route 4 (grass/cave) | `Route4WildMons` (03:518f) |
| 024 | Arbok | 22 | Wild encounter — Route 4 (grass/cave); evolve Ekans at level 22 | `Route4WildMons` (03:518f); ROM 0e:76ae |
| 025 | Pikachu | 3 | Wild encounter — Viridian Forest (grass/cave) | `ViridianForestWildMons` (03:5121) |
| 026 | Raichu | 3 | Wild encounter — Viridian Forest (grass/cave); item-evolve Pikachu | `ViridianForestWildMons` (03:5121); ROM 0e:7592 |
| 027 | Sandshrew | — | Unavailable in normal Red play | — |
| 028 | Sandslash | — | Unavailable in normal Red play | — |
| 029 | Nidoran♀ | 2 | Wild encounter — Route 22 (grass/cave); in-game trade Nidoran♂ for Nidoran♀ | `Route22WildMons` (03:510b); `TradeMons` row 9 (1c:5bf9); `UndergroundPathRoute5LittleGirlText` (17:56b2) |
| 030 | Nidorina | 16 | Wild encounter — Route 22 (grass/cave); evolve Nidoran♀ at level 16; or Wild encounter — Route 22 (grass/cave); evolve Nidoran♂ at level 16; in-game trade Nidorino for Nidorina; or Wild encounter — Route 22 (grass/cave); in-game trade Nidoran♂ for Nidoran♀; evolve Nidoran♀ at level 16 | `Route22WildMons` (03:510b); ROM 0e:7297; `Route22WildMons` (03:510b); ROM 0e:71f2; `TradeMons` row 0 (1c:5b7b); `Route11Gate2FYoungsterText` (12:545f); `Route22WildMons` (03:510b); `TradeMons` row 9 (1c:5bf9); `UndergroundPathRoute5LittleGirlText` (17:56b2); ROM 0e:7297 |
| 031 | Nidoqueen | 16 | Wild encounter — Route 22 (grass/cave); evolve Nidoran♀ at level 16; item-evolve Nidorina | `Route22WildMons` (03:510b); ROM 0e:7297; ROM 0e:78ea |
| 032 | Nidoran♂ | 2 | Wild encounter — Route 22 (grass/cave) | `Route22WildMons` (03:510b) |
| 033 | Nidorino | 16 | Wild encounter — Route 22 (grass/cave); evolve Nidoran♂ at level 16 | `Route22WildMons` (03:510b); ROM 0e:71f2 |
| 034 | Nidoking | 16 | Wild encounter — Route 22 (grass/cave); evolve Nidoran♂ at level 16; item-evolve Nidorino | `Route22WildMons` (03:510b); ROM 0e:71f2; ROM 0e:78d8 |
| 035 | Clefairy | 8 | Celadon Game Corner prize; or Wild encounter — Mt. Moon 1F (grass/cave) | `PrizeMonLevelDictionary` (14:698a); `MtMoon1FWildMons` (03:514d) |
| 036 | Clefable | 8 | Wild encounter — Mt. Moon 1F (grass/cave); item-evolve Clefairy | `MtMoon1FWildMons` (03:514d); ROM 0e:7203 |
| 037 | Vulpix | — | Unavailable in normal Red play | — |
| 038 | Ninetales | — | Unavailable in normal Red play | — |
| 039 | Jigglypuff | 3 | Wild encounter — Route 3 (grass/cave) | `Route3WildMons` (03:5137) |
| 040 | Wigglytuff | 3 | Wild encounter — Route 3 (grass/cave); item-evolve Jigglypuff | `Route3WildMons` (03:5137); ROM 0e:762e |
| 041 | Zubat | 6 | Wild encounter — Mt. Moon 1F (grass/cave) | `MtMoon1FWildMons` (03:514d) |
| 042 | Golbat | 22 | Wild encounter — Mt. Moon 1F (grass/cave); evolve Zubat at level 22 | `MtMoon1FWildMons` (03:514d); ROM 0e:769f |
| 043 | Oddish | 12 | Wild encounter — Route 24 (grass/cave); or Wild encounter — Route 25 (grass/cave) | `Route24WildMons` (03:51a5); `Route25WildMons` (03:51bb) |
| 044 | Gloom | 21 | Wild encounter — Route 24 (grass/cave); evolve Oddish at level 21 | `Route24WildMons` (03:51a5); ROM 0e:7992 |
| 045 | Vileplume | 21 | Wild encounter — Route 24 (grass/cave); evolve Oddish at level 21; item-evolve Gloom | `Route24WildMons` (03:51a5); ROM 0e:7992; ROM 0e:79a3 |
| 046 | Paras | 8 | Wild encounter — Mt. Moon 1F (grass/cave) | `MtMoon1FWildMons` (03:514d) |
| 047 | Parasect | 24 | Wild encounter — Mt. Moon 1F (grass/cave); evolve Paras at level 24 | `MtMoon1FWildMons` (03:514d); ROM 0e:76bd |
| 048 | Venonat | 22 | Wild encounter — Safari Zone Center (grass/cave) | `SafariZoneCenterWildMons` (03:53a3) |
| 049 | Venomoth | 31 | Wild encounter — Safari Zone West (grass/cave) | `SafariZoneWestWildMons` (03:53e5) |
| 050 | Diglett | 15 | Wild encounter — Diglett’s Cave (grass/cave) | `DiglettsCaveWildMons` (03:55b1) |
| 051 | Dugtrio | 26 | Wild encounter — Diglett’s Cave (grass/cave); evolve Diglett at level 26 | `DiglettsCaveWildMons` (03:55b1); ROM 0e:74c2 |
| 052 | Meowth | — | Unavailable in normal Red play | — |
| 053 | Persian | — | Unavailable in normal Red play | — |
| 054 | Psyduck | 15 | Super Rod — group 3; or Super Rod — group 6 | `SuperRodData.Group3` (03:6987); `SuperRodData.Group6` (03:6998) |
| 055 | Golduck | 33 | Super Rod — group 3; evolve Psyduck at level 33 | `SuperRodData.Group3` (03:6987); ROM 0e:7439 |
| 056 | Mankey | 10 | Wild encounter — Route 5 (grass/cave); or Wild encounter — Route 6 (grass/cave) | `Route5WildMons` (03:51e7); `Route6WildMons` (03:51fd) |
| 057 | Primeape | 28 | Wild encounter — Route 5 (grass/cave); evolve Mankey at level 28 | `Route5WildMons` (03:51e7); ROM 0e:74a4 |
| 058 | Growlithe | 15 | Wild encounter — Route 8 (grass/cave) | `Route8WildMons` (03:5281) |
| 059 | Arcanine | 15 | Wild encounter — Route 8 (grass/cave); item-evolve Growlithe | `Route8WildMons` (03:5281); ROM 0e:7374 |
| 060 | Poliwag | 10 | Good Rod | `GoodRodMons` (03:627f) |
| 061 | Poliwhirl | 23 | Super Rod — group 5 | `SuperRodData.Group5` (03:6993) |
| 062 | Poliwrath | 23 | Super Rod — group 5; item-evolve Poliwhirl | `SuperRodData.Group5` (03:6993); ROM 0e:76cc |
| 063 | Abra | 8 | Wild encounter — Route 24 (grass/cave) | `Route24WildMons` (03:51a5) |
| 064 | Kadabra | 16 | Wild encounter — Route 24 (grass/cave); evolve Abra at level 16 | `Route24WildMons` (03:51a5); ROM 0e:7810 |
| 065 | Alakazam | 16 | Wild encounter — Route 24 (grass/cave); evolve Abra at level 16; trade-evolve Kadabra | `Route24WildMons` (03:51a5); ROM 0e:7810; ROM 0e:73be |
| 066 | Machop | 15 | Wild encounter — Rock Tunnel 1F (grass/cave); or Wild encounter — Rock Tunnel B1F (grass/cave) | `RockTunnel1FWildMons` (03:5229); `RockTunnelB1FWildMons` (03:523f) |
| 067 | Machoke | 28 | Wild encounter — Rock Tunnel 1F (grass/cave); evolve Machop at level 28 | `RockTunnel1FWildMons` (03:5229); ROM 0e:7690 |
| 068 | Machamp | 28 | Wild encounter — Rock Tunnel 1F (grass/cave); evolve Machop at level 28; trade-evolve Machoke | `RockTunnel1FWildMons` (03:5229); ROM 0e:7690; ROM 0e:73ee |
| 069 | Bellsprout | — | Unavailable in normal Red play | — |
| 070 | Weepinbell | — | Unavailable in normal Red play | — |
| 071 | Victreebel | — | Unavailable in normal Red play | — |
| 072 | Tentacool | 5 | Super Rod — group 7; or Wild encounter — Route 21 (water); or Wild encounter — Sea Routes (water) | `SuperRodData.Group7` (03:69a1); `Route21WildMons` (03:54d7); `SeaRoutesWildMons` (03:53fb) |
| 073 | Tentacruel | 30 | Wild encounter — Route 21 (water); evolve Tentacool at level 30 | `Route21WildMons` (03:54d7); ROM 0e:7306 |
| 074 | Geodude | 7 | Wild encounter — Mt. Moon B1F (grass/cave) | `MtMoonB1FWildMons` (03:5163) |
| 075 | Graveler | 25 | Wild encounter — Mt. Moon B1F (grass/cave); evolve Geodude at level 25 | `MtMoonB1FWildMons` (03:5163); ROM 0e:78fc |
| 076 | Golem | 25 | Wild encounter — Mt. Moon B1F (grass/cave); evolve Geodude at level 25; trade-evolve Graveler | `MtMoonB1FWildMons` (03:5163); ROM 0e:78fc; ROM 0e:73cf |
| 077 | Ponyta | 28 | Wild encounter — Pokémon Mansion 1F (grass/cave); or Wild encounter — Pokémon Mansion 2F (grass/cave) | `PokemonMansion1FWildMons` (03:547f); `PokemonMansion2FWildMons` (03:5495) |
| 078 | Rapidash | 40 | Wild encounter — Pokémon Mansion 1F (grass/cave); evolve Ponyta at level 40 | `PokemonMansion1FWildMons` (03:547f); ROM 0e:78a2 |
| 079 | Slowpoke | 15 | Super Rod — group 5; or Super Rod — group 6 | `SuperRodData.Group5` (03:6993); `SuperRodData.Group6` (03:6998) |
| 080 | Slowbro | 23 | Super Rod — group 9 | `SuperRodData.Group9` (03:69b3) |
| 081 | Magnemite | 21 | Wild encounter — Power Plant (grass/cave) | `PowerPlantWildMons` (03:5543) |
| 082 | Magneton | 30 | Wild encounter — Power Plant (grass/cave); evolve Magnemite at level 30 | `PowerPlantWildMons` (03:5543); ROM 0e:7923 |
| 083 | Farfetch’d | 3 | Wild encounter — Route 22 (grass/cave); in-game trade Spearow for Farfetch’d | `Route22WildMons` (03:510b); `TradeMons` row 4 (1c:5bb3); `VermilionTradeHouseLittleGirlText` (06:5c17) |
| 084 | Doduo | 18 | Wild encounter — Route 16 (grass/cave) | `Route16WildMons` (03:5361) |
| 085 | Dodrio | 31 | Wild encounter — Route 16 (grass/cave); evolve Doduo at level 31 | `Route16WildMons` (03:5361); ROM 0e:7512 |
| 086 | Seel | 28 | Wild encounter — Seafoam Islands B1F (grass/cave) | `SeafoamIslandsB1FWildMons` (03:5427) |
| 087 | Dewgong | 34 | Wild encounter — Seafoam Islands B1F (grass/cave); evolve Seel at level 34 | `SeafoamIslandsB1FWildMons` (03:5427); ROM 0e:74b3 |
| 088 | Grimer | 30 | Wild encounter — Pokémon Mansion 1F (grass/cave); or Wild encounter — Pokémon Mansion 2F (grass/cave) | `PokemonMansion1FWildMons` (03:547f); `PokemonMansion2FWildMons` (03:5495) |
| 089 | Muk | 37 | Wild encounter — Pokémon Mansion 2F (grass/cave) | `PokemonMansion2FWildMons` (03:5495) |
| 090 | Shellder | 15 | Super Rod — group 4; or Super Rod — group 8 | `SuperRodData.Group4` (03:698e); `SuperRodData.Group8` (03:69aa) |
| 091 | Cloyster | 15 | Super Rod — group 4; item-evolve Shellder | `SuperRodData.Group4` (03:698e); ROM 0e:72f6 |
| 092 | Gastly | 18 | Wild encounter — Pokémon Tower 3F (grass/cave); or Wild encounter — Pokémon Tower 4F (grass/cave); or Wild encounter — Pokémon Tower 5F (grass/cave) | `PokemonTower3FWildMons` (03:52b1); `PokemonTower4FWildMons` (03:52c7); `PokemonTower5FWildMons` (03:52dd) |
| 093 | Haunter | 25 | Wild encounter — Pokémon Tower 3F (grass/cave); or Wild encounter — Pokémon Tower 4F (grass/cave); or Wild encounter — Pokémon Tower 5F (grass/cave) | `PokemonTower3FWildMons` (03:52b1); `PokemonTower4FWildMons` (03:52c7); `PokemonTower5FWildMons` (03:52dd) |
| 094 | Gengar | 25 | Wild encounter — Pokémon Tower 3F (grass/cave); trade-evolve Haunter | `PokemonTower3FWildMons` (03:52b1); ROM 0e:7807 |
| 095 | Onix | 13 | Wild encounter — Rock Tunnel 1F (grass/cave); or Wild encounter — Rock Tunnel B1F (grass/cave) | `RockTunnel1FWildMons` (03:5229); `RockTunnelB1FWildMons` (03:523f) |
| 096 | Drowzee | 9 | Wild encounter — Route 11 (grass/cave) | `Route11WildMons` (03:5213) |
| 097 | Hypno | 26 | Wild encounter — Route 11 (grass/cave); evolve Drowzee at level 26 | `Route11WildMons` (03:5213); ROM 0e:7448 |
| 098 | Krabby | 15 | Super Rod — group 10; or Super Rod — group 3; or Super Rod — group 4; or Super Rod — group 6; or Super Rod — group 7 | `SuperRodData.Group10` (03:69bc); `SuperRodData.Group3` (03:6987); `SuperRodData.Group4` (03:698e); `SuperRodData.Group6` (03:6998); `SuperRodData.Group7` (03:69a1) |
| 099 | Kingler | 23 | Super Rod — group 9 | `SuperRodData.Group9` (03:69b3) |
| 100 | Voltorb | 14 | Wild encounter — Route 10 (grass/cave) | `Route10WildMons` (03:5255) |
| 101 | Electrode | 3 | Wild encounter — Viridian Forest (grass/cave); item-evolve Pikachu; in-game trade Raichu for Electrode | `ViridianForestWildMons` (03:5121); ROM 0e:7592; `TradeMons` row 7 (1c:5bdd); `CinnabarLabTradeRoomGrampsText` (1d:5c2f) |
| 102 | Exeggcute | 23 | Wild encounter — Safari Zone East (grass/cave) | `SafariZoneEastWildMons` (03:53b9) |
| 103 | Exeggutor | 23 | Wild encounter — Safari Zone East (grass/cave); item-evolve Exeggcute | `SafariZoneEastWildMons` (03:53b9); ROM 0e:726e |
| 104 | Cubone | 20 | Wild encounter — Pokémon Tower 3F (grass/cave); or Wild encounter — Pokémon Tower 4F (grass/cave); or Wild encounter — Pokémon Tower 5F (grass/cave) | `PokemonTower3FWildMons` (03:52b1); `PokemonTower4FWildMons` (03:52c7); `PokemonTower5FWildMons` (03:52dd) |
| 105 | Marowak | 28 | Wild encounter — Pokémon Tower 3F (grass/cave); evolve Cubone at level 28 | `PokemonTower3FWildMons` (03:52b1); ROM 0e:72b0 |
| 106 | Hitmonlee | 30 | Fighting Dojo gift | `FightingDojoHitmonleePokeBallText` (17:4f16) |
| 107 | Hitmonchan | 30 | Fighting Dojo gift | `FightingDojoHitmonchanPokeBallText` (17:4f5e) |
| 108 | Lickitung | 23 | Super Rod — group 9; in-game trade Slowbro for Lickitung | `SuperRodData.Group9` (03:69b3); `TradeMons` row 5 (1c:5bc1); `Route18Gate2FYoungsterText` (12:597e) |
| 109 | Koffing | 30 | Wild encounter — Pokémon Mansion 1F (grass/cave); or Wild encounter — Pokémon Mansion 2F (grass/cave) | `PokemonMansion1FWildMons` (03:547f); `PokemonMansion2FWildMons` (03:5495) |
| 110 | Weezing | 35 | Wild encounter — Pokémon Mansion 1F (grass/cave); evolve Koffing at level 35 | `PokemonMansion1FWildMons` (03:547f); ROM 0e:7493 |
| 111 | Rhyhorn | 25 | Wild encounter — Safari Zone Center (grass/cave) | `SafariZoneCenterWildMons` (03:53a3) |
| 112 | Rhydon | 42 | Wild encounter — Safari Zone Center (grass/cave); evolve Rhyhorn at level 42 | `SafariZoneCenterWildMons` (03:53a3); ROM 0e:72bf |
| 113 | Chansey | 23 | Wild encounter — Safari Zone Center (grass/cave) | `SafariZoneCenterWildMons` (03:53a3) |
| 114 | Tangela | 22 | Wild encounter — Safari Zone Center (grass/cave); in-game trade Venonat for Tangela | `SafariZoneCenterWildMons` (03:53a3); `TradeMons` row 8 (1c:5beb); `CinnabarLabTradeRoomBeautyText` (1d:5c37) |
| 115 | Kangaskhan | 25 | Wild encounter — Safari Zone East (grass/cave) | `SafariZoneEastWildMons` (03:53b9) |
| 116 | Horsea | 15 | Super Rod — group 8 | `SuperRodData.Group8` (03:69aa) |
| 117 | Seadra | 23 | Super Rod — group 9 | `SuperRodData.Group9` (03:69b3) |
| 118 | Goldeen | 10 | Good Rod | `GoodRodMons` (03:627f) |
| 119 | Seaking | 23 | Super Rod — group 10; or Super Rod — group 9 | `SuperRodData.Group10` (03:69bc); `SuperRodData.Group9` (03:69b3) |
| 120 | Staryu | 15 | Super Rod — group 8 | `SuperRodData.Group8` (03:69aa) |
| 121 | Starmie | 15 | Super Rod — group 8; item-evolve Staryu | `SuperRodData.Group8` (03:69aa); ROM 0e:7332 |
| 122 | Mr. Mime | 8 | Wild encounter — Route 24 (grass/cave); in-game trade Abra for Mr. Mime | `Route24WildMons` (03:51a5); `TradeMons` row 1 (1c:5b89); `Route2TradeHouseScientistText` (07:5ef9) |
| 123 | Scyther | 23 | Wild encounter — Safari Zone Center (grass/cave) | `SafariZoneCenterWildMons` (03:53a3) |
| 124 | Jynx | 23 | Super Rod — group 5; in-game trade Poliwhirl for Jynx | `SuperRodData.Group5` (03:6993); `TradeMons` row 6 (1c:5bcf); `CeruleanTradeHouseGrannyText` (07:5702) |
| 125 | Electabuzz | 33 | Wild encounter — Power Plant (grass/cave) | `PowerPlantWildMons` (03:5543) |
| 126 | Magmar | — | Unavailable in normal Red play | — |
| 127 | Pinsir | — | Unavailable in normal Red play | — |
| 128 | Tauros | 26 | Wild encounter — Safari Zone West (grass/cave) | `SafariZoneWestWildMons` (03:53e5) |
| 129 | Magikarp | 5 | Mt. Moon Pokémon Center purchase; or Old Rod | `MtMoonPokecenterMagikarpSalesmanText` (12:531e); `ItemUseOldRod` (03:624c) |
| 130 | Gyarados | 20 | Old Rod; evolve Magikarp at level 20 | `ItemUseOldRod` (03:624c); ROM 0e:77a6 |
| 131 | Lapras | 15 | Silph Co. gift | `SilphCo7FSilphWorkerM1Text` (14:5dab) |
| 132 | Ditto | 23 | Wild encounter — Route 14 (grass/cave) | `Route14WildMons` (03:5335) |
| 133 | Eevee | 25 | Celadon Mansion gift | `CeladonMansionRoofHouseEeveePokeballText` (07:5d47) |
| 134 | Vaporeon | 25 | Celadon Mansion gift; item-evolve Eevee | `CeladonMansionRoofHouseEeveePokeballText` (07:5d47); ROM 0e:764c |
| 135 | Jolteon | 25 | Celadon Mansion gift; item-evolve Eevee | `CeladonMansionRoofHouseEeveePokeballText` (07:5d47); ROM 0e:7648 |
| 136 | Flareon | 25 | Celadon Mansion gift; item-evolve Eevee | `CeladonMansionRoofHouseEeveePokeballText` (07:5d47); ROM 0e:7644 |
| 137 | Porygon | 26 | Celadon Game Corner prize | `PrizeMonLevelDictionary` (14:698a) |
| 138 | Omanyte | 30 | Helix Fossil revival | `GiveFossilToCinnabarLab` (18:505b); `CinnabarLabFossilRoomScientist1Text` (1d:5db0) |
| 139 | Omastar | 40 | Helix Fossil revival; evolve Omanyte at level 40 | `GiveFossilToCinnabarLab` (18:505b); `CinnabarLabFossilRoomScientist1Text` (1d:5db0); ROM 0e:7617 |
| 140 | Kabuto | 30 | Dome Fossil revival | `GiveFossilToCinnabarLab` (18:505b); `CinnabarLabFossilRoomScientist1Text` (1d:5db0) |
| 141 | Kabutops | 40 | Dome Fossil revival; evolve Kabuto at level 40 | `GiveFossilToCinnabarLab` (18:505b); `CinnabarLabFossilRoomScientist1Text` (1d:5db0); ROM 0e:75c6 |
| 142 | Aerodactyl | 30 | Old Amber revival | `GiveFossilToCinnabarLab` (18:505b); `CinnabarLabFossilRoomScientist1Text` (1d:5db0) |
| 143 | Snorlax | 30 | Static encounter — Route 12 | `Route12DefaultScript` (16:562f) |
| 144 | Articuno | 50 | Static encounter — Seafoam Islands | `SeafoamIslandsB4F_Object` (11:68e8) |
| 145 | Zapdos | 50 | Static encounter — Power Plant | `PowerPlant_Object` (07:6415) |
| 146 | Moltres | 50 | Static encounter — Victory Road | `VictoryRoad2F_Object` (14:5963) |
| 147 | Dratini | 15 | Super Rod — group 6 | `SuperRodData.Group6` (03:6998) |
| 148 | Dragonair | 30 | Super Rod — group 6; evolve Dratini at level 30 | `SuperRodData.Group6` (03:6998); ROM 0e:75a8 |
| 149 | Dragonite | 55 | Super Rod — group 6; evolve Dratini at level 30; evolve Dragonair at level 55 | `SuperRodData.Group6` (03:6998); ROM 0e:75a8; ROM 0e:75b7 |
| 150 | Mewtwo | 70 | Static encounter — Cerulean Cave | `CeruleanCaveB1F_Object` (11:5f44) |
| 151 | Mew | — | Unavailable in normal Red play | — |
