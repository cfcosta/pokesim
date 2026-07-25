/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Status
import Battle.Data.Moves

/-!
# Full battle item dispatch

Covers every ordinary item-table ID `$01..$53` with an explicit disposition and
implements every canonical in-battle mutation: balls, medicines, Poke Doll,
X items, Poké Flute, Revive, and PP restorers. Overworld-only and unusable rows
reject without consuming the item or turn. Link mode rejects the bag before
handler dispatch.
-/

namespace Battle.Full.Items

structure Stack where
  item : UInt8
  count : UInt8
  deriving Repr, DecidableEq, BEq

abbrev Bag := List Stack

namespace Bag

def contains (bag : Bag) (item : UInt8) : Bool :=
  bag.any fun stack => stack.item == item && stack.count != 0

/-- Remove one from the first matching canonical stack. -/
def removeOne : Bag → UInt8 → Bag
  | [], _ => []
  | stack :: rest, item =>
      if stack.item == item then
        if stack.count ≤ 1 then rest
        else { stack with count := stack.count - 1 } :: rest
      else stack :: removeOne rest item

end Bag

inductive Disposition where
  | capture
  | battleUse
  | battleReject
  | safariPseudoAction
  | rawOnly
  | contextual
  | outOfRange
  deriving Repr, DecidableEq, BEq

/-- Exact ordinary item-pointer-table battle classification. -/
def disposition (item : UInt8) : Disposition :=
  let id := item.toNat
  if id < 1 || id > 0x53 then .outOfRange
  else if [1, 2, 3, 4, 8].contains id then .capture
  else if [7, 9].contains id then .rawOnly
  else if [0x15, 0x16].contains id then .safariPseudoAction
  else if [0x10, 0x33].contains id then .contextual
  else if [0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
      0x11, 0x12, 0x13, 0x14, 0x2E, 0x34, 0x35, 0x36, 0x37, 0x3A,
      0x3C, 0x3D, 0x3E, 0x41, 0x42, 0x43, 0x44, 0x49,
      0x50, 0x51, 0x52, 0x53].contains id then .battleUse
  else .battleReject

/-- Every indexed ordinary item has an explicit non-out-of-range disposition. -/
theorem ordinary_table_total (item : UInt8)
    (low : 1 ≤ item.toNat) (high : item.toNat ≤ 0x53) :
    disposition item ≠ .outOfRange := by
  have checked :
      (List.range 0x53).all (fun offset =>
        disposition (offset + 1).toUInt8 != .outOfRange) = true := by
    native_decide
  have offsetBound : item.toNat - 1 < 0x53 := by omega
  have atItem := (List.all_eq_true.mp checked) (item.toNat - 1)
    (List.mem_range.mpr offsetBound)
  have round : (item.toNat - 1 + 1).toUInt8 = item := by
    apply UInt8.toNat.inj
    simp
    omega
  have supported : (disposition item != .outOfRange) = true := by
    simpa only [round] using atItem
  intro equal
  rw [equal] at supported
  have impossible : (Disposition.outOfRange != Disposition.outOfRange) ≠ true := by
    native_decide
  exact impossible supported

structure UserState where
  side : Full.SideState
  bag : Bag
  deriving Repr, DecidableEq

structure Request where
  item : UInt8
  partyTarget : Nat := 0
  moveSlot : Nat := 0
  deriving Repr, DecidableEq, BEq

inductive Event where
  | healed (target : Nat) (amount : UInt16)
  | statusCured (target : Nat)
  | revived (target : Nat)
  | ppRestored (target slot : Nat)
  | xAccuracy
  | mist
  | focusEnergy
  | statRaised (stage : Nat)
  | flute
  | captureRequested (ball : UInt8)
  | escapedByDoll
  deriving Repr, DecidableEq, BEq

inductive Result where
  | committed (state : UserState) (events : List Event)
  | rejected (state : UserState)
  | capturePending (state : UserState) (ball : UInt8)
  | escaped (state : UserState)
  deriving Repr, DecidableEq

