# Link-only whole-battle equivalence contract

<!-- mode: research -->

This audit narrows the intended whole-battle claim to the environment used by
training: two Pokémon Red cartridges in a link battle. It does not include wild,
trainer-AI, Safari, Old Man, capture, experience, evolution, or blackout paths.

## Claim boundary

The low execution starts after Cable Club party/name/random-block negotiation,
with both processors at the fetched `InitOpponent` instruction. It ends when
both battle drivers return to their cable callers. The later Cable Club
`HealParty` call is outside the theorem.

The admitted high reset contains two progression-witnessed canonical generated
parties and one well-formed ten-byte link RNG image. The left semantic cartridge
has the internal clock and the right cartridge has the external clock. A later
generalization may admit the opposite orientation.

The target claim is:

```text
canonical ROM identity for both cartridges
and post-handshake link entry
and paired machine/model relation
and paired physical behavior
------------------------------------------------
there exists a Full.Link.Pair behavior with the same projected
responses, mechanics events, terminal results, waits, divergence,
and named desynchronization
```

Equivalence also requires the reverse direction: every action, nested response,
chance trace, return, and nonreturn admitted by the high model must have a
physical controller/cable schedule.

## Formal contract now in tree

`Battle.Rom.LinkEquivalence` defines:

- the generated-team `EntryDomain`;
- exact left/right high resets without resampling;
- a two-perspective `highPair` with retained clock ownership;
- adapter responses and their admissibility boundary;
- observable mechanics, desynchronization, terminal, and return events;
- nonreturn outcomes without a fuel or horizon constructor;
- the forward and reverse whole-behavior theorem shapes;
- an `Obligations` bundle that must contain actual simulations, final-state
  compatibility, reaction preservation, and reverse realizability.

`wholeBattle_equivalence` only composes proofs supplied by that bundle. It is
not an axiom and does not assert that the bundle currently has an inhabitant.

The high reset now proves that both active structs, persistent parties, active
indexes, RNG state, and phases begin mirrored. `Full.Link.classifyPairedResult`
checks persistent parties and indexes in addition to active structs, RNG, and
terminal phase before returning `synchronized`.

## Physical cable semantics

`Battle.GameBoy.LinkAdapter` replaces the unsound idea of running two standalone
adapters during serial transfer. A standalone adapter supplies a high incoming
bit to its own internal serial clock. The link adapter instead:

- interleaves one machine cycle from either console;
- keeps the peer CPU stationary during that interleaving step;
- advances timer, divider, and PPU state only for the selected oscillator;
- lets the internal-clock endpoint own the 512-T serial divider;
- shifts both serial devices from their pre-edge output bits on one cable edge;
- keeps serial input unavailable as an independent external response;
- proves each interleaved machine cycle preserves both immutable ROM images.

A complete eight-edge witness exchanges `$A5` and `$3C` in opposite directions
and leaves both transfer counters at zero. This is an executable cable
foundation, not yet a proof of the ROM's complete serial protocol.

## Paired machine/model checkpoint

`Battle.Rom.LinkStateProjection` relates each physical endpoint to its own
`Full.Link.Perspective`. It currently includes:

- all 58 bytes of the two live battle structs, with byte three related to
  party position rather than incorrectly treated as persistent box level;
- both persistent party counts and every admitted 44-byte party row;
- local and remote active indexes;
- four unmodified stat words per side;
- all eight stage bytes per side;
- all three volatile status bytes and the attacks-left, confusion, Toxic,
  Disable, substitute, Bide, and minimized fields;
- immutable loaded species identities;
- `wLinkState = LINK_STATE_BATTLING`;
- all ten link RNG bytes, including the vestigial byte, and the exact cursor;
- complementary physical clock roles;
- mirrored active structs, parties, indexes, RNG, and terminal phases;
- fetched canonical `$FA` at `InitOpponent` on both processors.

Every active and party witness re-encodes to the exact mapped WRAM bytes.
Malformed volatile combinations are retained as raw bytes.

## Remaining obligations

The current relation still needs:

1. selected/highlighted/loaded move records, used moves, shared damage, locked
   damage, replacement state, turn/order scratch, and terminal pre-cleanup bytes;
2. exact encoding of every generated reset into both post-handshake WRAM images;
3. a concrete paired low block relation built from `LinkAdapter` cycles rather
   than a certificate-selected relation;
4. semantic request transitions for action exchange, Metronome/Mirror Move,
   Mimic, automatic turns, forced replacement, Run, settle, and waits;
5. call-site-labelled coupling for every link `BattleRandom` use;
6. one request-to-request ordinary turn simulation;
7. miss, status, switch, faint, simultaneous-faint, replacement, terminal, and
   known-desynchronization extensions;
8. presentation frames with timing, interrupts, controller consumption, bank,
   stack, MMIO, and divergence contracts;
9. both `EndOfBattle` link epilogues and outer return frames;
10. reverse realizability for every admitted action and RNG transcript;
11. the synchronized quotient and RL feature/mask/handle/serialization/label
    preservation theorems;
12. a theorem-disposition manifest for every range reachable in this link-only
    domain.

## Accurate current statement

The project now has a compiled link-only equivalence contract, an interleaved
physical cable adapter, and a substantially expanded two-cartridge checkpoint
relation. These remove ambiguity about the target and close important state and
hardware seams. No `Obligations` inhabitant exists yet, so whole-link-battle ROM
equivalence is not yet proved.
