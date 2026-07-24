# External bug-formalization compatibility audit

## Scope and clean-room rule

The external `../gameboy-pokered-verify` tree was inspected only to enumerate
its public bug claims and theorem scope. The tree has no detected licence file,
so no Lean definitions, proofs, CPU semantics, or prose are copied into this
repository. Every compatibility model is re-derived from the pristine pinned
`pokered/` source and must use project-owned types. The external project is not
a proof dependency or trusted foundation.

Canonical source remains `pret/pokered` commit
`405b6246372d7e5a2cb029cbb65219b13286b8c9`. Labels, control flow, byte widths,
and asymmetries below were checked directly in that tree.

## Required compatibility matrix

| ID | External claim | Canonical source anchor | Exact behavior that must remain observable | Pre-audit support |
|---:|---|---|---|---|
| B01 | Focus Energy wrong shift | `engine/battle/core.asm`, `CriticalHitTest` | `baseSpeed >> 1` is shifted right again under Focus Energy; the ordinary branch shifts left, while high-critical moves apply their later saturating shifts | Missing |
| B02 | 1/256 accuracy miss | `engine/battle/core.asm`, `MoveHitTest` | `cp b; jr nc` accepts exactly random bytes strictly below effective accuracy, including the miss at `$ff/$ff` | Present in `Battle.Ordinary.moveHits`, but lacked a named universal compatibility theorem |
| B03 | critical boundary miss | `engine/battle/core.asm`, `CriticalHitTest` | after three `rlc` rotations, critical succeeds exactly when the byte is strictly below the threshold | Present in `Battle.Ordinary.critHits`, but lacked a named universal compatibility theorem |
| B04 | Substitute zero-cost and zero-user-HP cases | `engine/battle/move_effects/substitute.asm`, `SubstituteEffect_` | cost is the low byte of `maxHP / 4`; carry-only subtraction accepts equality and can leave the user at zero | Missing |
| B05 | Recover/Softboiled/Rest false failure | `engine/battle/move_effects/heal.asm`, `HealEffect_` | the high-byte `cp` only feeds borrow into low-byte `sbc`; only the final zero flag is tested, yielding false failures at reachable `256k−1` HP gaps | Missing |
| B06 | CooltrainerF dead random return | `engine/battle/trainer_ai.asm`, `CooltrainerFAI` | the first `ret nc` is absent; low HP always reaches healing, and the second HP check may switch or return normally | Missing. The external shorthand “always switches” is too broad; canonical code can still attack |
| B07 | Blaine unconditional Super Potion after trigger | `engine/battle/trainer_ai.asm`, `BlaineAI` | after the 25% gate, no HP-fraction check precedes `AIUseSuperPotion`, so full-HP use is retained | Missing |
| B08 | Psywave player/enemy link asymmetry | `engine/battle/core.asm`, both `SPECIAL_DAMAGE_EFFECT` branches | player rejects zero and values `≥ 1.5×level`; enemy rejects only values `≥ 1.5×level`, so zero changes both damage and RNG consumption | Missing |
| B09 | Bide faint-clear link asymmetry | `engine/battle/core.asm`, `FaintEnemyPokemon` and `RemoveFaintedPlayerMon` | enemy-faint path clears only the high byte of player Bide accumulation; counterpart clears both enemy bytes | Missing |
| B10 | Reflect/Light Screen uncapped overflow | `engine/battle/core.asm`, both `GetDamageVars…Attack` routines | screen doubles the 16-bit defensive stat before `/4` scaling; values crossing 1024 wrap in the retained low byte and may produce zero | Missing; `Battle.Damage` described the pending caller obligation but did not implement scaling |
| B11 | defense-zero damage freeze | `engine/battle/core.asm`, `.scaleStats` and `CalculateDamage` | when scaling is active, offensive zero is bumped to one but defensive zero is retained as the later divisor | Only the explicit `divisorFreezes` predicate was present; scaling and compatibility theorem missing |
| B12 | equal accuracy/evasion stages do not cancel | `engine/battle/core.asm`, `CalcHitChance`; `data/battle/stat_modifiers.asm` | table ratios are applied accuracy-first with an integer divide after each pass, minimum one, then maximum 255 | Missing |
| B13 | badge reapplication plus screen overflow | `engine/battle/core.asm`, `ApplyBadgeStatBoosts`, stat-down path, and screen scaling | non-link opponent stat-down effects reapply owned badge boosts to every eligible player stat; 9/8 compounding is capped at 999 before uncapped screen doubling | Missing |

## Proof acceptance criteria

Compatibility is complete only when project-owned Lean modules establish all of
the following without importing the external tree:

1. universal equations or iff characterizations for each finite-width routine;
2. explicit witnesses for each observable bug;
3. relational host/guest results for Psywave and Bide;
4. explicit freeze/divergence results rather than Lean division-by-zero values;
5. integration lemmas showing the battle-effect, AI, item, accuracy, damage, and
   link implementations call the characterized buggy primitive;
6. regression guards as supplementary checks, never as substitutes for the
   universal theorems.

The external project proves translated arithmetic functions, not decoded
canonical-ROM routine refinement. Matching or exceeding that theorem scope does
not close this repository's separate ROM-to-model refinement obligation.