/-- Raw pointer-table entries that legal bag validation excludes. These remain
separate from `Result` so the canonical API cannot silently accept them. -/
inductive RawDispatch where
  | pokedexCommitted
  | surfboardContextual
  | safariBaitAlias
  | safariRockAlias
  | ordinary (disposition : Disposition)
  | beyondTable
  deriving Repr, DecidableEq, BEq

/-- Classification after an injected structurally indexed byte reaches
`ItemUsePtrTable`; no overworld Surfboard effect is invented here. -/
def rawDispatch (item : UInt8) : RawDispatch :=
  match item.toNat with
  | 7 => .surfboardContextual
  | 9 => .pokedexCommitted
  | 0x15 => .safariBaitAlias
  | 0x16 => .safariRockAlias
  | id => if id < 1 || id > 0x53 then .beyondTable else .ordinary (disposition item)

private def updateMon (side : Full.SideState) (target : Nat)
    (update : MonState → MonState) : Option Full.SideState :=
  let side := side.syncOutgoing
  if target < side.party.mons.size then
    let old := side.party.mons.getD target side.active.active
    let new := update old
    let party := { mons := side.party.mons.modify target (fun _ => new) }
    let active := if target == side.activeIndex then { side.active with active := new } else side.active
    some { side with party, active }
  else none

private def mapTarget (state : UserState) (target : Nat)
    (update : MonState → Option MonState) : Option UserState :=
  let synced := state.side.syncOutgoing
  if target < synced.party.mons.size then
    let old := synced.party.mons.getD target synced.active.active
    match update old with
    | none => none
    | some new =>
        match updateMon synced target (fun _ => new) with
        | none => none
        | some side => some { state with side }
  else none

private def consume (state : UserState) (item : UInt8) : UserState :=
  { state with bag := state.bag.removeOne item }

private def healAmount (item : UInt8) : Option Nat :=
  match item.toNat with
  | 0x11 => some 65535 -- Max Potion
  | 0x12 => some 200
  | 0x13 => some 50
  | 0x14 => some 20
  | 0x3C => some 50
  | 0x3D => some 60
  | 0x3E => some 80
  | _ => none

private def cureMask (item : UInt8) : Option UInt8 :=
  match item.toNat with
  | 0x0B => some (1 <<< Wram.Status.psn).toUInt8
  | 0x0C => some (1 <<< Wram.Status.brn).toUInt8
  | 0x0D => some (1 <<< Wram.Status.frz).toUInt8
  | 0x0E => some Wram.Status.slpMask
  | 0x0F => some (1 <<< Wram.Status.par).toUInt8
  | 0x34 => some 0xFF
  | _ => none

private def useCure (state : UserState) (request : Request) (mask : UInt8) : Result :=
  match mapTarget state request.partyTarget fun mon =>
      if mon.status &&& mask == 0 then none else some { mon with status := 0 } with
  | none => .rejected state
  | some state =>
      let side :=
        if request.partyTarget == state.side.activeIndex then
          let volatile := { state.side.active.volatile with
            status3 := state.side.active.volatile.status3 &&&
              ~~~((1 <<< Wram.BattleStatus3.badlyPoisoned).toUInt8) }
          { state.side with active := { state.side.active with volatile } }
        else state.side
      .committed (consume { state with side } request.item)
        [.statusCured request.partyTarget]

private def useHeal (state : UserState) (request : Request) (amount : Nat) : Result :=
  match mapTarget state request.partyTarget fun mon =>
      if mon.hp == 0 || mon.hp == mon.maxHp then none
      else some { mon with hp := UInt16.ofNat (min (mon.hp.toNat + amount) mon.maxHp.toNat) } with
  | none => .rejected state
  | some next =>
      let before := state.side.syncOutgoing.party.mons.getD request.partyTarget state.side.active.active
      let after := next.side.party.mons.getD request.partyTarget next.side.active.active
      .committed (consume next request.item)
        [.healed request.partyTarget (after.hp - before.hp)]

def fullRestoreVolatile (volatile : Battle.Volatile) (fullHpStatusOnly : Bool) : Battle.Volatile :=
  if fullHpStatusOnly then
    { volatile with status3 := volatile.status3 &&&
      ~~~((1 <<< Wram.BattleStatus3.badlyPoisoned).toUInt8) }
  else volatile

