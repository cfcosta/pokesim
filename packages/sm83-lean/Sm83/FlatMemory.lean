/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Bus

namespace Sm83

structure FlatMemory where
  read : Word → Byte

namespace FlatMemory

instance : Inhabited FlatMemory := ⟨⟨fun _ => 0⟩⟩

def ofList (bytes : List Byte) (defaultValue : Byte := 0) : FlatMemory :=
  ⟨fun address => bytes.getD address.toNat defaultValue⟩

@[inline] def write (memory : FlatMemory) (address : Word) (value : Byte) : FlatMemory :=
  ⟨fun candidate => if candidate = address then value else memory.read candidate⟩

@[simp] theorem read_write_same (memory : FlatMemory) (address : Word) (value : Byte) :
    (memory.write address value).read address = value := by
  simp [write]

@[simp] theorem read_write_other (memory : FlatMemory) (address other : Word) (value : Byte)
    (different : other ≠ address) : (memory.write address value).read other = memory.read other := by
  simp [write, different]

end FlatMemory
end Sm83
