/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Types
import Battle.TypeChart

/-!
# Species data — the Gen-1 `BaseStats` table, transcribed 1:1

Every species' base-stat header, from pokered `data/pokemon/base_stats/*.asm`,
laid out exactly as the ROM lays it out:

* `baseStats` is the `BaseStats:` table in **national-dex order** — each entry's
  first byte is its dex number and `baseStats[d-1]` is dex `d`
  (`data/pokemon/base_stats.asm` includes the files in dex order). We keep the
  five base stats, the two types, the catch rate, and the base-exp yield — the
  battle-relevant header bytes (`db dex; db hp,atk,def,spd,spc; db type1,type2;
  db catch; db exp`).
* `pokedexOrder` is the `PokedexOrder:` table (`data/pokemon/dex_order.asm`),
  which maps an **internal** index (the byte the party/box/battle structs store,
  `constants/pokemon_constants.asm`) to a national-dex number, `0` for the 39
  MissingNo slots. The model's `SpeciesId` is the internal index, so a header
  lookup goes internal → `pokedexOrder` → dex → `baseStats`.

Transcribed from pret/pokered @ `405b6246372d7e5a2cb029cbb65219b13286b8c9` by a
deterministic parser over the disassembly (not hand-typed). `Battle.Rom.Tables`
decodes the canonical 150-row block plus detached `MewBaseStats` row and
`RequiredTableBytes.baseStats` proves agreement with this array. Only the 151
real species are data-backed—the fossil/ghost internal ids and MissingNo slots
carry no base-stats row, so they resolve to `default`.
-/

namespace Battle.Data

open Battle.TypeChart
  (normal fighting flying poison ground rock bird bug ghost fire water grass electric psychic ice dragon)

/-- A species' base-stat header — the battle-relevant bytes of a `BaseStats`
    entry. `dexNum` is the entry's leading national-dex byte. -/
structure SpeciesData where
  dexNum    : UInt8
  baseHp    : UInt8
  baseAtk   : UInt8
  baseDef   : UInt8
  baseSpd   : UInt8
  baseSpc   : UInt8
  type1     : UInt8
  type2     : UInt8
  catchRate : UInt8
  baseExp   : UInt8
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Row helper mirroring the base_stats field order:
    `sp DEX HP ATK DEF SPD SPC TYPE1 TYPE2 CATCH EXP`. -/
def sp (dex hp atk df spd spc : Nat) (t1 t2 : UInt8) (cat exp : Nat) : SpeciesData :=
  { dexNum := dex.toUInt8, baseHp := hp.toUInt8, baseAtk := atk.toUInt8,
    baseDef := df.toUInt8, baseSpd := spd.toUInt8, baseSpc := spc.toUInt8,
    type1 := t1, type2 := t2, catchRate := cat.toUInt8, baseExp := exp.toUInt8 }

/-- `BaseStats` — every species' header in national-dex order (`baseStats[d-1]`
    is dex `d`). -/