@[simp] theorem damaged_full_restore_preserves_status3 (volatile : Battle.Volatile) :
    (fullRestoreVolatile volatile false).status3 = volatile.status3 := by
  rfl

@[simp] theorem full_hp_full_restore_clears_toxic (volatile : Battle.Volatile) :
    (fullRestoreVolatile volatile true).badlyPoisoned = false := by
  simp [fullRestoreVolatile, Battle.Volatile.badlyPoisoned, bitSet,
    Wram.BattleStatus3.badlyPoisoned]

private def useFullRestore (state : UserState) (request : Request) : Result :=
  match mapTarget state request.partyTarget fun mon =>
      if mon.hp == 0 || (mon.hp == mon.maxHp && mon.status == 0) then none
      else some { mon with hp := mon.maxHp, status := 0 } with
  | none => .rejected state
  | some next =>
      -- Damaged Full Restore bypasses the Full Heal branch and leaves Toxic
      -- volatile state stale. At full HP, status-only Full Restore takes that
      -- branch and clears the active Toxic flag.
      let before := state.side.syncOutgoing.party.mons.getD request.partyTarget
        state.side.active.active
      let activeTarget := request.partyTarget == state.side.activeIndex
      let fullHpStatusOnly := activeTarget && before.hp == before.maxHp
      let volatile := fullRestoreVolatile state.side.active.volatile fullHpStatusOnly
      let next := { next with side := { next.side with active :=
        { next.side.active with volatile } } }
      .committed (consume next request.item)
        [.healed request.partyTarget
          ((next.side.party.mons.getD request.partyTarget next.side.active.active).hp -
            (state.side.syncOutgoing.party.mons.getD request.partyTarget state.side.active.active).hp),
         .statusCured request.partyTarget]

private def useRevive (state : UserState) (request : Request) (maximum : Bool) : Result :=
  match mapTarget state request.partyTarget fun mon =>
      if mon.hp != 0 then none
      else some { mon with hp := if maximum then mon.maxHp else mon.maxHp >>> 1 } with
  | none => .rejected state
  | some next => .committed (consume next request.item) [.revived request.partyTarget]

private def setVolatileBit (state : UserState) (request : Request)
    (which index : Nat) (event : Event) : Result :=
  let volatile := state.side.active.volatile
  let bit := (1 <<< index).toUInt8
  let volatile := match which with
    | 2 => { volatile with status2 := volatile.status2 ||| bit }
    | _ => { volatile with status3 := volatile.status3 ||| bit }
  let state := { state with side := { state.side with active := { state.side.active with volatile } } }
  .committed (consume state request.item) [event]

private def stageForXItem (item : UInt8) (stages : StatStages) : Option (StatStages × Nat) :=
  let raise (value : UInt8) := if value.toNat ≥ 13 then value else value + 1
  match item.toNat with
  | 0x41 => some ({ stages with attack := raise stages.attack }, 0)
  | 0x42 => some ({ stages with defense := raise stages.defense }, 1)
  | 0x43 => some ({ stages with speed := raise stages.speed }, 2)
  | 0x44 => some ({ stages with special := raise stages.special }, 3)
  | _ => none

/-- Maximum current PP from the packed PP-Up count. The cartridge divides the
base by five first, caps that per-item bonus at seven, then repeats it once per
PP Up; this differs from multiplying before division and matters for 40-PP
moves. -/
def maxPp (move : MoveId) (packed : UInt8) : UInt8 :=
  let base := (Data.moveData move).pp.toNat
  let ups := (packed >>> 6).toNat
  let bonus := min (base / 5) 7
  (base + bonus * ups).toUInt8

@[simp] theorem growl_three_pp_ups_cap : maxPp 45 0xC0 = 61 := by
  native_decide

private def restoreSlot (mon : MonState) (slot : Nat) (maximum : Bool) : MonState × Bool :=
  let move := mon.moves.getD slot 0
  let packed := mon.pp.getD slot 0
  let maximumPp := maxPp move packed
  let current := packed &&& Wram.ppMask
  let changed := if maximum then packed != maximumPp else current != maximumPp
  let restored := if maximum then maximumPp else min maximumPp (current + 10)
  let newPacked := (packed &&& Wram.ppUpMask) ||| restored
  ({ mon with pp := mon.pp.modify slot (fun _ => newPacked) }, changed)

