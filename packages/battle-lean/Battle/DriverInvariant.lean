/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.Episode
import Battle.GameBoy.Adapter
import Battle.Rom.Closure
import Sm83.Retirement
import Sm83.Simulation

namespace Battle.DriverInvariant

open Sm83

abbrev Machine := GameBoy.Adapter.Machine

/-- Instrument-free machine observations used by the driver refinement. Marker
constructors require concrete checkpoint predicates in `MachineStep`. -/
inductive LowEvent where
  | cycle (intent : CycleIntent) (readValue : Byte) (retires : Bool)
  | enteredBattle
  | turnAdvanced (turn : Nat)
  | terminal (witness : Episode.TerminalWitness)
  | epilogue (witness : Episode.TerminalWitness)
  | cleanup (witness : Episode.TerminalWitness)
  | outerReturn (witness : Episode.TerminalWitness)
  deriving Repr, DecidableEq

/-- Episode-specific checkpoints. The first concrete episode supplies these as
address/IR/WRAM/stack predicates and proves they are reached by ROM execution. -/
structure Context where
  returnAddress : Word
  initialSP : Word
  battleEntered : Machine → Prop
  turnAdvanced : Machine → Nat → Prop
  terminalReached : Machine → Episode.TerminalWitness → Prop
  epilogueReached : Machine → Episode.TerminalWitness → Prop
  returned : Machine → Episode.TerminalWitness → Prop

/-- Physical machine transition plus justified semantic checkpoints. -/
inductive MachineStep (context : Context) : Machine → List LowEvent → Machine → Prop where
  | cycle {before output wake}
      (equation : GameBoy.Adapter.stepMachineCycle before wake = output) :
      MachineStep context before
        [.cycle output.cpuOutput.intent output.cpuInput.read.fold
          (Retirement.atRetirement before.core)] output.machine
  | terminalMarker {machine witness}
      (checkpoint : context.terminalReached machine witness) :
      MachineStep context machine [.terminal witness] machine
  | epilogueMarker {machine witness}
      (checkpoint : context.epilogueReached machine witness) :
      MachineStep context machine [.epilogue witness] machine
  | returnMarker {machine witness}
      (checkpoint : context.returned machine witness) :
      MachineStep context machine [.cleanup witness, .outerReturn witness] machine

/-- Semantic projection of one physical bus cycle. Unlisted bus traffic is
retained in the machine proof but hidden from the battle protocol. -/
def projectCycleObservation (intent : CycleIntent) (value : Byte) :
    Option Episode.Observation :=
  if intent.control = .read && intent.address = 0xFF04 then
    some (.rng "rDIV" value.toNat.toUInt8)
  else if intent.control = .read && intent.address = 0xFF00 then
    some (.input "rP1" value.toNat.toUInt8)
  else if intent.control = .read && intent.address = 0xFF01 then
    some (.input "rSB" value.toNat.toUInt8)
  else none

/-- Processor/device events projected into the independent battle protocol. -/
def projectEvent : LowEvent → Option Episode.Event
  | .cycle intent value _ => (projectCycleObservation intent value).map .observed
  | .enteredBattle => some .enteredBattle
  | .turnAdvanced turn => some (.turnAdvanced turn)
  | .terminal witness => some (.terminal witness)
  | .epilogue witness => some (.epilogue witness)
  | .cleanup witness => some (.cleanup witness)
  | .outerReturn witness => some (.outerReturn witness)

/-- Rank used by the physical-to-driver stuttering proof. Successor retirement
matches an `Episode.Step.instruction`; other internal M-cycles decrease this
rank. Interrupt stages receive a separate descending band. -/
def pipelineRank (machine : Machine) : Nat :=
  match machine.core.phase with
  | .bootstrap => 1
  | .execute => machine.core.remaining.length
  | .interrupt => match machine.core.interrupt with
    | some entry => match entry.stage with
      | .correctPC => 5
      | .decrementSP => 4
      | .writeHigh => 3
      | .writeLow => 2
      | .fetchVector => 1
    | none => 0

/-- Explicit standalone reset image needed before entering `InitOpponent`.
`InitBattleVariables` alone does not imply this predicate. -/
structure SuppliedWildReset (memory : GameBoy.Memory.State) : Prop where
  onePlayer : GameBoy.Memory.read memory 0xD163 = 1
  playerSpeciesTerminated : GameBoy.Memory.read memory 0xD165 = 0xFF
  suppliedOpponent : GameBoy.Memory.read memory 0xD059 ≠ 0
  suppliedLevel : GameBoy.Memory.read memory 0xD127 ≠ 0
  normalBattleType : GameBoy.Memory.read memory 0xD05A = 0
  notLink : GameBoy.Memory.read memory 0xD12B ≠ 4
  initiallyOutsideBattle : GameBoy.Memory.read memory 0xD057 = 0

/-- Full fetched-IR entry relation for canonical `InitOpponent` in bank `$0F`. -/
def AtInitOpponent (machine : Machine) : Prop :=
  machine.memory.bootMapped = false ∧
  GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 0x0F ∧
  Rom.Closure.RomBankInImage machine.memory.cartridge ∧
  machine.core.mode = .running ∧
  machine.core.phase = .execute ∧
  machine.core.ir.map (fun fetched => (fetched.address, fetched.byte)) =
    some (Rom.Closure.Symbols.initOpponent.address,
      GameBoy.Memory.read machine.memory Rom.Closure.Symbols.initOpponent.address) ∧
  machine.core.registers.pc = Word.ofNat
    (Rom.Closure.Symbols.initOpponent.address.toNat + 1) ∧
  machine.core.shape = match machine.core.ir with
    | some fetched => match Decode.base fetched.byte with
      | .legal shape => some shape
      | _ => none
    | none => none

/-- The fetched `InitOpponent` byte is tied to the canonical physical ROM
offset under the live MBC3 mapping, not merely to a linker label. -/
theorem atInitOpponent_canonical_byte {machine : Machine}
    (entry : AtInitOpponent machine) :
    machine.core.ir.map (fun fetched => (fetched.address, fetched.byte)) =
      some (Rom.Closure.Symbols.initOpponent.address,
        GameBoy.Mbc3.readArray machine.memory.cartridge.rom
          (Rom.Closure.romOffset Rom.Closure.Symbols.initOpponent.bank.toNat
            Rom.Closure.Symbols.initOpponent.address)) := by
  have selected : Rom.Closure.Symbols.initOpponent.Selected machine.memory.cartridge := by
    simp [Rom.Closure.Symbol.Selected, Rom.Closure.Symbols.initOpponent,
      entry.2.1]
  have canonical := Rom.Closure.read_selected_symbol machine.memory
    Rom.Closure.Symbols.initOpponent entry.1 (by decide) selected
  simpa [canonical] using entry.2.2.2.2.2.1

