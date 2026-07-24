/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Pipeline

namespace Sm83

inductive ResetEvent where
  | assertAsync | held | releaseSynchronous
  deriving Repr, DecidableEq, Inhabited

/-- Reset is profile-owned because power-on ordinary registers and IR are not a reset image. -/
structure ResetProfile where
  permits : ResetEvent → CoreState → CoreState → Prop
  decidablePermits : ∀ event before after, Decidable (permits event before after)

attribute [instance] ResetProfile.decidablePermits

inductive ResetStep (profile : ResetProfile) : ResetEvent → CoreState → CoreState → Prop where
  | permitted {event before after} (allows : profile.permits event before after) :
      ResetStep profile event before after

namespace ResetProfile

/-- A conservative hook: no deterministic power-on values are claimed by the CPU package. -/
def relational : ResetProfile where
  permits _ _ _ := True
  decidablePermits := by intros; infer_instance

/-- A synthetic bootstrap is explicit and may only be selected by a system-profile proof. -/
def syntheticBootstrap (registers : Registers) : CoreState := Pipeline.bootstrap registers

/-- The generic relation does not collapse unreset ordinary registers to one image. -/
theorem admits_distinct_register_images :
    let first := syntheticBootstrap { a := 0x00 }
    let second := syntheticBootstrap { a := 0xFF }
    relational.permits .releaseSynchronous {} first ∧
      relational.permits .releaseSynchronous {} second ∧ first ≠ second := by
  native_decide

end ResetProfile
end Sm83
