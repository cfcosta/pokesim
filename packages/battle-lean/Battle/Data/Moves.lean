/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Types
import Battle.TypeChart

/-!
# Move data — the Gen-1 `Moves` table, transcribed 1:1

Every move's battle characteristics, from `pokered/data/moves/moves.asm`. Each
`Moves:` entry is `MOVE_LENGTH = 6` bytes via the `move` macro:

    db id (= animation) ; db effect ; db power ; db type ; db accuracy percent ; db pp

The `id` byte equals the move's ID for real moves, so it is *implicit* here — the
table is in ID order and `moves[i]` is move `i+1`. The other five bytes are
`MoveData`. Accuracy is stored the way the assembler stores it:
`DEF percent EQUS "* $ff / 100"`, i.e. `⌊N · 255 / 100⌋`.

Effect IDs are `constants/move_effect_constants.asm`
(`MoveEffectPointerTable` indexes). Type IDs are `Battle.TypeChart`
(`constants/type_constants.asm`); the physical/special split is by type
(`TypeChart.isSpecial`), not per-move.

This is the authored table the ROM round-trip certificate (`Battle/Rom/Tables`,
task #24) will decode-and-compare against. It carries move *data* only —
per-move effect *behaviours* (status, stat stages, the unique moves) are a later
slice; `effect` here is the ID those behaviours will dispatch on.
-/

namespace Battle.Data

open Battle.TypeChart
  (normal fighting flying poison ground rock bug ghost fire water grass electric psychic ice dragon)

/-- Accuracy byte encoding: pokered's `N percent` is `N * $ff / 100` with RGBDS
    integer (truncating) division. -/
def percent (n : Nat) : UInt8 := (n * 255 / 100).toUInt8

/-! ## Move-effect IDs — `constants/move_effect_constants.asm`

The `effect` byte a move dispatches on; `noAdditional` (`$00`) is a plain
damaging move. -/
namespace Effect
def noAdditional      : UInt8 := 0x00
def poisonSide1       : UInt8 := 0x02
def drainHp           : UInt8 := 0x03
def burnSide1         : UInt8 := 0x04
def freezeSide1       : UInt8 := 0x05
def paralyzeSide1     : UInt8 := 0x06
def explode           : UInt8 := 0x07
def dreamEater        : UInt8 := 0x08
def mirrorMove        : UInt8 := 0x09
def attackUp1         : UInt8 := 0x0A
def defenseUp1        : UInt8 := 0x0B
def speedUp1          : UInt8 := 0x0C
def specialUp1        : UInt8 := 0x0D
def accuracyUp1       : UInt8 := 0x0E
def evasionUp1        : UInt8 := 0x0F
def payDay            : UInt8 := 0x10
def swift             : UInt8 := 0x11
def attackDown1       : UInt8 := 0x12
def defenseDown1      : UInt8 := 0x13
def speedDown1        : UInt8 := 0x14
def specialDown1      : UInt8 := 0x15
def accuracyDown1     : UInt8 := 0x16
def evasionDown1      : UInt8 := 0x17
def conversion        : UInt8 := 0x18
def haze              : UInt8 := 0x19
def bide              : UInt8 := 0x1A
def thrashPetalDance  : UInt8 := 0x1B
def switchAndTeleport : UInt8 := 0x1C
def twoToFiveAttacks  : UInt8 := 0x1D
def flinchSide1       : UInt8 := 0x1F
def sleep             : UInt8 := 0x20
def poisonSide2       : UInt8 := 0x21
def burnSide2         : UInt8 := 0x22
def freezeSide2       : UInt8 := 0x23
def paralyzeSide2     : UInt8 := 0x24
def flinchSide2       : UInt8 := 0x25
def ohko              : UInt8 := 0x26
def charge            : UInt8 := 0x27
def superFang         : UInt8 := 0x28
def specialDamage     : UInt8 := 0x29
def trapping          : UInt8 := 0x2A
def fly               : UInt8 := 0x2B
def attackTwice       : UInt8 := 0x2C
def jumpKick          : UInt8 := 0x2D
def mist              : UInt8 := 0x2E
def focusEnergy       : UInt8 := 0x2F
def recoil            : UInt8 := 0x30
def confusion         : UInt8 := 0x31
def attackUp2         : UInt8 := 0x32
def defenseUp2        : UInt8 := 0x33
def speedUp2          : UInt8 := 0x34
def specialUp2        : UInt8 := 0x35
def accuracyUp2       : UInt8 := 0x36
def evasionUp2        : UInt8 := 0x37
def heal              : UInt8 := 0x38
def transform         : UInt8 := 0x39
def attackDown2       : UInt8 := 0x3A
def defenseDown2      : UInt8 := 0x3B
def speedDown2        : UInt8 := 0x3C
def specialDown2      : UInt8 := 0x3D
def accuracyDown2     : UInt8 := 0x3E
def evasionDown2      : UInt8 := 0x3F
def lightScreen       : UInt8 := 0x40
def reflect           : UInt8 := 0x41
def poison            : UInt8 := 0x42
def paralyze          : UInt8 := 0x43
def attackDownSide    : UInt8 := 0x44
def defenseDownSide   : UInt8 := 0x45
def speedDownSide     : UInt8 := 0x46
def specialDownSide   : UInt8 := 0x47
def confusionSide     : UInt8 := 0x4C
def twineedle         : UInt8 := 0x4D
def substitute        : UInt8 := 0x4F
def hyperBeam         : UInt8 := 0x50
def rage              : UInt8 := 0x51
def mimic             : UInt8 := 0x52
def metronome         : UInt8 := 0x53
def leechSeed         : UInt8 := 0x54
def splash            : UInt8 := 0x55
def disable           : UInt8 := 0x56
end Effect

/-- One move's battle characteristics — the five data bytes after the (implicit)
    id in a `Moves` entry. -/
structure MoveData where
  effect   : UInt8
  power    : UInt8
  type     : UInt8
  accuracy : UInt8
  pp       : UInt8
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Table-row helper mirroring the ASM `move` column order (minus the implicit
    id): `mv EFFECT POWER TYPE ACCURACY% PP`. -/
def mv (effect : UInt8) (power : Nat) (type : UInt8) (accPct pp : Nat) : MoveData :=
  { effect, power := power.toUInt8, type, accuracy := percent accPct, pp := pp.toUInt8 }

/-- The whole `Moves:` table, in ID order — `moves[i]` is move `i+1`. -/
def moves : Array MoveData := #[
  mv Effect.noAdditional       40 normal    100 35,  -- 001 POUND
  mv Effect.noAdditional       50 normal    100 25,  -- 002 KARATE_CHOP
  mv Effect.twoToFiveAttacks   15 normal     85 10,  -- 003 DOUBLESLAP
  mv Effect.twoToFiveAttacks   18 normal     85 15,  -- 004 COMET_PUNCH
  mv Effect.noAdditional       80 normal     85 20,  -- 005 MEGA_PUNCH
  mv Effect.payDay             40 normal    100 20,  -- 006 PAY_DAY
  mv Effect.burnSide1          75 fire      100 15,  -- 007 FIRE_PUNCH
  mv Effect.freezeSide1        75 ice       100 15,  -- 008 ICE_PUNCH
  mv Effect.paralyzeSide1      75 electric  100 15,  -- 009 THUNDERPUNCH
  mv Effect.noAdditional       40 normal    100 35,  -- 010 SCRATCH
  mv Effect.noAdditional       55 normal    100 30,  -- 011 VICEGRIP
  mv Effect.ohko                1 normal     30  5,  -- 012 GUILLOTINE
  mv Effect.charge             80 normal     75 10,  -- 013 RAZOR_WIND
  mv Effect.attackUp2           0 normal    100 30,  -- 014 SWORDS_DANCE
  mv Effect.noAdditional       50 normal     95 30,  -- 015 CUT
  mv Effect.noAdditional       40 normal    100 35,  -- 016 GUST
  mv Effect.noAdditional       35 flying    100 35,  -- 017 WING_ATTACK
  mv Effect.switchAndTeleport   0 normal     85 20,  -- 018 WHIRLWIND
  mv Effect.fly                70 flying     95 15,  -- 019 FLY
  mv Effect.trapping           15 normal     75 20,  -- 020 BIND
  mv Effect.noAdditional       80 normal     75 20,  -- 021 SLAM
  mv Effect.noAdditional       35 grass     100 10,  -- 022 VINE_WHIP
  mv Effect.flinchSide2        65 normal    100 20,  -- 023 STOMP
  mv Effect.attackTwice        30 fighting  100 30,  -- 024 DOUBLE_KICK
  mv Effect.noAdditional      120 normal     75  5,  -- 025 MEGA_KICK
  mv Effect.jumpKick           70 fighting   95 25,  -- 026 JUMP_KICK
  mv Effect.flinchSide2        60 fighting   85 15,  -- 027 ROLLING_KICK
  mv Effect.accuracyDown1       0 normal    100 15,  -- 028 SAND_ATTACK
  mv Effect.flinchSide2        70 normal    100 15,  -- 029 HEADBUTT
  mv Effect.noAdditional       65 normal    100 25,  -- 030 HORN_ATTACK
  mv Effect.twoToFiveAttacks   15 normal     85 20,  -- 031 FURY_ATTACK
  mv Effect.ohko                1 normal     30  5,  -- 032 HORN_DRILL
  mv Effect.noAdditional       35 normal     95 35,  -- 033 TACKLE
  mv Effect.paralyzeSide2      85 normal    100 15,  -- 034 BODY_SLAM
  mv Effect.trapping           15 normal     85 20,  -- 035 WRAP
  mv Effect.recoil             90 normal     85 20,  -- 036 TAKE_DOWN
  mv Effect.thrashPetalDance   90 normal    100 20,  -- 037 THRASH
  mv Effect.recoil            100 normal    100 15,  -- 038 DOUBLE_EDGE
  mv Effect.defenseDown1        0 normal    100 30,  -- 039 TAIL_WHIP
  mv Effect.poisonSide1        15 poison    100 35,  -- 040 POISON_STING
  mv Effect.twineedle          25 bug       100 20,  -- 041 TWINEEDLE
  mv Effect.twoToFiveAttacks   14 bug        85 20,  -- 042 PIN_MISSILE
  mv Effect.defenseDown1        0 normal    100 30,  -- 043 LEER
  mv Effect.flinchSide1        60 normal    100 25,  -- 044 BITE
  mv Effect.attackDown1         0 normal    100 40,  -- 045 GROWL
  mv Effect.switchAndTeleport   0 normal    100 20,  -- 046 ROAR
  mv Effect.sleep               0 normal     55 15,  -- 047 SING
  mv Effect.confusion           0 normal     55 20,  -- 048 SUPERSONIC
  mv Effect.specialDamage       1 normal     90 20,  -- 049 SONICBOOM
  mv Effect.disable             0 normal     55 20,  -- 050 DISABLE
  mv Effect.defenseDownSide    40 poison    100 30,  -- 051 ACID
  mv Effect.burnSide1          40 fire      100 25,  -- 052 EMBER
  mv Effect.burnSide1          95 fire      100 15,  -- 053 FLAMETHROWER
  mv Effect.mist                0 ice       100 30,  -- 054 MIST
  mv Effect.noAdditional       40 water     100 25,  -- 055 WATER_GUN
  mv Effect.noAdditional      120 water      80  5,  -- 056 HYDRO_PUMP
  mv Effect.noAdditional       95 water     100 15,  -- 057 SURF
  mv Effect.freezeSide1        95 ice       100 10,  -- 058 ICE_BEAM
  mv Effect.freezeSide1       120 ice        90  5,  -- 059 BLIZZARD
  mv Effect.confusionSide      65 psychic   100 20,  -- 060 PSYBEAM
  mv Effect.speedDownSide      65 water     100 20,  -- 061 BUBBLEBEAM
  mv Effect.attackDownSide     65 ice       100 20,  -- 062 AURORA_BEAM
  mv Effect.hyperBeam         150 normal     90  5,  -- 063 HYPER_BEAM
  mv Effect.noAdditional       35 flying    100 35,  -- 064 PECK
  mv Effect.noAdditional       80 flying    100 20,  -- 065 DRILL_PECK
  mv Effect.recoil             80 fighting   80 25,  -- 066 SUBMISSION
  mv Effect.flinchSide2        50 fighting   90 20,  -- 067 LOW_KICK
  mv Effect.noAdditional        1 fighting  100 20,  -- 068 COUNTER
  mv Effect.specialDamage       1 fighting  100 20,  -- 069 SEISMIC_TOSS
  mv Effect.noAdditional       80 normal    100 15,  -- 070 STRENGTH
  mv Effect.drainHp            20 grass     100 20,  -- 071 ABSORB
  mv Effect.drainHp            40 grass     100 10,  -- 072 MEGA_DRAIN
  mv Effect.leechSeed           0 grass      90 10,  -- 073 LEECH_SEED
  mv Effect.specialUp1          0 normal    100 40,  -- 074 GROWTH
  mv Effect.noAdditional       55 grass      95 25,  -- 075 RAZOR_LEAF
  mv Effect.charge            120 grass     100 10,  -- 076 SOLARBEAM
  mv Effect.poison              0 poison     75 35,  -- 077 POISONPOWDER
  mv Effect.paralyze            0 grass      75 30,  -- 078 STUN_SPORE
  mv Effect.sleep               0 grass      75 15,  -- 079 SLEEP_POWDER
  mv Effect.thrashPetalDance   70 grass     100 20,  -- 080 PETAL_DANCE
  mv Effect.speedDown1          0 bug        95 40,  -- 081 STRING_SHOT
  mv Effect.specialDamage       1 dragon    100 10,  -- 082 DRAGON_RAGE
  mv Effect.trapping           15 fire       70 15,  -- 083 FIRE_SPIN
  mv Effect.paralyzeSide1      40 electric  100 30,  -- 084 THUNDERSHOCK
  mv Effect.paralyzeSide1      95 electric  100 15,  -- 085 THUNDERBOLT
  mv Effect.paralyze            0 electric  100 20,  -- 086 THUNDER_WAVE
  mv Effect.paralyzeSide1     120 electric   70 10,  -- 087 THUNDER
  mv Effect.noAdditional       50 rock       65 15,  -- 088 ROCK_THROW
  mv Effect.noAdditional      100 ground    100 10,  -- 089 EARTHQUAKE
  mv Effect.ohko                1 ground     30  5,  -- 090 FISSURE
  mv Effect.charge            100 ground    100 10,  -- 091 DIG
  mv Effect.poison              0 poison     85 10,  -- 092 TOXIC
  mv Effect.confusionSide      50 psychic   100 25,  -- 093 CONFUSION
  mv Effect.specialDownSide    90 psychic   100 10,  -- 094 PSYCHIC_M
  mv Effect.sleep               0 psychic    60 20,  -- 095 HYPNOSIS
  mv Effect.attackUp1           0 psychic   100 40,  -- 096 MEDITATE
  mv Effect.speedUp2            0 psychic   100 30,  -- 097 AGILITY
  mv Effect.noAdditional       40 normal    100 30,  -- 098 QUICK_ATTACK
  mv Effect.rage               20 normal    100 20,  -- 099 RAGE
  mv Effect.switchAndTeleport   0 psychic   100 20,  -- 100 TELEPORT
  mv Effect.specialDamage       0 ghost     100 15,  -- 101 NIGHT_SHADE
  mv Effect.mimic               0 normal    100 10,  -- 102 MIMIC
  mv Effect.defenseDown2        0 normal     85 40,  -- 103 SCREECH
  mv Effect.evasionUp1          0 normal    100 15,  -- 104 DOUBLE_TEAM
  mv Effect.heal                0 normal    100 20,  -- 105 RECOVER
  mv Effect.defenseUp1          0 normal    100 30,  -- 106 HARDEN
  mv Effect.evasionUp1          0 normal    100 20,  -- 107 MINIMIZE
  mv Effect.accuracyDown1       0 normal    100 20,  -- 108 SMOKESCREEN
  mv Effect.confusion           0 ghost     100 10,  -- 109 CONFUSE_RAY
  mv Effect.defenseUp1          0 water     100 40,  -- 110 WITHDRAW
  mv Effect.defenseUp1          0 normal    100 40,  -- 111 DEFENSE_CURL
  mv Effect.defenseUp2          0 psychic   100 30,  -- 112 BARRIER
  mv Effect.lightScreen         0 psychic   100 30,  -- 113 LIGHT_SCREEN
  mv Effect.haze                0 ice       100 30,  -- 114 HAZE
  mv Effect.reflect             0 psychic   100 20,  -- 115 REFLECT
  mv Effect.focusEnergy         0 normal    100 30,  -- 116 FOCUS_ENERGY
  mv Effect.bide                0 normal    100 10,  -- 117 BIDE
  mv Effect.metronome           0 normal    100 10,  -- 118 METRONOME
  mv Effect.mirrorMove          0 flying    100 20,  -- 119 MIRROR_MOVE
  mv Effect.explode           130 normal    100  5,  -- 120 SELFDESTRUCT
  mv Effect.noAdditional      100 normal     75 10,  -- 121 EGG_BOMB
  mv Effect.paralyzeSide2      20 ghost     100 30,  -- 122 LICK
  mv Effect.poisonSide2        20 poison     70 20,  -- 123 SMOG
  mv Effect.poisonSide2        65 poison    100 20,  -- 124 SLUDGE
  mv Effect.flinchSide1        65 ground     85 20,  -- 125 BONE_CLUB
  mv Effect.burnSide2         120 fire       85  5,  -- 126 FIRE_BLAST
  mv Effect.noAdditional       80 water     100 15,  -- 127 WATERFALL
  mv Effect.trapping           35 water      75 10,  -- 128 CLAMP
  mv Effect.swift              60 normal    100 20,  -- 129 SWIFT
  mv Effect.charge            100 normal    100 15,  -- 130 SKULL_BASH
  mv Effect.twoToFiveAttacks   20 normal    100 15,  -- 131 SPIKE_CANNON
  mv Effect.speedDownSide      10 normal    100 35,  -- 132 CONSTRICT
  mv Effect.specialUp2          0 psychic   100 20,  -- 133 AMNESIA
  mv Effect.accuracyDown1       0 psychic    80 15,  -- 134 KINESIS
  mv Effect.heal                0 normal    100 10,  -- 135 SOFTBOILED
  mv Effect.jumpKick           85 fighting   90 20,  -- 136 HI_JUMP_KICK
  mv Effect.paralyze            0 normal     75 30,  -- 137 GLARE
  mv Effect.dreamEater        100 psychic   100 15,  -- 138 DREAM_EATER
  mv Effect.poison              0 poison     55 40,  -- 139 POISON_GAS
  mv Effect.twoToFiveAttacks   15 normal     85 20,  -- 140 BARRAGE
  mv Effect.drainHp            20 bug       100 15,  -- 141 LEECH_LIFE
  mv Effect.sleep               0 normal     75 10,  -- 142 LOVELY_KISS
  mv Effect.charge            140 flying     90  5,  -- 143 SKY_ATTACK
  mv Effect.transform           0 normal    100 10,  -- 144 TRANSFORM
  mv Effect.speedDownSide      20 water     100 30,  -- 145 BUBBLE
  mv Effect.noAdditional       70 normal    100 10,  -- 146 DIZZY_PUNCH
  mv Effect.sleep               0 grass     100 15,  -- 147 SPORE
  mv Effect.accuracyDown1       0 normal     70 20,  -- 148 FLASH
  mv Effect.specialDamage       1 psychic    80 15,  -- 149 PSYWAVE
  mv Effect.splash              0 normal    100 40,  -- 150 SPLASH
  mv Effect.defenseUp2          0 poison    100 40,  -- 151 ACID_ARMOR
  mv Effect.noAdditional       90 water      85 10,  -- 152 CRABHAMMER
  mv Effect.explode           170 normal    100  5,  -- 153 EXPLOSION
  mv Effect.twoToFiveAttacks   18 normal     80 15,  -- 154 FURY_SWIPES
  mv Effect.attackTwice        50 ground     90 10,  -- 155 BONEMERANG
  mv Effect.heal                0 psychic   100 10,  -- 156 REST
  mv Effect.noAdditional       75 rock       90 10,  -- 157 ROCK_SLIDE
  mv Effect.flinchSide1        80 normal     90 15,  -- 158 HYPER_FANG
  mv Effect.attackUp1           0 normal    100 30,  -- 159 SHARPEN
  mv Effect.conversion          0 normal    100 30,  -- 160 CONVERSION
  mv Effect.noAdditional       80 normal    100 10,  -- 161 TRI_ATTACK
  mv Effect.superFang           1 normal     90 10,  -- 162 SUPER_FANG
  mv Effect.noAdditional       70 normal    100 20,  -- 163 SLASH
  mv Effect.substitute          0 normal    100 10,  -- 164 SUBSTITUTE
  mv Effect.recoil             50 normal    100 10   -- 165 STRUGGLE
]

