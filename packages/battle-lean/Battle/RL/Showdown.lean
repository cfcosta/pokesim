/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.RL.DynamicGenerator

/-!
# Pokémon Showdown team export

Display-only names and serialization for generated Generation-I teams. This
module does not participate in mechanics or canonical-ROM proofs.
-/

namespace Battle.RL.Showdown

private def speciesNames : Array String := #[
  "Bulbasaur", "Ivysaur", "Venusaur", "Charmander", "Charmeleon", "Charizard",
  "Squirtle", "Wartortle", "Blastoise", "Caterpie", "Metapod", "Butterfree",
  "Weedle", "Kakuna", "Beedrill", "Pidgey", "Pidgeotto", "Pidgeot",
  "Rattata", "Raticate", "Spearow", "Fearow", "Ekans", "Arbok",
  "Pikachu", "Raichu", "Sandshrew", "Sandslash", "Nidoran-F", "Nidorina",
  "Nidoqueen", "Nidoran-M", "Nidorino", "Nidoking", "Clefairy", "Clefable",
  "Vulpix", "Ninetales", "Jigglypuff", "Wigglytuff", "Zubat", "Golbat",
  "Oddish", "Gloom", "Vileplume", "Paras", "Parasect", "Venonat",
  "Venomoth", "Diglett", "Dugtrio", "Meowth", "Persian", "Psyduck",
  "Golduck", "Mankey", "Primeape", "Growlithe", "Arcanine", "Poliwag",
  "Poliwhirl", "Poliwrath", "Abra", "Kadabra", "Alakazam", "Machop",
  "Machoke", "Machamp", "Bellsprout", "Weepinbell", "Victreebel", "Tentacool",
  "Tentacruel", "Geodude", "Graveler", "Golem", "Ponyta", "Rapidash",
  "Slowpoke", "Slowbro", "Magnemite", "Magneton", "Farfetch'd", "Doduo",
  "Dodrio", "Seel", "Dewgong", "Grimer", "Muk", "Shellder",
  "Cloyster", "Gastly", "Haunter", "Gengar", "Onix", "Drowzee",
  "Hypno", "Krabby", "Kingler", "Voltorb", "Electrode", "Exeggcute",
  "Exeggutor", "Cubone", "Marowak", "Hitmonlee", "Hitmonchan", "Lickitung",
  "Koffing", "Weezing", "Rhyhorn", "Rhydon", "Chansey", "Tangela",
  "Kangaskhan", "Horsea", "Seadra", "Goldeen", "Seaking", "Staryu",
  "Starmie", "Mr. Mime", "Scyther", "Jynx", "Electabuzz", "Magmar",
  "Pinsir", "Tauros", "Magikarp", "Gyarados", "Lapras", "Ditto",
  "Eevee", "Vaporeon", "Jolteon", "Flareon", "Porygon", "Omanyte",
  "Omastar", "Kabuto", "Kabutops", "Aerodactyl", "Snorlax", "Articuno",
  "Zapdos", "Moltres", "Dratini", "Dragonair", "Dragonite", "Mewtwo",
  "Mew"
]