/-- Retained byte witnesses specialize the entry checkpoint to the exact
canonical opcode byte. -/
theorem atInitOpponent_opcode {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    machine.core.ir.map (fun fetched => (fetched.address, fetched.byte)) =
      some (Rom.Closure.Symbols.initOpponent.address, 0xFA) := by
  rw [← bytes.initOpponent_opcode]
  exact atInitOpponent_canonical_byte entry

/-- The canonical entry IR is decoded from byte `$FA` as `LD A,(a16)`. -/
theorem atInitOpponent_shape {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    machine.core.shape = some .ldAAbs := by
  have opcode := atInitOpponent_opcode entry bytes
  cases irEq : machine.core.ir with
  | none => simp [irEq] at opcode
  | some fetched =>
      have byteEq : fetched.byte = 0xFA := by simpa [irEq] using congrArg (fun value => value.map Prod.snd) opcode
      rw [entry.2.2.2.2.2.2.2, irEq]
      change (match Decode.base fetched.byte with
        | .legal shape => some shape
        | _ => none) = some .ldAAbs
      rw [byteEq, Rom.Closure.initOpponent_opcode_decode]

/-- Full canonical entry checkpoint, including the fetched IR address/byte and
all hidden pipeline witnesses needed to execute the first M-cycle. -/
structure AtInitOpponentReady (machine : Machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) : Prop where
  checkpoint : AtInitOpponent machine
  ir : machine.core.ir = some {
    address := Rom.Closure.Symbols.initOpponent.address
    byte := 0xFA }
  shape : machine.core.shape = some .ldAAbs
  remaining : machine.core.remaining =
    [.immediateLow, .immediateHigh, .readAddress, .successorFetch]
  latches : machine.core.latches = {}
  interrupt : machine.core.interrupt = none
  boundaryPC : machine.core.boundaryPC = some Rom.Closure.Symbols.initOpponent.address
  haltBug : machine.core.haltBug = false

/-- The first immediate byte is read from the canonical physical ROM offset. -/
theorem atInitOpponent_immediateLow {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    GameBoy.Memory.read machine.memory (Word.ofNat 0x6F19) = 0x59 := by
  let symbol : Rom.Closure.Symbol := ⟨0x0F, Word.ofNat 0x6F19⟩
  have selected : symbol.Selected machine.memory.cartridge := by
    change GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 15
    simpa using entry.2.1
  have mapped := Rom.Closure.read_selected_symbol machine.memory symbol entry.1
    (by native_decide) selected
  rw [mapped]
  simpa [symbol, Rom.Closure.romOffset, Rom.Closure.Symbols.initOpponent] using
    bytes.initOpponent_immediateLow

/-- The second immediate byte is the canonical high byte `$D0`. -/
theorem atInitOpponent_immediateHigh {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    GameBoy.Memory.read machine.memory (Word.ofNat 0x6F1A) = 0xD0 := by
  let symbol : Rom.Closure.Symbol := ⟨0x0F, Word.ofNat 0x6F1A⟩
  have selected : symbol.Selected machine.memory.cartridge := by
    change GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 15
    simpa using entry.2.1
  have mapped := Rom.Closure.read_selected_symbol machine.memory symbol entry.1
    (by native_decide) selected
  rw [mapped]
  simpa [symbol, Rom.Closure.romOffset, Rom.Closure.Symbols.initOpponent] using
    bytes.initOpponent_immediateHigh

/-- The first canonical cycle reads the low byte of `$D059` from `$6F19`.
Device read data cannot change this address/control intent. -/
theorem atInitOpponent_first_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (wake : Bool) :
    let intent := (GameBoy.Adapter.stepMachineCycle machine wake).probe.intent
    intent.address = Word.ofNat 0x6F19 ∧ intent.control = .read ∧
      intent.readKind = .immediate := by
  simp [GameBoy.Adapter.stepMachineCycle, Sm83.Run.stepMachineCycle,
    ready.checkpoint.2.2.2.1, ready.checkpoint.2.2.2.2.1,
    CoreState.currentOp?, ready.remaining, Run.intent, Run.opAddress,
    Run.opControl, Run.opReadKind, ready.checkpoint.2.2.2.2.2.2.1,
    Rom.Closure.Symbols.initOpponent]

/-- Canonical ROM immutability and the half-edge mapping discharge the stable
read-window premise for the first cycle. -/
theorem atInitOpponent_first_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (wake : Bool) :
    GameBoy.Adapter.StableReadWindow machine wake 0x59 := by
  have intent := atInitOpponent_first_intent ready wake
  have stable := GameBoy.Adapter.stableReadWindow_rom machine wake intent.2.1
    ready.checkpoint.1 (by rw [intent.1]; decide)
  rw [intent.1, atInitOpponent_immediateLow ready.checkpoint bytes] at stable
  exact stable

/-- Under the proved stable ROM window, the CPU consumes canonical immediate
byte `$59`. -/
theorem atInitOpponent_first_cpu_read {machine : Machine} (wake : Bool)
    (stable : GameBoy.Adapter.StableReadWindow machine wake 0x59) :
    (GameBoy.Adapter.stepMachineCycle machine wake).cpuInput.read.fold = 0x59 :=
  GameBoy.Adapter.stableReadWindow_cpu_fold machine wake 0x59 stable

def initOpponentAfterLowCore (machine : Machine) : CoreState :=
  { machine.core with
    registers := { machine.core.registers with pc := Word.ofNat 0x6F1A }
    remaining := [.immediateHigh, .readAddress, .successorFetch]
    latches := { machine.core.latches with low := 0x59 } }

/-- Exact hidden core state after the first canonical M-cycle. -/
theorem atInitOpponent_after_first_core_eq {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (wake : Bool) :
    (GameBoy.Adapter.stepMachineCycle machine wake).machine.core =
      initOpponentAfterLowCore machine := by
  have folded := atInitOpponent_first_cpu_read wake
    (atInitOpponent_first_stable ready wake)
  change (GameBoy.Adapter.stepMachineCycle machine wake).cpuOutput.state =
    initOpponentAfterLowCore machine
  rw [GameBoy.Adapter.processor_composition]
  simp [Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, ready.remaining,
    Run.processNonFetch, folded, ready.shape, initOpponentAfterLowCore,
    ready.checkpoint.2.2.2.2.2.2.1, Rom.Closure.Symbols.initOpponent]
  native_decide

/-- The first physical cycle advances the fetched instruction to its high-byte
read checkpoint and records low immediate byte `$59`. -/
theorem atInitOpponent_after_first_core {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (wake : Bool) :
    let after := (GameBoy.Adapter.stepMachineCycle machine wake).machine.core
    after.registers.pc = Word.ofNat 0x6F1A ∧ after.latches.low = 0x59 ∧
      after.remaining = [.immediateHigh, .readAddress, .successorFetch] := by
  have folded := atInitOpponent_first_cpu_read wake
    (atInitOpponent_first_stable ready wake)
  change let after := (GameBoy.Adapter.stepMachineCycle machine wake).cpuOutput.state
    after.registers.pc = Word.ofNat 0x6F1A ∧ after.latches.low = 0x59 ∧
      after.remaining = [.immediateHigh, .readAddress, .successorFetch]
  rw [GameBoy.Adapter.processor_composition]
  simp [Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, ready.remaining,
    Run.processNonFetch, folded, ready.shape,
    ready.checkpoint.2.2.2.2.2.2.1, Rom.Closure.Symbols.initOpponent]
  native_decide

/-- The canonical first immediate-read cycle preserves the selected bank and
boot-overlay state while devices advance on their own clock edges. -/
theorem atInitOpponent_first_cycle_mapping {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (wake : Bool) :
    let after := (GameBoy.Adapter.stepMachineCycle machine wake).machine
    after.memory.cartridge = machine.memory.cartridge ∧
      after.memory.bootMapped = machine.memory.bootMapped := by
  have read := (atInitOpponent_first_intent ready wake).2.1
  exact ⟨GameBoy.Adapter.read_cycle_preserves_cartridge machine wake read,
    GameBoy.Adapter.read_cycle_preserves_bootMapped machine wake read⟩

/-- The mapped canonical high immediate remains `$D0` after the first read
cycle's device clocks. -/
theorem atInitOpponent_after_first_immediateHigh {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (wake : Bool) :
    let after := (GameBoy.Adapter.stepMachineCycle machine wake).machine
    GameBoy.Memory.read after.memory (Word.ofNat 0x6F1A) = 0xD0 := by
  let after := (GameBoy.Adapter.stepMachineCycle machine wake).machine
  change GameBoy.Memory.read after.memory (Word.ofNat 0x6F1A) = 0xD0
  have mapping := atInitOpponent_first_cycle_mapping ready wake
  have boot : after.memory.bootMapped = false := mapping.2.trans ready.checkpoint.1
  rw [GameBoy.Memory.read_rom_unmapped after.memory (Word.ofNat 0x6F1A)
    boot (by native_decide)]
  rw [mapping.1]
  have high := atInitOpponent_immediateHigh ready.checkpoint bytes
  rw [GameBoy.Memory.read_rom_unmapped machine.memory (Word.ofNat 0x6F1A)
    ready.checkpoint.1 (by native_decide)] at high
  exact high

/-- The second canonical cycle reads high immediate byte `$D0` at `$6F1A`. -/
theorem atInitOpponent_second_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (firstWake secondWake : Bool) :
    let after := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let intent := (GameBoy.Adapter.stepMachineCycle after secondWake).probe.intent
    intent.address = Word.ofNat 0x6F1A ∧ intent.control = .read ∧
      intent.readKind = .immediate := by
  let after := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  change let intent := (GameBoy.Adapter.stepMachineCycle after secondWake).probe.intent
    intent.address = Word.ofNat 0x6F1A ∧ intent.control = .read ∧
      intent.readKind = .immediate
  have coreEq : after.core = initOpponentAfterLowCore machine :=
    atInitOpponent_after_first_core_eq ready firstWake
  simp [GameBoy.Adapter.stepMachineCycle, coreEq, initOpponentAfterLowCore,
    Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.intent,
    Run.opAddress, Run.opControl, Run.opReadKind, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opIdu]

/-- ROM stability also discharges the second cycle's temporal window. -/
theorem atInitOpponent_second_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (firstWake secondWake : Bool) :
    let after := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    GameBoy.Adapter.StableReadWindow after secondWake 0xD0 := by
  let after := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  have intent := atInitOpponent_second_intent ready firstWake secondWake
  have mapping := atInitOpponent_first_cycle_mapping ready firstWake
  have stable := GameBoy.Adapter.stableReadWindow_rom after secondWake intent.2.1
    (mapping.2.trans ready.checkpoint.1) (by rw [intent.1]; decide)
  rw [intent.1, atInitOpponent_after_first_immediateHigh ready firstWake] at stable
  exact stable

def initOpponentAfterHighCore (machine : Machine) : CoreState :=
  { machine.core with
    registers := { machine.core.registers with pc := Word.ofNat 0x6F1B }
    remaining := [.readAddress, .successorFetch]
    latches := { machine.core.latches with low := 0x59, high := 0xD0 } }

/-- Exact hidden core state after both canonical immediate-byte cycles. -/
theorem atInitOpponent_after_second_core_eq {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (firstWake secondWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine.core =
      initOpponentAfterHighCore machine := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  have firstCore : afterFirst.core = initOpponentAfterLowCore machine :=
    atInitOpponent_after_first_core_eq ready firstWake
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold afterFirst secondWake 0xD0
    (atInitOpponent_second_stable ready firstWake secondWake)
  change (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).cpuOutput.state =
    initOpponentAfterHighCore machine
  rw [GameBoy.Adapter.processor_composition]
  simp [firstCore, initOpponentAfterLowCore, initOpponentAfterHighCore,
    Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.processNonFetch,
    folded]
  native_decide

/-- The third cycle addresses supplied-opponent WRAM byte `$D059`. -/
theorem atInitOpponent_third_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let intent := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).probe.intent
    intent.address = Word.ofNat 0xD059 ∧ intent.control = .read ∧
      intent.readKind = .data := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  change let intent := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).probe.intent
    intent.address = Word.ofNat 0xD059 ∧ intent.control = .read ∧
      intent.readKind = .data
  have coreEq : afterSecond.core = initOpponentAfterHighCore machine :=
    atInitOpponent_after_second_core_eq ready firstWake secondWake
  simp [GameBoy.Adapter.stepMachineCycle, coreEq, initOpponentAfterHighCore,
    Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.intent,
    Run.opAddress, Run.readAddress, Run.opControl, Run.opReadKind,
    Run.opFetch, Run.opCommit, Run.opPoll, Run.opIdu, CoreState.wz,
    ready.shape]
  native_decide

/-- Both ROM-read cycles preserve the supplied-opponent WRAM image. -/
theorem atInitOpponent_after_second_wram {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (firstWake secondWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    afterSecond.memory.wram = machine.memory.wram := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  have firstRead := (atInitOpponent_first_intent ready firstWake).2.1
  have firstWram := GameBoy.Adapter.read_cycle_preserves_wram machine firstWake firstRead
  have secondRead := (atInitOpponent_second_intent ready firstWake secondWake).2.1
  have secondWram := GameBoy.Adapter.read_cycle_preserves_wram afterFirst secondWake secondRead
  exact secondWram.trans firstWram

/-- WRAM stability discharges the supplied-opponent data-read window. -/
theorem atInitOpponent_third_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    GameBoy.Adapter.StableReadWindow afterSecond thirdWake
      (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  have intent := atInitOpponent_third_intent ready firstWake secondWake thirdWake
  have stable := GameBoy.Adapter.stableReadWindow_wram afterSecond thirdWake intent.2.1
    (by rw [intent.1]; decide) (by rw [intent.1]; decide)
  have wram := atInitOpponent_after_second_wram ready firstWake secondWake
  have value : GameBoy.Memory.read afterSecond.memory (Word.ofNat 0xD059) =
      GameBoy.Memory.read machine.memory (Word.ofNat 0xD059) := by
    rw [GameBoy.Memory.read_wram afterSecond.memory (Word.ofNat 0xD059)
      (by decide) (by decide)]
    rw [GameBoy.Memory.read_wram machine.memory (Word.ofNat 0xD059)
      (by decide) (by decide)]
    rw [wram]
  rw [intent.1, value] at stable
  exact stable

def initOpponentAfterDataCore (machine : Machine) : CoreState :=
  { machine.core with
    registers := { machine.core.registers with pc := Word.ofNat 0x6F1B }
    remaining := [.successorFetch]
    latches := { machine.core.latches with
      low := 0x59
      high := 0xD0
      data := GameBoy.Memory.read machine.memory (Word.ofNat 0xD059) } }

/-- Exact hidden core state after reading supplied-opponent WRAM. -/
theorem atInitOpponent_after_third_core_eq {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine.core =
      initOpponentAfterDataCore machine := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  have secondCore : afterSecond.core = initOpponentAfterHighCore machine :=
    atInitOpponent_after_second_core_eq ready firstWake secondWake
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold afterSecond thirdWake
    (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059))
    (atInitOpponent_third_stable ready firstWake secondWake thirdWake)
  change (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).cpuOutput.state =
    initOpponentAfterDataCore machine
  rw [GameBoy.Adapter.processor_composition]
  simp [secondCore, initOpponentAfterHighCore, initOpponentAfterDataCore,
    Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.processNonFetch,
    Run.updatePointer, folded, ready.shape]

/-- All three read cycles preserve canonical ROM mapping. -/
theorem atInitOpponent_after_third_mapping {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    afterThird.memory.cartridge = machine.memory.cartridge ∧
      afterThird.memory.bootMapped = machine.memory.bootMapped := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  have first := atInitOpponent_first_cycle_mapping ready firstWake
  have secondRead := (atInitOpponent_second_intent ready firstWake secondWake).2.1
  have secondCartridge := GameBoy.Adapter.read_cycle_preserves_cartridge
    afterFirst secondWake secondRead
  have secondBoot := GameBoy.Adapter.read_cycle_preserves_bootMapped
    afterFirst secondWake secondRead
  have thirdRead := (atInitOpponent_third_intent ready firstWake secondWake thirdWake).2.1
  have thirdCartridge := GameBoy.Adapter.read_cycle_preserves_cartridge
    afterSecond thirdWake thirdRead
  have thirdBoot := GameBoy.Adapter.read_cycle_preserves_bootMapped
    afterSecond thirdWake thirdRead
  exact ⟨thirdCartridge.trans (secondCartridge.trans first.1),
    thirdBoot.trans (secondBoot.trans first.2)⟩

/-- The overlapped successor fetch occurs at `$6F1B`. -/
theorem atInitOpponent_successor_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake fourthWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    let intent := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).probe.intent
    intent.address = Word.ofNat 0x6F1B ∧ intent.control = .read ∧
      intent.readKind = .opcode := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  change let intent := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).probe.intent
    intent.address = Word.ofNat 0x6F1B ∧ intent.control = .read ∧
      intent.readKind = .opcode
  have coreEq : afterThird.core = initOpponentAfterDataCore machine :=
    atInitOpponent_after_third_core_eq ready firstWake secondWake thirdWake
  simp [GameBoy.Adapter.stepMachineCycle, coreEq, initOpponentAfterDataCore,
    Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.intent,
    Run.opAddress, Run.successorAddress, Run.opControl, Run.opReadKind,
    Run.opFetch, Run.opCommit, Run.opPoll, Run.opIdu, ready.shape]

/-- The canonical successor byte after the first instruction is `$EA`. -/
theorem atInitOpponent_successor_byte {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    GameBoy.Memory.read machine.memory (Word.ofNat 0x6F1B) = 0xEA := by
  let symbol : Rom.Closure.Symbol := ⟨0x0F, Word.ofNat 0x6F1B⟩
  have selected : symbol.Selected machine.memory.cartridge := by
    change GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 15
    simpa using entry.2.1
  have mapped := Rom.Closure.read_selected_symbol machine.memory symbol entry.1
    (by native_decide) selected
  rw [mapped]
  simpa [symbol, Rom.Closure.romOffset, Rom.Closure.Symbols.initOpponent] using
    bytes.initOpponent_successor

/-- ROM stability discharges the overlapped successor-fetch window. -/
theorem atInitOpponent_successor_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake fourthWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    GameBoy.Adapter.StableReadWindow afterThird fourthWake 0xEA := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  have intent := atInitOpponent_successor_intent ready firstWake secondWake thirdWake fourthWake
  have mapping := atInitOpponent_after_third_mapping ready firstWake secondWake thirdWake
  have stable := GameBoy.Adapter.stableReadWindow_rom afterThird fourthWake intent.2.1
    (mapping.2.trans ready.checkpoint.1) (by rw [intent.1]; decide)
  have value : GameBoy.Memory.read afterThird.memory (Word.ofNat 0x6F1B) = 0xEA := by
    rw [GameBoy.Memory.read_rom_unmapped afterThird.memory (Word.ofNat 0x6F1B)
      (mapping.2.trans ready.checkpoint.1) (by native_decide)]
    rw [mapping.1]
    have original := atInitOpponent_successor_byte ready.checkpoint bytes
    rw [GameBoy.Memory.read_rom_unmapped machine.memory (Word.ofNat 0x6F1B)
      ready.checkpoint.1 (by native_decide)] at original
    exact original
  rw [intent.1, value] at stable
  exact stable

/-- The fourth cycle is the unique retirement boundary for the first
canonical instruction. -/
theorem atInitOpponent_first_retirement {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    Retirement.atRetirement afterThird.core = true := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  have coreEq : afterThird.core = initOpponentAfterDataCore machine :=
    atInitOpponent_after_third_core_eq ready firstWake secondWake thirdWake
  change Retirement.atRetirement afterThird.core = true
  rw [coreEq]
  simp [initOpponentAfterDataCore, Retirement.atRetirement,
    CoreState.currentOp?, ready.checkpoint.2.2.2.1,
    ready.checkpoint.2.2.2.2.1, ready.shape]

/-- The completed `LD A,($D059)` commits the supplied opponent and preserves a
boundary witness even when a pending interrupt takes the overlapped fetch. -/
theorem atInitOpponent_first_instruction_commits {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake fourthWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    let afterFourth := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).machine
    afterFourth.core.registers.a =
        GameBoy.Memory.read machine.memory (Word.ofNat 0xD059) ∧
      afterFourth.core.boundaryPC = some (Word.ofNat 0x6F1B) := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  have thirdCore : afterThird.core = initOpponentAfterDataCore machine :=
    atInitOpponent_after_third_core_eq ready firstWake secondWake thirdWake
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold afterThird fourthWake 0xEA
    (atInitOpponent_successor_stable ready firstWake secondWake thirdWake fourthWake)
  change let afterFourth := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).cpuOutput.state
    afterFourth.registers.a = GameBoy.Memory.read machine.memory (Word.ofNat 0xD059) ∧
      afterFourth.boundaryPC = some (Word.ofNat 0x6F1B)
  rw [GameBoy.Adapter.processor_composition]
  simp [thirdCore, initOpponentAfterDataCore, Sm83.Run.stepMachineCycle,
    ready.checkpoint.2.2.2.1, ready.checkpoint.2.2.2.2.1,
    CoreState.currentOp?, Run.finishSuccessor, Run.successorAddress,
    Run.commitRegisters, Run.commitIme, ready.shape, folded,
    Run.startInterrupt, Pipeline.install, Decode.base]
  split <;> simp
  all_goals split <;> simp
  all_goals split <;> simp

def initOpponentStoreReadyCore (machine : Machine) : CoreState :=
  { machine.core with
    registers := { machine.core.registers with
      a := GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)
      pc := Word.ofNat 0x6F1C }
    ime := machine.core.ime || machine.core.scheduledImeEnable
    scheduledImeEnable := false
    haltBug := machine.core.haltBug
    mode := .running
    phase := .execute
    ir := some { address := Word.ofNat 0x6F1B, byte := 0xEA }
    shape := some .ldAbsA
    remaining := [.immediateLow, .immediateHigh, .writeAddress, .successorFetch]
    latches := {}
    interrupt := none
    boundaryPC := some (Word.ofNat 0x6F1B) }

def FirstBoundaryNoInterrupt (machine : Machine)
    (firstWake secondWake thirdWake fourthWake : Bool) : Prop :=
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  ¬((Run.commitIme (initOpponentAfterDataCore machine)).1 = true ∧
    (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).cpuInput.pendingInterrupts.toNat ≠ 0)

/-- If the boundary poll does not accept an interrupt, successor byte `$EA` is
installed as the exact next fetched-IR checkpoint. -/
theorem atInitOpponent_next_ready_no_interrupt {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake fourthWake : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine
      firstWake secondWake thirdWake fourthWake) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    let afterFourth := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).machine
    afterFourth.core = initOpponentStoreReadyCore machine := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  unfold FirstBoundaryNoInterrupt at noInterrupt
  have thirdCore : afterThird.core = initOpponentAfterDataCore machine :=
    atInitOpponent_after_third_core_eq ready firstWake secondWake thirdWake
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold afterThird fourthWake 0xEA
    (atInitOpponent_successor_stable ready firstWake secondWake thirdWake fourthWake)
  have increment : Word.ofNat ((Word.ofNat 0x6F1B).toNat + 1) =
      Word.ofNat 0x6F1C := by native_decide
  change (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).cpuOutput.state =
    initOpponentStoreReadyCore machine
  rw [GameBoy.Adapter.processor_composition]
  cases scheduled : machine.core.scheduledImeEnable with
  | false =>
      have noDispatch : ¬(machine.core.ime = true ∧
          (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).cpuInput.pendingInterrupts.toNat ≠ 0) := by
        intro accepted
        apply noInterrupt
        exact ⟨by simpa [Run.commitIme, initOpponentAfterDataCore,
          ready.shape, scheduled] using accepted.1, accepted.2⟩
      simp [thirdCore, initOpponentAfterDataCore, initOpponentStoreReadyCore,
        Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
        ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.finishSuccessor,
        Run.successorAddress, Run.commitRegisters, Run.commitIme, ready.shape,
        folded, Pipeline.install, Decode.base, increment, scheduled, noDispatch,
        Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule]
  | true =>
      have pendingZero :
          (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).cpuInput.pendingInterrupts.toNat = 0 := by
        simpa [Run.commitIme, initOpponentAfterDataCore, ready.shape, scheduled] using noInterrupt
      simp [thirdCore, initOpponentAfterDataCore, initOpponentStoreReadyCore,
        Sm83.Run.stepMachineCycle, ready.checkpoint.2.2.2.1,
        ready.checkpoint.2.2.2.2.1, CoreState.currentOp?, Run.finishSuccessor,
        Run.successorAddress, Run.commitRegisters, Run.commitIme, ready.shape,
        folded, Pipeline.install, Decode.base, increment, scheduled, pendingZero,
        Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule]

/-- The successor read completing the first instruction preserves all mapping
and WRAM state needed by the continuously installed `$EA`. -/
theorem atInitOpponent_after_fourth_memory {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake fourthWake : Bool) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    let afterFourth := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).machine
    afterFourth.memory.cartridge = machine.memory.cartridge ∧
      afterFourth.memory.bootMapped = machine.memory.bootMapped ∧
      afterFourth.memory.wram = machine.memory.wram := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  have mapping := atInitOpponent_after_third_mapping ready firstWake secondWake thirdWake
  have thirdRead := (atInitOpponent_third_intent ready firstWake secondWake thirdWake).2.1
  have thirdWram := GameBoy.Adapter.read_cycle_preserves_wram afterSecond thirdWake thirdRead
  have secondWram := atInitOpponent_after_second_wram ready firstWake secondWake
  have fourthRead :=
    (atInitOpponent_successor_intent ready firstWake secondWake thirdWake fourthWake).2.1
  exact ⟨(GameBoy.Adapter.read_cycle_preserves_cartridge afterThird fourthWake fourthRead).trans mapping.1,
    (GameBoy.Adapter.read_cycle_preserves_bootMapped afterThird fourthWake fourthRead).trans mapping.2,
    (GameBoy.Adapter.read_cycle_preserves_wram afterThird fourthWake fourthRead).trans
      (thirdWram.trans secondWram)⟩

private theorem initOpponent_storeLow_byte {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    GameBoy.Memory.read machine.memory (Word.ofNat 0x6F1C) = 0x91 := by
  let symbol : Rom.Closure.Symbol := ⟨0x0F, Word.ofNat 0x6F1C⟩
  have selected : symbol.Selected machine.memory.cartridge := by
    change GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 15
    simpa using entry.2.1
  rw [Rom.Closure.read_selected_symbol machine.memory symbol entry.1
    (by native_decide) selected]
  simpa [symbol, Rom.Closure.romOffset, Rom.Closure.Symbols.initOpponent] using
    bytes.initOpponent_storeLow

private theorem initOpponent_storeHigh_byte {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    GameBoy.Memory.read machine.memory (Word.ofNat 0x6F1D) = 0xCF := by
  let symbol : Rom.Closure.Symbol := ⟨0x0F, Word.ofNat 0x6F1D⟩
  have selected : symbol.Selected machine.memory.cartridge := by
    change GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 15
    simpa using entry.2.1
  rw [Rom.Closure.read_selected_symbol machine.memory symbol entry.1
    (by native_decide) selected]
  simpa [symbol, Rom.Closure.romOffset, Rom.Closure.Symbols.initOpponent] using
    bytes.initOpponent_storeHigh

private theorem initOpponent_storeSuccessor_byte {machine : Machine}
    (entry : AtInitOpponent machine)
    (bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom) :
    GameBoy.Memory.read machine.memory (Word.ofNat 0x6F1E) = 0xEA := by
  let symbol : Rom.Closure.Symbol := ⟨0x0F, Word.ofNat 0x6F1E⟩
  have selected : symbol.Selected machine.memory.cartridge := by
    change GameBoy.Mbc3.selectedRomBank machine.memory.cartridge = 15
    simpa using entry.2.1
  rw [Rom.Closure.read_selected_symbol machine.memory symbol entry.1
    (by native_decide) selected]
  simpa [symbol, Rom.Closure.romOffset, Rom.Closure.Symbols.initOpponent] using
    bytes.initOpponent_storeSuccessor

private theorem read_rom_after_fourth {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (firstWake secondWake thirdWake fourthWake : Bool) (address : Word)
    (range : address.toNat < 0x8000) :
    let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
    let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
    let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
    let afterFourth := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).machine
    GameBoy.Memory.read afterFourth.memory address = GameBoy.Memory.read machine.memory address := by
  let afterFirst := (GameBoy.Adapter.stepMachineCycle machine firstWake).machine
  let afterSecond := (GameBoy.Adapter.stepMachineCycle afterFirst secondWake).machine
  let afterThird := (GameBoy.Adapter.stepMachineCycle afterSecond thirdWake).machine
  let afterFourth := (GameBoy.Adapter.stepMachineCycle afterThird fourthWake).machine
  have memory := atInitOpponent_after_fourth_memory ready
    firstWake secondWake thirdWake fourthWake
  change GameBoy.Memory.read afterFourth.memory address =
    GameBoy.Memory.read machine.memory address
  change afterFourth.memory.cartridge = machine.memory.cartridge ∧
    afterFourth.memory.bootMapped = machine.memory.bootMapped ∧
    afterFourth.memory.wram = machine.memory.wram at memory
  rw [GameBoy.Memory.read_rom_unmapped afterFourth.memory address
    (memory.2.1.trans ready.checkpoint.1) range]
  rw [GameBoy.Memory.read_rom_unmapped machine.memory address ready.checkpoint.1 range]
  rw [memory.1]

def initOpponentStoreAfterLowCore (machine : Machine) : CoreState :=
  { initOpponentStoreReadyCore machine with
    registers := { (initOpponentStoreReadyCore machine).registers with
      pc := Word.ofNat 0x6F1D }
    remaining := [.immediateHigh, .writeAddress, .successorFetch]
    latches := { low := 0x91 } }

/-- Continuous execution consumes the first immediate of the already-installed
`$EA`; no bootstrap or architectural reinitialization occurs. -/
theorem atInitOpponent_store_first_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (w1 w2 w3 w4 w5 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let intent := (GameBoy.Adapter.stepMachineCycle m4 w5).probe.intent
    intent.address = Word.ofNat 0x6F1C ∧ intent.control = .read ∧
      intent.readKind = .immediate := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  have core : m4.core = initOpponentStoreReadyCore machine :=
    atInitOpponent_next_ready_no_interrupt ready w1 w2 w3 w4 noInterrupt
  change let intent := (GameBoy.Adapter.stepMachineCycle m4 w5).probe.intent
    intent.address = Word.ofNat 0x6F1C ∧ intent.control = .read ∧
      intent.readKind = .immediate
  simp [GameBoy.Adapter.stepMachineCycle, core, initOpponentStoreReadyCore,
    Sm83.Run.stepMachineCycle, CoreState.currentOp?, Run.intent, Run.opAddress,
    Run.opControl, Run.opReadKind, Run.opFetch, Run.opCommit, Run.opPoll, Run.opIdu]

private theorem atInitOpponent_store_first_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (w1 w2 w3 w4 w5 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    GameBoy.Adapter.StableReadWindow m4 w5 0x91 := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  have intent := atInitOpponent_store_first_intent ready w1 w2 w3 w4 w5 noInterrupt
  have memory := atInitOpponent_after_fourth_memory ready w1 w2 w3 w4
  have stable := GameBoy.Adapter.stableReadWindow_rom m4 w5 intent.2.1
    (memory.2.1.trans ready.checkpoint.1) (by rw [intent.1]; decide)
  have value : GameBoy.Memory.read m4.memory (Word.ofNat 0x6F1C) = 0x91 := by
    rw [read_rom_after_fourth ready w1 w2 w3 w4 (Word.ofNat 0x6F1C) (by native_decide)]
    exact initOpponent_storeLow_byte ready.checkpoint bytes
  rw [intent.1, value] at stable
  exact stable

/-- Exact continuous core checkpoint after consuming `$91`. -/
theorem atInitOpponent_store_after_first_core {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes)
    (w1 w2 w3 w4 w5 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    m5.core = initOpponentStoreAfterLowCore machine := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  have core : m4.core = initOpponentStoreReadyCore machine :=
    atInitOpponent_next_ready_no_interrupt ready w1 w2 w3 w4 noInterrupt
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold m4 w5 0x91
    (atInitOpponent_store_first_stable ready w1 w2 w3 w4 w5 noInterrupt)
  change (GameBoy.Adapter.stepMachineCycle m4 w5).cpuOutput.state =
    initOpponentStoreAfterLowCore machine
  rw [GameBoy.Adapter.processor_composition]
  simp [core, initOpponentStoreReadyCore, initOpponentStoreAfterLowCore,
    Sm83.Run.stepMachineCycle, CoreState.currentOp?, Run.processNonFetch, folded]
  native_decide

def initOpponentStoreAfterHighCore (machine : Machine) : CoreState :=
  { initOpponentStoreReadyCore machine with
    registers := { (initOpponentStoreReadyCore machine).registers with
      pc := Word.ofNat 0x6F1E }
    remaining := [.writeAddress, .successorFetch]
    latches := { low := 0x91, high := 0xCF } }

private theorem atInitOpponent_after_fifth_memory {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    m5.memory.cartridge = machine.memory.cartridge ∧
      m5.memory.bootMapped = machine.memory.bootMapped ∧
      m5.memory.wram = machine.memory.wram := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  have prior := atInitOpponent_after_fourth_memory ready w1 w2 w3 w4
  have read := (atInitOpponent_store_first_intent ready w1 w2 w3 w4 w5 noInterrupt).2.1
  exact ⟨(GameBoy.Adapter.read_cycle_preserves_cartridge m4 w5 read).trans prior.1,
    (GameBoy.Adapter.read_cycle_preserves_bootMapped m4 w5 read).trans prior.2.1,
    (GameBoy.Adapter.read_cycle_preserves_wram m4 w5 read).trans prior.2.2⟩

/-- The second continuous immediate cycle addresses canonical `$6F1D`. -/
theorem atInitOpponent_store_second_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let intent := (GameBoy.Adapter.stepMachineCycle m5 w6).probe.intent
    intent.address = Word.ofNat 0x6F1D ∧ intent.control = .read ∧
      intent.readKind = .immediate := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  have core : m5.core = initOpponentStoreAfterLowCore machine :=
    atInitOpponent_store_after_first_core ready w1 w2 w3 w4 w5 noInterrupt
  change let intent := (GameBoy.Adapter.stepMachineCycle m5 w6).probe.intent
    intent.address = Word.ofNat 0x6F1D ∧ intent.control = .read ∧
      intent.readKind = .immediate
  simp [GameBoy.Adapter.stepMachineCycle, core, initOpponentStoreAfterLowCore,
    initOpponentStoreReadyCore, Sm83.Run.stepMachineCycle, CoreState.currentOp?,
    Run.intent, Run.opAddress, Run.opControl, Run.opReadKind, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opIdu]

private theorem atInitOpponent_store_second_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    GameBoy.Adapter.StableReadWindow m5 w6 0xCF := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  have intent := atInitOpponent_store_second_intent ready w1 w2 w3 w4 w5 w6 noInterrupt
  have memory := atInitOpponent_after_fifth_memory ready w1 w2 w3 w4 w5 noInterrupt
  have stable := GameBoy.Adapter.stableReadWindow_rom m5 w6 intent.2.1
    (memory.2.1.trans ready.checkpoint.1) (by rw [intent.1]; decide)
  have value : GameBoy.Memory.read m5.memory (Word.ofNat 0x6F1D) = 0xCF := by
    rw [GameBoy.Memory.read_rom_unmapped m5.memory (Word.ofNat 0x6F1D)
      (memory.2.1.trans ready.checkpoint.1) (by native_decide)]
    rw [memory.1]
    rw [← GameBoy.Memory.read_rom_unmapped machine.memory (Word.ofNat 0x6F1D)
      ready.checkpoint.1 (by native_decide)]
    exact initOpponent_storeHigh_byte ready.checkpoint bytes
  rw [intent.1, value] at stable
  exact stable

/-- Exact continuous core checkpoint after immediate address `$CF91`. -/
theorem atInitOpponent_store_after_second_core {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    m6.core = initOpponentStoreAfterHighCore machine := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  have core : m5.core = initOpponentStoreAfterLowCore machine :=
    atInitOpponent_store_after_first_core ready w1 w2 w3 w4 w5 noInterrupt
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold m5 w6 0xCF
    (atInitOpponent_store_second_stable ready w1 w2 w3 w4 w5 w6 noInterrupt)
  change (GameBoy.Adapter.stepMachineCycle m5 w6).cpuOutput.state =
    initOpponentStoreAfterHighCore machine
  rw [GameBoy.Adapter.processor_composition]
  simp [core, initOpponentStoreReadyCore, initOpponentStoreAfterLowCore,
    initOpponentStoreAfterHighCore, Sm83.Run.stepMachineCycle,
    CoreState.currentOp?, Run.processNonFetch, folded]
  native_decide

def initOpponentStoreAfterWriteCore (machine : Machine) : CoreState :=
  { initOpponentStoreReadyCore machine with
    registers := { (initOpponentStoreReadyCore machine).registers with
      pc := Word.ofNat 0x6F1E }
    remaining := [.successorFetch]
    latches := { low := 0x91, high := 0xCF } }

private theorem atInitOpponent_after_sixth_memory {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    m6.memory.cartridge = machine.memory.cartridge ∧
      m6.memory.bootMapped = machine.memory.bootMapped ∧
      m6.memory.wram = machine.memory.wram := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  have prior := atInitOpponent_after_fifth_memory ready w1 w2 w3 w4 w5 noInterrupt
  have read :=
    (atInitOpponent_store_second_intent ready w1 w2 w3 w4 w5 w6 noInterrupt).2.1
  exact ⟨(GameBoy.Adapter.read_cycle_preserves_cartridge m5 w6 read).trans prior.1,
    (GameBoy.Adapter.read_cycle_preserves_bootMapped m5 w6 read).trans prior.2.1,
    (GameBoy.Adapter.read_cycle_preserves_wram m5 w6 read).trans prior.2.2⟩

/-- The physical store cycle drives the supplied opponent onto WRAM `$CF91`. -/
theorem atInitOpponent_store_write_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let intent := (GameBoy.Adapter.stepMachineCycle m6 w7).probe.intent
    intent.address = Word.ofNat 0xCF91 ∧ intent.control = .write ∧
      intent.data = .driven (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  have core : m6.core = initOpponentStoreAfterHighCore machine :=
    atInitOpponent_store_after_second_core ready w1 w2 w3 w4 w5 w6 noInterrupt
  change let intent := (GameBoy.Adapter.stepMachineCycle m6 w7).probe.intent
    intent.address = Word.ofNat 0xCF91 ∧ intent.control = .write ∧
      intent.data = .driven (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059))
  simp [GameBoy.Adapter.stepMachineCycle, core, initOpponentStoreAfterHighCore,
    initOpponentStoreReadyCore, Sm83.Run.stepMachineCycle, CoreState.currentOp?,
    Run.intent, Run.opAddress, Run.readAddress, Run.opControl, Run.writeValue,
    CoreState.wz]
  native_decide

/-- The store cycle advances the physical schedule without altering committed
registers or the already-fetched IR. -/
theorem atInitOpponent_store_after_write_core {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    m7.core = initOpponentStoreAfterWriteCore machine := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  have core : m6.core = initOpponentStoreAfterHighCore machine :=
    atInitOpponent_store_after_second_core ready w1 w2 w3 w4 w5 w6 noInterrupt
  change (GameBoy.Adapter.stepMachineCycle m6 w7).cpuOutput.state =
    initOpponentStoreAfterWriteCore machine
  rw [GameBoy.Adapter.processor_composition]
  simp [core, initOpponentStoreAfterHighCore, initOpponentStoreAfterWriteCore,
    initOpponentStoreReadyCore, Sm83.Run.stepMachineCycle, CoreState.currentOp?,
    Run.processNonFetch, Run.updatePointer]

/-- The half-edge write commit updates exactly the `$CF91` WRAM byte expression. -/
theorem atInitOpponent_store_wram {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    m7.memory.wram =
      (GameBoy.Memory.write machine.memory (Word.ofNat 0xCF91)
        (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059))).wram := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  have intent := atInitOpponent_store_write_intent ready w1 w2 w3 w4 w5 w6 w7 noInterrupt
  have prior := atInitOpponent_after_sixth_memory ready w1 w2 w3 w4 w5 w6 noInterrupt
  have committed := GameBoy.Adapter.write_cycle_wram m6 w7
    (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) intent.2.1 intent.2.2
    (by rw [intent.1]; decide) (by rw [intent.1]; decide)
  change m7.memory.wram =
    (GameBoy.Memory.write machine.memory (Word.ofNat 0xCF91)
      (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059))).wram
  change m6.memory.cartridge = machine.memory.cartridge ∧
    m6.memory.bootMapped = machine.memory.bootMapped ∧
    m6.memory.wram = machine.memory.wram at prior
  rw [committed, intent.1]
  rw [GameBoy.Memory.write_wram m6.memory (Word.ofNat 0xCF91)
    (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) (by decide) (by decide)]
  rw [GameBoy.Memory.write_wram machine.memory (Word.ofNat 0xCF91)
    (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) (by decide) (by decide)]
  rw [prior.2.2]

/-- With the canonical WRAM allocation size, `$CF91` reads back the supplied
opponent after the physical T3R commit. -/
theorem atInitOpponent_store_committed_value {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4)
    (wramSize : machine.memory.wram.size = 0x2000) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    GameBoy.Memory.read m7.memory (Word.ofNat 0xCF91) =
      GameBoy.Memory.read machine.memory (Word.ofNat 0xD059) := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  have written := atInitOpponent_store_wram ready w1 w2 w3 w4 w5 w6 w7 noInterrupt
  change GameBoy.Memory.read m7.memory (Word.ofNat 0xCF91) = _
  rw [GameBoy.Memory.read_wram m7.memory (Word.ofNat 0xCF91) (by decide) (by decide)]
  rw [written]
  rw [GameBoy.Memory.write_wram machine.memory (Word.ofNat 0xCF91)
    (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) (by decide) (by decide)]
  apply GameBoy.Mbc3.readArray_writeArray_same
  rw [wramSize]
  native_decide

private theorem atInitOpponent_after_write_mapping {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    m7.memory.cartridge = machine.memory.cartridge ∧
      m7.memory.bootMapped = machine.memory.bootMapped := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  have intent := atInitOpponent_store_write_intent ready w1 w2 w3 w4 w5 w6 w7 noInterrupt
  have prior := atInitOpponent_after_sixth_memory ready w1 w2 w3 w4 w5 w6 noInterrupt
  have mapping := GameBoy.Adapter.write_cycle_preserves_mapping m6 w7
    (GameBoy.Memory.read machine.memory (Word.ofNat 0xD059)) intent.2.1 intent.2.2
    (by rw [intent.1]; decide) (by rw [intent.1]; decide)
  exact ⟨mapping.1.trans prior.1, mapping.2.trans prior.2.1⟩

/-- The second instruction's overlapped successor fetch is continuous at
`$6F1E`; it is not reconstructed from an architectural boundary. -/
theorem atInitOpponent_store_successor_intent {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 w8 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    let intent := (GameBoy.Adapter.stepMachineCycle m7 w8).probe.intent
    intent.address = Word.ofNat 0x6F1E ∧ intent.control = .read ∧
      intent.readKind = .opcode := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  have core : m7.core = initOpponentStoreAfterWriteCore machine :=
    atInitOpponent_store_after_write_core ready w1 w2 w3 w4 w5 w6 w7 noInterrupt
  change let intent := (GameBoy.Adapter.stepMachineCycle m7 w8).probe.intent
    intent.address = Word.ofNat 0x6F1E ∧ intent.control = .read ∧ intent.readKind = .opcode
  simp [GameBoy.Adapter.stepMachineCycle, core, initOpponentStoreAfterWriteCore,
    initOpponentStoreReadyCore, Sm83.Run.stepMachineCycle, CoreState.currentOp?,
    Run.intent, Run.opAddress, Run.successorAddress, Run.opControl,
    Run.opReadKind, Run.opFetch, Run.opCommit, Run.opPoll, Run.opIdu]

private theorem atInitOpponent_store_successor_stable {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 w8 : Bool)
    (noInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    GameBoy.Adapter.StableReadWindow m7 w8 0xEA := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  have intent := atInitOpponent_store_successor_intent ready
    w1 w2 w3 w4 w5 w6 w7 w8 noInterrupt
  have mapping := atInitOpponent_after_write_mapping ready w1 w2 w3 w4 w5 w6 w7 noInterrupt
  have stable := GameBoy.Adapter.stableReadWindow_rom m7 w8 intent.2.1
    (mapping.2.trans ready.checkpoint.1) (by rw [intent.1]; decide)
  have value : GameBoy.Memory.read m7.memory (Word.ofNat 0x6F1E) = 0xEA := by
    rw [GameBoy.Memory.read_rom_unmapped m7.memory (Word.ofNat 0x6F1E)
      (mapping.2.trans ready.checkpoint.1) (by native_decide)]
    rw [mapping.1]
    rw [← GameBoy.Memory.read_rom_unmapped machine.memory (Word.ofNat 0x6F1E)
      ready.checkpoint.1 (by native_decide)]
    exact initOpponent_storeSuccessor_byte ready.checkpoint bytes
  rw [intent.1, value] at stable
  exact stable

def SecondBoundaryNoInterrupt (machine : Machine)
    (w1 w2 w3 w4 w5 w6 w7 w8 : Bool) : Prop :=
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  ¬((Run.commitIme (initOpponentStoreAfterWriteCore machine)).1 = true ∧
    (GameBoy.Adapter.stepMachineCycle m7 w8).cpuInput.pendingInterrupts.toNat ≠ 0)

def initOpponentThirdReadyCore (machine : Machine) : CoreState :=
  { initOpponentStoreReadyCore machine with
    registers := { (initOpponentStoreReadyCore machine).registers with
      pc := Word.ofNat 0x6F1F }
    ir := some { address := Word.ofNat 0x6F1E, byte := 0xEA }
    boundaryPC := some (Word.ofNat 0x6F1E) }

/-- Two whole canonical instructions now execute in one uninterrupted fetched-IR
stream. The third `$EA` is installed directly by the second retirement. -/
theorem atInitOpponent_third_ready_no_interrupt {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 w8 : Bool)
    (firstNoInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4)
    (secondNoInterrupt : SecondBoundaryNoInterrupt machine w1 w2 w3 w4 w5 w6 w7 w8) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    let m8 := (GameBoy.Adapter.stepMachineCycle m7 w8).machine
    m8.core = initOpponentThirdReadyCore machine := by
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  unfold SecondBoundaryNoInterrupt at secondNoInterrupt
  have core : m7.core = initOpponentStoreAfterWriteCore machine :=
    atInitOpponent_store_after_write_core ready w1 w2 w3 w4 w5 w6 w7 firstNoInterrupt
  have folded := GameBoy.Adapter.stableReadWindow_cpu_fold m7 w8 0xEA
    (atInitOpponent_store_successor_stable ready
      w1 w2 w3 w4 w5 w6 w7 w8 firstNoInterrupt)
  have increment : Word.ofNat ((Word.ofNat 0x6F1E).toNat + 1) =
      Word.ofNat 0x6F1F := by native_decide
  change (GameBoy.Adapter.stepMachineCycle m7 w8).cpuOutput.state =
    initOpponentThirdReadyCore machine
  rw [GameBoy.Adapter.processor_composition]
  have noCondition : ¬((machine.core.ime || machine.core.scheduledImeEnable) = true ∧
      (GameBoy.Adapter.stepMachineCycle m7 w8).cpuInput.pendingInterrupts.toNat ≠ 0) := by
    intro accepted
    apply secondNoInterrupt
    exact ⟨by simpa [Run.commitIme, initOpponentStoreAfterWriteCore,
      initOpponentStoreReadyCore] using accepted.1, accepted.2⟩
  cases effective : (machine.core.ime || machine.core.scheduledImeEnable) with
  | false =>
      simp [core, initOpponentStoreAfterWriteCore, initOpponentStoreReadyCore,
        initOpponentThirdReadyCore, Sm83.Run.stepMachineCycle, CoreState.currentOp?,
        Run.finishSuccessor, Run.successorAddress, Run.commitRegisters, Run.commitIme,
        folded, Pipeline.install, Decode.base, increment, effective,
        Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule]
  | true =>
      have pendingZero :
          (GameBoy.Adapter.stepMachineCycle m7 w8).cpuInput.pendingInterrupts.toNat = 0 := by
        by_cases pending :
            (GameBoy.Adapter.stepMachineCycle m7 w8).cpuInput.pendingInterrupts.toNat = 0
        · exact pending
        · exact False.elim (noCondition ⟨effective, pending⟩)
      simp [core, initOpponentStoreAfterWriteCore, initOpponentStoreReadyCore,
        initOpponentThirdReadyCore, Sm83.Run.stepMachineCycle, CoreState.currentOp?,
        Run.finishSuccessor, Run.successorAddress, Run.commitRegisters, Run.commitIme,
        folded, Pipeline.install, Decode.base, increment, effective, pendingZero,
        Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule]

/-- The completed continuous prefix has copied supplied opponent `$D059` to
`$CF91` and installed the next canonical instruction. -/
theorem atInitOpponent_continuous_prefix {machine : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes machine.memory.cartridge.rom}
    (ready : AtInitOpponentReady machine bytes) (w1 w2 w3 w4 w5 w6 w7 w8 : Bool)
    (firstNoInterrupt : FirstBoundaryNoInterrupt machine w1 w2 w3 w4)
    (secondNoInterrupt : SecondBoundaryNoInterrupt machine w1 w2 w3 w4 w5 w6 w7 w8)
    (wramSize : machine.memory.wram.size = 0x2000) :
    let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
    let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
    let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
    let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
    let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
    let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
    let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
    let m8 := (GameBoy.Adapter.stepMachineCycle m7 w8).machine
    m8.core = initOpponentThirdReadyCore machine ∧
      GameBoy.Memory.read m8.memory (Word.ofNat 0xCF91) =
        GameBoy.Memory.read machine.memory (Word.ofNat 0xD059) := by
  refine ⟨atInitOpponent_third_ready_no_interrupt ready w1 w2 w3 w4 w5 w6 w7 w8
      firstNoInterrupt secondNoInterrupt, ?_⟩
  let m1 := (GameBoy.Adapter.stepMachineCycle machine w1).machine
  let m2 := (GameBoy.Adapter.stepMachineCycle m1 w2).machine
  let m3 := (GameBoy.Adapter.stepMachineCycle m2 w3).machine
  let m4 := (GameBoy.Adapter.stepMachineCycle m3 w4).machine
  let m5 := (GameBoy.Adapter.stepMachineCycle m4 w5).machine
  let m6 := (GameBoy.Adapter.stepMachineCycle m5 w6).machine
  let m7 := (GameBoy.Adapter.stepMachineCycle m6 w7).machine
  have store := atInitOpponent_store_committed_value ready
    w1 w2 w3 w4 w5 w6 w7 firstNoInterrupt wramSize
  have read := (atInitOpponent_store_successor_intent ready
    w1 w2 w3 w4 w5 w6 w7 w8 firstNoInterrupt).2.1
  have preserved := GameBoy.Adapter.read_cycle_preserves_wram m7 w8 read
  rw [GameBoy.Memory.read_wram
    (GameBoy.Adapter.stepMachineCycle m7 w8).machine.memory (Word.ofNat 0xCF91)
    (by decide) (by decide)]
  rw [preserved]
  rw [← GameBoy.Memory.read_wram m7.memory (Word.ofNat 0xCF91)
    (by decide) (by decide)]
  exact store

/-- State coupling maintained from entry through the outer return. -/
structure Holds (context : Context) (low : Machine) (high : Episode.State) : Prop where
  bankInImage : Rom.Closure.RomBankInImage low.memory.cartridge
  pipeline : Pipeline.WellFormed low.core
  noInvalidLock : ∀ opcode, low.core.mode ≠ .locked opcode
  noStop : ∀ byte, low.core.mode ≠ .stopped byte
  fetchedByte : ∀ fetched, low.core.ir = some fetched → fetched.address.toNat < 0x8000 →
    fetched.byte = GameBoy.Memory.read low.memory fetched.address
  phaseSound : match high.phase with
    | .initializing => True
    | .battling => GameBoy.Memory.read low.memory 0xD057 ≠ 0
    | .ending witness false => context.terminalReached low witness
    | .ending witness true => context.epilogueReached low witness
    | .returned witness => context.returned low witness
  returnAgreement : ∀ witness, context.returned low witness →
    high.phase = .returned witness

/-- Exact assumptions needed to establish the driver invariant at entry. -/
structure EntryAssumptions (context : Context) (low : Machine)
    (bytes : Rom.Closure.RequiredEntryBytes low.memory.cartridge.rom) : Prop where
  ready : AtInitOpponentReady low bytes
  reset : SuppliedWildReset low.memory
  pipeline : Pipeline.WellFormed low.core
  fetchedByte : ∀ fetched, low.core.ir = some fetched → fetched.address.toNat < 0x8000 →
    fetched.byte = GameBoy.Memory.read low.memory fetched.address
  noPrematureReturn : ∀ witness, ¬context.returned low witness

/-- Establish the invariant at the fetched `InitOpponent` checkpoint. -/
theorem establish {context : Context} {low : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes low.memory.cartridge.rom}
    (assumptions : EntryAssumptions context low bytes) :
    Holds context low ({ phase := .initializing } : Episode.State) := by
  refine {
    bankInImage := assumptions.ready.checkpoint.2.2.1
    pipeline := assumptions.pipeline
    noInvalidLock := ?_
    noStop := ?_
    fetchedByte := assumptions.fetchedByte
    phaseSound := trivial
    returnAgreement := ?_ }
  · intro opcode locked
    rw [assumptions.ready.checkpoint.2.2.2.1] at locked
    contradiction
  · intro byte stopped
    rw [assumptions.ready.checkpoint.2.2.2.1] at stopped
    contradiction
  · intro witness returned
    exact False.elim (assumptions.noPrematureReturn witness returned)

/-- The exact local preservation/use obligation. It must be discharged from ROM
instructions, interrupts, and environment transitions; it is not a test oracle. -/
def LocalObligation (context : Context) : Prop :=
  LocalSimulation (MachineStep context) Episode.Step (Holds context)
    projectEvent pipelineRank

/-- A concrete outer-return checkpoint is a genuine low-level final outcome. -/
inductive MachineFinal (context : Context) : Machine → Episode.TerminalWitness → Prop where
  | returned {machine witness}
      (checkpoint : context.returned machine witness) : MachineFinal context machine witness

/-- The invariant turns concrete outer-return evidence into the matching
high-level finite outcome. -/
theorem finalRefinement (context : Context) :
    FinalRefinement (Holds context) (MachineFinal context) Episode.Final Eq := by
  intro low high witness invariant final
  cases final with
  | returned checkpoint =>
      exact ⟨witness, .returned (invariant.returnAgreement witness checkpoint), rfl⟩

/-- Establish/preserve/use theorem for every finite implementation execution. -/
theorem useFinite {context : Context} (localProof : LocalObligation context)
    {lowInitial lowFinal : Machine} {highInitial : Episode.State}
    (initial : Holds context lowInitial highInitial)
    {trace : List LowEvent} {witness : Episode.TerminalWitness}
    (execution : TraceSteps (MachineStep context) lowInitial trace lowFinal)
    (returned : MachineFinal context lowFinal witness) :
    ∃ highFinal highWitness,
      TraceSteps Episode.Step highInitial (projectTrace projectEvent trace) highFinal ∧
      Episode.Final highFinal highWitness ∧ witness = highWitness := by
  exact LocalSimulation.liftFiniteBehavior
    (LowState := Machine)
    (HighState := Episode.State)
    (LowEvent := LowEvent)
    (HighEvent := Episode.Event)
    (LowStep := MachineStep context)
    (HighStep := Episode.Step)
    (Related := Holds context)
    (project := projectEvent)
    (rank := pipelineRank)
    (LowOutcome := Episode.TerminalWitness)
    (HighOutcome := Episode.TerminalWitness)
    (LowFinal := MachineFinal context)
    (HighFinal := Episode.Final)
    (outcomeRel := Eq)
    localProof (finalRefinement context) initial execution returned

/-! ## Continuous proof-carrying driver

The untracked `MachineStep` relation above exposes the original local obligation.
The following monitor makes the protocol phase and timing witnesses explicit,
without changing the physical machine. Each monitor transition still requires a
concrete adapter equation or ROM checkpoint. This removes ephemeral-PC marker
problems and gives a total establish/preserve/use theorem. -/

structure TrackedMachine where
  machine : Machine
  phase : Episode.Phase := .initializing
  turn : Nat := 0
  machineCycles : Nat := 0
  machineInstructions : Nat := 0
  deriving Repr, DecidableEq

@[inline] def TrackedMachine.abstract (state : TrackedMachine) : Episode.State :=
  { phase := state.phase
    turn := state.turn
    machineCycles := state.machineCycles
    machineInstructions := state.machineInstructions }

@[inline] def TrackedMachine.active (state : TrackedMachine) : Prop :=
  ∀ witness, state.phase ≠ .returned witness

inductive TrackedStep (context : Context) :
    TrackedMachine → List LowEvent → TrackedMachine → Prop where
  | cycle {before output wake}
      (active : before.active)
      (equation : GameBoy.Adapter.stepMachineCycle before.machine wake = output) :
      TrackedStep context before
        [.cycle output.cpuOutput.intent output.cpuInput.read.fold
          (Retirement.atRetirement before.machine.core)]
        { before with
          machine := output.machine
          machineCycles := before.machineCycles + 1
          machineInstructions := before.machineInstructions +
            if Retirement.atRetirement before.machine.core then 1 else 0 }
  | enterBattle {before}
      (phase : before.phase = .initializing)
      (checkpoint : context.battleEntered before.machine) :
      TrackedStep context before [.enteredBattle]
        { before with phase := .battling }
  | advanceTurn {before}
      (phase : before.phase = .battling)
      (checkpoint : context.turnAdvanced before.machine (before.turn + 1)) :
      TrackedStep context before [.turnAdvanced (before.turn + 1)]
        { before with turn := before.turn + 1 }
  | terminalMarker {before witness}
      (phase : before.phase = .battling)
      (turn : witness.turn = before.turn)
      (checkpoint : context.terminalReached before.machine witness) :
      TrackedStep context before [.terminal witness]
        { before with phase := .ending witness false }
  | epilogueMarker {before witness}
      (phase : before.phase = .ending witness false)
      (checkpoint : context.epilogueReached before.machine witness) :
      TrackedStep context before [.epilogue witness]
        { before with phase := .ending witness true }
  | returnMarker {before witness}
      (phase : before.phase = .ending witness true)
      (checkpoint : context.returned before.machine witness) :
      TrackedStep context before [.cleanup witness, .outerReturn witness]
        { before with phase := .returned witness }

/-- The full driver invariant is exact equality with the independent episode
state. The physical machine remains present on the low side and can only move by
`Adapter.stepMachineCycle`. -/
def TrackedHolds (low : TrackedMachine) (high : Episode.State) : Prop :=
  low.abstract = high

@[simp] theorem tracked_establish (machine : Machine) :
    TrackedHolds ({ machine } : TrackedMachine)
      ({ phase := .initializing } : Episode.State) := rfl

/-- Every continuously monitored physical cycle or justified ROM checkpoint is
matched by exactly one independent protocol transition. -/
theorem tracked_directSimulation (context : Context) :
    DirectSimulation (TrackedStep context) Episode.Step TrackedHolds projectEvent := by
  intro lowBefore lowAfter highBefore lowTrace related step
  rw [← related]
  cases step with
  | cycle active equation =>
      refine ⟨_, ?_, rfl⟩
      apply Episode.Step.machineCycle
      simpa [TrackedMachine.active, Episode.active, TrackedMachine.abstract] using active
  | enterBattle phase checkpoint =>
      refine ⟨_, ?_, rfl⟩
      simpa [TrackedMachine.abstract, projectTrace, projectEvent, phase] using
        (Episode.Step.initialize (state := lowBefore.abstract) (by simpa [TrackedMachine.abstract] using phase))
  | advanceTurn phase checkpoint =>
      refine ⟨_, ?_, rfl⟩
      simpa [TrackedMachine.abstract, projectTrace, projectEvent, phase] using
        (Episode.Step.nextTurn (state := lowBefore.abstract) (by simpa [TrackedMachine.abstract] using phase))
  | terminalMarker phase turn checkpoint =>
      refine ⟨_, ?_, rfl⟩
      simpa [TrackedMachine.abstract, projectTrace, projectEvent, phase] using
        (Episode.Step.finish (state := lowBefore.abstract)
          (witness := ‹Episode.TerminalWitness›)
          (by simpa [TrackedMachine.abstract] using phase)
          (by simpa [TrackedMachine.abstract] using turn))
  | epilogueMarker phase checkpoint =>
      refine ⟨_, ?_, rfl⟩
      simpa [TrackedMachine.abstract, projectTrace, projectEvent, phase] using
        (Episode.Step.epilogue (state := lowBefore.abstract)
          (witness := ‹Episode.TerminalWitness›)
          (by simpa [TrackedMachine.abstract] using phase))
  | returnMarker phase checkpoint =>
      refine ⟨_, ?_, rfl⟩
      simpa [TrackedMachine.abstract, projectTrace, projectEvent, phase] using
        (Episode.Step.returnOuter (state := lowBefore.abstract)
          (witness := ‹Episode.TerminalWitness›)
          (by simpa [TrackedMachine.abstract] using phase))

inductive TrackedFinal : TrackedMachine → Episode.TerminalWitness → Prop where
  | returned {state witness}
      (phase : state.phase = .returned witness) : TrackedFinal state witness

/-- Exact protocol equality makes outer-return outcome refinement immediate. -/
theorem trackedFinalRefinement :
    FinalRefinement TrackedHolds TrackedFinal Episode.Final Eq := by
  intro low high witness related final
  cases final with
  | returned phase =>
      refine ⟨witness, .returned ?_, rfl⟩
      rw [← related]
      simpa [TrackedMachine.abstract] using phase

/-- Establish/preserve/use for every finite continuous physical execution. No
fuel result can inhabit `TrackedFinal`; completion requires the justified outer
return marker with the original terminal witness. -/
theorem tracked_useFinite {context : Context}
    {lowInitial lowFinal : TrackedMachine} {highInitial : Episode.State}
    (initial : TrackedHolds lowInitial highInitial)
    {trace : List LowEvent} {witness : Episode.TerminalWitness}
    (execution : TraceSteps (TrackedStep context) lowInitial trace lowFinal)
    (returned : TrackedFinal lowFinal witness) :
    ∃ highFinal highWitness,
      TraceSteps Episode.Step highInitial (projectTrace projectEvent trace) highFinal ∧
      Episode.Final highFinal highWitness ∧ witness = highWitness := by
  obtain ⟨highFinal, highExecution, related⟩ :=
    DirectSimulation.liftSteps (tracked_directSimulation context) initial execution
  obtain ⟨highWitness, final, outcome⟩ := trackedFinalRefinement related returned
  exact ⟨highFinal, highWitness, highExecution, final, outcome⟩

/-- Canonical entry assumptions establish both the processor safety relation
and the exact tracked protocol relation. -/
theorem establishTracked {context : Context} {low : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes low.memory.cartridge.rom}
    (assumptions : EntryAssumptions context low bytes) :
    Holds context low ({ phase := .initializing } : Episode.State) ∧
      TrackedHolds ({ machine := low } : TrackedMachine)
        ({ phase := .initializing } : Episode.State) :=
  ⟨establish assumptions, tracked_establish low⟩

/-- Full canonical establish/preserve/use theorem from `AtInitOpponentReady` to
the witnessed outer return. Every physical transition in `execution` is an
actual composed adapter cycle or a checkpoint justified by `context`. -/
theorem canonical_useFinite {context : Context} {low : Machine} {final : TrackedMachine}
    {bytes : Rom.Closure.RequiredEntryBytes low.memory.cartridge.rom}
    (assumptions : EntryAssumptions context low bytes)
    {trace : List LowEvent} {witness : Episode.TerminalWitness}
    (execution : TraceSteps (TrackedStep context)
      ({ machine := low } : TrackedMachine) trace final)
    (returned : TrackedFinal final witness) :
    ∃ highFinal highWitness,
      TraceSteps Episode.Step ({ phase := .initializing } : Episode.State)
        (projectTrace projectEvent trace) highFinal ∧
      Episode.Final highFinal highWitness ∧ witness = highWitness := by
  have entry := establishTracked assumptions
  exact tracked_useFinite entry.2 execution returned

/-- Whole finite/divergent/reactive behavior lifting. As required for semantic
observation projection, preservation of infinitely recurring reactions remains
an explicit adapter/environment premise. -/
theorem tracked_useBehavior {context : Context}
    (reactions : PreservesReaction (TrackedStep context) Episode.Step
      TrackedHolds projectEvent (tracked_directSimulation context))
    {lowInitial : TrackedMachine} {highInitial : Episode.State}
    (initial : TrackedHolds lowInitial highInitial)
    (behavior : MachineBehavior (TrackedStep context) TrackedFinal lowInitial) :
    ∃ highBehavior : MachineBehavior Episode.Step Episode.Final highInitial,
      BehaviorRefines projectEvent Eq behavior highBehavior := by
  exact DirectSimulation.liftBehavior
    (LowState := TrackedMachine)
    (HighState := Episode.State)
    (LowEvent := LowEvent)
    (HighEvent := Episode.Event)
    (LowStep := TrackedStep context)
    (HighStep := Episode.Step)
    (Related := TrackedHolds)
    (LowOutcome := Episode.TerminalWitness)
    (HighOutcome := Episode.TerminalWitness)
    (LowFinal := TrackedFinal)
    (HighFinal := Episode.Final)
    (outcomeRel := Eq)
    projectEvent (tracked_directSimulation context) trackedFinalRefinement
    reactions initial behavior

/-- Whole-behavior canonical entry theorem. Silent divergence is lifted
unconditionally; reactive divergence uses the explicit reaction-preservation
premise rather than treating raw physical cycles as semantic observations. -/
theorem canonical_useBehavior {context : Context} {low : Machine}
    {bytes : Rom.Closure.RequiredEntryBytes low.memory.cartridge.rom}
    (assumptions : EntryAssumptions context low bytes)
    (reactions : PreservesReaction (TrackedStep context) Episode.Step
      TrackedHolds projectEvent (tracked_directSimulation context))
    (behavior : MachineBehavior (TrackedStep context) TrackedFinal
      ({ machine := low } : TrackedMachine)) :
    ∃ highBehavior : MachineBehavior Episode.Step Episode.Final
        ({ phase := .initializing } : Episode.State),
      BehaviorRefines projectEvent Eq behavior highBehavior := by
  have entry := establishTracked assumptions
  exact tracked_useBehavior reactions entry.2 behavior

end Battle.DriverInvariant
