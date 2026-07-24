/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Encode

namespace Sm83
namespace Proofs.Decode

example : Decode.base (Byte.ofNat 0x00) = .legal .nop := by native_decide
example : Decode.base (Byte.ofNat 0x76) = .legal .halt := by native_decide
example : Decode.base (Byte.ofNat 0xCB) = .prefix := by native_decide
example : Decode.base (Byte.ofNat 0xD3) = .locked (Byte.ofNat 0xD3) := by native_decide
example : Decode.cb (Byte.ofNat 0x7C) = .bit ⟨7, by omega⟩ (.reg .h) := by native_decide
example : Decode.cb (Byte.ofNat 0xFF) = .set ⟨7, by omega⟩ (.reg .a) := by native_decide

/-- The three unprefixed dispositions cover all 256 bytes. -/
theorem base_partition_total :
    Decode.legalBaseCount + Decode.prefixBaseCount + Decode.lockedBaseCount = 256 := by
  native_decide

end Proofs.Decode
end Sm83
