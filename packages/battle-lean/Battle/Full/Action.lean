/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Items

/-!
# Full battle action domain and legality

Unlike the link nybble channel, this policy domain includes ordinary bag items.
Mode and phase restrictions are explicit; forced replacement admits only living
reserve switches (plus link forfeit), and Struggle appears only when every
nonempty move has zero current PP.
-/

namespace Battle.Full

inductive Action where
  | fight (slot : Fin 4)
  | switch (target : Fin 6)
  | item (request : Items.Request)
  | struggle
  | noAction
  | run
  deriving Repr, DecidableEq, BEq

structure ActionContext where
  side : Full.SideState
  bag : Items.Bag
  mode : BattleMode
  owner : Side := .player
  forcedReplacement : Bool := false
  opponentTrapping : Bool := false
  deriving Repr, DecidableEq

private def currentPp (packed : UInt8) : UInt8 := packed &&& Wram.ppMask

def usableMoveSlot (side : Full.SideState) (slot : Nat) : Bool :=
  side.active.active.moves.getD slot 0 != 0 &&
    currentPp (side.active.active.pp.getD slot 0) != 0 &&
    side.active.volatile.disabledMoveNumber != side.active.active.moves.getD slot 0

/-- `AnyMoveToSelect`: without Disable, mask PP-Up bits after OR-ing all
four bytes. With Disable, skip that encoded slot and test the remaining packed
bytes without masking, preserving the PP-Up anomaly. -/
def anyMovePpAvailable (disabled : UInt8) (pp : Array UInt8) : Bool :=
  let encoded := disabled >>> 4
  if encoded == 0 then
    (((pp.getD 0 0 ||| pp.getD 1 0) ||| pp.getD 2 0) ||| pp.getD 3 0) &&& Wram.ppMask != 0
  else
    (Array.range Wram.numMoves).any fun slot =>
      slot + 1 != encoded.toNat && pp.getD slot 0 != 0

/-- Cartridge Struggle preselection, including malformed packed-PP behavior. -/
def mustStruggle (side : Full.SideState) : Bool :=
  !anyMovePpAvailable side.active.volatile.disabledMove side.active.active.pp

