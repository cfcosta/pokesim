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
structure EntryAssumptions (context : Context) (low : Machine) : Prop where
  entry : AtInitOpponent low
  reset : SuppliedWildReset low.memory
  pipeline : Pipeline.WellFormed low.core
  fetchedByte : ∀ fetched, low.core.ir = some fetched → fetched.address.toNat < 0x8000 →
    fetched.byte = GameBoy.Memory.read low.memory fetched.address
  noPrematureReturn : ∀ witness, ¬context.returned low witness

/-- Establish the invariant at the fetched `InitOpponent` checkpoint. -/
theorem establish {context : Context} {low : Machine}
    (assumptions : EntryAssumptions context low) :
    Holds context low ({ phase := .initializing } : Episode.State) := by
  refine {
    bankInImage := assumptions.entry.2.2.1
    pipeline := assumptions.pipeline
    noInvalidLock := ?_
    noStop := ?_
    fetchedByte := assumptions.fetchedByte
    phaseSound := trivial
    returnAgreement := ?_ }
  · intro opcode locked
    rw [assumptions.entry.2.2.2.1] at locked
    contradiction
  · intro byte stopped
    rw [assumptions.entry.2.2.2.1] at stopped
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