def baseStats : Array SpeciesData := #[
  sp   1  45  49  49  45  65 grass    poison    45  64,  -- #001 BULBASAUR
  sp   2  60  62  63  60  80 grass    poison    45 141,  -- #002 IVYSAUR
  sp   3  80  82  83  80 100 grass    poison    45 208,  -- #003 VENUSAUR
  sp   4  39  52  43  65  50 fire     fire      45  65,  -- #004 CHARMANDER
  sp   5  58  64  58  80  65 fire     fire      45 142,  -- #005 CHARMELEON
  sp   6  78  84  78 100  85 fire     flying    45 209,  -- #006 CHARIZARD
  sp   7  44  48  65  43  50 water    water     45  66,  -- #007 SQUIRTLE
  sp   8  59  63  80  58  65 water    water     45 143,  -- #008 WARTORTLE
  sp   9  79  83 100  78  85 water    water     45 210,  -- #009 BLASTOISE
  sp  10  45  30  35  45  20 bug      bug      255  53,  -- #010 CATERPIE
  sp  11  50  20  55  30  25 bug      bug      120  72,  -- #011 METAPOD
  sp  12  60  45  50  70  80 bug      flying    45 160,  -- #012 BUTTERFREE
  sp  13  40  35  30  50  20 bug      poison   255  52,  -- #013 WEEDLE
  sp  14  45  25  50  35  25 bug      poison   120  71,  -- #014 KAKUNA
  sp  15  65  80  40  75  45 bug      poison    45 159,  -- #015 BEEDRILL
  sp  16  40  45  40  56  35 normal   flying   255  55,  -- #016 PIDGEY
  sp  17  63  60  55  71  50 normal   flying   120 113,  -- #017 PIDGEOTTO
  sp  18  83  80  75  91  70 normal   flying    45 172,  -- #018 PIDGEOT
  sp  19  30  56  35  72  25 normal   normal   255  57,  -- #019 RATTATA
  sp  20  55  81  60  97  50 normal   normal    90 116,  -- #020 RATICATE
  sp  21  40  60  30  70  31 normal   flying   255  58,  -- #021 SPEAROW
  sp  22  65  90  65 100  61 normal   flying    90 162,  -- #022 FEAROW
  sp  23  35  60  44  55  40 poison   poison   255  62,  -- #023 EKANS
  sp  24  60  85  69  80  65 poison   poison    90 147,  -- #024 ARBOK
  sp  25  35  55  30  90  50 electric electric 190  82,  -- #025 PIKACHU
  sp  26  60  90  55 100  90 electric electric  75 122,  -- #026 RAICHU
  sp  27  50  75  85  40  30 ground   ground   255  93,  -- #027 SANDSHREW
  sp  28  75 100 110  65  55 ground   ground    90 163,  -- #028 SANDSLASH
  sp  29  55  47  52  41  40 poison   poison   235  59,  -- #029 NIDORAN_F
  sp  30  70  62  67  56  55 poison   poison   120 117,  -- #030 NIDORINA
  sp  31  90  82  87  76  75 poison   ground    45 194,  -- #031 NIDOQUEEN
  sp  32  46  57  40  50  40 poison   poison   235  60,  -- #032 NIDORAN_M
  sp  33  61  72  57  65  55 poison   poison   120 118,  -- #033 NIDORINO
  sp  34  81  92  77  85  75 poison   ground    45 195,  -- #034 NIDOKING
  sp  35  70  45  48  35  60 normal   normal   150  68,  -- #035 CLEFAIRY
  sp  36  95  70  73  60  85 normal   normal    25 129,  -- #036 CLEFABLE
  sp  37  38  41  40  65  65 fire     fire     190  63,  -- #037 VULPIX
  sp  38  73  76  75 100 100 fire     fire      75 178,  -- #038 NINETALES
  sp  39 115  45  20  20  25 normal   normal   170  76,  -- #039 JIGGLYPUFF
  sp  40 140  70  45  45  50 normal   normal    50 109,  -- #040 WIGGLYTUFF
  sp  41  40  45  35  55  40 poison   flying   255  54,  -- #041 ZUBAT
  sp  42  75  80  70  90  75 poison   flying    90 171,  -- #042 GOLBAT
  sp  43  45  50  55  30  75 grass    poison   255  78,  -- #043 ODDISH
  sp  44  60  65  70  40  85 grass    poison   120 132,  -- #044 GLOOM
  sp  45  75  80  85  50 100 grass    poison    45 184,  -- #045 VILEPLUME
  sp  46  35  70  55  25  55 bug      grass    190  70,  -- #046 PARAS
  sp  47  60  95  80  30  80 bug      grass     75 128,  -- #047 PARASECT
  sp  48  60  55  50  45  40 bug      poison   190  75,  -- #048 VENONAT
  sp  49  70  65  60  90  90 bug      poison    75 138,  -- #049 VENOMOTH
  sp  50  10  55  25  95  45 ground   ground   255  81,  -- #050 DIGLETT
  sp  51  35  80  50 120  70 ground   ground    50 153,  -- #051 DUGTRIO
  sp  52  40  45  35  90  40 normal   normal   255  69,  -- #052 MEOWTH
  sp  53  65  70  60 115  65 normal   normal    90 148,  -- #053 PERSIAN
  sp  54  50  52  48  55  50 water    water    190  80,  -- #054 PSYDUCK
  sp  55  80  82  78  85  80 water    water     75 174,  -- #055 GOLDUCK
  sp  56  40  80  35  70  35 fighting fighting 190  74,  -- #056 MANKEY
  sp  57  65 105  60  95  60 fighting fighting  75 149,  -- #057 PRIMEAPE
  sp  58  55  70  45  60  50 fire     fire     190  91,  -- #058 GROWLITHE
  sp  59  90 110  80  95  80 fire     fire      75 213,  -- #059 ARCANINE
  sp  60  40  50  40  90  40 water    water    255  77,  -- #060 POLIWAG
  sp  61  65  65  65  90  50 water    water    120 131,  -- #061 POLIWHIRL
  sp  62  90  85  95  70  70 water    fighting  45 185,  -- #062 POLIWRATH
  sp  63  25  20  15  90 105 psychic  psychic  200  73,  -- #063 ABRA
  sp  64  40  35  30 105 120 psychic  psychic  100 145,  -- #064 KADABRA
  sp  65  55  50  45 120 135 psychic  psychic   50 186,  -- #065 ALAKAZAM
  sp  66  70  80  50  35  35 fighting fighting 180  88,  -- #066 MACHOP
  sp  67  80 100  70  45  50 fighting fighting  90 146,  -- #067 MACHOKE
  sp  68  90 130  80  55  65 fighting fighting  45 193,  -- #068 MACHAMP
  sp  69  50  75  35  40  70 grass    poison   255  84,  -- #069 BELLSPROUT
  sp  70  65  90  50  55  85 grass    poison   120 151,  -- #070 WEEPINBELL
  sp  71  80 105  65  70 100 grass    poison    45 191,  -- #071 VICTREEBEL
  sp  72  40  40  35  70 100 water    poison   190 105,  -- #072 TENTACOOL
  sp  73  80  70  65 100 120 water    poison    60 205,  -- #073 TENTACRUEL
  sp  74  40  80 100  20  30 rock     ground   255  86,  -- #074 GEODUDE
  sp  75  55  95 115  35  45 rock     ground   120 134,  -- #075 GRAVELER
  sp  76  80 110 130  45  55 rock     ground    45 177,  -- #076 GOLEM
  sp  77  50  85  55  90  65 fire     fire     190 152,  -- #077 PONYTA
  sp  78  65 100  70 105  80 fire     fire      60 192,  -- #078 RAPIDASH
  sp  79  90  65  65  15  40 water    psychic  190  99,  -- #079 SLOWPOKE
  sp  80  95  75 110  30  80 water    psychic   75 164,  -- #080 SLOWBRO
  sp  81  25  35  70  45  95 electric electric 190  89,  -- #081 MAGNEMITE
  sp  82  50  60  95  70 120 electric electric  60 161,  -- #082 MAGNETON
  sp  83  52  65  55  60  58 normal   flying    45  94,  -- #083 FARFETCHD
  sp  84  35  85  45  75  35 normal   flying   190  96,  -- #084 DODUO
  sp  85  60 110  70 100  60 normal   flying    45 158,  -- #085 DODRIO
  sp  86  65  45  55  45  70 water    water    190 100,  -- #086 SEEL
  sp  87  90  70  80  70  95 water    ice       75 176,  -- #087 DEWGONG
  sp  88  80  80  50  25  40 poison   poison   190  90,  -- #088 GRIMER
  sp  89 105 105  75  50  65 poison   poison    75 157,  -- #089 MUK
  sp  90  30  65 100  40  45 water    water    190  97,  -- #090 SHELLDER
  sp  91  50  95 180  70  85 water    ice       60 203,  -- #091 CLOYSTER
  sp  92  30  35  30  80 100 ghost    poison   190  95,  -- #092 GASTLY
  sp  93  45  50  45  95 115 ghost    poison    90 126,  -- #093 HAUNTER
  sp  94  60  65  60 110 130 ghost    poison    45 190,  -- #094 GENGAR
  sp  95  35  45 160  70  30 rock     ground    45 108,  -- #095 ONIX
  sp  96  60  48  45  42  90 psychic  psychic  190 102,  -- #096 DROWZEE
  sp  97  85  73  70  67 115 psychic  psychic   75 165,  -- #097 HYPNO
  sp  98  30 105  90  50  25 water    water    225 115,  -- #098 KRABBY
  sp  99  55 130 115  75  50 water    water     60 206,  -- #099 KINGLER
  sp 100  40  30  50 100  55 electric electric 190 103,  -- #100 VOLTORB
  sp 101  60  50  70 140  80 electric electric  60 150,  -- #101 ELECTRODE
  sp 102  60  40  80  40  60 grass    psychic   90  98,  -- #102 EXEGGCUTE
  sp 103  95  95  85  55 125 grass    psychic   45 212,  -- #103 EXEGGUTOR
  sp 104  50  50  95  35  40 ground   ground   190  87,  -- #104 CUBONE
  sp 105  60  80 110  45  50 ground   ground    75 124,  -- #105 MAROWAK
  sp 106  50 120  53  87  35 fighting fighting  45 139,  -- #106 HITMONLEE
  sp 107  50 105  79  76  35 fighting fighting  45 140,  -- #107 HITMONCHAN
  sp 108  90  55  75  30  60 normal   normal    45 127,  -- #108 LICKITUNG
  sp 109  40  65  95  35  60 poison   poison   190 114,  -- #109 KOFFING
  sp 110  65  90 120  60  85 poison   poison    60 173,  -- #110 WEEZING
  sp 111  80  85  95  25  30 ground   rock     120 135,  -- #111 RHYHORN
  sp 112 105 130 120  40  45 ground   rock      60 204,  -- #112 RHYDON
  sp 113 250   5   5  50 105 normal   normal    30 255,  -- #113 CHANSEY
  sp 114  65  55 115  60 100 grass    grass     45 166,  -- #114 TANGELA
  sp 115 105  95  80  90  40 normal   normal    45 175,  -- #115 KANGASKHAN
  sp 116  30  40  70  60  70 water    water    225  83,  -- #116 HORSEA
  sp 117  55  65  95  85  95 water    water     75 155,  -- #117 SEADRA
  sp 118  45  67  60  63  50 water    water    225 111,  -- #118 GOLDEEN
  sp 119  80  92  65  68  80 water    water     60 170,  -- #119 SEAKING
  sp 120  30  45  55  85  70 water    water    225 106,  -- #120 STARYU
  sp 121  60  75  85 115 100 water    psychic   60 207,  -- #121 STARMIE
  sp 122  40  45  65  90 100 psychic  psychic   45 136,  -- #122 MR_MIME
  sp 123  70 110  80 105  55 bug      flying    45 187,  -- #123 SCYTHER
  sp 124  65  50  35  95  95 ice      psychic   45 137,  -- #124 JYNX
  sp 125  65  83  57 105  85 electric electric  45 156,  -- #125 ELECTABUZZ
  sp 126  65  95  57  93  85 fire     fire      45 167,  -- #126 MAGMAR
  sp 127  65 125 100  85  55 bug      bug       45 200,  -- #127 PINSIR
  sp 128  75 100  95 110  70 normal   normal    45 211,  -- #128 TAUROS
  sp 129  20  10  55  80  20 water    water    255  20,  -- #129 MAGIKARP
  sp 130  95 125  79  81 100 water    flying    45 214,  -- #130 GYARADOS
  sp 131 130  85  80  60  95 water    ice       45 219,  -- #131 LAPRAS
  sp 132  48  48  48  48  48 normal   normal    35  61,  -- #132 DITTO
  sp 133  55  55  50  55  65 normal   normal    45  92,  -- #133 EEVEE
  sp 134 130  65  60  65 110 water    water     45 196,  -- #134 VAPOREON
  sp 135  65  65  60 130 110 electric electric  45 197,  -- #135 JOLTEON
  sp 136  65 130  60  65 110 fire     fire      45 198,  -- #136 FLAREON
  sp 137  65  60  70  40  75 normal   normal    45 130,  -- #137 PORYGON
  sp 138  35  40 100  35  90 rock     water     45 120,  -- #138 OMANYTE
  sp 139  70  60 125  55 115 rock     water     45 199,  -- #139 OMASTAR
  sp 140  30  80  90  55  45 rock     water     45 119,  -- #140 KABUTO
  sp 141  60 115 105  80  70 rock     water     45 201,  -- #141 KABUTOPS
  sp 142  80 105  65 130  60 rock     flying    45 202,  -- #142 AERODACTYL
  sp 143 160 110  65  30  65 normal   normal    25 154,  -- #143 SNORLAX
  sp 144  90  85 100  85 125 ice      flying     3 215,  -- #144 ARTICUNO
  sp 145  90  90  85 100 125 electric flying     3 216,  -- #145 ZAPDOS
  sp 146  90 100  90  90 125 fire     flying     3 217,  -- #146 MOLTRES
  sp 147  41  64  45  50  50 dragon   dragon    45  67,  -- #147 DRATINI
  sp 148  61  84  65  70  70 dragon   dragon    45 144,  -- #148 DRAGONAIR
  sp 149  91 134  95  80 100 dragon   flying    45 218,  -- #149 DRAGONITE
  sp 150 106 110  90 130 154 psychic  psychic    3 220,  -- #150 MEWTWO
  sp 151 100 100 100 100 100 psychic  psychic   45  64  -- #151 MEW
]

