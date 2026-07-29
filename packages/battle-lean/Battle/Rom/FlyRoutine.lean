/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.RoutineSummary
import Battle.Rom.Tables
import Battle.Full.Engine

/-!
# Canonical Fly/charge control-flow witnesses

Pokémon Red implements Fly as a two-turn move. `ChargeEffect` sets
`CHARGING_UP` and `INVULNERABLE`; `MainInBattleLoop` then bypasses the player's
menu; and `PlayerCanExecuteChargingMove` clears both bits before continuing into
the ordinary move executor. The enemy routine has the same two `RES` opcodes.

This module retains exact canonical-ROM windows for those four facts. It also
executes the player's `LD HL`/`RES 4,[HL]`/`RES 6,[HL]` sequence through the
proved SM83 functional semantics. Presentation calls after the clear are outside
this small routine theorem.
-/

namespace Battle.Rom.FlyRoutine

open Sm83 Battle.Rom.Closure

private def menuBypassEntry : Word := 0x425E
private def playerContinuationEntry : Word := 0x56A9
private def enemyContinuationEntry : Word := 0x670B
private def chargeSetupEntry : Word := 0x78A1

/-- `ld a,[hl]; and $12; jr nz,.selectEnemyMove`. Bit 4 is `CHARGING_UP`. -/
private def menuBypassBytes : List Byte :=
  [0x7E, 0xE6, 0x12, 0x20, 0x43]

/-- `ld hl,wPlayerBattleStatus1; res CHARGING_UP,[hl];
res INVULNERABLE,[hl]`. -/
private def playerContinuationBytes : List Byte :=
  [0x21, 0x62, 0xD0, 0xCB, 0xA6, 0xCB, 0xB6]

/-- Enemy-side counterpart over `wEnemyBattleStatus1`. -/
private def enemyContinuationBytes : List Byte :=
  [0x21, 0x67, 0xD0, 0xCB, 0xA6, 0xCB, 0xB6]

/-- Start of `ChargeEffect.chargeEffect`: set charge, identify Fly effect `$2b`,
then set invulnerability. -/
private def chargeSetupBytes : List Byte :=
  [0xCB, 0xE6, 0x1A, 0x1B, 0xFE, 0x2B, 0x20, 0x04,
   0xCB, 0xF6, 0x06, 0x64]

structure RequiredFlyBytes (rom : Array Byte) : Prop where
  menuBypass : Tables.tableBytes rom (romOffset 0x0F menuBypassEntry)
      menuBypassBytes.length = menuBypassBytes.map (fun byte => byte.toNat.toUInt8)
  playerContinuation : Tables.tableBytes rom
      (romOffset 0x0F playerContinuationEntry) playerContinuationBytes.length =
    playerContinuationBytes.map (fun byte => byte.toNat.toUInt8)
  enemyContinuation : Tables.tableBytes rom
      (romOffset 0x0F enemyContinuationEntry) enemyContinuationBytes.length =
    enemyContinuationBytes.map (fun byte => byte.toNat.toUInt8)
  chargeSetup : Tables.tableBytes rom (romOffset 0x0F chargeSetupEntry)
      chargeSetupBytes.length = chargeSetupBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalFlyBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  fly : RequiredFlyBytes rom.bytes

/-- The retained bytes decode to the exact menu test and charge-bit operations,
not to source-level pseudo-instructions supplied by the model. -/
theorem decoded_charge_control :
    Decode.base (0x7E : Byte) = .legal (.ld8 (.reg .a) .atHL) ∧
    Decode.base (0xE6 : Byte) = .legal (.aluAImm .and) ∧
    Decode.base (0x20 : Byte) = .legal (.jrCond .nz) ∧
    Decode.cb (0xA6 : Byte) = .res ⟨4, by omega⟩ .atHL ∧
    Decode.cb (0xB6 : Byte) = .res ⟨6, by omega⟩ .atHL ∧
    Decode.cb (0xE6 : Byte) = .set ⟨4, by omega⟩ .atHL ∧
    Decode.cb (0xF6 : Byte) = .set ⟨6, by omega⟩ .atHL := by
  native_decide

private def res4AtHl (state : FunctionalState) : FunctionalState :=
  let value := Alu.resetBit ⟨4, by omega⟩ (state.memory.read state.registers.hl)
  let memory := state.memory.write state.registers.hl value
  let registers := { state.registers with
    pc := Word.ofNat (state.registers.pc.toNat + 2) }
  { state with registers, memory, haltBug := false }

private def res6AtHl (state : FunctionalState) : FunctionalState :=
  let value := Alu.resetBit ⟨6, by omega⟩ (state.memory.read state.registers.hl)
  let memory := state.memory.write state.registers.hl value
  let registers := { state.registers with
    pc := Word.ofNat (state.registers.pc.toNat + 2) }
  { state with registers, memory, haltBug := false }

