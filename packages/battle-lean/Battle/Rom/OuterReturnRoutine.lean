/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.RoutineSummary
import Battle.Rom.Closure

/-! # Decoded `_InitBattleCommon` outer return shell -/

namespace Battle.Rom.OuterReturnRoutine

open Sm83 Battle.Rom.Closure

private def entry : Word := 0x703B
private def sentinel : Word := 0x8000
private def stack : Word := 0xFFF8
private def letterDelay : Word := 0xD358
private def mapPalette : Word := 0xD35D
private def savedAnimations : Word := 0xD0D4
private def tileAnimations : Word := 0xFFD7

private def code : List Byte :=
  [0xF1, 0xEA, 0x58, 0xD3, 0xF1, 0xEA, 0x5D, 0xD3,
    0xFA, 0xD4, 0xD0, 0xE0, 0xD7, 0x37, 0xC9]

private def install (memory : FlatMemory) (base : Word) (bytes : List Byte) : FlatMemory :=
  (List.range bytes.length).foldl (fun memory index =>
    memory.write (Word.ofNat (base.toNat + index)) (bytes.getD index 0)) memory

private def memory (letter palette animations : Byte) : FlatMemory :=
  let memory := install (default : FlatMemory) entry code
  let memory := memory.write stack 0
  let memory := memory.write (Word.ofNat (stack.toNat + 1)) letter
  let memory := memory.write (Word.ofNat (stack.toNat + 2)) 0
  let memory := memory.write (Word.ofNat (stack.toNat + 3)) palette
  let memory := memory.write (Word.ofNat (stack.toNat + 4)) sentinel.lowByte
  let memory := memory.write (Word.ofNat (stack.toNat + 5)) sentinel.highByte
  memory.write savedAnimations animations

private def initial (letter palette animations : Byte) : FunctionalState :=
  { registers := { pc := entry, sp := stack }
    memory := memory letter palette animations }

private def run (letter palette animations : Byte) : RoutineSummary.Execution :=
  RoutineSummary.runSteps 8 (initial letter palette animations)

/-- Each caller-owned byte is universally propagated through the decoded
shell. The separate finite theorems avoid replacing byte-parametric behavior by
one concrete fixture. -/
theorem shell_restores_letter : ∀ letter : Byte,
    (run letter 0 0).state.memory.read letterDelay = letter := by
  native_decide


theorem shell_restores_palette : ∀ palette : Byte,
    (run 0 palette 0).state.memory.read mapPalette = palette := by
  native_decide


theorem shell_restores_animations : ∀ animations : Byte,
    (run 0 0 animations).state.memory.read tileAnimations = animations := by
  native_decide

/-- Control facts do not depend on the restored payload bytes. A representative
decoded run establishes exact instruction count, frame pop, carry, and return. -/
theorem shell_control_exact :
    let final := (run 0 0 0).state
    final.registers.pc = sentinel ∧
      final.registers.sp = Word.ofNat (stack.toNat + 6) ∧
      final.registers.flags.c = true ∧ final.mode = .running := by
  native_decide

structure RequiredOuterReturnBytes (rom : Array Byte) : Prop where
  shell : bytesAt rom (romOffset 0x0F entry) code.length = code


theorem canonical_shell_exact {rom : Array Byte}
    (required : RequiredOuterReturnBytes rom) :
    bytesAt rom (romOffset 0x0F entry) 15 =
      [0xF1, 0xEA, 0x58, 0xD3, 0xF1, 0xEA, 0x5D, 0xD3,
        0xFA, 0xD4, 0xD0, 0xE0, 0xD7, 0x37, 0xC9] :=
  required.shell

end Battle.Rom.OuterReturnRoutine
