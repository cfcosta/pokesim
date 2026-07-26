/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.Mechanics

/-!
# Exhaustive canonical-table certificate boundary

Every table listed by the mechanics inventory has a dependent typed codec and
an explicit caller-supplied canonical-ROM witness. This does not infer bytes
from source catalogues or from the hash: a final Red theorem must supply this
structure from exact byte proofs.
-/

namespace Battle.Rom.AllTables

open Sm83 Battle.Rom.Closure

inductive TableId where
  | moveRecords | moveIds | moveEffects | effectPointers | baseSpecies
  | internalSpeciesMap | pokedexIds | typeIds | typeTriples | stageRatios
  | percentThresholds | trainerClasses | trainerParties | trainerMoveScoring
  | trainerActionAi | specialTrainerMoves | learnsetsEvolutions | growthRates
  | battleItemDispatch | evolutionEntries | bagBoxLayouts | internalToPokedex
  deriving Repr, DecidableEq, BEq

@[simp] theorem table_id_count :
    [TableId.moveRecords, .moveIds, .moveEffects, .effectPointers, .baseSpecies,
      .internalSpeciesMap, .pokedexIds, .typeIds, .typeTriples, .stageRatios,
      .percentThresholds, .trainerClasses, .trainerParties, .trainerMoveScoring,
      .trainerActionAi, .specialTrainerMoves, .learnsetsEvolutions, .growthRates,
      .battleItemDispatch, .evolutionEntries, .bagBoxLayouts,
      .internalToPokedex].length = 22 := by
  rfl

/-- The model type may differ by table; codecs are therefore dependent on the
inventory ID rather than collapsing rows to untyped bytes. -/
structure TypedCodec (id : TableId) where
  Model : Type
  offset : Nat
  length : Nat
  decode : List Byte → Option Model
  encode : Model → List Byte
  expected : Model
  decodeEncode : ∀ value, decode (encode value) = some value
  encodedLength : ∀ value, (encode value).length = length

structure Certificate (rom : CanonicalRom) (id : TableId) where
  codec : TypedCodec id
  bounds : codec.offset + codec.length ≤ rom.bytes.size
  originalBytes : bytesAt rom.bytes codec.offset codec.length =
    codec.encode codec.expected
  typedDecode : codec.decode (bytesAt rom.bytes codec.offset codec.length) =
    some codec.expected

/-- One certificate for every inventory constructor. This is the final theorem
boundary for tables not already projected by `RequiredTableBytes`,
`RequiredEffectBytes`, and `RequiredCombatBytes`. -/
structure RequiredAllTableBytes (rom : CanonicalRom) : Prop where
  table : ∀ id : TableId, Nonempty (Certificate rom id)


theorem bounds_theorem {rom : CanonicalRom} (required : RequiredAllTableBytes rom)
    (id : TableId) :
    ∃ codec : TypedCodec id, codec.offset + codec.length ≤ rom.bytes.size := by
  let ⟨certificate⟩ := required.table id
  exact ⟨certificate.codec, certificate.bounds⟩


theorem typed_decoder_theorem {rom : CanonicalRom}
    (required : RequiredAllTableBytes rom) (id : TableId) :
    ∃ (codec : TypedCodec id),
      codec.decode (bytesAt rom.bytes codec.offset codec.length) = some codec.expected := by
  let ⟨certificate⟩ := required.table id
  exact ⟨certificate.codec, certificate.typedDecode⟩


theorem encode_decode_theorem {rom : CanonicalRom}
    (required : RequiredAllTableBytes rom) (id : TableId) :
    ∃ codec : TypedCodec id, ∀ value, codec.decode (codec.encode value) = some value := by
  let ⟨certificate⟩ := required.table id
  exact ⟨certificate.codec, certificate.codec.decodeEncode⟩


theorem original_byte_equality_theorem {rom : CanonicalRom}
    (required : RequiredAllTableBytes rom) (id : TableId) :
    ∃ codec : TypedCodec id,
      bytesAt rom.bytes codec.offset codec.length = codec.encode codec.expected := by
  let ⟨certificate⟩ := required.table id
  exact ⟨certificate.codec, certificate.originalBytes⟩


theorem table_length_theorem {rom : CanonicalRom}
    (required : RequiredAllTableBytes rom) (id : TableId) :
    ∃ codec : TypedCodec id, ∀ value, (codec.encode value).length = codec.length := by
  let ⟨certificate⟩ := required.table id
  exact ⟨certificate.codec, certificate.codec.encodedLength⟩

end Battle.Rom.AllTables
