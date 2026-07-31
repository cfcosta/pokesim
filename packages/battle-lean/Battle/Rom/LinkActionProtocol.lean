/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.Link
import Battle.GameBoy.LinkAdapter

/-!
# Link action-nybble protocol

This module joins the semantic link action codec to the physical full-duplex
serial device. Pokémon Red frames an action nybble as `$60 + action`, exchanges
the byte, validates the high nybble, and stores the low nybble. For every
encodable pair of actions, the proofs below deliver and decode the peer's exact
framed action.

The theorem covers framing, byte transport, and cable completion. It does not
yet prove that decoded Pokémon Red instructions select the action, execute the
repeated synchronization loops, wait for the interrupt, or commit the received
value into battle WRAM.
-/

namespace Battle.Rom.LinkActionProtocol

open Sm83 Battle Battle.Full

/-- A joint semantic action together with the exact cartridge wire bytes.
Items cannot inhabit this structure because `Full.Link.encodeAction` returns
`none` for them. -/
structure Committed where
  leftAction : Full.Action
  rightAction : Full.Action
  leftWire : UInt8
  rightWire : UInt8
  leftEncoded : Full.Link.encodeAction leftAction = some leftWire
  rightEncoded : Full.Link.encodeAction rightAction = some rightWire
  deriving Repr

/-- Cartridge framing used by `Serial_ExchangeNybble`: add `$60` before the
byte transfer. -/
def frame (wire : UInt8) : UInt8 := wire + 0x60

/-- Cartridge receive filter: only `$6x` is accepted, then the low nybble is
stored as the peer action value. -/
def unframe (received : UInt8) : Option UInt8 :=
  if received &&& 0xF0 == 0x60 then some (received &&& 0x0F) else none

/-- Every action wire value fits in the framed low nybble. -/
theorem encoded_wire_lt_sixteen {action : Full.Action} {wire : UInt8}
    (encoded : Full.Link.encodeAction action = some wire) : wire.toNat < 16 := by
  cases action with
  | fight slot =>
      simp only [Full.Link.encodeAction] at encoded
      injection encoded with equality
      subst wire
      simp
      omega
  | switch target =>
      simp only [Full.Link.encodeAction] at encoded
      injection encoded with equality
      subst wire
      simp
      omega
  | item request => simp [Full.Link.encodeAction] at encoded
  | struggle | noAction | run =>
      simp only [Full.Link.encodeAction] at encoded
      injection encoded with equality
      subst wire
      native_decide

private theorem frame_roundtrip_all (wire : UInt8) (range : wire.toNat < 16) :
    unframe (frame wire) = some wire := by
  have checked : (List.range 16).all (fun raw =>
      decide (unframe (frame raw.toUInt8) = some raw.toUInt8)) = true := by
    native_decide
  have item := (List.all_eq_true.mp checked) wire.toNat
    (List.mem_range.mpr range)
  have round : wire.toNat.toUInt8 = wire := by
    apply UInt8.toNat.inj
    simp
  simpa only [round] using of_decide_eq_true item

@[simp] theorem unframe_frame {wire : UInt8} (range : wire.toNat < 16) :
    unframe (frame wire) = some wire :=
  frame_roundtrip_all wire range

/-- The paired serial device after exchanging one pair of framed actions. The
left cartridge owns the internal clock at this orientation. -/
def exchange (commit : Committed) :
    GameBoy.Devices.State × GameBoy.Devices.State :=
  GameBoy.LinkAdapter.exchangeByte
    (Byte.ofNat (frame commit.leftWire).toNat)
    (Byte.ofNat (frame commit.rightWire).toNat)

@[inline] def asUInt8 (byte : Byte) : UInt8 := byte.toNat.toUInt8

@[simp] private theorem asUInt8_ofUInt8 (value : UInt8) :
    asUInt8 (Byte.ofNat value.toNat) = value := by
  apply UInt8.toNat.inj
  simp [asUInt8, Byte.ofNat]

private theorem encoded_is_some {action : Full.Action} {wire : UInt8}
    (encoded : Full.Link.encodeAction action = some wire) :
    (Full.Link.encodeAction action).isSome = true := by
  rw [encoded]
  rfl

