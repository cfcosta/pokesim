# Battle verification documentation

These documents record twelve codebase, processor, and proof-architecture review passes and define the boundary for a formally verified Lean battle simulator.

## Start here

- [Project specification](../SPEC.md) — requirements, proof contract, architecture, milestones, and definition of done.
- [Current battle engine](explanation/current-battle-engine.md) — how the existing assembly organizes and executes battles.
- [Formal verification strategy](explanation/formal-verification-strategy.md) — how the high-level Lean model will be connected to actual ROM bytes.
- [RNG and time](explanation/rng-and-time.md) — why console randomness cannot honestly be reduced to a software seed.
- [RL environment design](explanation/rl-environment.md) — legal teams, actions, observations, replay, and batching.

## Reference

- [Battle source map](reference/battle-source-map.md) — files, labels, tables, and scope ownership.
- [Canonical ROM artifacts](reference/canonical-rom-artifacts.md) — pinned RGBDS derivation, ROM hashes, retained symbol/map files, exact addresses, and conservative whole-machine closure.
- [Battle state model](reference/battle-state-model.md) — persistent, active, volatile, and shared state.
- [Mechanics coverage](reference/mechanics-coverage.md) — checklist the implementation and proofs must close.
- [Effect dispatch](reference/effect-dispatch.md) — exact phase-table memberships and all effect-pointer targets.
- [Item dispatch](reference/item-dispatch.md) — all 83 ordinary-item pointers and their battle dispositions.
- [Trainer AI dispatch](reference/trainer-ai-dispatch.md) — all 47 class layer/count/pointer rows and exact action thresholds.
- [Battle outcomes](reference/battle-outcomes.md) — terminal control paths, raw result bytes, and cleanup erasure.
- [Probability thresholds](reference/probability-thresholds.md) — exact expanded `percent` bytes and branch boundaries.
- [Stat modifier flow](reference/stat-modifier-flow.md) — stage arithmetic, cap anomalies, badges, and status-penalty targets.
- [Switch, faint, and participation flow](reference/switch-faint-and-participation.md) — active/party synchronization, reset matrices, EXP flags, replacement, and faint asymmetries.
- [End-to-end verification closure](reference/end-to-end-closure.md) — concrete driver boundary, transitive range/hardware closure, theorem stack, caller integrations, and release gates.
- [Standalone SM83 semantics package](reference/sm83-semantics-package.md) — separate dependency boundary, complete decoder/clock/bus semantics, interrupts/HALT/lockup, proof obligations, and conformance corpus.
- [SM83 implementation specification](reference/sm83-implementation-spec.md) — pinned 512-row catalogue audit, normalized decoder, exact ALU/flag rules, logical M-cycle schedules, metadata dispositions, and theorem matrix.
- [SM83 microarchitecture and system-boundary contract](reference/sm83-microarchitecture-contract.md) — physical fetched-IR pipeline, IDU/address pins, clock domains, interrupt phases, HALT/STOP/lock, OAM trigger, checkpoints, and three-layer refinements.
- [DMG-CPU B console profile and evidence contract](reference/dmg-cpu-b-profile.md) — first SoC target, eight-half-edge bus protocol, reset/boot relation, clock gates, oracle quarantine, and physical capture procedure.

## Research record

- [Codebase memory](research/codebase-memory.md) — pinned revisions, review notes, wiki findings, known hazards, and unanswered questions.
- [Second-pass ASM audit](research/second-pass-asm-audit.md) — corrections found by rereading control flow, WRAM aliases, menu writes, items, and progression.
- [Third-pass ASM audit](research/third-pass-asm-audit.md) — paired link state, complete item dispatch, and deeper PP/status/EXP/end-state findings.
- [Fourth-pass ASM audit](research/fourth-pass-asm-audit.md) — terminal witnesses, partial reset assumptions, exact trainer AI, and residual/shared-scratch findings.
- [Fifth-pass ASM audit](research/fifth-pass-asm-audit.md) — phased capture/naming, nested learning, stat cross-effects, unbound charge, and exact probability boundaries.
- [Sixth-pass ASM audit](research/sixth-pass-asm-audit.md) — switch/send-out reset semantics, deterministic enemy replacement, participation/Revive flow, faint status, and wild-faint escape.
- [Seventh-pass end-to-end audit](research/seventh-pass-end-to-end-audit.md) — entry/exit theorem boundary, epilogue completion, caller separation, indirect call closure, and implementation gates.
- [Eighth-pass SM83 semantics audit](research/eighth-pass-sm83-semantics-audit.md) — existing Lean model gaps, opcode/timing/interrupt behavior, external validation sources, and standalone-package decision.
- [Ninth-pass gb-opcodes audit](research/ninth-pass-gb-opcodes-audit.md) — complete cloned-catalogue review, JSON hazards, STOP/prefix disputes, timing-unit decision, and implementation-ready semantic contract.
- [Tenth-pass SM83 microarchitecture audit](research/tenth-pass-sm83-microarchitecture-audit.md) — fetch overlap, internal latches, 101 physical families, clock gates, IDU/OAM behavior, interrupt/HALT/STOP closure, and exact source/corpus audit.
- [Eleventh-pass SM83 profile evidence audit](research/eleventh-pass-sm83-profile-evidence-audit.md) — DMG-CPU B selection, T1F–T4R evidence, temporal bus reads, reset/NMI/gates, SameBoy oracle, and hardware validation.
- [Twelfth-pass RISC-V and CompCert proof audit](research/twelfth-pass-riscv-compcert-proof-audit.md) — the simulation and whole-behavior theorems required to turn the current executable SM83 candidate into an end-to-end formal verification.
- [External bug compatibility audit](research/external-bug-compatibility-audit.md) — clean-room inventory of all 13 externally claimed battle bugs, canonical source anchors, corrected scope, and proof acceptance criteria.

## Documentation modes

The folder follows a small Diátaxis split:

- `explanation/` discusses architecture and design reasoning;
- `reference/` is lookup-oriented source and state information;
- `research/` preserves investigation notes and provenance.

Tutorials and how-to guides should be added after executable Lean code exists. Mixing setup instructions into these design documents would make both harder to use.