private def moveNames : Array String := #[
  "Pound", "Karate Chop", "Double Slap", "Comet Punch", "Mega Punch", "Pay Day",
  "Fire Punch", "Ice Punch", "Thunder Punch", "Scratch", "Vice Grip", "Guillotine",
  "Razor Wind", "Swords Dance", "Cut", "Gust", "Wing Attack", "Whirlwind",
  "Fly", "Bind", "Slam", "Vine Whip", "Stomp", "Double Kick",
  "Mega Kick", "Jump Kick", "Rolling Kick", "Sand Attack", "Headbutt", "Horn Attack",
  "Fury Attack", "Horn Drill", "Tackle", "Body Slam", "Wrap", "Take Down",
  "Thrash", "Double-Edge", "Tail Whip", "Poison Sting", "Twineedle", "Pin Missile",
  "Leer", "Bite", "Growl", "Roar", "Sing", "Supersonic",
  "Sonic Boom", "Disable", "Acid", "Ember", "Flamethrower", "Mist",
  "Water Gun", "Hydro Pump", "Surf", "Ice Beam", "Blizzard", "Psybeam",
  "Bubble Beam", "Aurora Beam", "Hyper Beam", "Peck", "Drill Peck", "Submission",
  "Low Kick", "Counter", "Seismic Toss", "Strength", "Absorb", "Mega Drain",
  "Leech Seed", "Growth", "Razor Leaf", "Solar Beam", "Poison Powder", "Stun Spore",
  "Sleep Powder", "Petal Dance", "String Shot", "Dragon Rage", "Fire Spin", "Thunder Shock",
  "Thunderbolt", "Thunder Wave", "Thunder", "Rock Throw", "Earthquake", "Fissure",
  "Dig", "Toxic", "Confusion", "Psychic", "Hypnosis", "Meditate",
  "Agility", "Quick Attack", "Rage", "Teleport", "Night Shade", "Mimic",
  "Screech", "Double Team", "Recover", "Harden", "Minimize", "Smokescreen",
  "Confuse Ray", "Withdraw", "Defense Curl", "Barrier", "Light Screen", "Haze",
  "Reflect", "Focus Energy", "Bide", "Metronome", "Mirror Move", "Self-Destruct",
  "Egg Bomb", "Lick", "Smog", "Sludge", "Bone Club", "Fire Blast",
  "Waterfall", "Clamp", "Swift", "Skull Bash", "Spike Cannon", "Constrict",
  "Amnesia", "Kinesis", "Soft-Boiled", "High Jump Kick", "Glare", "Dream Eater",
  "Poison Gas", "Barrage", "Leech Life", "Lovely Kiss", "Sky Attack", "Transform",
  "Bubble", "Dizzy Punch", "Spore", "Flash", "Psywave", "Splash",
  "Acid Armor", "Crabhammer", "Explosion", "Fury Swipes", "Bonemerang", "Rest",
  "Rock Slide", "Hyper Fang", "Sharpen", "Conversion", "Tri Attack", "Super Fang",
  "Slash", "Substitute", "Struggle"
]

/-- Showdown-compatible species spelling, indexed through the canonical
internal-index-to-Pokédex map. -/
def speciesName (species : SpeciesId) : String :=
  let dex := Data.internalToDex species
  if dex == 0 then s!"MissingNo-{species.toNat}"
  else speciesNames.getD (dex.toNat - 1) s!"Species-{species.toNat}"

/-- Showdown-compatible move spelling. Move zero is an empty slot. -/
def moveName (move : MoveId) : String :=
  if move == 0 then ""
  else moveNames.getD (move.toNat - 1) s!"Move-{move.toNat}"

private def dvAttack (mon : MonState) : Nat := (mon.dvs.toNat >>> 12) &&& 0x0F
private def dvDefense (mon : MonState) : Nat := (mon.dvs.toNat >>> 8) &&& 0x0F
private def dvSpeed (mon : MonState) : Nat := (mon.dvs.toNat >>> 4) &&& 0x0F
private def dvSpecial (mon : MonState) : Nat := mon.dvs.toNat &&& 0x0F
private def dvHp (mon : MonState) : Nat :=
  Battle.RL.hpDV (dvAttack mon).toUInt8 (dvDefense mon).toUInt8
    (dvSpeed mon).toUInt8 (dvSpecial mon).toUInt8 |>.toNat

/-- Showdown stores IVs even for old generations. `2 * DV + 1` round-trips to
the same Generation-I DV under Showdown's integer division. -/
private def showdownIv (dv : Nat) : Nat := 2 * dv + 1

/-- One importable Pokémon Showdown set. Packed PP/PP-Up state has no Showdown
team-text field and is therefore deliberately omitted. -/
def formatMon (mon : MonState) : String :=
  let special := showdownIv (dvSpecial mon)
  let ivs := s!"IVs: {showdownIv (dvHp mon)} HP / {showdownIv (dvAttack mon)} Atk / {showdownIv (dvDefense mon)} Def / {special} SpA / {special} SpD / {showdownIv (dvSpeed mon)} Spe"
  let moves := mon.moves.toList.filter (· != 0) |>.map fun move => s!"- {moveName move}"
  String.intercalate "\n" ([speciesName mon.species, s!"Level: {mon.level.toNat}", ivs] ++ moves)

/-- A complete Showdown team-list section. Multiple sections may be concatenated
and imported together. -/
def formatTeam (name : String) (team : Array MonState) : String :=
  let sets := team.toList.map formatMon
  s!"=== [gen1customgame] {name} ===\n\n" ++ String.intercalate "\n\n" sets

@[simp] theorem species_name_table_complete : speciesNames.size = 151 := by native_decide
@[simp] theorem move_name_table_complete : moveNames.size = 165 := by native_decide
@[simp] theorem no_move_name : moveName 0 = "" := by rfl

end Battle.RL.Showdown
