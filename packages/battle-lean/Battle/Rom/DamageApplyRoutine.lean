/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.RoutineSummary
import Battle.Rom.Tables
import Battle.Full.Engine

/-!
# Decoded ordinary player-damage application

This is the first numeric machine/model transition slice of an ordinary player
attack. The canonical prefix of `ApplyDamageToEnemyPokemon` reads `wDamage`,
rejects zero and Substitute paths, subtracts the 16-bit word from enemy HP,
clips overkill to zero, and replaces `wDamage` with actual inflicted damage.
Execution stops at `.animateHpBar`, before presentation code.
-/

namespace Battle.Rom.DamageApplyRoutine

open Sm83 Battle.Rom.Closure

/-- Bank `$0f` CPU entry address of `ApplyDamageToEnemyPokemon`. -/
def entry : Word := 0x6142

/-- First presentation instruction at `.animateHpBar`; execution stops here. -/
def exit : Word := 0x617B
private def damageAddress : Word := 0xD0D7
private def enemyHpAddress : Word := 0xCFE6
private def enemyStatus2 : Word := 0xD068

private def bytes : List Byte :=
  [0x21, 0xD7, 0xD0, 0x2A, 0x47, 0x7E, 0xB0, 0x28, 0x52,
   0xFA, 0x68, 0xD0, 0xCB, 0x67, 0xC2, 0x5E, 0x62, 0x3A,
   0x47, 0xFA, 0xE7, 0xCF, 0xEA, 0xEB, 0xCE, 0x90, 0xEA,
   0xE7, 0xCF, 0x7E, 0x47, 0xFA, 0xE6, 0xCF, 0xEA, 0xEC,
   0xCE, 0x98, 0xEA, 0xE6, 0xCF, 0x30, 0x0E, 0xFA, 0xEC,
   0xCE, 0x22, 0xFA, 0xEB, 0xCE, 0x77, 0xAF, 0x21, 0xE6,
   0xCF, 0x22, 0x77]

structure RequiredDamageApplyBytes (rom : Array Byte) : Prop where
  window : Tables.tableBytes rom (romOffset 0x0F entry) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalDamageApplyBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  damageApply : RequiredDamageApplyBytes rom.bytes

private def byteAtCode (address : Word) : Byte :=
  if entry.toNat ≤ address.toNat && address.toNat < exit.toNat then
    bytes.getD (address.toNat - entry.toNat) 0
  else 0

private def highByte (value : UInt16) : Byte := Byte.ofNat (value.toNat / 256)
private def lowByte (value : UInt16) : Byte := Byte.ofNat (value.toNat % 256)

private def initialMemory (hp damage : UInt16) : FlatMemory :=
  ⟨fun address =>
    if address = damageAddress then highByte damage
    else if address = Word.ofNat (damageAddress.toNat + 1) then lowByte damage
    else if address = enemyHpAddress then highByte hp
    else if address = Word.ofNat (enemyHpAddress.toNat + 1) then lowByte hp
    else if address = enemyStatus2 then 0
    else byteAtCode address⟩

private def initial (hp damage : UInt16) : FunctionalState :=
  Driver.setupCall (initialMemory hp damage) (UInt16.ofNat entry.toNat) 0x8000 0xFFFE

/-- Execute the retained decoded window from its call entry to the checkpoint. -/
def run (hp damage : UInt16) : Program.RunResult :=
  Program.runUntil (fun state => state.registers.pc == exit) 40
    (initial hp damage) [] 0

/-- Whether bounded execution reached `.animateHpBar` rather than exhausting. -/
def reachedExit : Program.RunResult → Bool
  | .reached state _ _ => state.registers.pc == exit
  | _ => false

private def readWord (memory : FlatMemory) (address : Word) : UInt16 :=
  UInt16.ofNat (memory.read address).toNat <<< 8 |||
    UInt16.ofNat (memory.read (Word.ofNat (address.toNat + 1))).toNat

private def expectedHp (hp damage : UInt16) : UInt16 :=
  Battle.Step.saturatingSub hp damage

private def expectedActualDamage (hp damage : UInt16) : UInt16 :=
  hp - expectedHp hp damage

/-- The two words observable at the damage-application checkpoint. -/
structure DamageWords where
  targetHp : UInt16
  actualDamage : UInt16
  deriving DecidableEq

/-- Machine observation after executing the decoded canonical window. -/
def machineWords (hp damage : UInt16) : DamageWords :=
  let final := Driver.finalState (run hp damage)
  ⟨readWord final.memory enemyHpAddress, readWord final.memory damageAddress⟩

/-- Corresponding high-level observation after `Full.Engine.applyDamage`. -/
def modelWords (state : Full.Engine.State) (who : Side)
    (damage : UInt16) : DamageWords :=
  let applied := Full.Engine.applyDamage state who damage
  ⟨(applied.state.battle.side who.other).active.active.hp, applied.state.sharedDamage⟩

private def summaryHolds (hp damage : UInt16) : Bool :=
  let result := run hp damage
  let final := Driver.finalState result
  reachedExit result &&
    readWord final.memory enemyHpAddress == expectedHp hp damage &&
    readWord final.memory damageAddress == expectedActualDamage hp damage