private def usePpRestore (state : UserState) (request : Request) (all maximum : Bool) : Result :=
  match mapTarget state request.partyTarget fun mon =>
      if all then
        let folded := (List.range Wram.numMoves).foldl
          (fun pair slot =>
            let restored := restoreSlot pair.1 slot maximum
            (restored.1, pair.2 || restored.2)) (mon, false)
        if folded.2 then some folded.1 else none
      else
        let restored := restoreSlot mon request.moveSlot maximum
        if restored.2 then some restored.1 else none with
  | none => .rejected state
  | some next => .committed (consume next request.item)
      [.ppRestored request.partyTarget request.moveSlot]

def wakeMon (mon : MonState) : MonState :=
  { mon with status := mon.status &&& ~~~Wram.Status.slpMask }

def wakeSideForFlute (side : Full.SideState) (scanParty : Bool) : Full.SideState :=
  let side := side.syncOutgoing
  let party := if scanParty then { mons := side.party.mons.map wakeMon } else side.party
  let active := { side.active with active := wakeMon side.active.active }
  { side with party, active }

def wakeOpponentForFlute (mode : BattleMode) (side : Full.SideState) : Full.SideState :=
  wakeSideForFlute side (mode == .trainer)

/-- `wWereAnyMonsAsleep` is set only by the fixed party scans, not by the later
active-row clears. Wild battles skip the enemy-party scan. -/
def fluteReportedEffect (mode : BattleMode) (player enemy : Full.SideState) : Bool :=
  let sleeping (mon : MonState) := mon.status &&& Wram.Status.slpMask != 0
  player.party.mons.any sleeping ||
    (mode == .trainer && enemy.party.mons.any sleeping)

private def useFlute (state : UserState) (_request : Request) : Result :=
  let next := { state with side := wakeSideForFlute state.side true }
  -- The Poké Flute is a reusable key item.
  .committed next [.flute]

/-- Execute one ordinary bag item. Capture arithmetic is delegated to the capture
module through `.capturePending`; no ball is approximated as damage. -/
def use (mode : BattleMode) (state : UserState) (request : Request) : Result :=
  if mode == .link || !state.bag.contains request.item then .rejected state
  else
    match disposition request.item with
    | .capture => .capturePending (consume state request.item) request.item
    | .battleReject | .outOfRange | .rawOnly | .safariPseudoAction => .rejected state
    | .contextual =>
        if request.item == 0x10 then useFullRestore state request
        else if request.item == 0x33 && mode == .wild then
          .escaped (consume state request.item)
        else .rejected state
    | .battleUse =>
        match cureMask request.item with
        | some mask => useCure state request mask
        | none => match healAmount request.item with
          | some amount => useHeal state request amount
          | none => match request.item.toNat with
            | 0x35 => useRevive state request false
            | 0x36 => useRevive state request true
            | 0x2E => setVolatileBit state request 2 Wram.BattleStatus2.usingXAccuracy .xAccuracy
            | 0x37 => setVolatileBit state request 2 Wram.BattleStatus2.protectedByMist .mist
            | 0x3A => setVolatileBit state request 2 Wram.BattleStatus2.gettingPumped .focusEnergy
            | 0x41 | 0x42 | 0x43 | 0x44 =>
                match stageForXItem request.item state.side.active.stages with
                | none => .rejected state
                | some (stages, index) =>
                    let next := { state with side := { state.side with active :=
                      { state.side.active with stages } } }
                    .committed (consume next request.item) [.statRaised index]
            | 0x49 => useFlute state request
            | 0x50 => usePpRestore state request false false
            | 0x51 => usePpRestore state request false true
            | 0x52 => usePpRestore state request true false
            | 0x53 => usePpRestore state request true true
            | _ => .rejected state

