/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Types

/-! Generated from the hash-checked canonical ROM by
`tools/generate-pokered-progression.py`. Index is internal species ID;
entry zero is `NO_MON`. The ROM itself is not vendored. -/

namespace Battle.Data.Progression

inductive EvolutionMethod where
  | level (level : UInt8)
  | item (item minimumLevel : UInt8)
  | trade (minimumLevel : UInt8)
  deriving Repr, DecidableEq, BEq

structure Evolution where
  method : EvolutionMethod
  target : SpeciesId
  deriving Repr, DecidableEq, BEq

structure LevelMove where
  level : UInt8
  move : MoveId
  deriving Repr, DecidableEq, BEq

structure Row where
  evolutions : Array Evolution
  levelMoves : Array LevelMove
  deriving Repr, DecidableEq, BEq

/-- Base-header growth-rate IDs for internal species `$00..$BE`. -/
def growthRates : Array UInt8 := #[0, 5, 0, 3, 4, 0, 0, 3, 0, 3, 5, 0, 5, 0, 3, 3, 3, 0, 5, 5, 5, 3, 5, 5, 5, 3, 0, 5, 3, 5, 0, 0, 0, 5, 0, 0, 3, 0, 3, 3, 4, 3, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 3, 0, 5, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 0, 0, 0, 0, 3, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 5, 5, 5, 0, 0, 0, 0, 0, 5, 0, 0, 4, 0, 0, 0, 0, 3, 3, 3, 3, 3, 5, 3, 3, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 0, 5, 0, 0, 0, 0, 3, 3, 3, 3, 3, 0, 0, 0, 0, 3, 3, 3, 3, 3, 3]

/-- Nonblank level-one moves from each base-stat row. -/
def initialMoves : Array (Array MoveId) := #[
  #[], -- $00
  #[30, 23, 39, 31], -- $01
  #[4, 99], -- $02
  #[43, 33], -- $03
  #[1, 45], -- $04
  #[64, 45], -- $05
  #[33, 103], -- $06
  #[33, 30, 40, 37], -- $07
  #[93, 50, 29], -- $08
  #[33, 45, 73], -- $09
  #[140, 95], -- $0A
  #[35, 48], -- $0B
  #[140, 95], -- $0C
  #[1, 50], -- $0D
  #[122, 109, 101], -- $0E
  #[45, 33], -- $0F
  #[33, 10, 39, 34], -- $10
  #[125, 45], -- $11
  #[30], -- $12
  #[55, 45], -- $13
  #[46, 52, 43, 36], -- $14
  #[1], -- $15
  #[44, 82, 43, 56], -- $16
  #[33, 110], -- $17
  #[51], -- $18
  #[122, 109, 101], -- $19
  #[98], -- $1A
  #[33], -- $1B
  #[33, 39, 145, 55], -- $1C
  #[11], -- $1D
  #[132, 20], -- $1E
  #[], -- $1F
  #[], -- $20
  #[44, 46], -- $21
  #[33, 103], -- $22
  #[64, 45, 43], -- $23
  #[16], -- $24
  #[93], -- $25
  #[100, 93, 50], -- $26
  #[33, 111], -- $27
  #[1, 3], -- $28
  #[2, 67, 43], -- $29
  #[93, 112], -- $2A
  #[24, 96], -- $2B
  #[4, 97], -- $2C
  #[35, 43, 40], -- $2D
  #[10, 78, 141], -- $2E
  #[10], -- $2F
  #[1, 95], -- $30
  #[33, 111], -- $31
  #[], -- $32
  #[52], -- $33
  #[], -- $34
  #[98, 43], -- $35
  #[33, 49, 84], -- $36
  #[33, 123], -- $37
  #[], -- $38
  #[10, 43], -- $39
  #[29], -- $3A
  #[10], -- $3B
  #[33], -- $3C
  #[], -- $3D
  #[], -- $3E
  #[], -- $3F
  #[64, 28], -- $40
  #[33, 50], -- $41
  #[35, 43, 86, 97], -- $42
  #[], -- $43
  #[], -- $44
  #[], -- $45
  #[64], -- $46
  #[145], -- $47
  #[1, 142], -- $48
  #[64, 83], -- $49
  #[64, 58], -- $4A
  #[84, 65], -- $4B
  #[144], -- $4C
  #[10, 45], -- $4D
  #[145, 43], -- $4E
  #[], -- $4F
  #[], -- $50
  #[], -- $51
  #[52, 39], -- $52
  #[52, 39, 98, 46], -- $53
  #[84, 45], -- $54
  #[84, 45, 86], -- $55
  #[], -- $56
  #[], -- $57
  #[35, 43], -- $58
  #[35, 43, 86], -- $59
  #[10, 106], -- $5A
  #[10, 106, 71], -- $5B
  #[145], -- $5C
  #[145, 108], -- $5D
  #[], -- $5E
  #[], -- $5F
  #[10], -- $60
  #[10, 28], -- $61
  #[55, 110], -- $62
  #[55, 110, 30], -- $63
  #[47], -- $64
  #[47, 50, 111, 3], -- $65
  #[33, 28], -- $66
  #[33, 28, 98, 52], -- $67
  #[33, 28, 98, 84], -- $68
  #[33, 28, 98, 55], -- $69
  #[2], -- $6A
  #[141], -- $6B
  #[35, 43], -- $6C
  #[10], -- $6D
  #[145, 95, 55], -- $6E
  #[95, 55, 3, 34], -- $6F
  #[40, 81], -- $70
  #[106], -- $71
  #[31], -- $72
  #[], -- $73
  #[64, 45, 31], -- $74
  #[10, 43, 2, 154], -- $75
  #[10, 45, 91], -- $76
  #[33, 50, 77, 141], -- $77
  #[29, 45, 62], -- $78
  #[], -- $79
  #[], -- $7A
  #[33, 81], -- $7B
  #[106], -- $7C
  #[93], -- $7D
  #[2, 67, 43], -- $7E
  #[], -- $7F
  #[10, 39, 50], -- $80
  #[1, 95, 50, 93], -- $81
  #[141, 103, 44], -- $82
  #[93, 50, 129, 94], -- $83
  #[29, 133, 156], -- $84
  #[150], -- $85
  #[], -- $86
  #[], -- $87
  #[1, 50, 139], -- $88
  #[], -- $89
  #[145, 43, 11], -- $8A
  #[110, 48, 128, 62], -- $8B
  #[], -- $8C
  #[33, 103, 49], -- $8D
  #[47, 3, 107, 118], -- $8E
  #[33, 123, 124], -- $8F
  #[10, 45, 44, 103], -- $90
  #[125, 45, 43, 116], -- $91
  #[], -- $92
  #[122, 109, 101], -- $93
  #[100], -- $94
  #[100, 93, 50], -- $95
  #[16, 28], -- $96
  #[16, 28, 98], -- $97
  #[33, 55, 106], -- $98
  #[33, 45], -- $99
  #[33, 45, 73, 22], -- $9A
  #[51, 48, 35], -- $9B
  #[], -- $9C
  #[64, 39], -- $9D
  #[64, 39, 48], -- $9E
  #[], -- $9F
  #[], -- $A0
  #[], -- $A1
  #[], -- $A2
  #[52], -- $A3
  #[52, 39, 23, 45], -- $A4
  #[33, 39], -- $A5
  #[33, 39, 98], -- $A6
  #[43, 33, 30], -- $A7
  #[45, 33, 10], -- $A8
  #[33], -- $A9
  #[33, 159, 160], -- $AA
  #[17, 97], -- $AB
  #[], -- $AC
  #[33], -- $AD
  #[], -- $AE
  #[], -- $AF
  #[10, 45], -- $B0
  #[33, 39], -- $B1
  #[10, 45, 52], -- $B2
  #[33, 39, 145], -- $B3
  #[10, 45, 52, 43], -- $B4
  #[], -- $B5
  #[], -- $B6
  #[], -- $B7
  #[], -- $B8
  #[71], -- $B9
  #[71, 77, 78], -- $BA
  #[78, 79, 51, 80], -- $BB
  #[22, 74], -- $BC
  #[22, 74, 35], -- $BD
  #[79, 78, 51, 75], -- $BE
]

