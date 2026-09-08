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

def windowAgrees (rom : Array Byte) : Bool :=
  [false, true].all (fun enemy =>
    decide (Tables.tableBytes rom (romOffset 0x0F (entry enemy)) 15 =
      (code enemy).map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom (romOffset 0x0F (ordinary enemy)) 1 =
      [(ordinaryOpcode enemy).toNat.toUInt8])) &&
    decide (Tables.tableBytes rom (romOffset 0x0F dispatch) 1 = [0xCD])

end Battle.Rom.ChargeDispatchRoutine