/-- `PokedexOrder` — internal index → national-dex number (`0` = MissingNo).
    Internal id `i` maps through `pokedexOrder[i-1]`. -/
def pokedexOrder : Array UInt8 := #[
  112, 115,  32,  35,  21, 100,  34,  80,   2, 103,  -- internal $01..$0A
  108, 102,  88,  94,  29,  31, 104, 111, 131,  59,  -- internal $0B..$14
  151, 130,  90,  72,  92, 123, 120,   9, 127, 114,  -- internal $15..$1E
    0,   0,  58,  95,  22,  16,  79,  64,  75, 113,  -- internal $1F..$28
   67, 122, 106, 107,  24,  47,  54,  96,  76,   0,  -- internal $29..$32
  126,   0, 125,  82, 109,   0,  56,  86,  50, 128,  -- internal $33..$3C
    0,   0,   0,  83,  48, 149,   0,   0,   0,  84,  -- internal $3D..$46
   60, 124, 146, 144, 145, 132,  52,  98,   0,   0,  -- internal $47..$50
    0,  37,  38,  25,  26,   0,   0, 147, 148, 140,  -- internal $51..$5A
  141, 116, 117,   0,   0,  27,  28, 138, 139,  39,  -- internal $5B..$64
   40, 133, 136, 135, 134,  66,  41,  23,  46,  61,  -- internal $65..$6E
   62,  13,  14,  15,   0,  85,  57,  51,  49,  87,  -- internal $6F..$78
    0,   0,  10,  11,  12,  68,   0,  55,  97,  42,  -- internal $79..$82
  150, 143, 129,   0,   0,  89,   0,  99,  91,   0,  -- internal $83..$8C
  101,  36, 110,  53, 105,   0,  93,  63,  65,  17,  -- internal $8D..$96
   18, 121,   1,   3,  73,   0, 118, 119,   0,   0,  -- internal $97..$A0
    0,   0,  77,  78,  19,  20,  33,  30,  74, 137,  -- internal $A1..$AA
  142,   0,  81,   0,   0,   4,   7,   5,   8,   6,  -- internal $AB..$B4
    0,   0,   0,   0,  43,  44,  45,  69,  70,  71  -- internal $B5..$BE
]