/-- `TM01..TM50`, then `HM01..HM05`, in base-stat flag order. -/
def tmhmMoves : Array MoveId := #[5, 13, 14, 18, 25, 92, 32, 34, 36, 38, 61, 55, 58, 59, 63, 6, 66, 68, 69, 99, 72, 76, 82, 85, 87, 89, 90, 91, 94, 100, 102, 104, 115, 117, 118, 120, 121, 126, 129, 130, 135, 138, 143, 156, 86, 149, 153, 157, 161, 164, 15, 19, 57, 70, 148]

/-- Seven compatibility bytes from every base-stat row, by internal species ID. -/
def tmhmFlags : Array (Array UInt8) := #[
  #[], -- $00
  #[241, 255, 143, 207, 162, 136, 50], -- $01
  #[177, 127, 143, 199, 162, 136, 50], -- $02
  #[224, 35, 136, 193, 131, 8, 2], -- $03
  #[177, 63, 175, 241, 167, 56, 99], -- $04
  #[42, 3, 8, 192, 66, 12, 10], -- $05
  #[32, 1, 136, 225, 75, 88, 66], -- $06
  #[241, 255, 143, 199, 163, 136, 50], -- $07
  #[177, 255, 15, 254, 227, 56, 115], -- $08
  #[164, 3, 56, 192, 3, 8, 6], -- $09
  #[32, 67, 56, 240, 27, 104, 34], -- $0A
  #[181, 127, 143, 199, 162, 8, 54], -- $0B
  #[32, 3, 8, 240, 27, 104, 2], -- $0C
  #[160, 0, 152, 193, 42, 72, 2], -- $0D
  #[177, 67, 159, 209, 142, 106, 34], -- $0E
  #[160, 35, 136, 193, 131, 8, 2], -- $0F
  #[241, 255, 143, 199, 163, 136, 50], -- $10
  #[177, 63, 15, 206, 162, 8, 34], -- $11
  #[224, 3, 136, 207, 162, 136, 34], -- $12
  #[224, 127, 232, 209, 131, 40, 50], -- $13
  #[160, 67, 72, 232, 227, 8, 2], -- $14
  #[255, 255, 255, 255, 255, 255, 255], -- $15
  #[160, 127, 200, 193, 163, 8, 50], -- $16
  #[32, 63, 8, 224, 75, 72, 19], -- $17
  #[36, 63, 24, 192, 131, 8, 22], -- $18
  #[32, 0, 152, 209, 10, 106, 2], -- $19
  #[36, 67, 8, 192, 194, 8, 6], -- $1A
  #[32, 63, 136, 241, 195, 56, 83], -- $1B
  #[177, 127, 15, 206, 131, 8, 50], -- $1C
  #[164, 67, 13, 192, 2, 8, 38], -- $1D
  #[164, 67, 56, 192, 130, 8, 6], -- $1E
  #[], -- $1F
  #[], -- $20
  #[160, 3, 72, 200, 227, 8, 2], -- $21
  #[160, 3, 8, 206, 138, 200, 34], -- $22
  #[42, 67, 8, 192, 66, 12, 10], -- $23
  #[42, 3, 8, 192, 67, 12, 10], -- $24
  #[160, 191, 8, 254, 227, 56, 115], -- $25
  #[177, 3, 15, 248, 135, 56, 67], -- $26
  #[161, 3, 15, 206, 46, 200, 34], -- $27
  #[177, 127, 175, 241, 183, 57, 99], -- $28
  #[177, 3, 15, 206, 166, 136, 34], -- $29
  #[177, 67, 175, 241, 135, 56, 66], -- $2A
  #[177, 3, 15, 192, 198, 8, 34], -- $2B
  #[177, 3, 15, 192, 198, 8, 34], -- $2C
  #[160, 67, 24, 206, 130, 136, 34], -- $2D
  #[164, 67, 56, 200, 131, 8, 6], -- $2E
  #[177, 191, 15, 200, 194, 8, 50], -- $2F
  #[177, 3, 15, 240, 135, 58, 67], -- $30
  #[177, 67, 15, 206, 46, 200, 34], -- $31
  #[], -- $32
  #[177, 67, 15, 240, 166, 40, 34], -- $33
  #[], -- $34
  #[177, 67, 143, 241, 199, 56, 98], -- $35
  #[32, 67, 136, 225, 67, 24, 66], -- $36
  #[32, 0, 136, 193, 42, 72, 2], -- $37
  #[], -- $38
  #[177, 131, 143, 201, 198, 136, 34], -- $39
  #[224, 191, 8, 192, 130, 8, 50], -- $3A
  #[160, 3, 8, 206, 2, 136, 2], -- $3B
  #[224, 115, 136, 199, 162, 8, 34], -- $3C
  #[], -- $3D
  #[], -- $3E
  #[], -- $3F
  #[174, 3, 8, 192, 195, 8, 14], -- $40
  #[32, 3, 56, 208, 3, 40, 2], -- $41
  #[226, 127, 200, 193, 227, 24, 50], -- $42
  #[], -- $43
  #[], -- $44
  #[], -- $45
  #[168, 3, 8, 192, 131, 12, 11], -- $46
  #[160, 63, 8, 208, 130, 40, 18], -- $47
  #[177, 127, 15, 240, 135, 40, 2], -- $48
  #[42, 67, 8, 192, 99, 12, 10], -- $49
  #[42, 127, 8, 192, 67, 12, 10], -- $4A
  #[42, 67, 136, 193, 67, 28, 74], -- $4B
  #[0, 0, 0, 0, 0, 0, 0], -- $4C
  #[160, 143, 136, 193, 194, 8, 2], -- $4D
  #[164, 63, 8, 192, 2, 8, 54], -- $4E
  #[], -- $4F
  #[], -- $50
  #[], -- $51
  #[160, 3, 8, 200, 227, 8, 2], -- $52
  #[160, 67, 8, 200, 227, 8, 2], -- $53
  #[177, 131, 141, 193, 195, 24, 66], -- $54
  #[177, 195, 141, 193, 195, 24, 66], -- $55
  #[], -- $56
  #[], -- $57
  #[160, 63, 200, 193, 227, 24, 18], -- $58
  #[224, 63, 200, 193, 227, 24, 18], -- $59
  #[160, 63, 8, 192, 3, 8, 18], -- $5A
  #[182, 127, 13, 192, 131, 8, 18], -- $5B
  #[32, 63, 8, 192, 194, 8, 18], -- $5C
  #[32, 127, 8, 192, 194, 8, 18], -- $5D
  #[], -- $5E
  #[], -- $5F
  #[164, 3, 13, 206, 194, 136, 38], -- $60
  #[164, 67, 13, 206, 194, 136, 38], -- $61
  #[160, 63, 8, 192, 3, 8, 18], -- $62
  #[224, 127, 13, 192, 131, 8, 18], -- $63
  #[177, 63, 175, 241, 163, 56, 99], -- $64
  #[177, 127, 175, 241, 163, 56, 99], -- $65
  #[160, 3, 8, 192, 195, 8, 2], -- $66
  #[160, 67, 8, 192, 227, 8, 2], -- $67
  #[160, 67, 136, 193, 195, 24, 66], -- $68
  #[160, 127, 8, 192, 195, 8, 18], -- $69
  #[177, 3, 15, 206, 166, 136, 34], -- $6A
  #[42, 3, 24, 192, 66, 8, 2], -- $6B
  #[160, 3, 24, 206, 130, 136, 34], -- $6C
  #[164, 3, 56, 200, 131, 8, 6], -- $6D
  #[177, 63, 15, 214, 134, 40, 50], -- $6E
  #[177, 127, 15, 214, 134, 40, 50], -- $6F
  #[0, 0, 0, 0, 0, 0, 0], -- $70
  #[0, 0, 0, 0, 0, 0, 0], -- $71
  #[36, 67, 24, 192, 195, 8, 6], -- $72
  #[], -- $73
  #[168, 67, 8, 192, 131, 12, 11], -- $74
  #[177, 195, 143, 201, 198, 136, 34], -- $75
  #[160, 67, 8, 206, 2, 136, 2], -- $76
  #[42, 67, 56, 240, 67, 40, 2], -- $77
  #[224, 255, 8, 192, 130, 8, 50], -- $78
  #[], -- $79
  #[], -- $7A
  #[0, 0, 0, 0, 0, 0, 0], -- $7B
  #[0, 0, 0, 0, 0, 0, 0], -- $7C
  #[42, 67, 56, 240, 67, 40, 2], -- $7D
  #[177, 67, 15, 206, 166, 136, 34], -- $7E
  #[], -- $7F
  #[177, 255, 15, 200, 194, 8, 50], -- $80
  #[177, 67, 15, 240, 135, 58, 67], -- $81
  #[42, 67, 24, 192, 66, 8, 2], -- $82
  #[177, 255, 175, 241, 175, 56, 99], -- $83
  #[177, 255, 175, 215, 175, 168, 50], -- $84
  #[0, 0, 0, 0, 0, 0, 0], -- $85
  #[], -- $86
  #[], -- $87
  #[160, 64, 152, 193, 42, 72, 2], -- $88
  #[], -- $89
  #[164, 127, 8, 192, 2, 8, 54], -- $8A
  #[32, 127, 8, 224, 75, 72, 19], -- $8B
  #[], -- $8C
  #[32, 65, 136, 225, 203, 88, 66], -- $8D
  #[177, 127, 175, 241, 167, 56, 99], -- $8E
  #[32, 64, 136, 193, 42, 72, 2], -- $8F
  #[160, 207, 136, 193, 194, 8, 2], -- $90
  #[177, 127, 15, 206, 162, 8, 34], -- $91
  #[], -- $92
  #[32, 0, 152, 209, 10, 106, 2], -- $93
  #[177, 3, 15, 240, 135, 56, 67], -- $94
  #[177, 67, 15, 248, 135, 56, 67], -- $95
  #[42, 3, 8, 192, 67, 12, 10], -- $96
  #[42, 67, 8, 192, 67, 12, 10], -- $97
  #[32, 127, 136, 241, 195, 56, 83], -- $98
  #[164, 3, 56, 192, 3, 8, 6], -- $99
  #[164, 67, 56, 192, 3, 8, 6], -- $9A
  #[36, 127, 24, 192, 131, 8, 22], -- $9B
  #[], -- $9C
  #[96, 63, 8, 192, 194, 8, 18], -- $9D
  #[96, 127, 8, 192, 194, 8, 18], -- $9E
  #[], -- $9F
  #[], -- $A0
  #[], -- $A1
  #[], -- $A2
  #[224, 3, 8, 192, 227, 8, 2], -- $A3
  #[224, 67, 8, 192, 227, 8, 2], -- $A4
  #[160, 47, 136, 201, 194, 8, 2], -- $A5
  #[160, 127, 136, 201, 194, 8, 2], -- $A6
  #[224, 63, 136, 193, 131, 8, 2], -- $A7
  #[224, 63, 136, 193, 131, 8, 2], -- $A8
  #[161, 3, 15, 206, 46, 200, 34], -- $A9
  #[32, 115, 136, 241, 195, 56, 67], -- $AA
  #[42, 67, 72, 192, 99, 12, 10], -- $AB
  #[], -- $AC
  #[32, 3, 136, 225, 67, 24, 66], -- $AD
  #[], -- $AE
  #[], -- $AF
  #[181, 3, 79, 200, 227, 8, 38], -- $B0
  #[177, 63, 15, 200, 131, 8, 50], -- $B1
  #[181, 3, 79, 200, 227, 8, 38], -- $B2
  #[177, 63, 15, 200, 131, 8, 50], -- $B3
  #[181, 67, 79, 206, 227, 8, 38], -- $B4
  #[], -- $B5
  #[], -- $B6
  #[], -- $B7
  #[], -- $B8
  #[36, 3, 56, 192, 3, 8, 6], -- $B9
  #[36, 3, 56, 192, 3, 8, 6], -- $BA
  #[164, 67, 56, 192, 3, 8, 6], -- $BB
  #[36, 3, 56, 192, 3, 8, 6], -- $BC
  #[36, 3, 56, 192, 3, 8, 6], -- $BD
  #[164, 67, 56, 192, 3, 8, 6], -- $BE
]

