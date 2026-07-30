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

## Current replay boundary

The monitor can boot and control the canonical ROM and can route the title
screen into Red's unused built-in `TestBattle` routine as an integration demo.
That runtime-only patch is restored on emulator reset. It proves the ROM,
SameBoy, worker, framebuffer, input, and dashboard path, but it does **not**
reproduce the selected training battle.

Exact recorded-match playback still requires a versioned replay manifest with
full cartridge party bytes and RNG transitions, a setup staging patch, action
injection at battle request boundaries, and transition-by-transition ROM/Lean
validation. Historical compact UI records do not contain all of those fields.