/-- National-dex number of an internal species id (`0` for NO_MON/MissingNo). -/
def internalToDex (id : SpeciesId) : UInt8 :=
  if id == 0 then 0 else pokedexOrder.getD (id.toNat - 1) 0

/-- Base header for a national-dex number `1..151` (`default` otherwise). -/
def baseStatsOfDex (d : UInt8) : SpeciesData :=
  if d == 0 then default else baseStats.getD (d.toNat - 1) default

/-- Base header for an internal species id (`default` for NO_MON/MissingNo). -/
def speciesData (id : SpeciesId) : SpeciesData := baseStatsOfDex (internalToDex id)

/-- Whether an internal index names a real, data-backed species — false for
    NO_MON, MissingNo slots, and the non-species internal ids (fossils, ghost). -/
def isRealSpecies (id : SpeciesId) : Bool := internalToDex id != 0

/-! ## Fidelity guards -/

#guard baseStats.size == 151
#guard pokedexOrder.size == 190  -- NUM_POKEMON_INDEXES

-- Dex-order headers, field-by-field vs `data/pokemon/base_stats/*.asm`.
#guard baseStatsOfDex 1 == sp 1 45 49 49 45 65 grass poison 45 64             -- BULBASAUR
#guard baseStatsOfDex 6 == sp 6 78 84 78 100 85 fire flying 45 209            -- CHARIZARD
#guard baseStatsOfDex 150 == sp 150 106 110 90 130 154 psychic psychic 3 220  -- MEWTWO
#guard baseStatsOfDex 151 == sp 151 100 100 100 100 100 psychic psychic 45 64 -- MEW

-- Internal index → dex via `PokedexOrder`, including the internal ordering.
#guard internalToDex 1 == 112     -- RHYDON   ($01)
#guard internalToDex 21 == 151    -- MEW      ($15)
#guard internalToDex 131 == 150   -- MEWTWO   ($83)
#guard internalToDex 153 == 1     -- BULBASAUR($99)
#guard internalToDex 190 == 71    -- VICTREEBEL ($BE)
#guard internalToDex 31 == 0      -- $1F MissingNo
#guard internalToDex 0 == 0       -- NO_MON

-- Internal id → full header, and the real-species predicate.
#guard (speciesData 153).type1 == grass && (speciesData 153).baseSpc == 65    -- BULBASAUR
#guard (speciesData 21).baseHp == 100                                         -- MEW
#guard isRealSpecies 153 && isRealSpecies 21 && !isRealSpecies 31 && !isRealSpecies 0
#guard !isRealSpecies 182 && !isRealSpecies 183 && !isRealSpecies 184  -- fossils/ghost $B6-$B8

end Battle.Data
