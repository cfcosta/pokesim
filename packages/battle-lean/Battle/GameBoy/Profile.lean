/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.GameBoy.Adapter
import Sm83.Profile

namespace Battle.GameBoy.Profile

open Sm83

/-- The selected first system profile. Empirical fields that are not established
for common CPU-B hardware remain relations rather than executable constants. -/
structure DmgCpuBCommonBoot where
  stop : StopProfile
  invalidLock : InvalidLockProfile
  bootSha256 : String

/-- DMG has no speed-switch request; the reviewed STOP relation retains the
remaining button/interrupt cases. -/
def dmgStop : StopProfile where
  permits context byte outcome :=
    context.speedSwitchRequested = false ∧ StopProfile.reviewed.permits context byte outcome
  decidablePermits := by intros; infer_instance

def commonBoot : DmgCpuBCommonBoot :=
  { stop := dmgStop
    invalidLock := InvalidLockProfile.retainedLevels
    bootSha256 := Memory.canonicalDmgBootSha256 }

/-- Reset owns control-state constraints but deliberately leaves the register
and RAM image relational. The canonical post-boot image is derived by executing
identified boot bytes, not asserted here. -/
inductive ResetStep (sha256 : Memory.Sha256) : Adapter.Machine → Adapter.Machine → Prop where
  | asserted {before after}
      (boot : Memory.BootRom.Valid sha256 after.memory.bootRom)
      (cartridge : after.memory.cartridge = before.memory.cartridge)
      (mapped : after.memory.bootMapped = true)
      (phase : after.core.phase = .bootstrap)
      (ir : after.core.ir = none)
      (shape : after.core.shape = none)
      (remaining : after.core.remaining = []) :
      ResetStep sha256 before after

/-- Reset uncertainty genuinely admits distinct architectural register images. -/
theorem reset_admits_distinct_registers (sha256 : Memory.Sha256)
    (before afterA afterB : Adapter.Machine)
    (bootA : Memory.BootRom.Valid sha256 afterA.memory.bootRom)
    (bootB : Memory.BootRom.Valid sha256 afterB.memory.bootRom)
    (cartA : afterA.memory.cartridge = before.memory.cartridge)
    (cartB : afterB.memory.cartridge = before.memory.cartridge)
    (mappedA : afterA.memory.bootMapped = true)
    (mappedB : afterB.memory.bootMapped = true)
    (bootstrapA : afterA.core.phase = .bootstrap ∧ afterA.core.ir = none ∧
      afterA.core.shape = none ∧ afterA.core.remaining = [])
    (bootstrapB : afterB.core.phase = .bootstrap ∧ afterB.core.ir = none ∧
      afterB.core.shape = none ∧ afterB.core.remaining = [])
    (distinct : afterA.core.registers ≠ afterB.core.registers) :
    ResetStep sha256 before afterA ∧ ResetStep sha256 before afterB ∧
      afterA.core.registers ≠ afterB.core.registers := by
  exact ⟨.asserted bootA cartA mappedA bootstrapA.1 bootstrapA.2.1
      bootstrapA.2.2.1 bootstrapA.2.2.2,
    .asserted bootB cartB mappedB bootstrapB.1 bootstrapB.2.1
      bootstrapB.2.2.1 bootstrapB.2.2.2,
    distinct⟩

/-- Full fetched-IR witness at the cartridge handoff. `PC = $0100` alone is not
a valid physical checkpoint because fetch is overlapped. -/
structure CartridgeHandoffWitness where
  fetched : FetchedIR
  nextPC : Word
  shape : Option InstructionShape
  latches : CoreLatches
  ime : Bool
  scheduledImeEnable : Bool
  deriving Repr, DecidableEq

/-- Boot has handed control to the cartridge only after `$0100` is fetched into
IR, boot mapping is disabled, and hidden pipeline witnesses agree. -/
def AtCartridge0100 (machine : Adapter.Machine)
    (witness : CartridgeHandoffWitness) : Prop :=
  machine.memory.bootMapped = false ∧
  machine.core.phase = .execute ∧
  machine.core.ir = some witness.fetched ∧
  witness.fetched.address = 0x0100 ∧
  witness.fetched.byte = Memory.read machine.memory 0x0100 ∧
  machine.core.registers.pc = witness.nextPC ∧
  witness.nextPC = 0x0101 ∧
  machine.core.shape = witness.shape ∧
  machine.core.latches = witness.latches ∧
  machine.core.ime = witness.ime ∧
  machine.core.scheduledImeEnable = witness.scheduledImeEnable

/-- An identified boot execution certificate packages the assumptions and exact
system trace whose handoff theorem is checked separately. -/
structure BootCertificate (sha256 : Memory.Sha256) where
  initial : Adapter.Machine
  final : Adapter.Machine
  wakeAt : Nat → Bool
  cycles : Nat
  bootValid : Memory.BootRom.Valid sha256 initial.memory.bootRom
  resetMapped : initial.memory.bootMapped = true
  execution : final = Adapter.run cycles wakeAt initial
  witness : CartridgeHandoffWitness
  handoff : AtCartridge0100 final witness

/-- Advanced monochrome OAM effects remain fixture-qualified. -/
structure OamFixture where
  captureSha256 : String
  cpuBIdentified : Prop
  calibrated : Prop

structure OamProfile where
  permits : OamFixture → Adapter.Machine → Adapter.Machine → Prop

/-- No deterministic advanced-OAM instance is exported without an identified,
calibrated capture witness. -/
def fixtureQualifiedOam : OamProfile where
  permits fixture _ _ := fixture.cpuBIdentified ∧ fixture.calibrated

end Battle.GameBoy.Profile