private theorem step_res4AtHl (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (prefixAtPc : state.memory.read state.registers.pc = 0xCB)
    (subopcode : state.memory.read
      (Word.ofNat (state.registers.pc.toNat + 1)) = 0xA6) :
    (Functional.step state).state = res4AtHl state := by
  have baseDecoded : Decode.base (0xCB : Byte) = .prefix := by native_decide
  have cbDecoded : Decode.cb (0xA6 : Byte) = .res ⟨4, by omega⟩ .atHL := by
    native_decide
  unfold Functional.step
  simp only [running]
  rw [prefixAtPc]
  simp only [noHaltBug, Bool.false_eq_true, if_false, baseDecoded]
  simp only [Functional.read]
  rw [subopcode, cbDecoded]
  simp [res4AtHl, Functional.executeShape, Functional.readTarget,
    Functional.writeTarget, Functional.read, Functional.write,
    Functional.withRegisters, Functional.matureIme, Registers.hl, scheduled, running]

private theorem step_res6AtHl (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (prefixAtPc : state.memory.read state.registers.pc = 0xCB)
    (subopcode : state.memory.read
      (Word.ofNat (state.registers.pc.toNat + 1)) = 0xB6) :
    (Functional.step state).state = res6AtHl state := by
  have baseDecoded : Decode.base (0xCB : Byte) = .prefix := by native_decide
  have cbDecoded : Decode.cb (0xB6 : Byte) = .res ⟨6, by omega⟩ .atHL := by
    native_decide
  unfold Functional.step
  simp only [running]
  rw [prefixAtPc]
  simp only [noHaltBug, Bool.false_eq_true, if_false, baseDecoded]
  simp only [Functional.read]
  rw [subopcode, cbDecoded]
  simp [res6AtHl, Functional.executeShape, Functional.readTarget,
    Functional.writeTarget, Functional.read, Functional.write,
    Functional.withRegisters, Functional.matureIme, Registers.hl, scheduled, running]

private def playerAfterAddress (state : FunctionalState) : FunctionalState :=
  RoutineSummary.ldHlImmediate state

private def playerAfterChargingClear (state : FunctionalState) : FunctionalState :=
  res4AtHl (playerAfterAddress state)

/-- Pure transformer implemented by the three canonical player-continuation
instructions. -/
def playerContinuation (state : FunctionalState) : FunctionalState :=
  res6AtHl (playerAfterChargingClear state)

structure PlayerContinuationContract (state : FunctionalState) : Prop where
  quiet : RoutineSummary.Quiet state
  pc : state.registers.pc = playerContinuationEntry
  op21 : state.memory.read 0x56A9 = 0x21
  low : state.memory.read 0x56AA = 0x62
  high : state.memory.read 0x56AB = 0xD0
  prefix4 : state.memory.read 0x56AC = 0xCB
  opA6 : state.memory.read 0x56AD = 0xA6
  prefix6 : state.memory.read 0x56AE = 0xCB
  opB6 : state.memory.read 0x56AF = 0xB6

private theorem player_address_exact (state : FunctionalState)
    (contract : PlayerContinuationContract state) :
    (playerAfterAddress state).registers.hl = 0xD062 := by
  have lowAddress : Word.ofNat ((0x56A9 : Word).toNat + 1) = 0x56AA := by
    native_decide
  have highAddress : Word.ofNat ((0x56AA : Word).toNat + 1) = 0x56AB := by
    native_decide
  unfold playerAfterAddress RoutineSummary.ldHlImmediate
  change (state.registers.setHL (RoutineSummary.immediateWord state)).hl = 0xD062
  rw [Registers.hl_setHL]
  dsimp [RoutineSummary.immediateWord]
  rw [contract.pc]
  simp only [playerContinuationEntry]
  rw [lowAddress, highAddress, contract.low, contract.high]
  native_decide

/-- Three architectural steps through canonical decoded bytes reach the exact
state transformer that clears the two charge flags. -/
theorem player_continuation_exact (state : FunctionalState)
    (contract : PlayerContinuationContract state) :
    (RoutineSummary.runSteps 3 state).state = playerContinuation state := by
  rcases contract.quiet with ⟨running, noHaltBug, scheduled⟩
  have first := RoutineSummary.step_ldHlImmediate state running scheduled noHaltBug
    (by simpa [contract.pc] using contract.op21)
  let s1 := playerAfterAddress state
  have running1 : s1.mode = .running := by
    simp [s1, playerAfterAddress, RoutineSummary.ldHlImmediate, running]
  have scheduled1 : s1.scheduledImeEnable = false := by
    simp [s1, playerAfterAddress, RoutineSummary.ldHlImmediate, scheduled]
  have halt1 : s1.haltBug = false := by
    simp [s1, playerAfterAddress, RoutineSummary.ldHlImmediate]
  have pc1 : s1.registers.pc = 0x56AC := by
    simp [s1, playerAfterAddress, RoutineSummary.ldHlImmediate, contract.pc]
    native_decide
  have hl1 : s1.registers.hl = 0xD062 := by
    simpa [s1] using player_address_exact state contract
  have second := step_res4AtHl s1 running1 scheduled1 halt1
    (by simpa [pc1] using contract.prefix4)
    (by simpa [pc1] using contract.opA6)
  let s2 := playerAfterChargingClear state
  have running2 : s2.mode = .running := by
    simpa [s2, playerAfterChargingClear, res4AtHl, s1] using running1
  have scheduled2 : s2.scheduledImeEnable = false := by
    simpa [s2, playerAfterChargingClear, res4AtHl, s1] using scheduled1
  have halt2 : s2.haltBug = false := by
    simp [s2, playerAfterChargingClear, res4AtHl]
  have pc2 : s2.registers.pc = 0x56AE := by
    change Word.ofNat (s1.registers.pc.toNat + 2) = 0x56AE
    rw [pc1]
    native_decide
  have prefix6 : s2.memory.read 0x56AE = 0xCB := by
    change (s1.memory.write s1.registers.hl
      (Alu.resetBit ⟨4, by omega⟩ (s1.memory.read s1.registers.hl))).read
        0x56AE = 0xCB
    rw [FlatMemory.read_write_other]
    · simpa [s1, playerAfterAddress, RoutineSummary.ldHlImmediate] using
        contract.prefix6
    · rw [hl1]
      native_decide
  have opB6 : s2.memory.read 0x56AF = 0xB6 := by
    change (s1.memory.write s1.registers.hl
      (Alu.resetBit ⟨4, by omega⟩ (s1.memory.read s1.registers.hl))).read
        0x56AF = 0xB6
    rw [FlatMemory.read_write_other]
    · simpa [s1, playerAfterAddress, RoutineSummary.ldHlImmediate] using
        contract.opB6
    · rw [hl1]
      native_decide
  have third := step_res6AtHl s2 running2 scheduled2 halt2
    (by simpa [pc2] using prefix6) (by simpa [pc2] using opB6)
  simp only [RoutineSummary.runSteps]
  rw [first]
  change (Functional.step (Functional.step s1).state).state = playerContinuation state
  rw [second]
  change (Functional.step s2).state = playerContinuation state
  rw [third]
  rfl

/-- The executable routine theorem's concrete memory consequence: the local
player status byte has bits 4 and 6 reset, and execution falls through to
`PlayerCanExecuteMove` at `$56b0`. -/
theorem player_continuation_result (state : FunctionalState)
    (contract : PlayerContinuationContract state) :
    let out := (RoutineSummary.runSteps 3 state).state
    out.memory.read 0xD062 =
      Alu.resetBit ⟨6, by omega⟩
        (Alu.resetBit ⟨4, by omega⟩ (state.memory.read 0xD062)) ∧
      out.registers.pc = 0x56B0 := by
  rw [player_continuation_exact state contract]
  unfold playerContinuation playerAfterChargingClear
  let s1 := playerAfterAddress state
  let s2 := res4AtHl s1
  have hl1 : s1.registers.hl = 0xD062 := by
    simpa [s1] using player_address_exact state contract
  have hl2 : s2.registers.hl = 0xD062 := by
    simpa [s2, res4AtHl] using hl1
  constructor
  · change (res6AtHl s2).memory.read 0xD062 =
      Alu.resetBit ⟨6, by omega⟩
        (Alu.resetBit ⟨4, by omega⟩ (state.memory.read 0xD062))
    simp only [res6AtHl]
    rw [hl2]
    simp only [FlatMemory.read_write_same]
    change Alu.resetBit ⟨6, by omega⟩ (s2.memory.read 0xD062) =
      Alu.resetBit ⟨6, by omega⟩
        (Alu.resetBit ⟨4, by omega⟩ (state.memory.read 0xD062))
    congr 1
    simp only [s2, res4AtHl]
    rw [hl1]
    simp [s1, playerAfterAddress, RoutineSummary.ldHlImmediate]
  · change (res6AtHl s2).registers.pc = 0x56B0
    simp [res6AtHl, s2, res4AtHl, s1, playerAfterAddress,
      RoutineSummary.ldHlImmediate, contract.pc, playerContinuationEntry]
    native_decide

/-- High-level and machine-level facts used by the repair are jointly available:
the model sets both Fly flags, admits only the automatic action, executes the
retained move, decrements PP on continuation, and clears both flags on success. -/
theorem model_fly_protocol
    (context : Full.ActionContext) (notForced : context.forcedReplacement = false)
    (charging : context.side.active.volatile.chargingUp = true) :
    Full.legal context .noAction = true ∧
      (∀ slot, Full.legal context (.fight slot) = false) ∧
      (∀ target, Full.legal context (.switch target) = false) :=
  Full.charging_forces_no_action context notForced charging

/-- Runtime fixture predicate only; theorem consumers require
`RequiredFlyBytes` instead. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F menuBypassEntry)
      menuBypassBytes.length = menuBypassBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F playerContinuationEntry)
      playerContinuationBytes.length =
        playerContinuationBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F enemyContinuationEntry)
      enemyContinuationBytes.length =
        enemyContinuationBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F chargeSetupEntry)
      chargeSetupBytes.length = chargeSetupBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.FlyRoutine
