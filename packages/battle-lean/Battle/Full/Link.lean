/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Engine
import Battle.LinkBugs

/-!
# Paired link-battle perspectives

Two cartridge-owned engine states exchange only the canonical action nybble.
The paired result keeps synchronized, pending, and known-desynchronized outcomes
distinct; one cartridge is never treated as the authoritative state for both.
-/

namespace Battle.Full.Link

inductive ClockRole where
  | internal | external
  deriving Repr, DecidableEq, BEq

structure Perspective where
  engine : Engine.State
  role : ClockRole
  deriving Repr, DecidableEq

structure Pair where
  left : Perspective
  right : Perspective
  deriving Repr, DecidableEq

/-- Canonical serial action values: move `$0..$3`, switch `$4..$9`, no-action
`$D`, Struggle `$E`, run `$F`. Items have no link encoding. -/
def encodeAction : Full.Action → Option UInt8
  | .fight slot => some slot.val.toUInt8
  | .switch target => some (target.val + 4).toUInt8
  | .noAction => some 0x0d
  | .struggle => some 0x0e
  | .run => some 0x0f
  | .item _ => none

def decodeAction (value : UInt8) : Option Full.Action :=
  if h : value.toNat < 4 then some (.fight ⟨value.toNat, h⟩)
  else if low : 4 ≤ value.toNat then
    if high : value.toNat < 10 then
      some (.switch ⟨value.toNat - 4, by omega⟩)
    else if value == 0x0d then some .noAction
    else if value == 0x0e then some .struggle
    else if value == 0x0f then some .run
    else none
  else none

/-- Internal-clock side wins the cartridge's equal-Speed inversion. -/
def equalSpeedFirst (role : ClockRole) : Side :=
  match role with | .internal => .player | .external => .enemy

/-- Active battle structs are mirror images before disposable enemy-party cleanup. -/
def mirroredActive (pair : Pair) : Bool :=
  pair.left.engine.battle.player.active.active == pair.right.engine.battle.enemy.active.active &&
  pair.left.engine.battle.enemy.active.active == pair.right.engine.battle.player.active.active

/-- Internal-clock cartridge keeps its locally generated ten bytes. -/
def internalSetupList (generated : Array UInt8) : Array UInt8 := generated.extract 0 10

private def firstExternalData (block : Array UInt8) : Nat :=
  (List.range block.size).find? (fun index =>
    let byte := block.getD index 0xff
    byte != 0 && byte != 0xfd && byte != 0xff) |>.getD block.size

/-- External-clock scan skips leading zero/preamble/no-data bytes, then copies
ten bytes while continuing to skip `$FF`. A legitimate leading zero is therefore
not shared with the internal cartridge. -/
def externalSetupList (receivedBlock : Array UInt8) : Array UInt8 :=
  let tail := (receivedBlock.extract (firstExternalData receivedBlock) receivedBlock.size).toList
  (tail.filter (fun byte => byte != 0xff)).take 10 |>.toArray

/-- Conditional shared-RNG invariant. Known asymmetric routines may break it. -/
def mirroredRng (pair : Pair) : Bool :=
  pair.left.engine.battle.rng == pair.right.engine.battle.rng

inductive DesyncCause where
  | psywaveZero
  | bideFaintClear
  | generatedTrappingWrapper
  | stateMismatch
  deriving Repr, DecidableEq, BEq

inductive StepResult where
  | synchronized (pair : Pair) (leftEvents rightEvents : List Engine.Event)
  | desynchronized (pair : Pair) (cause : DesyncCause)
      (leftEvents rightEvents : List Engine.Event)
  | pending (pair : Pair) (left right : Engine.StepResult)
  | invalidWire

private def selectedMove (engine : Engine.State) (action : Full.Action) : MoveId :=
  match action with
  | .fight slot => engine.battle.player.active.active.moves.getD slot.val 0
  | .struggle => 165
  | _ => 0

private def knownCause (pair : Pair) (leftAction rightAction : Full.Action) : DesyncCause :=
  let leftMove := selectedMove pair.left.engine leftAction
  let rightMove := selectedMove pair.right.engine rightAction
  if leftMove == 149 || rightMove == 149 then .psywaveZero
  else if pair.left.engine.battle.player.active.volatile.bideAccumulated.toUInt8 != 0 ||
      pair.right.engine.battle.player.active.volatile.bideAccumulated.toUInt8 != 0 then
    .bideFaintClear
  else if leftMove == 118 || leftMove == 119 || rightMove == 118 || rightMove == 119 then
    .generatedTrappingWrapper
  else .stateMismatch

/-- Exchange both action bytes and execute each cartridge from its own
perspective. Any nontransition continuation remains paired and explicit. -/
def step (pair : Pair) (leftWire rightWire : UInt8) : StepResult :=
  match decodeAction leftWire, decodeAction rightWire with
  | some leftAction, some rightAction =>
      let leftResult := Engine.step pair.left.engine leftAction rightAction
      let rightResult := Engine.step pair.right.engine rightAction leftAction
      match leftResult, rightResult with
      | .transitioned left leftEvents, .transitioned right rightEvents =>
          let pair := { pair with left := { pair.left with engine := left } }
          let pair := { pair with right := { pair.right with engine := right } }
          if mirroredActive pair && mirroredRng pair then
            .synchronized pair leftEvents rightEvents
          else .desynchronized pair (knownCause pair leftAction rightAction) leftEvents rightEvents
      | _, _ => .pending pair leftResult rightResult
  | _, _ => .invalidWire

/-- Every encodable action round-trips. -/
theorem action_roundtrip (action : Full.Action) (encoded : (encodeAction action).isSome = true) :
    (encodeAction action).bind decodeAction = some action := by
  cases action with
  | fight slot =>
      have round : slot.val.toUInt8.toNat = slot.val := by simp; omega
      simp [encodeAction, decodeAction, round]
  | switch target =>
      have modulo : (target.val + 4) % 256 = target.val + 4 :=
        Nat.mod_eq_of_lt (by omega)
      have lower : ¬ target.val + 4 < 4 := by omega
      have upper : target.val + 4 < 10 := by omega
      simp [encodeAction, decodeAction, modulo, lower, upper]
  | item request => simp [encodeAction] at encoded
  | struggle | noAction | run => native_decide

@[simp] theorem items_have_no_link_encoding (request : Items.Request) :
    encodeAction (.item request) = none := by
  rfl

/-- Concrete legitimate-leading-zero setup mismatch. -/
theorem leading_zero_setup_mismatch :
    let generated : Array UInt8 := #[0, 5, 6, 7, 8, 9, 10, 11, 12, 13]
    let block : Array UInt8 := #[0xfd, 0xfd, 0, 5, 6, 7, 8, 9, 10, 11, 12, 13]
    internalSetupList generated != externalSetupList block := by
  native_decide

@[simp] theorem equal_speed_roles_agree_on_physical_first :
    equalSpeedFirst .internal = .player ∧ equalSpeedFirst .external = .enemy := by
  exact ⟨rfl, rfl⟩

end Battle.Full.Link
