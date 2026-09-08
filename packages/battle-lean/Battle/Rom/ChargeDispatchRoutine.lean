/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.ChargeRoutine
import Battle.Full.Engine

/-!
# Charging bypasses damage calculation on its first turn

The two canonical CheckIf*NeedsToChargeUp windows dispatch effects $27/$2b
straight to JumpMoveEffect. They do not call CriticalHitTest, GetDamageVars,
CalculateDamage, or MoveHitTest. Presentation and the shared effect dispatcher
are explicit boundaries; ChargeRoutine separately certifies charge setup.
The retained no-action release enters the separate continuation path.
-/
namespace Battle.Rom.ChargeDispatchRoutine

open Sm83 Battle.Rom.Closure

private def entry (enemy : Bool) : Word := if enemy then 0x66FC else 0x569A
private def effectAddress (enemy : Bool) : Word := if enemy then 0xCFCD else 0xCFD3
private def ordinary (enemy : Bool) : Word := if enemy then 0x672B else 0x56B0
private def dispatch : Word := 0x7132
private def ordinaryOpcode (enemy : Bool) : Byte := if enemy then 0xAF else 0xCD
private def code (enemy : Bool) : List Byte :=
  [0xFA, (if enemy then 0xCD else 0xD3), 0xCF, 0xFE, 0x27,
   0xCA, 0x32, 0x71, 0xFE, 0x2B, 0xCA, 0x32, 0x71,
   0x18, (if enemy then 0x20 else 0x07)]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def initial (bytes : List Byte) (enemy : Bool) (effect : UInt8) : FunctionalState :=
  let memory := install default (entry enemy) bytes
  let memory := (memory.write dispatch 0xCD).write (ordinary enemy) (ordinaryOpcode enemy)
  let memory := memory.write (effectAddress enemy) (Byte.ofNat effect.toNat)
  Driver.setupCall memory (UInt16.ofNat (entry enemy).toNat) 0x8000 0xFFFE

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

/-- Full functional and physical branch execution, including the actual
boundary opcode prefetch. No WRAM writes, RNG reads, or stack calls occur. -/
def summaryWith (bytes : List Byte) (enemy : Bool) (effect : UInt8) : Bool :=
  let before := initial bytes enemy effect
  let result := Program.runUntil
    (fun state => state.registers.pc == dispatch || state.registers.pc == ordinary enemy)
    6 before [] 0
  let after := Driver.finalState result
  let trace := traceOf result
  let charge := Full.Engine.startsCharging effect (.fight 0)
  let physical := FlatAdapter.run (trace.length + 1)
    { core := Pipeline.bootstrap before.registers, memory := before.memory }
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  Driver.reachedReturn result &&
    after.registers.pc == (if charge then dispatch else ordinary enemy) &&
    after.registers.sp == before.registers.sp &&
    trace.all (fun event => match event with
      | .write _ _ => false
      | .read .data address _ => address == effectAddress enemy
      | _ => true) &&
    physical.trace == trace ++ [.read .opcode after.registers.pc
      (if charge then 0xCD else ordinaryOpcode enemy)] &&
    projected.registers == after.registers && projected.mode == .running &&
    physical.core.boundaryPC.isSome

private def exhaustive : Bool :=
  (List.range 256).all fun value =>
    summaryWith (code false) false value.toUInt8 &&
    summaryWith (code true) true value.toUInt8

private theorem exhaustive_checked : exhaustive = true := by native_decide

theorem dispatch_matches_model (enemy : Bool) (effect : UInt8) :
    summaryWith (code enemy) enemy effect = true := by
  have rows := List.all_eq_true.mp exhaustive_checked
  have row := rows effect.toNat (List.mem_range.mpr effect.toNat_lt)
  have round : effect.toNat.toUInt8 = effect := by
    apply UInt8.toNat.inj
    simp
  simp only [round] at row
  cases enemy <;> simp_all

private def decoded (rom : Array Byte) (enemy : Bool) : List Byte :=
  (Tables.tableBytes rom (romOffset 0x0F (entry enemy)) 15).map fun byte => Byte.ofNat byte.toNat

