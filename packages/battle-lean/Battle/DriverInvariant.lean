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
  | terminal (witness : Episode.TerminalWitness)
  | epilogue (witness : Episode.TerminalWitness)
  | outerReturn (witness : Episode.TerminalWitness)
  deriving Repr, DecidableEq

/-- Episode-specific checkpoints. The first concrete episode supplies these as
address/IR/WRAM/stack predicates and proves they are reached by ROM execution. -/
structure Context where
  returnAddress : Word
  initialSP : Word
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
      MachineStep context machine [.outerReturn witness] machine

/-- Processor/device events projected into the independent battle protocol. -/
def projectEvent : LowEvent → Option Episode.Event
  | .cycle intent value _ =>
      if intent.control = .read && intent.address = 0xFF04 then
        some (.observed (.rng "rDIV" value.toNat.toUInt8))
      else if intent.control = .read && intent.address = 0xFF00 then
        some (.observed (.input "rP1" value.toNat.toUInt8))
      else if intent.control = .read && intent.address = 0xFF01 then
        some (.observed (.input "rSB" value.toNat.toUInt8))
      else none
  | .terminal witness => some (.terminal witness)
  | .epilogue witness => some (.epilogue witness)
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

end Battle.DriverInvariant