/-- An exact encoder witness determines the decoder result. -/
theorem decode_encoded {action : Full.Action} {wire : UInt8}
    (encoded : Full.Link.encodeAction action = some wire) :
    Full.Link.decodeAction wire = some action := by
  have roundtrip := Full.Link.action_roundtrip action (encoded_is_some encoded)
  rw [encoded] at roundtrip
  exact roundtrip

/-- All 65,536 possible byte pairs cross the cable without fabricated input.
This specializes that universal hardware theorem to committed actions and also
retains transfer completion, clock ownership, and both serial interrupts. -/
theorem exchange_exact (commit : Committed) :
    let result := GameBoy.LinkAdapter.exchangeByte
      (Byte.ofNat (frame commit.leftWire).toNat)
      (Byte.ofNat (frame commit.rightWire).toNat)
    asUInt8 result.1.serial.data = frame commit.rightWire ∧
      asUInt8 result.2.serial.data = frame commit.leftWire ∧
      result.1.serial.bitsRemaining = 0 ∧
      result.2.serial.bitsRemaining = 0 ∧
      result.1.serial.control = 0x01 ∧
      result.2.serial.control = 0x00 ∧
      result.1.interruptFlags &&& 0x08 ≠ 0 ∧
      result.2.interruptFlags &&& 0x08 ≠ 0 := by
  dsimp only
  have exact := GameBoy.LinkAdapter.full_duplex_byte_exact
    (Byte.ofNat (frame commit.leftWire).toNat)
    (Byte.ofNat (frame commit.rightWire).toNat)
  exact ⟨(congrArg asUInt8 exact.1).trans
      (asUInt8_ofUInt8 (frame commit.rightWire)),
    (congrArg asUInt8 exact.2.1).trans
      (asUInt8_ofUInt8 (frame commit.leftWire)),
    exact.2.2⟩

/-- After one physical byte exchange, each side's semantic decoder receives
exactly the peer action. -/
theorem received_actions_exact (commit : Committed) :
    let result := GameBoy.LinkAdapter.exchangeByte
      (Byte.ofNat (frame commit.leftWire).toNat)
      (Byte.ofNat (frame commit.rightWire).toNat)
    (unframe (asUInt8 result.1.serial.data)).bind Full.Link.decodeAction =
        some commit.rightAction ∧
      (unframe (asUInt8 result.2.serial.data)).bind Full.Link.decodeAction =
        some commit.leftAction := by
  have bytes := exchange_exact commit
  dsimp only
  rw [bytes.1, bytes.2.1,
    unframe_frame (encoded_wire_lt_sixteen commit.rightEncoded),
    unframe_frame (encoded_wire_lt_sixteen commit.leftEncoded)]
  exact ⟨decode_encoded commit.rightEncoded,
    decode_encoded commit.leftEncoded⟩

/-- Every semantically admissible ordinary response has concrete wire bytes
and therefore a physical full-duplex realization. -/
theorem realize_encodable_pair (left right : Full.Action)
    (leftOk : (Full.Link.encodeAction left).isSome = true)
    (rightOk : (Full.Link.encodeAction right).isSome = true) :
    ∃ commit : Committed,
      commit.leftAction = left ∧ commit.rightAction = right ∧
        let result := GameBoy.LinkAdapter.exchangeByte
          (Byte.ofNat (frame commit.leftWire).toNat)
          (Byte.ofNat (frame commit.rightWire).toNat)
        (unframe (asUInt8 result.1.serial.data)).bind Full.Link.decodeAction =
            some right ∧
          (unframe (asUInt8 result.2.serial.data)).bind Full.Link.decodeAction =
            some left := by
  cases leftEncoding : Full.Link.encodeAction left with
  | none => simp [leftEncoding] at leftOk
  | some leftWire =>
      cases rightEncoding : Full.Link.encodeAction right with
      | none => simp [rightEncoding] at rightOk
      | some rightWire =>
          let commit : Committed :=
            { leftAction := left, rightAction := right
              leftWire, rightWire
              leftEncoded := leftEncoding, rightEncoded := rightEncoding }
          refine ⟨commit, rfl, rfl, ?_⟩
          exact received_actions_exact commit

end Battle.Rom.LinkActionProtocol
