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
monitor's package-data directory. The wrapper exposes video frames, 48 kHz
stereo game audio, save states, memory access, and the program counter. The
replay pane has no manual joypad: its worker injects only the recorded actions
and the automatic input needed to advance cartridge text. Its runtime-only
`PlaySound` filter drops requests explicitly staged as music while passing
stop-all control and ordinary SFX requests unchanged. This leaves cartridge
cries and sound effects available in playback and exported video.

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

The versioned `pokered-recorded-link-replay-v2` manifest contains full party
structures, nicknames, link RNG state, both sides' actions, WRAM checkpoints,
and a deterministic random trainer-picture class. When a recorded evaluation
put the candidate model on the enemy side, replay reconstruction swaps the exact
generated parties, actions, forced-replacement requests, checkpoints, and
outcome so the candidate is always presented as RED on the player side.
A runtime-only patch routes Red's built-in `TestBattle` setup into a staged link
trainer battle, bypasses menu and serial-cable rendezvous, and leaves the
original ROM to render and execute the battle. It also clears TestBattle's
Pound-only move override and updates the species variables normally written by
the party menu so move names and switched sprites follow the recording. The
runtime patch is restored on reset.

At every decision boundary, the adapter compares and then synchronizes party and
active-mon structures, HP, status, PP, active slots, stat stages, volatile
multi-turn state and counters, move-selection scratch, shared damage, and link
RNG to the Lean-validated recording. The completion status reports how many cartridge bytes
needed correction. This distinction is deliberate: the selected battle is
reproduced exactly at its recorded semantic boundaries, while presentation-time
cartridge execution between boundaries remains visible rather than being
replaced with a simulated animation.

The browser can restart a replay at normal speed and record its 640×576 canvas
plus SameBoy's music-free sound-effect samples through `MediaRecorder`. It
downloads WebM with Opus audio where supported, with MP4 as a browser-dependent
fallback. Encoding and download stay entirely in the browser; neither ROM bytes
nor rendered video are sent to the monitor server.