/-- Trainer cures write healed/status-cleared identity back to the active row
without rebuilding mutable combat stats from the party record. -/
def retainTrainerCureStats (before after : Battle.SideState) : Battle.SideState :=
  let mon := { after.active with attack := before.active.attack }
  let mon := { mon with defense := before.active.defense }
  let mon := { mon with speed := before.active.speed }
  let mon := { mon with special := before.active.special }
  { after with active := mon }

@[simp] theorem trainer_cure_retains_combat_stats (before after : Battle.SideState) :
    let result := retainTrainerCureStats before after
    result.active.attack = before.active.attack ∧
      result.active.defense = before.active.defense ∧
      result.active.speed = before.active.speed ∧
      result.active.special = before.active.special := by
  simp [retainTrainerCureStats]

def clearTrainerToxic (side : Battle.SideState) : Battle.SideState :=
  { side with volatile := { side.volatile with status3 := side.volatile.status3 &&&
    ~~~((1 <<< Wram.BattleStatus3.badlyPoisoned).toUInt8) } }

@[simp] theorem trainer_full_restore_clears_toxic (side : Battle.SideState) :
    (clearTrainerToxic side).volatile.badlyPoisoned = false := by
  simp [clearTrainerToxic, Battle.Volatile.badlyPoisoned, bitSet,
    Wram.BattleStatus3.badlyPoisoned]

/-- Execute an AI-owned item. Full Heal and Full Restore share player item
storage updates but retain the loaded enemy combat-stat bytes. -/
def aiUse (mode : BattleMode) (state : UserState) (request : Request) : Result :=
  match use mode state request with
  | .committed next events =>
      if request.item == 0x34 || request.item == 0x10 then
        let side := retainTrainerCureStats state.side.active next.side.active
        let side := if request.item == 0x10 then clearTrainerToxic side else side
        .committed { next with side := { next.side with active := side } } events
      else .committed next events
  | result => result

def Result.isCommitted : Result → Bool
  | .committed _ _ => true
  | _ => false

def Result.outputBag : Result → Option Bag
  | .committed state _ | .capturePending state _ | .escaped state => some state.bag
  | .rejected _ => none

def Result.outputMon (result : Result) (target : Nat := 0) : Option MonState :=
  match result with
  | .committed state _ | .capturePending state _ | .escaped state =>
      state.side.party.mons[target]?
  | .rejected _ => none

def Result.outputActive : Result → Option Battle.SideState
  | .committed state _ | .capturePending state _ | .escaped state => some state.side.active
  | .rejected _ => none