/-- Whether an internal species accepts a machine index (`0..49` TM, `50..54` HM). -/
def machineCompatible (species : SpeciesId) (index : Nat) : Bool :=
  if index < tmhmMoves.size then
    let flags := tmhmFlags.getD species.toNat #[]
    (flags.getD (index / 8) 0).toNat.testBit (index % 8)
  else false

/-- Evolution methods and exact level-up rows. -/
def rows : Array Row := #[
  { evolutions := #[], levelMoves := #[] }, -- $00
  { evolutions := #[], levelMoves := #[{ level := 30, move := 23 }, { level := 35, move := 39 }, { level := 40, move := 31 }, { level := 48, move := 32 }, { level := 55, move := 43 }, { level := 64, move := 36 }] }, -- $01
  { evolutions := #[], levelMoves := #[{ level := 26, move := 44 }, { level := 31, move := 39 }, { level := 36, move := 5 }, { level := 41, move := 43 }, { level := 46, move := 146 }] }, -- $02
  { evolutions := #[{ method := .level 16, target := 167 }], levelMoves := #[{ level := 8, move := 30 }, { level := 14, move := 40 }, { level := 21, move := 116 }, { level := 29, move := 31 }, { level := 36, move := 32 }, { level := 43, move := 24 }] }, -- $03
  { evolutions := #[{ method := .item 10 1, target := 142 }], levelMoves := #[{ level := 13, move := 47 }, { level := 18, move := 3 }, { level := 24, move := 107 }, { level := 31, move := 118 }, { level := 39, move := 111 }, { level := 48, move := 113 }] }, -- $04
  { evolutions := #[{ method := .level 20, target := 35 }], levelMoves := #[{ level := 9, move := 43 }, { level := 15, move := 31 }, { level := 22, move := 119 }, { level := 29, move := 65 }, { level := 36, move := 97 }] }, -- $05
  { evolutions := #[{ method := .level 30, target := 141 }], levelMoves := #[{ level := 17, move := 49 }, { level := 22, move := 120 }, { level := 29, move := 113 }, { level := 36, move := 129 }, { level := 43, move := 153 }] }, -- $06
  { evolutions := #[], levelMoves := #[{ level := 8, move := 30 }, { level := 14, move := 40 }, { level := 23, move := 37 }] }, -- $07
  { evolutions := #[], levelMoves := #[{ level := 18, move := 50 }, { level := 22, move := 29 }, { level := 27, move := 45 }, { level := 33, move := 55 }, { level := 37, move := 110 }, { level := 44, move := 133 }, { level := 55, move := 94 }] }, -- $08
  { evolutions := #[{ method := .level 32, target := 154 }], levelMoves := #[{ level := 7, move := 73 }, { level := 13, move := 22 }, { level := 22, move := 77 }, { level := 30, move := 75 }, { level := 38, move := 74 }, { level := 46, move := 79 }, { level := 54, move := 76 }] }, -- $09
  { evolutions := #[], levelMoves := #[{ level := 28, move := 23 }] }, -- $0A
  { evolutions := #[], levelMoves := #[{ level := 7, move := 23 }, { level := 15, move := 50 }, { level := 23, move := 111 }, { level := 31, move := 21 }, { level := 39, move := 103 }] }, -- $0B
  { evolutions := #[{ method := .item 47 1, target := 10 }], levelMoves := #[{ level := 25, move := 115 }, { level := 28, move := 73 }, { level := 32, move := 78 }, { level := 37, move := 77 }, { level := 42, move := 76 }, { level := 48, move := 79 }] }, -- $0C
  { evolutions := #[{ method := .level 38, target := 136 }], levelMoves := #[{ level := 30, move := 139 }, { level := 33, move := 107 }, { level := 37, move := 124 }, { level := 42, move := 106 }, { level := 48, move := 103 }, { level := 55, move := 151 }] }, -- $0D
  { evolutions := #[], levelMoves := #[{ level := 29, move := 95 }, { level := 38, move := 138 }] }, -- $0E
  { evolutions := #[{ method := .level 16, target := 168 }], levelMoves := #[{ level := 8, move := 10 }, { level := 14, move := 40 }, { level := 21, move := 39 }, { level := 29, move := 44 }, { level := 36, move := 154 }, { level := 43, move := 24 }] }, -- $0F
  { evolutions := #[], levelMoves := #[{ level := 8, move := 10 }, { level := 14, move := 40 }, { level := 23, move := 34 }] }, -- $10
  { evolutions := #[{ method := .level 28, target := 145 }], levelMoves := #[{ level := 25, move := 43 }, { level := 31, move := 116 }, { level := 38, move := 37 }, { level := 43, move := 155 }, { level := 46, move := 99 }] }, -- $11
  { evolutions := #[{ method := .level 42, target := 1 }], levelMoves := #[{ level := 30, move := 23 }, { level := 35, move := 39 }, { level := 40, move := 31 }, { level := 45, move := 32 }, { level := 50, move := 43 }, { level := 55, move := 36 }] }, -- $12
  { evolutions := #[], levelMoves := #[{ level := 16, move := 47 }, { level := 20, move := 54 }, { level := 25, move := 34 }, { level := 31, move := 109 }, { level := 38, move := 58 }, { level := 46, move := 56 }] }, -- $13
  { evolutions := #[], levelMoves := #[] }, -- $14
  { evolutions := #[], levelMoves := #[{ level := 10, move := 144 }, { level := 20, move := 5 }, { level := 30, move := 118 }, { level := 40, move := 94 }] }, -- $15
  { evolutions := #[], levelMoves := #[{ level := 20, move := 44 }, { level := 25, move := 82 }, { level := 32, move := 43 }, { level := 41, move := 56 }, { level := 52, move := 63 }] }, -- $16
  { evolutions := #[{ method := .item 34 1, target := 139 }], levelMoves := #[{ level := 18, move := 48 }, { level := 23, move := 128 }, { level := 30, move := 62 }, { level := 39, move := 43 }, { level := 50, move := 58 }] }, -- $17
  { evolutions := #[{ method := .level 30, target := 155 }], levelMoves := #[{ level := 7, move := 48 }, { level := 13, move := 35 }, { level := 18, move := 40 }, { level := 22, move := 55 }, { level := 27, move := 132 }, { level := 33, move := 112 }, { level := 40, move := 103 }, { level := 48, move := 56 }] }, -- $18
  { evolutions := #[{ method := .level 25, target := 147 }], levelMoves := #[{ level := 27, move := 95 }, { level := 35, move := 138 }] }, -- $19
  { evolutions := #[], levelMoves := #[{ level := 17, move := 43 }, { level := 20, move := 116 }, { level := 24, move := 104 }, { level := 29, move := 163 }, { level := 35, move := 14 }, { level := 42, move := 97 }] }, -- $1A
  { evolutions := #[{ method := .item 34 1, target := 152 }], levelMoves := #[{ level := 17, move := 55 }, { level := 22, move := 106 }, { level := 27, move := 105 }, { level := 32, move := 129 }, { level := 37, move := 107 }, { level := 42, move := 113 }, { level := 47, move := 56 }] }, -- $1B
  { evolutions := #[], levelMoves := #[{ level := 8, move := 145 }, { level := 15, move := 55 }, { level := 24, move := 44 }, { level := 31, move := 110 }, { level := 42, move := 130 }, { level := 52, move := 56 }] }, -- $1C
  { evolutions := #[], levelMoves := #[{ level := 25, move := 69 }, { level := 30, move := 12 }, { level := 36, move := 116 }, { level := 43, move := 106 }, { level := 49, move := 163 }, { level := 54, move := 14 }] }, -- $1D
  { evolutions := #[], levelMoves := #[{ level := 29, move := 71 }, { level := 32, move := 77 }, { level := 36, move := 78 }, { level := 39, move := 79 }, { level := 45, move := 21 }, { level := 49, move := 74 }] }, -- $1E
  { evolutions := #[], levelMoves := #[] }, -- $1F
  { evolutions := #[], levelMoves := #[] }, -- $20
  { evolutions := #[{ method := .item 32 1, target := 20 }], levelMoves := #[{ level := 18, move := 52 }, { level := 23, move := 43 }, { level := 30, move := 36 }, { level := 39, move := 97 }, { level := 50, move := 53 }] }, -- $21
  { evolutions := #[], levelMoves := #[{ level := 15, move := 20 }, { level := 19, move := 88 }, { level := 25, move := 99 }, { level := 33, move := 21 }, { level := 43, move := 106 }] }, -- $22
  { evolutions := #[], levelMoves := #[{ level := 9, move := 43 }, { level := 15, move := 31 }, { level := 25, move := 119 }, { level := 34, move := 65 }, { level := 43, move := 97 }] }, -- $23
  { evolutions := #[{ method := .level 18, target := 150 }], levelMoves := #[{ level := 5, move := 28 }, { level := 12, move := 98 }, { level := 19, move := 18 }, { level := 28, move := 17 }, { level := 36, move := 97 }, { level := 44, move := 119 }] }, -- $24
  { evolutions := #[{ method := .level 37, target := 8 }], levelMoves := #[{ level := 18, move := 50 }, { level := 22, move := 29 }, { level := 27, move := 45 }, { level := 33, move := 55 }, { level := 40, move := 133 }, { level := 48, move := 94 }] }, -- $25
  { evolutions := #[{ method := .trade 1, target := 149 }], levelMoves := #[{ level := 16, move := 93 }, { level := 20, move := 50 }, { level := 27, move := 60 }, { level := 31, move := 105 }, { level := 38, move := 94 }, { level := 42, move := 115 }] }, -- $26
  { evolutions := #[{ method := .trade 1, target := 49 }], levelMoves := #[{ level := 11, move := 111 }, { level := 16, move := 88 }, { level := 21, move := 120 }, { level := 29, move := 106 }, { level := 36, move := 89 }, { level := 43, move := 153 }] }, -- $27
  { evolutions := #[], levelMoves := #[{ level := 24, move := 47 }, { level := 30, move := 45 }, { level := 38, move := 107 }, { level := 44, move := 111 }, { level := 48, move := 113 }, { level := 54, move := 38 }] }, -- $28
  { evolutions := #[{ method := .trade 1, target := 126 }], levelMoves := #[{ level := 20, move := 67 }, { level := 25, move := 43 }, { level := 36, move := 116 }, { level := 44, move := 69 }, { level := 52, move := 66 }] }, -- $29
  { evolutions := #[], levelMoves := #[{ level := 15, move := 93 }, { level := 23, move := 113 }, { level := 31, move := 3 }, { level := 39, move := 96 }, { level := 47, move := 164 }] }, -- $2A
  { evolutions := #[], levelMoves := #[{ level := 33, move := 27 }, { level := 38, move := 26 }, { level := 43, move := 116 }, { level := 48, move := 136 }, { level := 53, move := 25 }] }, -- $2B
  { evolutions := #[], levelMoves := #[{ level := 33, move := 7 }, { level := 38, move := 8 }, { level := 43, move := 9 }, { level := 48, move := 5 }, { level := 53, move := 68 }] }, -- $2C
  { evolutions := #[], levelMoves := #[{ level := 10, move := 40 }, { level := 17, move := 44 }, { level := 27, move := 137 }, { level := 36, move := 103 }, { level := 47, move := 51 }] }, -- $2D
  { evolutions := #[], levelMoves := #[{ level := 13, move := 78 }, { level := 20, move := 141 }, { level := 30, move := 147 }, { level := 39, move := 163 }, { level := 48, move := 74 }] }, -- $2E
  { evolutions := #[{ method := .level 33, target := 128 }], levelMoves := #[{ level := 28, move := 39 }, { level := 31, move := 50 }, { level := 36, move := 93 }, { level := 43, move := 154 }, { level := 52, move := 56 }] }, -- $2F
  { evolutions := #[{ method := .level 26, target := 129 }], levelMoves := #[{ level := 12, move := 50 }, { level := 17, move := 93 }, { level := 24, move := 29 }, { level := 29, move := 139 }, { level := 32, move := 94 }, { level := 37, move := 96 }] }, -- $30
  { evolutions := #[], levelMoves := #[{ level := 11, move := 111 }, { level := 16, move := 88 }, { level := 21, move := 120 }, { level := 29, move := 106 }, { level := 36, move := 89 }, { level := 43, move := 153 }] }, -- $31
  { evolutions := #[], levelMoves := #[] }, -- $32
  { evolutions := #[], levelMoves := #[{ level := 36, move := 43 }, { level := 39, move := 109 }, { level := 43, move := 7 }, { level := 48, move := 108 }, { level := 52, move := 123 }, { level := 55, move := 53 }] }, -- $33
  { evolutions := #[], levelMoves := #[] }, -- $34
  { evolutions := #[], levelMoves := #[{ level := 34, move := 84 }, { level := 37, move := 103 }, { level := 42, move := 9 }, { level := 49, move := 113 }, { level := 54, move := 87 }] }, -- $35
  { evolutions := #[], levelMoves := #[{ level := 21, move := 49 }, { level := 25, move := 84 }, { level := 29, move := 48 }, { level := 38, move := 86 }, { level := 46, move := 129 }, { level := 54, move := 103 }] }, -- $36
  { evolutions := #[{ method := .level 35, target := 143 }], levelMoves := #[{ level := 32, move := 124 }, { level := 37, move := 108 }, { level := 40, move := 120 }, { level := 45, move := 114 }, { level := 48, move := 153 }] }, -- $37
  { evolutions := #[], levelMoves := #[] }, -- $38
  { evolutions := #[{ method := .level 28, target := 117 }], levelMoves := #[{ level := 15, move := 2 }, { level := 21, move := 154 }, { level := 27, move := 116 }, { level := 33, move := 69 }, { level := 39, move := 37 }] }, -- $39
  { evolutions := #[{ method := .level 34, target := 120 }], levelMoves := #[{ level := 30, move := 45 }, { level := 35, move := 62 }, { level := 40, move := 156 }, { level := 45, move := 36 }, { level := 50, move := 58 }] }, -- $3A
  { evolutions := #[{ method := .level 26, target := 118 }], levelMoves := #[{ level := 15, move := 45 }, { level := 19, move := 91 }, { level := 24, move := 28 }, { level := 31, move := 163 }, { level := 40, move := 89 }] }, -- $3B
  { evolutions := #[], levelMoves := #[{ level := 21, move := 23 }, { level := 28, move := 39 }, { level := 35, move := 43 }, { level := 44, move := 99 }, { level := 51, move := 36 }] }, -- $3C
  { evolutions := #[], levelMoves := #[] }, -- $3D
  { evolutions := #[], levelMoves := #[] }, -- $3E
  { evolutions := #[], levelMoves := #[] }, -- $3F
  { evolutions := #[], levelMoves := #[{ level := 7, move := 43 }, { level := 15, move := 31 }, { level := 23, move := 14 }, { level := 31, move := 97 }, { level := 39, move := 163 }] }, -- $40
  { evolutions := #[{ method := .level 31, target := 119 }], levelMoves := #[{ level := 24, move := 77 }, { level := 27, move := 141 }, { level := 30, move := 78 }, { level := 35, move := 60 }, { level := 38, move := 79 }, { level := 43, move := 94 }] }, -- $41
  { evolutions := #[], levelMoves := #[{ level := 10, move := 86 }, { level := 20, move := 97 }, { level := 35, move := 21 }, { level := 45, move := 82 }, { level := 60, move := 63 }] }, -- $42
  { evolutions := #[], levelMoves := #[] }, -- $43
  { evolutions := #[], levelMoves := #[] }, -- $44
  { evolutions := #[], levelMoves := #[] }, -- $45
  { evolutions := #[{ method := .level 31, target := 116 }], levelMoves := #[{ level := 20, move := 45 }, { level := 24, move := 31 }, { level := 30, move := 65 }, { level := 36, move := 99 }, { level := 40, move := 161 }, { level := 44, move := 97 }] }, -- $46
  { evolutions := #[{ method := .level 25, target := 110 }], levelMoves := #[{ level := 16, move := 95 }, { level := 19, move := 55 }, { level := 25, move := 3 }, { level := 31, move := 34 }, { level := 38, move := 133 }, { level := 45, move := 56 }] }, -- $47
  { evolutions := #[], levelMoves := #[{ level := 18, move := 122 }, { level := 23, move := 3 }, { level := 31, move := 8 }, { level := 39, move := 34 }, { level := 47, move := 37 }, { level := 58, move := 59 }] }, -- $48
  { evolutions := #[], levelMoves := #[{ level := 51, move := 43 }, { level := 55, move := 97 }, { level := 60, move := 143 }] }, -- $49
  { evolutions := #[], levelMoves := #[{ level := 51, move := 59 }, { level := 55, move := 97 }, { level := 60, move := 54 }] }, -- $4A
  { evolutions := #[], levelMoves := #[{ level := 51, move := 87 }, { level := 55, move := 97 }, { level := 60, move := 113 }] }, -- $4B
  { evolutions := #[], levelMoves := #[] }, -- $4C
  { evolutions := #[{ method := .level 28, target := 144 }], levelMoves := #[{ level := 12, move := 44 }, { level := 17, move := 6 }, { level := 24, move := 103 }, { level := 33, move := 154 }, { level := 44, move := 163 }] }, -- $4D
  { evolutions := #[{ method := .level 28, target := 138 }], levelMoves := #[{ level := 20, move := 11 }, { level := 25, move := 12 }, { level := 30, move := 23 }, { level := 35, move := 152 }, { level := 40, move := 106 }] }, -- $4E
  { evolutions := #[], levelMoves := #[] }, -- $4F
  { evolutions := #[], levelMoves := #[] }, -- $50
  { evolutions := #[], levelMoves := #[] }, -- $51
  { evolutions := #[{ method := .item 32 1, target := 83 }], levelMoves := #[{ level := 16, move := 98 }, { level := 21, move := 46 }, { level := 28, move := 109 }, { level := 35, move := 53 }, { level := 42, move := 83 }] }, -- $52
  { evolutions := #[], levelMoves := #[] }, -- $53
  { evolutions := #[{ method := .item 33 1, target := 85 }], levelMoves := #[{ level := 9, move := 86 }, { level := 16, move := 98 }, { level := 26, move := 129 }, { level := 33, move := 97 }, { level := 43, move := 87 }] }, -- $54
  { evolutions := #[], levelMoves := #[] }, -- $55
  { evolutions := #[], levelMoves := #[] }, -- $56
  { evolutions := #[], levelMoves := #[] }, -- $57
  { evolutions := #[{ method := .level 30, target := 89 }], levelMoves := #[{ level := 10, move := 86 }, { level := 20, move := 97 }, { level := 30, move := 21 }, { level := 40, move := 82 }, { level := 50, move := 63 }] }, -- $58
  { evolutions := #[{ method := .level 55, target := 66 }], levelMoves := #[{ level := 10, move := 86 }, { level := 20, move := 97 }, { level := 35, move := 21 }, { level := 45, move := 82 }, { level := 55, move := 63 }] }, -- $59
  { evolutions := #[{ method := .level 40, target := 91 }], levelMoves := #[{ level := 34, move := 71 }, { level := 39, move := 163 }, { level := 44, move := 43 }, { level := 49, move := 56 }] }, -- $5A
  { evolutions := #[], levelMoves := #[{ level := 34, move := 71 }, { level := 39, move := 163 }, { level := 46, move := 43 }, { level := 53, move := 56 }] }, -- $5B
  { evolutions := #[{ method := .level 32, target := 93 }], levelMoves := #[{ level := 19, move := 108 }, { level := 24, move := 43 }, { level := 30, move := 55 }, { level := 37, move := 97 }, { level := 45, move := 56 }] }, -- $5C
  { evolutions := #[], levelMoves := #[{ level := 19, move := 108 }, { level := 24, move := 43 }, { level := 30, move := 55 }, { level := 41, move := 97 }, { level := 52, move := 56 }] }, -- $5D
  { evolutions := #[], levelMoves := #[] }, -- $5E
  { evolutions := #[], levelMoves := #[] }, -- $5F
  { evolutions := #[{ method := .level 22, target := 97 }], levelMoves := #[{ level := 10, move := 28 }, { level := 17, move := 163 }, { level := 24, move := 40 }, { level := 31, move := 129 }, { level := 38, move := 154 }] }, -- $60
  { evolutions := #[], levelMoves := #[{ level := 10, move := 28 }, { level := 17, move := 163 }, { level := 27, move := 40 }, { level := 36, move := 129 }, { level := 47, move := 154 }] }, -- $61
  { evolutions := #[{ method := .level 40, target := 99 }], levelMoves := #[{ level := 34, move := 30 }, { level := 39, move := 43 }, { level := 46, move := 131 }, { level := 53, move := 56 }] }, -- $62
  { evolutions := #[], levelMoves := #[{ level := 34, move := 30 }, { level := 39, move := 43 }, { level := 44, move := 131 }, { level := 49, move := 56 }] }, -- $63
  { evolutions := #[{ method := .item 10 1, target := 101 }], levelMoves := #[{ level := 9, move := 1 }, { level := 14, move := 50 }, { level := 19, move := 111 }, { level := 24, move := 3 }, { level := 29, move := 156 }, { level := 34, move := 34 }, { level := 39, move := 38 }] }, -- $64
  { evolutions := #[], levelMoves := #[] }, -- $65
  { evolutions := #[{ method := .item 32 1, target := 103 }, { method := .item 33 1, target := 104 }, { method := .item 34 1, target := 105 }], levelMoves := #[{ level := 27, move := 98 }, { level := 31, move := 39 }, { level := 37, move := 44 }, { level := 45, move := 36 }] }, -- $66
  { evolutions := #[], levelMoves := #[{ level := 27, move := 98 }, { level := 31, move := 52 }, { level := 37, move := 39 }, { level := 40, move := 44 }, { level := 42, move := 43 }, { level := 44, move := 83 }, { level := 48, move := 99 }, { level := 54, move := 53 }] }, -- $67
  { evolutions := #[], levelMoves := #[{ level := 27, move := 98 }, { level := 31, move := 84 }, { level := 37, move := 39 }, { level := 40, move := 86 }, { level := 42, move := 24 }, { level := 44, move := 97 }, { level := 48, move := 42 }, { level := 54, move := 87 }] }, -- $68
  { evolutions := #[], levelMoves := #[{ level := 27, move := 98 }, { level := 31, move := 55 }, { level := 37, move := 39 }, { level := 40, move := 44 }, { level := 42, move := 151 }, { level := 44, move := 114 }, { level := 48, move := 54 }, { level := 54, move := 56 }] }, -- $69
  { evolutions := #[{ method := .level 28, target := 41 }], levelMoves := #[{ level := 20, move := 67 }, { level := 25, move := 43 }, { level := 32, move := 116 }, { level := 39, move := 69 }, { level := 46, move := 66 }] }, -- $6A
  { evolutions := #[{ method := .level 22, target := 130 }], levelMoves := #[{ level := 10, move := 48 }, { level := 15, move := 44 }, { level := 21, move := 109 }, { level := 28, move := 17 }, { level := 36, move := 114 }] }, -- $6B
  { evolutions := #[{ method := .level 22, target := 45 }], levelMoves := #[{ level := 10, move := 40 }, { level := 17, move := 44 }, { level := 24, move := 137 }, { level := 31, move := 103 }, { level := 38, move := 51 }] }, -- $6C
  { evolutions := #[{ method := .level 24, target := 46 }], levelMoves := #[{ level := 13, move := 78 }, { level := 20, move := 141 }, { level := 27, move := 147 }, { level := 34, move := 163 }, { level := 41, move := 74 }] }, -- $6D
  { evolutions := #[{ method := .item 34 1, target := 111 }], levelMoves := #[{ level := 16, move := 95 }, { level := 19, move := 55 }, { level := 26, move := 3 }, { level := 33, move := 34 }, { level := 41, move := 133 }, { level := 49, move := 56 }] }, -- $6E
  { evolutions := #[], levelMoves := #[{ level := 16, move := 95 }, { level := 19, move := 55 }] }, -- $6F
  { evolutions := #[{ method := .level 7, target := 113 }], levelMoves := #[] }, -- $70
  { evolutions := #[{ method := .level 10, target := 114 }], levelMoves := #[] }, -- $71
  { evolutions := #[], levelMoves := #[{ level := 12, move := 31 }, { level := 16, move := 116 }, { level := 20, move := 41 }, { level := 25, move := 99 }, { level := 30, move := 42 }, { level := 35, move := 97 }] }, -- $72
  { evolutions := #[], levelMoves := #[] }, -- $73
  { evolutions := #[], levelMoves := #[{ level := 20, move := 45 }, { level := 24, move := 31 }, { level := 30, move := 65 }, { level := 39, move := 99 }, { level := 45, move := 161 }, { level := 51, move := 97 }] }, -- $74
  { evolutions := #[], levelMoves := #[{ level := 15, move := 2 }, { level := 21, move := 154 }, { level := 27, move := 116 }, { level := 37, move := 69 }, { level := 46, move := 37 }] }, -- $75
  { evolutions := #[], levelMoves := #[{ level := 15, move := 45 }, { level := 19, move := 91 }, { level := 24, move := 28 }, { level := 35, move := 163 }, { level := 47, move := 89 }] }, -- $76
  { evolutions := #[], levelMoves := #[{ level := 24, move := 77 }, { level := 27, move := 141 }, { level := 30, move := 78 }, { level := 38, move := 60 }, { level := 43, move := 79 }, { level := 50, move := 94 }] }, -- $77
  { evolutions := #[], levelMoves := #[{ level := 30, move := 45 }, { level := 35, move := 62 }, { level := 44, move := 156 }, { level := 50, move := 36 }, { level := 56, move := 58 }] }, -- $78
  { evolutions := #[], levelMoves := #[] }, -- $79
  { evolutions := #[], levelMoves := #[] }, -- $7A
  { evolutions := #[{ method := .level 7, target := 124 }], levelMoves := #[] }, -- $7B
  { evolutions := #[{ method := .level 10, target := 125 }], levelMoves := #[] }, -- $7C
  { evolutions := #[], levelMoves := #[{ level := 12, move := 93 }, { level := 15, move := 77 }, { level := 16, move := 78 }, { level := 17, move := 79 }, { level := 21, move := 48 }, { level := 26, move := 18 }, { level := 32, move := 60 }] }, -- $7D
  { evolutions := #[], levelMoves := #[{ level := 20, move := 67 }, { level := 25, move := 43 }, { level := 36, move := 116 }, { level := 44, move := 69 }, { level := 52, move := 66 }] }, -- $7E
  { evolutions := #[], levelMoves := #[] }, -- $7F
  { evolutions := #[], levelMoves := #[{ level := 28, move := 39 }, { level := 31, move := 50 }, { level := 39, move := 93 }, { level := 48, move := 154 }, { level := 59, move := 56 }] }, -- $80
  { evolutions := #[], levelMoves := #[{ level := 12, move := 50 }, { level := 17, move := 93 }, { level := 24, move := 29 }, { level := 33, move := 139 }, { level := 37, move := 94 }, { level := 43, move := 96 }] }, -- $81
  { evolutions := #[], levelMoves := #[{ level := 10, move := 48 }, { level := 15, move := 44 }, { level := 21, move := 109 }, { level := 32, move := 17 }, { level := 43, move := 114 }] }, -- $82
  { evolutions := #[], levelMoves := #[{ level := 63, move := 112 }, { level := 66, move := 94 }, { level := 70, move := 105 }, { level := 75, move := 54 }, { level := 81, move := 133 }] }, -- $83
  { evolutions := #[], levelMoves := #[{ level := 35, move := 34 }, { level := 41, move := 106 }, { level := 48, move := 38 }, { level := 56, move := 63 }] }, -- $84
  { evolutions := #[{ method := .level 20, target := 22 }], levelMoves := #[{ level := 15, move := 33 }] }, -- $85
  { evolutions := #[], levelMoves := #[] }, -- $86
  { evolutions := #[], levelMoves := #[] }, -- $87
  { evolutions := #[], levelMoves := #[{ level := 30, move := 139 }, { level := 33, move := 107 }, { level := 37, move := 124 }, { level := 45, move := 106 }, { level := 53, move := 103 }, { level := 60, move := 151 }] }, -- $88
  { evolutions := #[], levelMoves := #[] }, -- $89
  { evolutions := #[], levelMoves := #[{ level := 20, move := 11 }, { level := 25, move := 12 }, { level := 34, move := 23 }, { level := 42, move := 152 }, { level := 49, move := 106 }] }, -- $8A
  { evolutions := #[], levelMoves := #[{ level := 50, move := 131 }] }, -- $8B
  { evolutions := #[], levelMoves := #[] }, -- $8C
  { evolutions := #[], levelMoves := #[{ level := 17, move := 49 }, { level := 22, move := 120 }, { level := 29, move := 113 }, { level := 40, move := 129 }, { level := 50, move := 153 }] }, -- $8D
  { evolutions := #[], levelMoves := #[] }, -- $8E
  { evolutions := #[], levelMoves := #[{ level := 32, move := 124 }, { level := 39, move := 108 }, { level := 43, move := 120 }, { level := 49, move := 114 }, { level := 53, move := 153 }] }, -- $8F
  { evolutions := #[], levelMoves := #[{ level := 12, move := 44 }, { level := 17, move := 6 }, { level := 24, move := 103 }, { level := 37, move := 154 }, { level := 51, move := 163 }] }, -- $90
  { evolutions := #[], levelMoves := #[{ level := 25, move := 43 }, { level := 33, move := 116 }, { level := 41, move := 37 }, { level := 48, move := 155 }, { level := 55, move := 99 }] }, -- $91
  { evolutions := #[], levelMoves := #[] }, -- $92
  { evolutions := #[{ method := .trade 1, target := 14 }], levelMoves := #[{ level := 29, move := 95 }, { level := 38, move := 138 }] }, -- $93
  { evolutions := #[{ method := .level 16, target := 38 }], levelMoves := #[] }, -- $94
  { evolutions := #[], levelMoves := #[{ level := 16, move := 93 }, { level := 20, move := 50 }, { level := 27, move := 60 }, { level := 31, move := 105 }, { level := 38, move := 94 }, { level := 42, move := 115 }] }, -- $95
  { evolutions := #[{ method := .level 36, target := 151 }], levelMoves := #[{ level := 5, move := 28 }, { level := 12, move := 98 }, { level := 21, move := 18 }, { level := 31, move := 17 }, { level := 40, move := 97 }, { level := 49, move := 119 }] }, -- $96
  { evolutions := #[], levelMoves := #[{ level := 5, move := 28 }, { level := 12, move := 98 }, { level := 21, move := 18 }, { level := 31, move := 17 }, { level := 44, move := 97 }, { level := 54, move := 119 }] }, -- $97
  { evolutions := #[], levelMoves := #[] }, -- $98
  { evolutions := #[{ method := .level 16, target := 9 }], levelMoves := #[{ level := 7, move := 73 }, { level := 13, move := 22 }, { level := 20, move := 77 }, { level := 27, move := 75 }, { level := 34, move := 74 }, { level := 41, move := 79 }, { level := 48, move := 76 }] }, -- $99
  { evolutions := #[], levelMoves := #[{ level := 7, move := 73 }, { level := 13, move := 22 }, { level := 22, move := 77 }, { level := 30, move := 75 }, { level := 43, move := 74 }, { level := 55, move := 79 }, { level := 65, move := 76 }] }, -- $9A
  { evolutions := #[], levelMoves := #[{ level := 7, move := 48 }, { level := 13, move := 35 }, { level := 18, move := 40 }, { level := 22, move := 55 }, { level := 27, move := 132 }, { level := 35, move := 112 }, { level := 43, move := 103 }, { level := 50, move := 56 }] }, -- $9B
  { evolutions := #[], levelMoves := #[] }, -- $9C
  { evolutions := #[{ method := .level 33, target := 158 }], levelMoves := #[{ level := 19, move := 48 }, { level := 24, move := 30 }, { level := 30, move := 31 }, { level := 37, move := 127 }, { level := 45, move := 32 }, { level := 54, move := 97 }] }, -- $9D
  { evolutions := #[], levelMoves := #[{ level := 19, move := 48 }, { level := 24, move := 30 }, { level := 30, move := 31 }, { level := 39, move := 127 }, { level := 48, move := 32 }, { level := 54, move := 97 }] }, -- $9E
  { evolutions := #[], levelMoves := #[] }, -- $9F
  { evolutions := #[], levelMoves := #[] }, -- $A0
  { evolutions := #[], levelMoves := #[] }, -- $A1
  { evolutions := #[], levelMoves := #[] }, -- $A2
  { evolutions := #[{ method := .level 40, target := 164 }], levelMoves := #[{ level := 30, move := 39 }, { level := 32, move := 23 }, { level := 35, move := 45 }, { level := 39, move := 83 }, { level := 43, move := 36 }, { level := 48, move := 97 }] }, -- $A3
  { evolutions := #[], levelMoves := #[{ level := 30, move := 39 }, { level := 32, move := 23 }, { level := 35, move := 45 }, { level := 39, move := 83 }, { level := 47, move := 36 }, { level := 55, move := 97 }] }, -- $A4
  { evolutions := #[{ method := .level 20, target := 166 }], levelMoves := #[{ level := 7, move := 98 }, { level := 14, move := 158 }, { level := 23, move := 116 }, { level := 34, move := 162 }] }, -- $A5
  { evolutions := #[], levelMoves := #[{ level := 7, move := 98 }, { level := 14, move := 158 }, { level := 27, move := 116 }, { level := 41, move := 162 }] }, -- $A6
  { evolutions := #[{ method := .item 10 1, target := 7 }], levelMoves := #[{ level := 8, move := 30 }, { level := 14, move := 40 }, { level := 23, move := 116 }, { level := 32, move := 31 }, { level := 41, move := 32 }, { level := 50, move := 24 }] }, -- $A7
  { evolutions := #[{ method := .item 10 1, target := 16 }], levelMoves := #[{ level := 8, move := 10 }, { level := 14, move := 40 }, { level := 23, move := 39 }, { level := 32, move := 44 }, { level := 41, move := 154 }, { level := 50, move := 24 }] }, -- $A8
  { evolutions := #[{ method := .level 25, target := 39 }], levelMoves := #[{ level := 11, move := 111 }, { level := 16, move := 88 }, { level := 21, move := 120 }, { level := 26, move := 106 }, { level := 31, move := 89 }, { level := 36, move := 153 }] }, -- $A9
  { evolutions := #[], levelMoves := #[{ level := 23, move := 60 }, { level := 28, move := 105 }, { level := 35, move := 97 }, { level := 42, move := 161 }] }, -- $AA
  { evolutions := #[], levelMoves := #[{ level := 33, move := 48 }, { level := 38, move := 44 }, { level := 45, move := 36 }, { level := 54, move := 63 }] }, -- $AB
  { evolutions := #[], levelMoves := #[] }, -- $AC
  { evolutions := #[{ method := .level 30, target := 54 }], levelMoves := #[{ level := 21, move := 49 }, { level := 25, move := 84 }, { level := 29, move := 48 }, { level := 35, move := 86 }, { level := 41, move := 129 }, { level := 47, move := 103 }] }, -- $AD
  { evolutions := #[], levelMoves := #[] }, -- $AE
  { evolutions := #[], levelMoves := #[] }, -- $AF
  { evolutions := #[{ method := .level 16, target := 178 }], levelMoves := #[{ level := 9, move := 52 }, { level := 15, move := 43 }, { level := 22, move := 99 }, { level := 30, move := 163 }, { level := 38, move := 53 }, { level := 46, move := 83 }] }, -- $B0
  { evolutions := #[{ method := .level 16, target := 179 }], levelMoves := #[{ level := 8, move := 145 }, { level := 15, move := 55 }, { level := 22, move := 44 }, { level := 28, move := 110 }, { level := 35, move := 130 }, { level := 42, move := 56 }] }, -- $B1
  { evolutions := #[{ method := .level 36, target := 180 }], levelMoves := #[{ level := 9, move := 52 }, { level := 15, move := 43 }, { level := 24, move := 99 }, { level := 33, move := 163 }, { level := 42, move := 53 }, { level := 56, move := 83 }] }, -- $B2
  { evolutions := #[{ method := .level 36, target := 28 }], levelMoves := #[{ level := 8, move := 145 }, { level := 15, move := 55 }, { level := 24, move := 44 }, { level := 31, move := 110 }, { level := 39, move := 130 }, { level := 47, move := 56 }] }, -- $B3
  { evolutions := #[], levelMoves := #[{ level := 9, move := 52 }, { level := 15, move := 43 }, { level := 24, move := 99 }, { level := 36, move := 163 }, { level := 46, move := 53 }, { level := 55, move := 83 }] }, -- $B4
  { evolutions := #[], levelMoves := #[] }, -- $B5
  { evolutions := #[], levelMoves := #[] }, -- $B6
  { evolutions := #[], levelMoves := #[] }, -- $B7
  { evolutions := #[], levelMoves := #[] }, -- $B8
  { evolutions := #[{ method := .level 21, target := 186 }], levelMoves := #[{ level := 15, move := 77 }, { level := 17, move := 78 }, { level := 19, move := 79 }, { level := 24, move := 51 }, { level := 33, move := 80 }, { level := 46, move := 76 }] }, -- $B9
  { evolutions := #[{ method := .item 47 1, target := 187 }], levelMoves := #[{ level := 15, move := 77 }, { level := 17, move := 78 }, { level := 19, move := 79 }, { level := 28, move := 51 }, { level := 38, move := 80 }, { level := 52, move := 76 }] }, -- $BA
  { evolutions := #[], levelMoves := #[{ level := 15, move := 77 }, { level := 17, move := 78 }, { level := 19, move := 79 }] }, -- $BB
  { evolutions := #[{ method := .level 21, target := 189 }], levelMoves := #[{ level := 13, move := 35 }, { level := 15, move := 77 }, { level := 18, move := 79 }, { level := 21, move := 78 }, { level := 26, move := 51 }, { level := 33, move := 75 }, { level := 42, move := 21 }] }, -- $BC
  { evolutions := #[{ method := .item 47 1, target := 190 }], levelMoves := #[{ level := 13, move := 35 }, { level := 15, move := 77 }, { level := 18, move := 79 }, { level := 23, move := 78 }, { level := 29, move := 51 }, { level := 38, move := 75 }, { level := 49, move := 21 }] }, -- $BD
  { evolutions := #[], levelMoves := #[{ level := 13, move := 35 }, { level := 15, move := 77 }, { level := 18, move := 79 }] }, -- $BE
]

@[simp] theorem growthRates_size : growthRates.size = 191 := by native_decide
@[simp] theorem initialMoves_size : initialMoves.size = 191 := by native_decide
@[simp] theorem tmhmMoves_size : tmhmMoves.size = 55 := by native_decide
@[simp] theorem tmhmFlags_size : tmhmFlags.size = 191 := by native_decide
@[simp] theorem rows_size : rows.size = 191 := by native_decide

end Battle.Data.Progression