structure RequiredBytes (rom : Array Byte) : Prop where
  gate : ∀ enemy, Tables.tableBytes rom (romOffset 0x0F (entry enemy)) 15 =
    (code enemy).map (fun byte => byte.toNat.toUInt8)
  effectBoundary : Tables.tableBytes rom (romOffset 0x0F dispatch) 1 = [0xCD]
  ordinaryBoundary : ∀ enemy,
    Tables.tableBytes rom (romOffset 0x0F (ordinary enemy)) 1 =
      [(ordinaryOpcode enemy).toNat.toUInt8]

/-- A caller's actual ROM windows execute the same early-charge predicate used
by executeMove. The separately proved charge setup owns the subsequent writes. -/
theorem cartridge_dispatch_matches_model {rom : Array Byte}
    (required : RequiredBytes rom) (enemy : Bool) (effect : UInt8) :
    summaryWith (decoded rom enemy) enemy effect = true := by
  have bytes : decoded rom enemy = code enemy := by
    simp only [decoded, required.gate, List.map_map]
    cases enemy <;> native_decide
  rw [bytes]
  exact dispatch_matches_model enemy effect

/-- Exact screen-overflow arithmetic from the incident: 513*2/4 wraps to zero.
This remains a supported cartridge freeze when damage is actually calculated. -/
theorem incident_divisor :
    DamageStats.resolve 163 513 true =
      .divisionFreeze { attack := 40, defense := 0 } ∧
    DamageStats.resolve 163 513 false =
      .ready { attack := 40, defense := 128 } := by native_decide

set_option maxRecDepth 4096 in
private theorem canonical_charge_mechanic (case : ChargeRoutine.CanonicalMove) :
    (Full.EffectPlan.plan (Data.moveData case.move).effect).mechanic =
      .charge (case == .fly) := by
  cases case <;> decide

private theorem canonical_charge_invulnerability (case : ChargeRoutine.CanonicalMove) :
    ((case == .fly) || case.move == 91) = case.invulnerable := by
  cases case <;> decide

/-- All six canonical moves refine the real engine executor, for both ordinary
and generated moves and every prepared battle state. This is whole-result
equality, not just equality of the dispatch predicate. -/
theorem engine_charge_exact (case : ChargeRoutine.CanonicalMove)
    (state : Full.Engine.State) (who : Side) (action : Full.Action) (slot : Fin 4)
    (attacker : Battle.SideState) (attackerFull defenderFull : Full.SideState)
    (rng : Rng.LinkRng) (generated : Bool)
    (initial : (action != .noAction) = true) :
    Full.Engine.executeMove state who action case.move slot attacker attackerFull
      defenderFull rng generated =
      .transitioned
        (Full.Engine.chargeSetupState state who attacker attackerFull rng case.invulnerable)
        [.effect (.signal (.charging case.invulnerable))] := by
  simpa only [canonical_charge_invulnerability] using
    Full.Engine.executeMove_initial_charge_exact state who action case.move slot
      attacker attackerFull defenderFull rng generated (case == .fly)
      (canonical_charge_mechanic case) initial

/-- Routine-boundary refinement: the supplied cartridge dispatch bytes take
the charge branch; the actual Lean executor returns only setup; and its status
byte equals execution of the supplied cartridge setup bytes. The shared effect
dispatcher and presentation remain explicit boundaries, not whole-turn proofs. -/
theorem cartridge_charge_refines_executor {rom : Array Byte}
    (dispatchBytes : RequiredBytes rom)
    (setupBytes : ChargeRoutine.RequiredChargeBytes rom)
    (case : ChargeRoutine.CanonicalMove) (state : Full.Engine.State)
    (who : Side) (action : Full.Action) (slot : Fin 4)
    (attacker : Battle.SideState) (attackerFull defenderFull : Full.SideState)
    (rng : Rng.LinkRng) (generated : Bool)
    (initial : (action != .noAction) = true) :
    let enemy := who == .enemy
    let after := Full.Engine.chargeSetupState state who attacker attackerFull rng case.invulnerable
    summaryWith (decoded rom enemy) enemy (Data.moveData case.move).effect = true ∧
    Full.Engine.executeMove state who action case.move slot attacker attackerFull
      defenderFull rng generated =
      .transitioned after [.effect (.signal (.charging case.invulnerable))] ∧
    (after.battle.side who).active.volatile.status1 =
      ChargeRoutine.cartridgeSetupStatus rom case enemy attacker.volatile.status1 := by
  refine ⟨cartridge_dispatch_matches_model dispatchBytes _ _,
    engine_charge_exact case state who action slot attacker attackerFull defenderFull
      rng generated initial, ?_⟩
  rw [ChargeRoutine.cartridge_setup_status_exact setupBytes]
  cases who <;> rfl

