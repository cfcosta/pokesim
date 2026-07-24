/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Fixtures

/-!
# Stage-0 fixture-matrix test runner

Runs every fixture through its harness-owned checks and prints a per-fixture
report. Exit code is the `lake test` contract: `0` all pass, `1` one or more
fail, `2` no fixtures (a wiring regression). The `#guard`s in `Battle.Fixtures`
already fail the *build* on a red matrix; this executable makes the same result
observable as a runnable check.
-/

open Battle

def main : IO UInt32 := do
  let results := runMatrix
  for (name, ok) in results do
    let tag := if ok then "PASS" else "FAIL"
    IO.println s!"{tag}  {name}"
  let total := results.length
  let failures := (results.filter (fun r => !r.2)).length
  if total == 0 then
    IO.eprintln "FAIL  no fixtures in matrix"
    return 2
  else if failures == 0 then
    IO.println s!"PASS  {total}/{total} fixtures"
    return 0
  else
    IO.eprintln s!"FAIL  {failures}/{total} fixtures diverged"
    return 1