private def itemTestMon : MonState :=
  { species := 1, hp := 50, boxLevel := 50, status := 0x08,
    type1 := 0, type2 := 0, catchRate := 45, moves := #[33, 45, 0, 0],
    dvs := 0, level := 50, maxHp := 100, attack := 80, defense := 70,
    speed := 60, special := 50, pp := #[10, 20, 0, 0] }

private def itemTestState (item : UInt8) (mon : MonState := itemTestMon) : UserState :=
  let side : Full.SideState :=
    { party := { mons := #[mon] }
      activeIndex := 0
      active := Battle.SideState.fresh mon }
  { side, bag := [{ item, count := 1 }] }

/-! ## Item fidelity theorems -/

@[simp] theorem link_bag_rejected (state : UserState) (request : Request) :
    use .link state request = .rejected state := by
  rfl

/-- One stack is removed in place without reordering the remaining bag. -/
theorem ordered_bag_removal_witness :
    Bag.removeOne [{ item := 1, count := 2 }, { item := 2, count := 1 }] 1 =
      [{ item := 1, count := 1 }, { item := 2, count := 1 }] ∧
    Bag.removeOne [{ item := 1, count := 1 }, { item := 2, count := 1 }] 1 =
      [{ item := 2, count := 1 }] := by
  native_decide

/-- Exact representative executions cover each canonical ordinary battle-item
family, including consumption, target mutation, reusable Flute, and repeated
bit-setting behavior. -/
theorem canonical_item_effect_witnesses :
    let antidote := use .wild (itemTestState 0x0b) { item := 0x0b }
    let fullHeal := use .wild (itemTestState 0x34) { item := 0x34 }
    let fullRestore := use .wild (itemTestState 0x10) { item := 0x10 }
    let potion := use .wild (itemTestState 0x14) { item := 0x14 }
    let water := use .wild (itemTestState 0x3c) { item := 0x3c }
    let fainted := { itemTestMon with hp := 0, status := 0 }
    let revive := use .wild (itemTestState 0x35 fainted) { item := 0x35 }
    let maxRevive := use .wild (itemTestState 0x36 fainted) { item := 0x36 }
    let xAccuracy := use .wild (itemTestState 0x2e) { item := 0x2e }
    let guardSpec := use .wild (itemTestState 0x37) { item := 0x37 }
    let direHit := use .wild (itemTestState 0x3a) { item := 0x3a }
    let xAttack := use .wild (itemTestState 0x41) { item := 0x41 }
    let doll := use .wild (itemTestState 0x33) { item := 0x33 }
    let flute := use .wild (itemTestState 0x49) { item := 0x49 }
    let ether := use .wild (itemTestState 0x50) { item := 0x50, moveSlot := 0 }
    (antidote.outputMon.bind (fun mon => some mon.status)) = some 0 ∧
    (fullHeal.outputMon.bind (fun mon => some mon.status)) = some 0 ∧
    (fullRestore.outputMon.bind (fun mon => some (mon.hp, mon.status))) = some (100, 0) ∧
    (potion.outputMon.bind (fun mon => some mon.hp)) = some 70 ∧
    (water.outputMon.bind (fun mon => some mon.hp)) = some 100 ∧
    (revive.outputMon.bind (fun mon => some mon.hp)) = some 50 ∧
    (maxRevive.outputMon.bind (fun mon => some mon.hp)) = some 100 ∧
    (xAccuracy.outputActive.bind (fun side => some side.volatile.status2)).getD 0 != 0 ∧
    (guardSpec.outputActive.bind (fun side => some side.volatile.status2)).getD 0 != 0 ∧
    (direHit.outputActive.bind (fun side => some side.volatile.status2)).getD 0 != 0 ∧
    (xAttack.outputActive.bind (fun side => some side.stages.attack)) = some 8 ∧
    doll = .escaped { (itemTestState 0x33) with bag := [] } ∧
    flute.outputBag = some (itemTestState 0x49).bag ∧
    (ether.outputMon.bind (fun mon => some (mon.pp.getD 0 0))) = some 20 := by
  native_decide

theorem medicine_family_witnesses :
    let statusResult (item status : UInt8) :=
      use .wild (itemTestState item { itemTestMon with status := status }) { item }
    let healResult (item : UInt8) := use .wild (itemTestState item) { item }
    (statusResult 0x0b 0x08).outputMon.bind (fun mon => some mon.status) = some 0 ∧
    (statusResult 0x0c 0x10).outputMon.bind (fun mon => some mon.status) = some 0 ∧
    (statusResult 0x0d 0x20).outputMon.bind (fun mon => some mon.status) = some 0 ∧
    (statusResult 0x0e 0x07).outputMon.bind (fun mon => some mon.status) = some 0 ∧
    (statusResult 0x0f 0x40).outputMon.bind (fun mon => some mon.status) = some 0 ∧
    (healResult 0x11).outputMon.bind (fun mon => some mon.hp) = some 100 ∧
    (healResult 0x12).outputMon.bind (fun mon => some mon.hp) = some 100 ∧
    (healResult 0x13).outputMon.bind (fun mon => some mon.hp) = some 100 ∧
    (healResult 0x14).outputMon.bind (fun mon => some mon.hp) = some 70 ∧
    (healResult 0x3c).outputMon.bind (fun mon => some mon.hp) = some 100 ∧
    (healResult 0x3d).outputMon.bind (fun mon => some mon.hp) = some 100 ∧
    (healResult 0x3e).outputMon.bind (fun mon => some mon.hp) = some 100 := by
  native_decide

/-- All four X-stat IDs share the capped, action-consuming stage path. -/
theorem x_stat_family_witnesses :
    let stage (item : UInt8) (read : StatStages → UInt8) :=
      (use .wild (itemTestState item) { item }).outputActive.bind
        (fun side => some (read side.stages))
    stage 0x41 StatStages.attack = some 8 ∧
    stage 0x42 StatStages.defense = some 8 ∧
    stage 0x43 StatStages.speed = some 8 ∧
    stage 0x44 StatStages.special = some 8 := by
  native_decide

/-- Each PP-restoration family is battle-reachable with its distinct single/all
and ten/max behavior. -/
theorem pp_restore_family_witnesses :
    let restored (item : UInt8) := use .wild (itemTestState item) { item, moveSlot := 0 }
    (restored 0x50).outputMon.bind (fun mon => some mon.pp) = some #[20, 20, 0, 0] ∧
    (restored 0x51).outputMon.bind (fun mon => some mon.pp) = some #[35, 20, 0, 0] ∧
    (restored 0x52).outputMon.bind (fun mon => some mon.pp) = some #[20, 30, 0, 0] ∧
    (restored 0x53).outputMon.bind (fun mon => some mon.pp) = some #[35, 40, 0, 0] := by
  native_decide

/-- Balls are removed before capture resolution; all five canonical IDs route
to the pending capture protocol. -/
theorem canonical_ball_dispatch_witnesses :
    (use .wild (itemTestState 1) { item := 1 }).outputBag = some [] ∧
    (use .wild (itemTestState 2) { item := 2 }).outputBag = some [] ∧
    (use .wild (itemTestState 3) { item := 3 }).outputBag = some [] ∧
    (use .wild (itemTestState 4) { item := 4 }).outputBag = some [] ∧
    (use .wild (itemTestState 8) { item := 8 }).outputBag = some [] := by
  native_decide

/-- Reusing permanent battle flags still consumes the item; X stats cap at
stage thirteen while consuming the action. -/
theorem repeated_flags_and_x_stat_cap :
    let volatile := { (itemTestState 0x2e).side.active.volatile with status2 := 0xff }
    let flagged := { (itemTestState 0x2e) with side :=
      { (itemTestState 0x2e).side with active :=
        { (itemTestState 0x2e).side.active with volatile } } }
    let stages := { (itemTestState 0x41).side.active.stages with attack := 13 }
    let capped := { (itemTestState 0x41) with side :=
      { (itemTestState 0x41).side with active :=
        { (itemTestState 0x41).side.active with stages } } }
    (use .wild flagged { item := 0x2e }).outputBag = some [] ∧
    (use .wild capped { item := 0x41 }).outputBag = some [] ∧
    (use .wild capped { item := 0x41 }).outputActive.bind
      (fun side => some side.stages.attack) = some 13 := by
  native_decide

/-- Active cures reload the persistent party combat row while retaining stage
bytes; active and party identities are synchronized at the item boundary. -/
theorem active_cure_reloads_party_stats_witness :
    let base := itemTestState 0x0b
    let staleMon := { { { { base.side.active.active with attack := 1 } with
      defense := 2 } with speed := 3 } with special := 4 }
    let staleActive := { base.side.active with active := staleMon }
    let staleSide := { base.side with active := staleActive }
    let stale := { base with side := staleSide }
    let result := use .wild stale { item := 0x0b }
    result.outputActive.bind (fun side =>
      some (side.active.attack, side.active.defense, side.active.speed,
        side.active.special, side.stages)) =
      some (80, 70, 60, 50, StatStages.neutral) ∧
    result.outputActive.map Battle.SideState.active = result.outputMon := by
  native_decide

@[simp] theorem wild_flute_report_ignores_enemy (player enemy : Full.SideState) :
    fluteReportedEffect .wild player enemy =
      player.party.mons.any (fun mon => mon.status &&& Wram.Status.slpMask != 0) := by
  have distinct : (BattleMode.wild == BattleMode.trainer) = false := by native_decide
  simp [fluteReportedEffect, distinct]

@[simp] theorem trainer_flute_report_scans_both (player enemy : Full.SideState) :
    fluteReportedEffect .trainer player enemy =
      (player.party.mons.any (fun mon => mon.status &&& Wram.Status.slpMask != 0) ||
       enemy.party.mons.any (fun mon => mon.status &&& Wram.Status.slpMask != 0)) := by
  have same : (BattleMode.trainer == BattleMode.trainer) = true := by native_decide
  simp [fluteReportedEffect, same]

@[simp] theorem wake_mon_clears_sleep (mon : MonState) :
    (wakeMon mon).status &&& Wram.Status.slpMask = 0 := by
  have exhaustive : (List.range 256).all (fun raw =>
      ((raw.toUInt8 &&& ~~~Wram.Status.slpMask) &&& Wram.Status.slpMask) == 0) = true := by
    native_decide
  have item := (List.all_eq_true.mp exhaustive) mon.status.toNat
    (List.mem_range.mpr (UInt8.toNat_lt mon.status))
  have round : mon.status.toNat.toUInt8 = mon.status := by
    apply UInt8.toNat.inj
    simp
  simpa [wakeMon, round] using item

@[simp] theorem wild_flute_wakes_opponent_active_only (side : Full.SideState) :
    (wakeOpponentForFlute .wild side).party = side.syncOutgoing.party ∧
    (wakeOpponentForFlute .wild side).active.active.status &&& Wram.Status.slpMask = 0 := by
  have distinct : (BattleMode.wild == BattleMode.trainer) = false := by native_decide
  simp [wakeOpponentForFlute, wakeSideForFlute, distinct]

@[simp] theorem flute_wild_opponent_party_not_scanned (side : Full.SideState) :
    (wakeSideForFlute side false).party = side.syncOutgoing.party := by
  simp [wakeSideForFlute]

@[simp] theorem flute_always_wakes_active (side : Full.SideState) (scanParty : Bool) :
    (wakeSideForFlute side scanParty).active.active.status &&& Wram.Status.slpMask = 0 := by
  simp [wakeSideForFlute]

@[simp] theorem flute_preserves_bag (state : UserState) (request : Request) :
    match useFlute state request with
    | .committed next _ => next.bag = state.bag
    | _ => False := by
  simp [useFlute]

@[simp] theorem pp_up_rejected_in_battle : disposition 0x4f = .battleReject := by
  native_decide

/-- Vitamins, Rare Candy, evolution stones, PP Up, and the TM/HM item range all
reject through the battle API. -/
theorem progression_items_rejected_in_battle :
    disposition 0x0a = .battleReject ∧ disposition 0x20 = .battleReject ∧
    disposition 0x21 = .battleReject ∧ disposition 0x22 = .battleReject ∧
    disposition 0x2f = .battleReject ∧ disposition 0x23 = .battleReject ∧
    disposition 0x24 = .battleReject ∧ disposition 0x25 = .battleReject ∧
    disposition 0x26 = .battleReject ∧ disposition 0x27 = .battleReject ∧
    disposition 0x28 = .battleReject ∧ disposition 0x4f = .battleReject ∧
    (use .wild (itemTestState 0xc4) { item := 0xc4 }) =
      .rejected (itemTestState 0xc4) := by
  native_decide

@[simp] theorem out_of_range_54 : disposition 0x54 = .outOfRange := by
  native_decide

theorem raw_dispatch_special_paths :
    rawDispatch 7 = .surfboardContextual ∧ rawDispatch 9 = .pokedexCommitted ∧
    rawDispatch 0x15 = .safariBaitAlias ∧ rawDispatch 0x16 = .safariRockAlias ∧
    rawDispatch 0x54 = .beyondTable := by
  native_decide

/-- Max Ether's no-effect comparison uses the full packed byte. Therefore a
packed value with PP-Up bits cannot compare equal to a max-PP byte whose PP-Up
bits are clear, even if the low current-PP bits are already full. -/
theorem max_restore_packed_comparison_bug (packed maximum : UInt8)
    (hasPpUps : packed &&& Wram.ppUpMask ≠ 0)
    (maximumHasNoPpUps : maximum &&& Wram.ppUpMask = 0) :
    (packed != maximum) = true := by
  by_cases equal : packed = maximum
  · subst maximum
    exact (hasPpUps maximumHasNoPpUps).elim
  · simpa [bne_iff_ne] using equal

#guard disposition 1 == .capture
#guard disposition 0x2E == .battleUse
#guard disposition 0x30 == .battleReject
#guard disposition 0x54 == .outOfRange

end Battle.Full.Items