/-- Reduced incident witness at the post-status move boundary. Only the
offensive stat, screened defensive stat, move and noncritical RNG matter;
this is not a reconstruction of every field in the recorded episode. -/
private def incidentAttacker : MonState :=
  { species := 0x4B, hp := 200, boxLevel := 70, status := 0,
    type1 := 23, type2 := 2, catchRate := 3, moves := #[143, 0, 0, 0],
    dvs := 0, level := 70, maxHp := 200, attack := 163, defense := 100,
    speed := 100, special := 100, pp := #[5, 0, 0, 0] }

private def incidentRng : Rng.LinkRng :=
  { list := Array.replicate 10 255, index := 0 }

private def incidentState (who : Side) : Full.Engine.State :=
  let attacker := Full.SideState.fromParty { mons := #[incidentAttacker] } incidentAttacker
  let defenderMon := { incidentAttacker with species := 0x83, defense := 171 }
  let defender := Full.SideState.fromParty { mons := #[defenderMon] } defenderMon
  let defender := { defender with active := { defender.active with
    active := { defender.active.active with defense := 513 },
    stages := { defender.active.stages with defense := 11 },
    volatile := { defender.active.volatile with status3 := 4 } } }
  let player := if who == .player then attacker else defender
  let enemy := if who == .player then defender else attacker
  let battle : Full.State :=
    { player, enemy, rng := incidentRng, turn := 0, mode := .link, phase := .battling }
  { battle }

/-- The same zero-divisor state safely charges on either side, including a
generated Sky Attack. The universal theorem supplies exact HP/PP/RNG framing. -/
theorem incident_initial_charge_exact (who : Side) (generated : Bool) :
    let state := incidentState who
    let attacker := state.battle.side who
    Full.Engine.executeMove state who (.fight 0) 143 0 attacker.active attacker
      (state.battle.side who.other) incidentRng generated =
      .transitioned
        (Full.Engine.chargeSetupState state who attacker.active attacker incidentRng false)
        [.effect (.signal (.charging false))] := by
  exact engine_charge_exact .skyAttack _ who (.fight 0) 0 _ _ _ incidentRng generated rfl

private def incidentReleaseFreezes (who : Side) (generated : Bool) : Bool :=
  let state := incidentState who
  let attacker := state.battle.side who
  match Full.Engine.executeMove state who .noAction 143 0 attacker.active attacker
      (state.battle.side who.other) incidentRng generated with
  | .divisionFreeze after events =>
      events == [.rng "critical" 255] &&
      (after.battle.side who).active.active.pp == #[4, 0, 0, 0] &&
      (after.battle.side who).active.active.hp == 200 &&
      after.battle.side who.other == state.battle.side who.other
  | _ => false

/-- A noncritical release still reaches divisionFreeze in the actual executor,
after spending PP and evaluating critical RNG, on both sides and for generated
moves. The fix must not hide a legitimate cartridge zero-divisor condition. -/
theorem incident_release_still_freezes (who : Side) (generated : Bool) :
    incidentReleaseFreezes who generated = true := by
  cases who <;> cases generated <;> native_decide

def windowAgrees (rom : Array Byte) : Bool :=
  [false, true].all (fun enemy =>
    decide (Tables.tableBytes rom (romOffset 0x0F (entry enemy)) 15 =
      (code enemy).map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom (romOffset 0x0F (ordinary enemy)) 1 =
      [(ordinaryOpcode enemy).toNat.toUInt8])) &&
    decide (Tables.tableBytes rom (romOffset 0x0F dispatch) 1 = [0xCD])

end Battle.Rom.ChargeDispatchRoutine
