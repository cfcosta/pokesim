# SameBoy browser bridge

This directory builds the emulator used by the training monitor's recorded-match
pane. It is a narrow wrapper around SameBoy's DMG-B core, not a general libretro
frontend.

## Build the web core

SameBoy is pinned to commit
`213a12ce93d66b105a113debd9396306066a7cfc`. To rebuild from an existing clean
checkout:

```sh
nix shell nixpkgs#emscripten nixpkgs#rgbds nixpkgs#gnumake \
  nixpkgs#git nixpkgs#python3 --command \
  env SAMEBOY_ROOT=/path/to/SameBoy \
  packages/battle-training/emulator/build-sameboy-web.sh
```

Without `SAMEBOY_ROOT`, the script clones and checks out the pinned revision. It
writes `sameboy-core.js`, `sameboy-core.wasm`, and the upstream license into the
monitor's package-data directory. The wrapper exposes video frames, joypad
input, save states, memory access, and the program counter. Audio is not wired in
this first slice.

## ROM boundary

No Pokémon ROM is built into or copied by these assets. The browser accepts a
user-supplied `.gb` file or a ZIP containing one, requires exactly 1 MiB, and
checks SHA-256
`5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.
Validated bytes stay in browser-local IndexedDB and are transferred only to the
local SameBoy worker.

## Recorded-match replay

`/api/replay` reconstructs the selected self-play or promotion battle from its
recorded reset coordinates. Before returning a manifest, the server runs every
recorded action through the deterministic Lean engine and rejects any initial,
transition, request, final-state, or outcome mismatch.

The versioned `pokered-recorded-link-replay-v1` manifest contains full party
structures, nicknames, link RNG state, both sides' actions, and WRAM checkpoints.
A runtime-only patch routes Red's built-in `TestBattle` setup into a staged link
battle, bypasses menu and serial-cable rendezvous, and leaves the original ROM to
render and execute the battle. It is restored on reset.

At every decision boundary, the adapter compares and then synchronizes party and
active-mon structures, HP, status, PP, active slots, and link RNG to the
Lean-validated recording. The completion status reports how many cartridge bytes
needed correction. This distinction is deliberate: the selected battle is
reproduced exactly at its recorded semantic boundaries, while presentation-time
cartridge execution between boundaries remains visible rather than being
replaced with a simulated animation.
