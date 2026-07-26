/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.DriverInvariant
import Battle.Full.Environment
import Battle.Full.OuterFlow
import Battle.Rom.OuterReturnRoutine
import Battle.Rom.Reachability

/-!
# ROM-linked battle-driver closure contract

This module makes the remaining whole-driver evidence explicit. `MachineCycles`
contains only actual composed Game Boy adapter steps; checkpoint constructors do
not move the machine. A certificate therefore cannot turn fuel exhaustion or a
high-level marker into cartridge execution.
-/

namespace Battle.Rom.DriverClosure

open Sm83 Battle Battle.Full

abbrev Machine := DriverInvariant.Machine

inductive MachineCycles : Machine → List Bool → Machine → Prop where
  | nil (machine) : MachineCycles machine [] machine
  | cons {before middle after wake wakes}
      (equation : (GameBoy.Adapter.stepMachineCycle before wake).machine = middle)
      (rest : MachineCycles middle wakes after) :
      MachineCycles before (wake :: wakes) after


theorem MachineCycles.append {first middle final : Machine}
    {left right : List Bool}
    (before : MachineCycles first left middle)
    (after : MachineCycles middle right final) :
    MachineCycles first (left ++ right) final := by
  induction before with
  | nil => simpa using after
  | cons equation rest induction =>
      exact .cons equation (induction after)


def modeBytesMatch (machine : Machine) : BattleMode → Prop
  | .wild => GameBoy.Memory.read machine.memory 0xD057 = 1 ∧
      GameBoy.Memory.read machine.memory 0xD05A = 0 ∧
      GameBoy.Memory.read machine.memory 0xD12B ≠ 4
  | .trainer => GameBoy.Memory.read machine.memory 0xD057 = 2 ∧
      GameBoy.Memory.read machine.memory 0xD12B ≠ 4
  | .safari => GameBoy.Memory.read machine.memory 0xD05A = 2
  | .oldMan => GameBoy.Memory.read machine.memory 0xD05A = 1
  | .link => GameBoy.Memory.read machine.memory 0xD12B = 4

/-- Fetched-IR checkpoint at canonical `StartBattle`, after all mode-specific
setup and with the CALL return frame still visible in HRAM. -/
structure ModeSetupCheckpoint (machine : Machine) (mode : BattleMode) : Prop where
  bootUnmapped : machine.memory.bootMapped = false
  bank : GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 0x0F
  ir : machine.core.ir = some {
    address := Closure.Symbols.startBattle.address
    byte := 0xAF }
  nextPc : machine.core.registers.pc = 0x411F
  returnLow : GameBoy.Memory.read machine.memory machine.core.registers.sp = 0x33
  returnHigh : GameBoy.Memory.read machine.memory
    (Word.ofNat (machine.core.registers.sp.toNat + 1)) = 0x70
  modeBytes : modeBytesMatch machine mode

/-- The checkpoint immediately after `StartBattle` returns and before the
`EndOfBattle` far call. Terminal provenance is related to raw pre-cleanup bytes;
it is not reconstructed after cleanup. -/
structure TerminalCheckpoint (machine : Machine)
    (terminal : Outcome.BattleTerminal) : Prop where
  bootUnmapped : machine.memory.bootMapped = false
  bank : GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 0x0F
  irAddress : machine.core.ir.map (·.address) = some 0x7033
  rawResult : (GameBoy.Memory.read machine.memory 0xCF0B).toNat.toUInt8 =
    terminal.rawResult
  escaped : (GameBoy.Memory.read machine.memory 0xD078).toNat.toUInt8 =
    terminal.preCleanupEscaped
  modeBytes : modeBytesMatch machine terminal.mode

