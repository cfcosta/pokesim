# V33 charge-ordering proof

The original fix proved the cartridge dispatch predicate and tested the native
server regression. That did not establish a theorem about the actual Lean move
executor. This change closes that gap without changing battle execution.

## What is proved

`Full.Engine.executeMove_initial_charge_exact` proves whole-result equality for
the actual `executeMove` definition. For any prepared battle state, either side,
any slot, RNG stream, generated-move flag, and initial charging action, it returns
exactly `transitioned` with the charge setup state and one charging event.
There is no hypothesis excluding zero divisors, screens, or large combat stats.
It therefore excludes `divisionFreeze`, `rngStuck`, damage, and RNG events on
initial charge at this boundary.

The specification `chargeSetupState` is independent of the runtime path. It
installs the caller's post-status attacker and RNG, then changes only the
charging bit and, for Fly/Dig, the invulnerability bit. Whole-state equality and
`chargeSetupState_preserves` establish preservation of HP, PP, combat stats,
party storage, the opposing side, selected moves, and shared damage.
`Effects.charge_before_exact` proves the underlying whole-context transformer.

`Rom.ChargeDispatchRoutine.engine_charge_exact` instantiates the executor theorem
for Razor Wind, Fly, SolarBeam, Dig, Skull Bash and Sky Attack.
`cartridge_charge_refines_executor` connects this result to both the supplied
ROM's dispatch window and the status byte obtained by executing its setup
window. Its premises are `RequiredBytes` and `RequiredChargeBytes`; the ROM
fixture checks the retained windows against the hash-verified cartridge.

The incident theorems use a reduced move-entry witness with Attack 163, Defense
513 after two Barriers, Reflect, and a noncritical RNG byte. Initial Sky Attack
charges safely. A `.noAction` release still returns `divisionFreeze`, spending
one PP and reporting the critical RNG draw. Both sides and both generated-move
flags are covered. This fixture is not a claim that every field reproduces the
recorded episode; the native regression separately replays that recording.

## Proof boundaries and trust

The entry boundary is **after status gating**. The theorem does not claim that
an entire battle turn consumes no RNG or that the opponent cannot cause a
freeze. The shared cartridge effect dispatcher and presentation remain explicit
boundaries; this is not whole-battle ROM bisimulation. The existing setup CPU
matrix varies all 256 acting status bytes and uses `0xA5` for the opposing byte.

The universal effects/executor/family theorems depend only on `propext` and
`Quot.sound`, as checked with `#print axioms`. The finite cartridge CPU matrices
and release witness use `native_decide`, with its compiled-evaluation trust,
consistent with existing routine proofs. No `sorry` or new assumed axiom is
introduced.

## Negative control and validation

The isolated `EngineBeforeFix.lean` uses the exact old executor body from commit
`edd3046010c7`. Lean accepts its concrete initial-charge freeze assertion and
rejects the required transition assertion with `native_decide ... is false`.
The negative control does not alter the working executor or use a timeout as
evidence of failure.

Validation logs, the axiom audit, and negative-control metadata are retained
under `output/v33-charge-proof-20260908/`. The generated old-executor source is
kept at `/tmp/pokemon-v33-charge-proof-negative/EngineBeforeFix.lean` rather than
vendoring a second engine. Commands:

```sh
lake -d packages/battle-lean build Battle battleFixtures battleRomFixture battleSearchServer
packages/battle-lean/.lake/build/bin/battleFixtures
python tools/check-pokered-build.py --rom /tmp/pokemon-v33-canonical.gbc
packages/battle-lean/.lake/build/bin/battleRomFixture /tmp/pokemon-v33-canonical.gbc
python -m unittest discover -s packages/battle-training/tests
```

Results: 279 Lean build targets passed; 10/10 battle fixtures passed; the
canonical ROM source/window check and rebuilt ROM fixture passed; all 462
Python tests passed without skips. `validation.json` records the cartridge
and Lean source hashes. Training was not restarted.
