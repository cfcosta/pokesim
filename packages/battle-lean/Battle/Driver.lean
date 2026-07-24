/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram
import Battle.Checkpoint
import Sm83.Functional
import Sm83.Program
import Sm83.FlatMemory

/-!
# The ROM-trace driver (L0 oracle)

The driver runs `sm83-lean`'s verified functional core over an assembled battle
ROM image and reads the resulting memory back into the checkpoint trace. It is
the concrete realization of the oracle side of the Stage-0 differential: the
`read : RegionSpec → Bytes` that `Checkpoint.capture` abstracts over is here
"resolve the pokered symbol to an address and read the live emulated memory".

## What this module provides now, and what it awaits

The battle ROM and its symbol table are produced by `rgbds` (`.gb` + `.sym`),
which is not assembled in this checkout. So the driver is written against two
inputs it does not yet have concretely:

* a **memory image** — `List Sm83.Byte` loaded with `FlatMemory.ofList`, holding
  the routine's code bank and the initial WRAM;
* a **symbol map** — `SymbolMap`, binding each pokered WRAM/HRAM label to its
  linker-assigned absolute address, parsed from the `.sym` file.

Everything downstream of those inputs — setting up a `call`-style stack frame,
running to the routine's `ret` via `Program.runUntil`, and reading named regions
back out — is implemented and exercised here against a hand-assembled synthetic
program, so the machine coupling is validated end-to-end today. When `rgbds` is
available the same code drives the real ROM unchanged.

The flat-memory model is a single 64 KiB `Word → Byte` space; it is faithful for
routines that stay within one ROM bank (`CalculateDamage`, `BattleRandom`, the
per-turn residual handlers, …). Routines that bankswitch mid-run need the driver
to stage the relevant banks into the flat image — a later concern, flagged where
it bites.
-/

namespace Battle.Driver

open Sm83 Battle Battle.Wram

/-- A 16-bit absolute address, as the linker assigns and the `.sym` file lists. -/
abbrev Addr := UInt16

/-! ## Symbol resolution -/

/-- A resolved symbol table: pokered label → absolute address, parsed from the
    assembled `.sym` map. An association list — a few dozen battle symbols. -/
abbrev SymbolMap := List (String × Addr)

/-- Resolve a symbol to its address. -/
def SymbolMap.resolve (syms : SymbolMap) (symbol : String) : Option Addr :=
  (syms.find? (·.1 == symbol)).map (·.2)

/-! ## Byte-level memory access -/

/-- Narrow a machine byte (`BitVec 8`) to a capture byte (`UInt8`). -/
def toByte (b : Sm83.Byte) : UInt8 := b.toNat.toUInt8

/-- Read `len` bytes from flat memory starting at `base` (addresses wrap mod
    2^16, matching the hardware bus). -/
def readBytes (memory : FlatMemory) (base : Addr) (len : Nat) : Bytes :=
  ((List.range len).map fun i => toByte (memory.read (Word.ofNat (base.toNat + i)))).toArray

/-! ## Region and checkpoint capture

The oracle-side `read` for `Checkpoint.capture`: resolve each region's symbol and
read its bytes. Capture fails loudly (`Except.error`) on an unbound symbol rather
than silently comparing zeros. -/

/-- Read one region from memory, or report the unbound symbol. -/
def readRegion (memory : FlatMemory) (syms : SymbolMap) (region : RegionSpec) :
    Except String Snapshot :=
  match syms.resolve region.symbol with
  | some base => .ok { region, bytes := readBytes memory base region.len }
  | none => .error s!"unbound symbol: {region.symbol}"

/-- Capture a full checkpoint from live emulated memory over the given regions. -/
def captureAt (label : String) (memory : FlatMemory) (syms : SymbolMap)
    (regions : List RegionSpec) : Except String Checkpoint := do
  let snapshots ← regions.mapM (readRegion memory syms)
  return { label, snapshots }

/-! ## Running a routine to its return