/-- Return from `EndOfBattle` to the decoded outer shell. Cleanup preserves the
result byte while erasing escape/mode/opponent context. -/
structure EpilogueCheckpoint (machine : Machine)
    (terminal : Outcome.BattleTerminal) : Prop where
  bootUnmapped : machine.memory.bootMapped = false
  bank : GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 0x0F
  irAddress : machine.core.ir.map (·.address) = some 0x703B
  rawResult : (GameBoy.Memory.read machine.memory 0xCF0B).toNat.toUInt8 =
    terminal.rawResult
  escapedCleared : GameBoy.Memory.read machine.memory 0xD078 = 0
  modeCleared : GameBoy.Memory.read machine.memory 0xD05A = 0
  opponentCleared : GameBoy.Memory.read machine.memory 0xD059 = 0

structure ReturnCheckpoint (machine : Machine) (caller : Full.OuterFlow.CallerFrame)
    (returnAddress : Word) : Prop where
  pc : machine.core.registers.pc = returnAddress
  sp : machine.core.registers.sp.toNat = caller.stackPointer.toNat
  carry : machine.core.registers.flags.c = true
  letterDelay : (GameBoy.Memory.read machine.memory 0xD358).toNat.toUInt8 =
    caller.letterDelayFlags
  mapPalette : (GameBoy.Memory.read machine.memory 0xD35D).toNat.toUInt8 =
    caller.mapPaletteOffset
  tileAnimations : (GameBoy.Memory.read machine.memory 0xFFD7).toNat.toUInt8 =
    caller.tileAnimations
  bank : GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = caller.romBank.toNat

/-- A whole-driver certificate is segmented at mechanically recognizable ROM
checkpoints. Every segment is a finite list of actual adapter cycles. Nested
learning/evolution completion remains visible as a supplied high-level relation
at the epilogue boundary. -/
structure Certificate (initial modeSetup terminalState epilogue returned : Machine)
    (mode : BattleMode) (terminal : Outcome.BattleTerminal)
    (caller : Full.OuterFlow.CallerFrame) (returnAddress : Word)
    (entryBytes : Closure.RequiredEntryBytes initial.memory.cartridge.rom)
    (outerBytes : OuterReturnRoutine.RequiredOuterReturnBytes
      initial.memory.cartridge.rom) where
  entry : DriverInvariant.AtInitOpponentReady initial entryBytes
  setupCycles : List Bool
  battleCycles : List Bool
  epilogueCycles : List Bool
  returnCycles : List Bool
  toSetup : MachineCycles initial setupCycles modeSetup
  setup : ModeSetupCheckpoint modeSetup mode
  toTerminal : MachineCycles modeSetup battleCycles terminalState
  terminalCheckpoint : TerminalCheckpoint terminalState terminal
  toEpilogue : MachineCycles terminalState epilogueCycles epilogue
  epilogueCheckpoint : EpilogueCheckpoint epilogue terminal
  toReturn : MachineCycles epilogue returnCycles returned
  returnCheckpoint : ReturnCheckpoint returned caller returnAddress


theorem mode_setup_precedes_startBattle
    {initial modeSetup terminalState epilogue returned : Machine}
    {mode : BattleMode} {terminal : Outcome.BattleTerminal}
    {caller : Full.OuterFlow.CallerFrame} {returnAddress : Word}
    {entryBytes : Closure.RequiredEntryBytes initial.memory.cartridge.rom}
    {outerBytes : OuterReturnRoutine.RequiredOuterReturnBytes initial.memory.cartridge.rom}
    (certificate : Certificate initial modeSetup terminalState epilogue returned
      mode terminal caller returnAddress entryBytes outerBytes) :
    modeBytesMatch modeSetup mode ∧
      modeSetup.core.ir.map (·.address) = some Closure.Symbols.startBattle.address := by
  exact ⟨certificate.setup.modeBytes, by rw [certificate.setup.ir]; rfl⟩