private def legalWordsChecked : Bool :=
  (List.range 1000).all fun hp =>
    (List.range 1000).all fun damage =>
      damage == 0 || summaryHolds hp.toUInt16 damage.toUInt16

private theorem legal_words_checked : legalWordsChecked = true := by
  native_decide

/-- Every legal Gen-I HP/damage pair with nonzero damage reaches the canonical
HP-animation checkpoint. Enemy HP is saturating subtraction and `wDamage`
contains exactly the inflicted amount, including overkill clipping. -/
theorem player_damage_application_exact (hp damage : UInt16)
    (hpBound : hp.toNat < 1000) (damageBound : damage.toNat < 1000)
    (nonzero : damage ≠ 0) :
    let result := run hp damage
    let final := Driver.finalState result
    reachedExit result = true ∧
      readWord final.memory enemyHpAddress = Battle.Step.saturatingSub hp damage ∧
      readWord final.memory damageAddress = hp - Battle.Step.saturatingSub hp damage := by
  have hpItem := (List.all_eq_true.mp legal_words_checked) hp.toNat
    (List.mem_range.mpr hpBound)
  have damageItem := (List.all_eq_true.mp hpItem) damage.toNat
    (List.mem_range.mpr damageBound)
  have hpRound : hp.toNat.toUInt16 = hp := by
    apply UInt16.toNat.inj
    simp
  have damageRound : damage.toNat.toUInt16 = damage := by
    apply UInt16.toNat.inj
    simp
  have nonzeroNat : damage.toNat ≠ 0 := by
    intro zero
    apply nonzero
    apply UInt16.toNat.inj
    simpa using zero
  simp [nonzeroNat, hpRound, damageRound, summaryHolds, expectedHp,
    expectedActualDamage] at damageItem
  exact ⟨damageItem.1.1, damageItem.1.2, damageItem.2⟩

/-- High-level `Engine.applyDamage` uses the same clipped HP and actual-damage
functions on the no-Substitute path. -/
theorem model_damage_words (state : Full.Engine.State) (who : Side)
    (damage : UInt16)
    (noSubstitute : (state.battle.side who.other).active.volatile.hasSubstitute = false) :
    let target := state.battle.side who.other
    let applied := Full.Engine.applyDamage state who damage
    applied.state.sharedDamage = target.active.active.hp -
        Battle.Step.saturatingSub target.active.active.hp damage ∧
      (applied.state.battle.side who.other).active.active.hp =
        Battle.Step.saturatingSub target.active.active.hp damage := by
  have words := Full.Engine.apply_damage_no_substitute_words state who damage
    noSubstitute
  exact ⟨words.2.2, words.2.1⟩

/-- At the bounded ordinary player-damage checkpoint, decoded SM83 execution
and the high-level transition have exactly the same target-HP and actual-damage
observation. This includes exact damage, overkill clipping, zero-HP targets,
and Rage targets; Substitute and zero-damage take different ROM branches. -/
theorem player_damage_transition_refines (state : Full.Engine.State)
    (damage : UInt16)
    (hpBound : state.battle.enemy.active.active.hp.toNat < 1000)
    (damageBound : damage.toNat < 1000)
    (nonzero : damage ≠ 0)
    (noSubstitute : state.battle.enemy.active.volatile.hasSubstitute = false) :
    let hp := state.battle.enemy.active.active.hp
    reachedExit (run hp damage) = true ∧
      machineWords hp damage = modelWords state .player damage := by
  let hp := state.battle.enemy.active.active.hp
  have machine := player_damage_application_exact hp damage hpBound damageBound nonzero
  have model := model_damage_words state .player damage noSubstitute
  dsimp only
  constructor
  · exact machine.1
  · simp only [machineWords, modelWords]
    rw [machine.2.1, machine.2.2, model.1, model.2]
    simp [hp, Side.other, Full.State.side]

/-- The same bounded refinement packaged with caller-supplied canonical-ROM
identity and byte-window witnesses. The ROM remains unvendored, so both are
explicit theorem hypotheses rather than host hash computations in Lean. -/
theorem canonical_player_damage_transition_refines
    (sha256 : Sha256) (rom : CanonicalRom)
    (canonical : CanonicalDamageApplyBytes sha256 rom)
    (state : Full.Engine.State) (damage : UInt16)
    (hpBound : state.battle.enemy.active.active.hp.toNat < 1000)
    (damageBound : damage.toNat < 1000)
    (nonzero : damage ≠ 0)
    (noSubstitute : state.battle.enemy.active.volatile.hasSubstitute = false) :
    rom.Valid sha256 ∧
      (Tables.tableBytes rom.bytes (romOffset 0x0F entry) bytes.length =
        bytes.map (fun byte => byte.toNat.toUInt8)) ∧
      (let hp := state.battle.enemy.active.active.hp
       reachedExit (run hp damage) = true ∧
         machineWords hp damage = modelWords state .player damage) := by
  exact ⟨canonical.identity, canonical.damageApply.window,
    player_damage_transition_refines state damage hpBound damageBound nonzero noSubstitute⟩

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F entry) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.DamageApplyRoutine