/-- Look up a move's data by ID (1-based; `0` is the empty move slot → all-zero
    `default`). -/
def moveData (id : MoveId) : MoveData :=
  if id == 0 then default else moves.getD (id.toNat - 1) default

/-- Swift (and only Swift, via `SWIFT_EFFECT`) forgoes the accuracy roll. -/
def MoveData.alwaysHits (d : MoveData) : Bool := d.effect == Effect.swift

/-- Gen-1 physical/special is decided by the move's TYPE (`cp SPECIAL`). -/
def MoveData.isSpecial (d : MoveData) : Bool := Battle.TypeChart.isSpecial d.type

/-! ## Fidelity guards -/

-- Table shape and the accuracy encoding.
#guard moves.size == 165                                   -- NUM_ATTACKS
#guard percent 100 == 255 && percent 95 == 242 && percent 90 == 229
#guard percent 85 == 216 && percent 75 == 191 && percent 70 == 178
#guard percent 65 == 165 && percent 55 == 140 && percent 30 == 76

-- Representative rows checked field-by-field against `moves.asm`.
#guard moveData 1 == mv Effect.noAdditional 40 normal 100 35      -- POUND
#guard moveData 52 == mv Effect.burnSide1 40 fire 100 25          -- EMBER
#guard moveData 63 == mv Effect.hyperBeam 150 normal 90 5         -- HYPER_BEAM (acc 229)
#guard (moveData 63).accuracy == 229
#guard moveData 93 == mv Effect.confusionSide 50 psychic 100 25   -- CONFUSION
#guard moveData 101 == mv Effect.specialDamage 0 ghost 100 15     -- NIGHT_SHADE (power 0)
#guard moveData 129 == mv Effect.swift 60 normal 100 20           -- SWIFT
#guard moveData 165 == mv Effect.recoil 50 normal 100 10          -- STRUGGLE
#guard moveData 0 == default                                     -- empty slot

-- Derived predicates.
#guard (moveData 129).alwaysHits && !(moveData 1).alwaysHits      -- only Swift
#guard (moveData 52).isSpecial && (moveData 93).isSpecial         -- FIRE, PSYCHIC
#guard !(moveData 1).isSpecial && !(moveData 34).isSpecial        -- NORMAL

end Battle.Data
