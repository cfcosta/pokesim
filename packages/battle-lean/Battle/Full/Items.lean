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

private def useFullRestore (state : UserState) (request : Request) : Result :=
  match mapTarget state request.partyTarget fun mon =>
      if mon.hp == 0 || (mon.hp == mon.maxHp && mon.status == 0) then none
      else some { mon with hp := mon.maxHp, status := 0 } with
  | none => .rejected state
  | some next =>
      -- The player item path never clears the active Toxic flag/counter.
      let next := { next with side := { next.side with active :=
        { next.side.active with volatile := state.side.active.volatile } } }
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

private def maxPp (move : MoveId) (packed : UInt8) : UInt8 :=
  let base := (Data.moveData move).pp.toNat
  let ups := (packed >>> 6).toNat
  (base + base * ups / 5).toUInt8

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

private def wakeMon (mon : MonState) : MonState :=
  { mon with status := mon.status &&& ~~~Wram.Status.slpMask }

private def useFlute (state : UserState) (request : Request) : Result :=
  let side := state.side.syncOutgoing
  let party := { mons := side.party.mons.map wakeMon }
  let active := { side.active with active := wakeMon side.active.active }
  let next := { state with side := { side with party, active } }
  .committed (consume next request.item) [.flute]

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

/-! ## Item fidelity theorems -/

@[simp] theorem link_bag_rejected (state : UserState) (request : Request) :
    use .link state request = .rejected state := by
  rfl

/-- Player Full Restore updates HP and major status but never clears the active
`BADLY_POISONED` volatile bit. -/
theorem full_restore_preserves_active_status3 (state next : UserState) (request : Request)
    (events : List Event)
    (h : useFullRestore state request = .committed next events) :
    next.side.active.volatile.status3 = state.side.active.volatile.status3 := by
  simp only [useFullRestore, mapTarget, updateMon, consume] at h
  split at h <;> simp_all
  rcases h with ⟨rfl, _⟩
  rfl

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