/-- With slot two disabled, slot one's zero-current-PP byte still prevents
Struggle solely because its PP-Up bit is set. -/
theorem disabled_pp_up_struggle_anomaly :
    anyMovePpAvailable 0x20 #[0x40, 0, 0, 0] = true ∧
      (#[0x40, 0, 0, 0].all fun packed => packed &&& Wram.ppMask == 0) = true := by
  native_decide

/-- Item is policy-reachable in this mode and bag. Handler-level contextual
failure remains distinct and is returned by `Items.use`. -/
def itemSelectable (context : ActionContext) (request : Items.Request) : Bool :=
  context.mode != .link && context.bag.contains request.item &&
    Items.disposition request.item != .battleReject &&
    Items.disposition request.item != .outOfRange

def fullMenuBypass (side : Full.SideState) : Bool :=
  side.active.volatile.recharging || side.active.volatile.chargingUp ||
    bitSet side.active.volatile.status1 Wram.BattleStatus1.thrashingAbout ||
    bitSet side.active.volatile.status2 Wram.BattleStatus2.usingRage

def fightSkipsMoveMenu (side : Full.SideState) (opponentTrapping : Bool) : Bool :=
  side.active.active.asleep || side.active.active.frozen || opponentTrapping ||
    bitSet side.active.volatile.status1 Wram.BattleStatus1.storingEnergy

/-- Exact action validity at a choice boundary. -/
def legal (context : ActionContext) (action : Action) : Bool :=
  if context.forcedReplacement then
    match action with
    | .switch target => context.side.canSwitchTo target.val
    | .run => context.mode == .link ||
        (context.owner == .player && context.mode == .wild)
    | _ => false
  else if fullMenuBypass context.side then
    action == .noAction
  else
    match context.mode with
    | .safari =>
        match action with
        | .item request => [1, 2, 3, 4, 8, 0x15, 0x16].contains request.item.toNat
        | .run => true
        | _ => false
    | .oldMan => action == .noAction
    | _ =>
        match action with
        | .fight slot => !mustStruggle context.side && usableMoveSlot context.side slot.val
        | .struggle => mustStruggle context.side
        | .switch target => context.side.canSwitchTo target.val
        | .item request => itemSelectable context request
        | .run => true
        | .noAction => fullMenuBypass context.side ||
            fightSkipsMoveMenu context.side context.opponentTrapping

/-- Finite legal-action vector for policies. -/
def legalActions (context : ActionContext) : Array Action :=
  let fights := (Array.range 4).filterMap fun slot =>
    if h : slot < 4 then
      let action := Action.fight ⟨slot, h⟩
      if legal context action then some action else none
    else none
  let switches := (Array.range 6).filterMap fun target =>
    if h : target < 6 then
      let action := Action.switch ⟨target, h⟩
      if legal context action then some action else none
    else none
  let special := [.struggle, .noAction, .run].toArray.filter (legal context)
  fights ++ switches ++ special

/-! ## Legality theorems -/

/-- Cartridge menu bypass exposes exactly the automatic continuation action;
policy code cannot reselect Fly/Dig, switch, or choose another move while the
first-turn charge bit is set. -/
theorem menu_bypass_only_no_action (context : ActionContext)
    (notForced : context.forcedReplacement = false)
    (bypass : fullMenuBypass context.side = true) (action : Action) :
    legal context action = (action == .noAction) := by
  unfold legal
  rw [notForced]
  simp only [Bool.false_eq_true, if_false]
  rw [bypass]
  simp only [if_true]

@[simp] theorem charging_forces_no_action (context : ActionContext)
    (notForced : context.forcedReplacement = false)
    (charging : context.side.active.volatile.chargingUp = true) :
    legal context .noAction = true ∧
      (∀ slot, legal context (.fight slot) = false) ∧
      (∀ target, legal context (.switch target) = false) := by
  have bypass : fullMenuBypass context.side = true := by
    simp [fullMenuBypass, charging]
  constructor
  · rw [menu_bypass_only_no_action context notForced bypass]
    native_decide
  · constructor
    · intro slot
      rw [menu_bypass_only_no_action context notForced bypass]
      rfl
    · intro target
      rw [menu_bypass_only_no_action context notForced bypass]
      rfl

@[simp] theorem automatic_and_post_fight_locks_are_separate (side : Full.SideState) :
    fullMenuBypass side =
      (side.active.volatile.recharging || side.active.volatile.chargingUp ||
        bitSet side.active.volatile.status1 Wram.BattleStatus1.thrashingAbout ||
        bitSet side.active.volatile.status2 Wram.BattleStatus2.usingRage) ∧
    fightSkipsMoveMenu side true =
      (side.active.active.asleep || side.active.active.frozen || true ||
        bitSet side.active.volatile.status1 Wram.BattleStatus1.storingEnergy) := by
  exact ⟨rfl, rfl⟩

/-- At a forced-replacement boundary, switch legality is exactly the
party-state switch predicate. -/
theorem forced_switch_exact (context : ActionContext) (target : Fin 6)
    (forced : context.forcedReplacement = true) :
    legal context (.switch target) = context.side.canSwitchTo target.val := by
  unfold legal
  rw [forced]
  rfl

@[simp] theorem forced_wild_player_may_try_run (side : Full.SideState) (bag : Items.Bag) :
    legal { side, bag, mode := .wild, owner := .player, forcedReplacement := true } .run = true := rfl

@[simp] theorem forced_wild_enemy_cannot_run (side : Full.SideState) (bag : Items.Bag) :
    legal { side, bag, mode := .wild, owner := .enemy, forcedReplacement := true } .run = false := rfl

theorem ordinary_fight_exact (context : ActionContext) (slot : Fin 4)
    (mode : context.mode = .wild ∨ context.mode = .trainer ∨ context.mode = .link)
    (notForced : context.forcedReplacement = false)
    (menu : fullMenuBypass context.side = false) :
    legal context (.fight slot) =
      (!mustStruggle context.side && usableMoveSlot context.side slot.val) := by
  rcases mode with mode | mode | mode
  all_goals
    unfold legal
    rw [notForced]
    simp only [Bool.false_eq_true, if_false]
    rw [menu]
    simp only [Bool.false_eq_true, if_false]
    rw [mode]

theorem ordinary_switch_exact (context : ActionContext)
    (target : Fin 6) (ordinary : context.mode = .wild ∨ context.mode = .trainer ∨
      context.mode = .link) (notForced : context.forcedReplacement = false)
    (menu : fullMenuBypass context.side = false) :
    legal context (.switch target) = context.side.canSwitchTo target.val := by
  rcases ordinary with ordinary | ordinary | ordinary
  all_goals
    unfold legal
    rw [notForced]
    simp only [Bool.false_eq_true, if_false]
    rw [menu]
    simp only [Bool.false_eq_true, if_false]
    rw [ordinary]

@[simp] theorem trainer_run_selectable (side : Full.SideState) (bag : Items.Bag)
    (menu : fullMenuBypass side = false) :
    legal { side, bag, mode := .trainer } .run = true := by
  unfold legal
  simp only [Bool.false_eq_true, if_false]
  rw [menu]
  rfl

@[simp] theorem ordinary_item_exact (side : Full.SideState) (bag : Items.Bag)
    (mode : BattleMode) (request : Items.Request)
    (ordinary : mode = .wild ∨ mode = .trainer)
    (menu : fullMenuBypass side = false) :
    legal { side, bag, mode } (.item request) =
      itemSelectable { side, bag, mode } request := by
  rcases ordinary with rfl | rfl
  all_goals
    unfold legal
    simp only [Bool.false_eq_true, if_false]
    rw [menu]
    rfl

/-- A fight slot can be legal only when Struggle is not required. -/
theorem legal_fight_not_exhausted (context : ActionContext) (slot : Fin 4)
    (fight : legal context (.fight slot) = true)
    (ordinaryMode : context.mode ≠ .safari)
    (notTutorial : context.mode ≠ .oldMan)
    (notForced : context.forcedReplacement = false) :
    mustStruggle context.side = false := by
  unfold legal at fight
  rw [notForced] at fight
  simp only [Bool.false_eq_true, if_false] at fight
  split at fight
  · change false = true at fight
    contradiction
  · cases mode : context.mode <;> simp_all

/-- Link mode never admits an item. -/
theorem link_item_illegal (side : Full.SideState) (bag : Items.Bag)
    (request : Items.Request) :
    legal { side, bag, mode := .link } (.item request) = false := by
  unfold legal
  simp only [Bool.false_eq_true, if_false]
  split
  · rfl
  · have notLink : (BattleMode.link != BattleMode.link) = false := by
      native_decide
    simp [itemSelectable, notLink]

end Battle.Full