theorem terminal_enters_ending_before_cleanup
    {initial modeSetup terminalState epilogue returned : Machine}
    {mode : BattleMode} {terminal : Outcome.BattleTerminal}
    {caller : Full.OuterFlow.CallerFrame} {returnAddress : Word}
    {entryBytes : Closure.RequiredEntryBytes initial.memory.cartridge.rom}
    {outerBytes : OuterReturnRoutine.RequiredOuterReturnBytes initial.memory.cartridge.rom}
    (certificate : Certificate initial modeSetup terminalState epilogue returned
      mode terminal caller returnAddress entryBytes outerBytes) :
    (Full.OuterFlow.terminalCheckpoint terminal caller).phase = .ending terminal ∧
      (GameBoy.Memory.read terminalState.memory 0xCF0B).toNat.toUInt8 =
        terminal.rawResult := by
  exact ⟨rfl, certificate.terminalCheckpoint.rawResult⟩


theorem epilogue_preserves_terminal_provenance
    {initial modeSetup terminalState epilogue returned : Machine}
    {mode : BattleMode} {terminal : Outcome.BattleTerminal}
    {caller : Full.OuterFlow.CallerFrame} {returnAddress : Word}
    {entryBytes : Closure.RequiredEntryBytes initial.memory.cartridge.rom}
    {outerBytes : OuterReturnRoutine.RequiredOuterReturnBytes initial.memory.cartridge.rom}
    (certificate : Certificate initial modeSetup terminalState epilogue returned
      mode terminal caller returnAddress entryBytes outerBytes) :
    let cleaned := Full.OuterFlow.cleanupCheckpoint
      (Full.OuterFlow.terminalCheckpoint terminal caller)
    cleaned.phase = .ending terminal ∧ cleaned.encounterCooldown = true ∧
      (GameBoy.Memory.read epilogue.memory 0xCF0B).toNat.toUInt8 =
        (GameBoy.Memory.read terminalState.memory 0xCF0B).toNat.toUInt8 := by
  refine ⟨rfl, rfl, ?_⟩
  exact certificate.epilogueCheckpoint.rawResult.trans
    certificate.terminalCheckpoint.rawResult.symm


theorem returned_episode_exact
    {initial modeSetup terminalState epilogue returned : Machine}
    {mode : BattleMode} {terminal : Outcome.BattleTerminal}
    {caller : Full.OuterFlow.CallerFrame} {returnAddress : Word}
    {entryBytes : Closure.RequiredEntryBytes initial.memory.cartridge.rom}
    {outerBytes : OuterReturnRoutine.RequiredOuterReturnBytes initial.memory.cartridge.rom}
    (certificate : Certificate initial modeSetup terminalState epilogue returned
      mode terminal caller returnAddress entryBytes outerBytes) :
    let result := Full.OuterFlow.outerReturn
      (Full.OuterFlow.cleanupCheckpoint
        (Full.OuterFlow.terminalCheckpoint terminal caller)) caller
    result.phase = .returned ⟨terminal⟩ ∧ result.carry = true ∧
      returned.core.registers.pc = returnAddress ∧
      returned.core.registers.flags.c = true := by
  simp [Full.OuterFlow.terminalCheckpoint, Full.OuterFlow.cleanupCheckpoint,
    Full.OuterFlow.outerReturn, certificate.returnCheckpoint.pc,
    certificate.returnCheckpoint.carry]

/-- Composition retains one actual adapter-cycle path from `InitOpponent` to
the returned caller checkpoint. -/
theorem continuous_initOpponent_to_return
    {initial modeSetup terminalState epilogue returned : Machine}
    {mode : BattleMode} {terminal : Outcome.BattleTerminal}
    {caller : Full.OuterFlow.CallerFrame} {returnAddress : Word}
    {entryBytes : Closure.RequiredEntryBytes initial.memory.cartridge.rom}
    {outerBytes : OuterReturnRoutine.RequiredOuterReturnBytes initial.memory.cartridge.rom}
    (certificate : Certificate initial modeSetup terminalState epilogue returned
      mode terminal caller returnAddress entryBytes outerBytes) :
    MachineCycles initial
      (certificate.setupCycles ++ certificate.battleCycles ++
        certificate.epilogueCycles ++ certificate.returnCycles) returned := by
  simpa [List.append_assoc] using certificate.toSetup.append
    (certificate.toTerminal.append
      (certificate.toEpilogue.append certificate.toReturn))

end Battle.Rom.DriverClosure