pokered routines are entered by `call`, which pushes a return address. To run one
"until it returns", the driver stages a synthetic return address (a sentinel PC
that the routine's code never occupies) as if a `call` had just happened, then
runs until the architectural PC reaches that sentinel. -/

/-- Load a flat memory image (code bank + initial WRAM) from bytes. -/
def loadImage (bytes : List Sm83.Byte) : FlatMemory := FlatMemory.ofList bytes

/-- Build the entry state for `entry`, with `sentinel` staged on the stack below
    `stackTop` exactly as `call` would leave it (little-endian, `SP := stackTop-2`).
    The routine's terminal `ret` then pops `sentinel` into PC. -/
def setupCall (memory : FlatMemory) (entry sentinel stackTop : Addr) : FunctionalState :=
  let sp := stackTop - 2
  let memory := memory.write (Word.ofNat sp.toNat) (Byte.ofNat (sentinel.toNat % 256))
  let memory := memory.write (Word.ofNat (sp.toNat + 1)) (Byte.ofNat (sentinel.toNat / 256))
  { registers := { pc := Word.ofNat entry.toNat, sp := Word.ofNat sp.toNat }, memory }

/-- Run until the architectural PC reaches `sentinel` or `fuel` instructions
    elapse. -/
def runToReturn (state : FunctionalState) (sentinel : Addr) (fuel : Nat := 100000) :
    Program.RunResult :=
  Program.runUntil (fun s => s.registers.pc == Word.ofNat sentinel.toNat) fuel state [] 0

/-- The final state of a run, whatever the outcome. -/
def finalState : Program.RunResult → FunctionalState
  | .reached s _ _ | .halted s _ _ | .stopped s _ _ | .locked s _ _ | .fuelExhausted s _ _ => s

/-- `true` iff the run reached the sentinel (as opposed to exhausting fuel or
    halting). Callers assert this before trusting a capture. -/
def reachedReturn : Program.RunResult → Bool
  | .reached _ _ _ => true
  | _ => false

/-- The end-to-end oracle step: load an image, run `entry` to its return, and
    capture the requested regions from the final memory. Errors if the run did
    not return or a symbol is unbound. -/
def traceRoutine (image : List Sm83.Byte) (syms : SymbolMap) (entry sentinel stackTop : Addr)
    (label : String) (regions : List RegionSpec) (fuel : Nat := 100000) :
    Except String Checkpoint :=
  let result := runToReturn (setupCall (loadImage image) entry sentinel stackTop) sentinel fuel
  if reachedReturn result then
    captureAt label (finalState result).memory syms regions
  else
    .error s!"routine did not return within {fuel} instructions (outcome: fuel/halt/stop/lock)"

/-! ## Synthetic end-to-end validation

A hand-assembled program with no ROM required, exercising load → call-setup →
run-to-return → region read. The program is

```
0x0000  3E 42        ld a, $42
0x0002  EA 00 C0     ld [$C000], a
0x0005  C9           ret
```

entered at `0x0000` with sentinel `0x8000` and stack top `0xFFFE`. After it
returns, `$C000` holds `$42`, PC is the sentinel, and SP has unwound to `0xFFFE`.
-/

/-- The synthetic program's bytes. -/
def demoImage : List Sm83.Byte := [0x3E, 0x42, 0xEA, 0x00, 0xC0, 0xC9].map Byte.ofNat

/-- A symbol table binding one label to the address the program writes. -/
def demoSyms : SymbolMap := [("wDemoCell", 0xC000)]

/-- The region read back by the capture path. -/
def demoRegion : RegionSpec := { symbol := "wDemoCell", len := 1, note := "synthetic" }

private def demoResult : Program.RunResult :=
  runToReturn (setupCall (loadImage demoImage) 0x0000 0x8000 0xFFFE) 0x8000

-- The routine returns cleanly to the sentinel and unwinds the stack.
#guard reachedReturn demoResult
#guard (finalState demoResult).registers.pc == Word.ofNat 0x8000
#guard (finalState demoResult).registers.sp == Word.ofNat 0xFFFE
-- The store landed in memory and reads back through `readBytes`.
#guard readBytes (finalState demoResult).memory 0xC000 1 == #[0x42]
-- The full oracle step resolves the symbol and captures the written byte.
#guard
  (traceRoutine demoImage demoSyms 0x0000 0x8000 0xFFFE "demo" [demoRegion]).toOption.map
    (fun c => c.snapshots.map (·.bytes)) == some [#[0x42]]
-- An unbound symbol is reported, not silently zero-filled.
#guard (readRegion (finalState demoResult).memory demoSyms
    { symbol := "wMissing", len := 1 }).toOption == none

end Battle.Driver
