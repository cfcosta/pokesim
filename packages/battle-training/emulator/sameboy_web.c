/*
 * Minimal browser bridge for SameBoy's Expat-licensed core.
 *
 * The ROM is supplied by the browser at runtime and is never embedded in this
 * module. The replay adapter stages deterministic link-battle state in WRAM and
 * bypasses only cable/menu rendezvous; Red still renders and executes the battle.
 * Replay music is suppressed before mixing while cartridge sound effects remain.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "Core/gb.h"
#include "Core/apu.h"
#include "Core/display.h"
#include "Core/joypad.h"
#include "Core/memory.h"
#include "Core/save_state.h"

#include "dmg_boot.h"

#define FRAME_PIXELS (160 * 144)
#define AUDIO_SAMPLE_RATE 48000
#define AUDIO_FRAMES_PER_VIDEO_FRAME 2048
#define MAX_REPLAY_ACTIONS 512
#define MAX_EXPECTATIONS 768 /* Keep replay.py _MAX_CHECKPOINT_BYTES in sync. */
#define PARTY_MON_SIZE 0x2c
#define PARTY_BYTES (6 * PARTY_MON_SIZE)
#define PARTY_NAMES (6 * 11)

#define BANK_HOME 0
#define BANK_TEST_BATTLE 1
#define BANK_BATTLE_CORE 15
#define ADDR_PLAY_SOUND 0x23b1
#define ADDR_AUDIO_TRAMPOLINE 0x3fa6
#define ADDR_TITLE_JOYPAD 0x443b
#define ADDR_TEST_BATTLE 0x4da6
#define ADDR_TEST_BATTLE_INIT_OPPONENT 0x4dd3
#define ADDR_INIT_BATTLE_COMMON 0x6feb
#define ADDR_MAIN_BATTLE_LOOP 0x4233
#define ADDR_DISPLAY_BATTLE_MENU 0x4eb3
#define ADDR_SWITCH_PLAYER_MON 0x51ba
#define ADDR_MOVE_SELECTION_MENU 0x5219
#define ADDR_MOVE_SELECTION_RETRY 0x42a4
#define ADDR_LINK_EXCHANGE 0x5605
#define ADDR_CHOOSE_NEXT_MON 0x47d8
#define ADDR_CHOOSE_NEXT_MON_VALID 0x47ec
#define ADDR_PLAYER_LOSS_CLEAR_SCREEN 0x487f
#define ADDR_PLAYER_WIN_RETURN 0x46c5
#define ADDR_REPLAY_TRAMPOLINES 0x7c00
#define ADDR_DISPLAY_TRAMPOLINE 0x7c00
#define ADDR_MOVE_TRAMPOLINE 0x7c04
#define ADDR_REPLACEMENT_TRAMPOLINE 0x7c08
#define ADDR_TERMINAL_TRAMPOLINE 0x7c0c

#define W_TEST_BATTLE_PLAYER_SELECTED_MOVE 0xccd9
#define W_PLAYER_MOVE_LIST_INDEX 0xcc2e
#define W_PLAYER_MON_NUMBER 0xcc2f
#define W_SERIAL_RECEIVE 0xcc3e
#define W_PLAYER_SELECTED_MOVE 0xccdc
#define W_LINK_RNG_INDEX 0xccde
#define W_ACTION_RESULT 0xcd6a
#define W_CUR_PARTY_SPECIES 0xcf91
#define W_ENEMY_MON_PARTY_POS 0xcfe8
#define W_BATTLE_MON_SPECIES2 0xcfd9
#define W_BATTLE_MON_MOVES 0xd01c
#define W_IS_IN_BATTLE 0xd057
#define W_BATTLE_TYPE 0xd05a
#define W_CUR_OPPONENT 0xd059
#define W_TRAINER_NO 0xd05d
#define W_LINK_STATE 0xd12b
#define W_LINK_RNG_LIST 0xd148
#define W_PLAYER_NAME 0xd158
#define W_PARTY_COUNT 0xd163
#define W_PARTY_SPECIES 0xd164
#define W_PARTY_MONS 0xd16b
#define W_PARTY_OT_NAMES 0xd273
#define W_PARTY_NICKNAMES 0xd2b5
#define W_NUM_BAG_ITEMS 0xd31d
#define W_PLAYER_ID 0xd359
#define W_STATUS_FLAGS7 0xd733
#define W_ENEMY_PARTY_COUNT 0xd89c
#define W_ENEMY_PARTY_SPECIES 0xd89d
#define W_ENEMY_MONS 0xd8a4
#define W_ENEMY_OT_NAMES 0xd9ac
#define W_ENEMY_NICKNAMES 0xd9ee
#define H_SERIAL_CONNECTION_STATUS 0xffaa

#define LINK_STATE_BATTLING 4
#define USING_EXTERNAL_CLOCK 1
#define LINK_ACTION_NO_ACTION 13
#define LINK_ACTION_STRUGGLE 14
#define LINK_ACTION_RUN 15
#define MOVE_STRUGGLE 165

static GB_gameboy_t gameboy;
static uint32_t framebuffer[FRAME_PIXELS];
static int16_t audio_samples[AUDIO_FRAMES_PER_VIDEO_FRAME * 2];
static size_t audio_frame_count;
static bool initialized;
static bool loaded;

static int demo_state;
static bool runtime_patched;
static uint8_t runtime_original[3];

static int replay_state;
static bool replay_started;
static bool replay_initial_active_synced;
static int replay_outcome;
static uint8_t replay_trainer_class;
static unsigned replay_action_count;
static unsigned replay_action_index;
static int replay_mismatch_count;
static int replay_first_mismatch;
static int replay_first_expected;
static int replay_first_actual;
static int replay_last_verified;
static int replay_last_synced;
static int replay_last_hook;
static uint8_t replay_player_count;
static uint8_t replay_enemy_count;
static uint8_t replay_player_species[7];
static uint8_t replay_enemy_species[7];
static uint8_t replay_player_party[PARTY_BYTES];
static uint8_t replay_enemy_party[PARTY_BYTES];
static uint8_t replay_player_ot[PARTY_NAMES];
static uint8_t replay_enemy_ot[PARTY_NAMES];
static uint8_t replay_player_nicks[PARTY_NAMES];
static uint8_t replay_enemy_nicks[PARTY_NAMES];
static uint8_t replay_rng[10];
static uint8_t replay_rng_index;
static uint8_t replay_player_actions[MAX_REPLAY_ACTIONS];
static uint8_t replay_enemy_actions[MAX_REPLAY_ACTIONS];
static uint8_t replay_requests[MAX_REPLAY_ACTIONS];
static uint16_t replay_expected_addresses[MAX_REPLAY_ACTIONS][MAX_EXPECTATIONS];
static uint8_t replay_expected_values[MAX_REPLAY_ACTIONS][MAX_EXPECTATIONS];
static uint16_t replay_expected_counts[MAX_REPLAY_ACTIONS];

typedef struct {
    size_t offset;
    size_t size;
    uint8_t original[32];
} replay_patch_t;

static replay_patch_t replay_patches[12];
static unsigned replay_patch_count;

static void load_boot_rom(GB_gameboy_t *gb, GB_boot_rom_t type)
{
    if (type == GB_BOOT_ROM_DMG || type == GB_BOOT_ROM_DMG_0) {
        GB_load_boot_rom_from_buffer(gb, sameboy_dmg_boot, sameboy_dmg_boot_length);
    }
}

static uint32_t encode_rgba(GB_gameboy_t *gb, uint8_t red, uint8_t green, uint8_t blue)
{
    (void) gb;
    return (uint32_t) red |
           ((uint32_t) green << 8) |
           ((uint32_t) blue << 16) |
           UINT32_C(0xff000000);
}

static void receive_audio_sample(GB_gameboy_t *gb, GB_sample_t *sample)
{
    (void) gb;
    if (audio_frame_count >= AUDIO_FRAMES_PER_VIDEO_FRAME) {
        return;
    }
    audio_samples[audio_frame_count * 2] = sample->left;
    audio_samples[audio_frame_count * 2 + 1] = sample->right;
    audio_frame_count++;
}

static void write_name(uint16_t address, const char *name)
{
    unsigned index = 0;
    for (; name[index] && index < 10; index++) {
        GB_write_memory(&gameboy, address + index, (uint8_t) (0x80 + name[index] - 'A'));
    }
    for (; index < 11; index++) {
        GB_write_memory(&gameboy, address + index, 0x50);
    }
}

static void write_bytes(uint16_t address, const uint8_t *bytes, size_t size)
{
    for (size_t index = 0; index < size; index++) {
        GB_write_memory(&gameboy, (uint16_t) (address + index), bytes[index]);
    }
}

static uint8_t *rom_bytes(size_t *size, uint16_t *bank)
{
    return GB_get_direct_access(&gameboy, GB_DIRECT_ACCESS_ROM, size, bank);
}

static uint16_t current_rom_bank(void)
{
    size_t size = 0;
    uint16_t bank = 0;
    (void) rom_bytes(&size, &bank);
    return bank;
}

static void restore_runtime_patch(void)
{
    size_t size = 0;
    uint16_t bank = 0;
    uint8_t *rom = rom_bytes(&size, &bank);
    while (rom && replay_patch_count) {
        replay_patch_t *patch = &replay_patches[--replay_patch_count];
        if (patch->offset + patch->size <= size) {
            memcpy(rom + patch->offset, patch->original, patch->size);
        }
    }
    if (runtime_patched && rom && size > 0x443d) {
        memcpy(rom + 0x443b, runtime_original, sizeof(runtime_original));
    }
    runtime_patched = false;
}

static bool rom_offset(uint16_t bank, uint16_t address, size_t *offset)
{
    if (bank == BANK_HOME) {
        if (address >= 0x4000) {
            return false;
        }
        *offset = address;
        return true;
    }
    if (address < 0x4000 || address >= 0x8000) {
        return false;
    }
    *offset = bank * 0x4000u + address - 0x4000u;
    return true;
}

static uint8_t *rom_address(uint16_t bank, uint16_t address)
{
    size_t size = 0;
    size_t offset = 0;
    uint16_t mapped_bank = 0;
    uint8_t *rom = rom_bytes(&size, &mapped_bank);
    return rom_offset(bank, address, &offset) && rom && offset < size ? rom + offset : NULL;
}

static bool apply_replay_patch(uint16_t bank, uint16_t address,
                               const uint8_t *replacement, size_t replacement_size)
{
    if (!replacement_size || replacement_size > sizeof(replay_patches[0].original) ||
        replay_patch_count >= sizeof(replay_patches) / sizeof(replay_patches[0])) {
        return false;
    }
    size_t size = 0;
    size_t offset = 0;
    uint16_t mapped_bank = 0;
    uint8_t *rom = rom_bytes(&size, &mapped_bank);
    if (!rom_offset(bank, address, &offset) || !rom || offset + replacement_size > size) {
        return false;
    }
    replay_patch_t *patch = &replay_patches[replay_patch_count++];
    patch->offset = offset;
    patch->size = replacement_size;
    memcpy(patch->original, rom + offset, replacement_size);
    memcpy(rom + offset, replacement, replacement_size);
    return true;
}

static bool install_runtime_patch(void)
{
    size_t size = 0;
    uint16_t bank = 0;
    uint8_t *rom = rom_bytes(&size, &bank);
    static const uint8_t trampoline[] = {
        0xcd, 0x0f, 0x19, /* call ClearScreen */
        0xcd, 0x80, 0x36, /* call LoadFontTilePatterns */
        0xcd, 0xc0, 0x36, /* call LoadHpBarAndStatusTilePatterns */
        0xcd, 0x82, 0x00, /* call ClearSprites */
        0xcd, 0xed, 0x3d, /* call RunDefaultPaletteCommand */
        0xc3, 0xa6, 0x4d, /* jp TestBattle */
    };
    static const uint8_t jump_audio_trampoline[] = {
        0xc3, ADDR_AUDIO_TRAMPOLINE & 0xff, ADDR_AUDIO_TRAMPOLINE >> 8,
    };
    static const uint8_t suppress_music[] = {
        0xe5, 0xd5, 0xc5,       /* preserve hl, de, bc exactly as PlaySound */
        0x47,                   /* ld b, a: requested sound ID */
        0xfe, 0xff,             /* stop-all is control, not music */
        0x28, 0x11,             /* jr z, pass */
        0xfa, 0xee, 0xc0,       /* ld a, [wNewSoundID] */
        0xa7,                   /* and a: ordinary SFX leave this zero */
        0x28, 0x0b,             /* jr z, pass */
        0xb8,                   /* cp b: direct music requests mirror their ID */
        0x20, 0x08,             /* jr nz, pass */
        0xaf,                   /* xor a */
        0xea, 0xee, 0xc0,       /* ld [wNewSoundID], a */
        0xc1, 0xd1, 0xe1, 0xc9, /* restore and return without starting music */
        0x78,                   /* pass: ld a, b */
        0xc3, 0xb4, 0x23,       /* jp PlaySound after its three pushes */
    };
    if (!rom || size <= 0x7c49 + sizeof(trampoline) ||
        !apply_replay_patch(BANK_HOME, ADDR_PLAY_SOUND,
                            jump_audio_trampoline, sizeof(jump_audio_trampoline)) ||
        !apply_replay_patch(BANK_HOME, ADDR_AUDIO_TRAMPOLINE,
                            suppress_music, sizeof(suppress_music))) {
        return false;
    }
    memcpy(runtime_original, rom + 0x443b, sizeof(runtime_original));
    memcpy(rom + 0x7c49, trampoline, sizeof(trampoline));
    rom[0x443b] = 0xc3;
    rom[0x443c] = 0x49;
    rom[0x443d] = 0x7c;
    runtime_patched = true;
    write_name(W_PLAYER_NAME, "RED");
    write_name(0xd34a, "BLUE");
    return true;
}

static void replay_fail(int code)
{
    replay_state = -code;
    GB_set_execution_callback(&gameboy, NULL);
}

static void verify_replay_checkpoint(unsigned decision)
{
    if (decision >= replay_action_count || replay_last_verified >= (int) decision) {
        return;
    }
    unsigned count = replay_expected_counts[decision];
    for (unsigned index = 0; index < count; index++) {
        uint16_t address = replay_expected_addresses[decision][index];
        uint8_t expected = replay_expected_values[decision][index];
        uint8_t actual = GB_read_memory(&gameboy, address);
        if (actual != expected) {
            replay_mismatch_count++;
            if (!replay_first_mismatch) {
                replay_first_mismatch = (int) address;
                replay_first_expected = expected;
                replay_first_actual = actual;
            }
        }
    }
    replay_last_verified = (int) decision;
}

static void verify_previous_replay_action(void)
{
    if (replay_action_index) {
        verify_replay_checkpoint(replay_action_index - 1);
    }
}

static void synchronize_previous_replay_action(void)
{
    if (!replay_action_index) {
        return;
    }
    unsigned decision = replay_action_index - 1;
    if (replay_last_synced >= (int) decision) {
        return;
    }
    verify_replay_checkpoint(decision);
    unsigned count = replay_expected_counts[decision];
    for (unsigned index = 0; index < count; index++) {
        GB_write_memory(&gameboy,
                        replay_expected_addresses[decision][index],
                        replay_expected_values[decision][index]);
    }
    replay_last_synced = (int) decision;
}

static void install_replay_state(void)
{
    GB_write_memory(&gameboy, W_PARTY_COUNT, replay_player_count);
    write_bytes(W_PARTY_SPECIES, replay_player_species, sizeof(replay_player_species));
    write_bytes(W_PARTY_MONS, replay_player_party, sizeof(replay_player_party));
    write_bytes(W_PARTY_OT_NAMES, replay_player_ot, sizeof(replay_player_ot));
    write_bytes(W_PARTY_NICKNAMES, replay_player_nicks, sizeof(replay_player_nicks));

    GB_write_memory(&gameboy, W_ENEMY_PARTY_COUNT, replay_enemy_count);
    write_bytes(W_ENEMY_PARTY_SPECIES, replay_enemy_species, sizeof(replay_enemy_species));
    write_bytes(W_ENEMY_MONS, replay_enemy_party, sizeof(replay_enemy_party));
    write_bytes(W_ENEMY_OT_NAMES, replay_enemy_ot, sizeof(replay_enemy_ot));
    write_bytes(W_ENEMY_NICKNAMES, replay_enemy_nicks, sizeof(replay_enemy_nicks));

    write_bytes(W_LINK_RNG_LIST, replay_rng, sizeof(replay_rng));
    GB_write_memory(&gameboy, W_LINK_RNG_INDEX, replay_rng_index);
    GB_write_memory(&gameboy, W_LINK_STATE, LINK_STATE_BATTLING);
    GB_write_memory(&gameboy, H_SERIAL_CONNECTION_STATUS, USING_EXTERNAL_CLOCK);
    GB_write_memory(&gameboy, W_IS_IN_BATTLE, 2);
    GB_write_memory(&gameboy, W_BATTLE_TYPE, 0);
    GB_write_memory(&gameboy, W_PLAYER_ID, 0);
    GB_write_memory(&gameboy, W_PLAYER_ID + 1, 0);
    GB_write_memory(&gameboy, W_NUM_BAG_ITEMS, 0);
    GB_write_memory(&gameboy, W_NUM_BAG_ITEMS + 1, 0xff);
    GB_write_memory(
        &gameboy,
        W_STATUS_FLAGS7,
        GB_read_memory(&gameboy, W_STATUS_FLAGS7) & 0xfe
    );
    write_name(W_PLAYER_NAME, "RED");
    write_name(0xd887, "MODEL");

    static const uint8_t jump_display_trampoline[] = {0xc3, ADDR_DISPLAY_TRAMPOLINE & 0xff, ADDR_DISPLAY_TRAMPOLINE >> 8};
    static const uint8_t jump_move_trampoline[] = {0xc3, ADDR_MOVE_TRAMPOLINE & 0xff, ADDR_MOVE_TRAMPOLINE >> 8};
    static const uint8_t return_immediately[] = {0xc9};
    static const uint8_t jump_replacement_trampoline[] = {0xc3, ADDR_REPLACEMENT_TRAMPOLINE & 0xff, ADDR_REPLACEMENT_TRAMPOLINE >> 8};
    static const uint8_t disable_move_retry[] = {0x00, 0x00};
    static const uint8_t call_finish_trampoline[] = {0xcd, ADDR_TERMINAL_TRAMPOLINE & 0xff, ADDR_TERMINAL_TRAMPOLINE >> 8};
    static const uint8_t trampolines[] = {
        0xaf, 0xc9, 0x00, 0x00, /* $7c00: xor a; ret */
        0xaf, 0xc9, 0x00, 0x00, /* $7c04: xor a; ret */
        0xc3, ADDR_CHOOSE_NEXT_MON_VALID & 0xff, ADDR_CHOOSE_NEXT_MON_VALID >> 8, 0x00,
        0x18, 0xfe, 0x00, 0x00, /* $7c0c: jr -2 */
    };
    bool patched =
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_DISPLAY_BATTLE_MENU,
                           jump_display_trampoline, sizeof(jump_display_trampoline)) &&
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_MOVE_SELECTION_MENU,
                           jump_move_trampoline, sizeof(jump_move_trampoline)) &&
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_LINK_EXCHANGE,
                           return_immediately, sizeof(return_immediately)) &&
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_CHOOSE_NEXT_MON,
                           jump_replacement_trampoline, sizeof(jump_replacement_trampoline)) &&
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_MOVE_SELECTION_RETRY,
                           disable_move_retry, sizeof(disable_move_retry)) &&
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_PLAYER_LOSS_CLEAR_SCREEN,
                           call_finish_trampoline, sizeof(call_finish_trampoline)) &&
        apply_replay_patch(BANK_BATTLE_CORE, ADDR_REPLAY_TRAMPOLINES,
                           trampolines, sizeof(trampolines));
    if (!patched) {
        replay_fail(9);
    }
}

static void install_active_mon(const uint8_t *party, const uint8_t *nickname,
                               uint16_t battle_address, uint16_t nickname_address)
{
    write_bytes(battle_address, party, 12);
    write_bytes((uint16_t) (battle_address + 12), party + 27, 2);
    write_bytes((uint16_t) (battle_address + 14), party + 33, 11);
    write_bytes((uint16_t) (battle_address + 25), party + 29, 4);
    write_bytes(nickname_address, nickname, 11);
}

static void install_initial_active_mons(void)
{
    install_active_mon(replay_player_party, replay_player_nicks, 0xd014, 0xd009);
    install_active_mon(replay_enemy_party, replay_enemy_nicks, 0xcfe5, 0xcfda);
    GB_write_memory(&gameboy, W_PLAYER_MON_NUMBER, 0);
    GB_write_memory(&gameboy, W_ENEMY_MON_PARTY_POS, 0);
    replay_initial_active_synced = true;
}

static void select_player_party_slot(uint8_t slot)
{
    uint8_t species = GB_read_memory(
        &gameboy,
        (uint16_t) (W_PARTY_SPECIES + slot)
    );
    GB_write_memory(&gameboy, 0xcf92, slot); /* wWhichPokemon */
    GB_write_memory(&gameboy, W_CUR_PARTY_SPECIES, species);
    GB_write_memory(&gameboy, W_BATTLE_MON_SPECIES2, species);
}

static uint8_t link_packet(uint8_t action)
{
    if (action <= 9) {
        return action;
    }
    if (action == 10) {
        return LINK_ACTION_NO_ACTION;
    }
    if (action == 11) {
        return LINK_ACTION_STRUGGLE;
    }
    return LINK_ACTION_RUN;
}

static bool finish_replay(void)
{
    if (replay_action_index != replay_action_count) {
        replay_fail(8);
        return false;
    }
    verify_previous_replay_action();
    replay_last_hook = 7;
    replay_state = 4;
    GB_set_execution_callback(&gameboy, NULL);
    return true;
}

static void runtime_callback(GB_gameboy_t *gb, uint16_t address, uint8_t opcode)
{
    (void) opcode;
    bool interesting = address == ADDR_TITLE_JOYPAD ||
                       address == ADDR_TEST_BATTLE_INIT_OPPONENT ||
                       address == ADDR_INIT_BATTLE_COMMON ||
                       address == ADDR_MAIN_BATTLE_LOOP ||
                       address == ADDR_DISPLAY_BATTLE_MENU ||
                       address == ADDR_MOVE_SELECTION_MENU ||
                       address == ADDR_CHOOSE_NEXT_MON ||
                       address == ADDR_LINK_EXCHANGE ||
                       address == ADDR_PLAYER_LOSS_CLEAR_SCREEN ||
                       address == ADDR_PLAYER_WIN_RETURN;
    if (!interesting) {
        return;
    }
    uint16_t bank = current_rom_bank();

    if (demo_state == 1 && bank == BANK_TEST_BATTLE && address == ADDR_TITLE_JOYPAD) {
        demo_state = 2;
        GB_set_execution_callback(gb, NULL);
        return;
    }
    if (replay_state == 1 && bank == BANK_TEST_BATTLE && address == ADDR_TITLE_JOYPAD) {
        replay_last_hook = 1;
        replay_state = 2;
        return;
    }
    if (replay_state < 2 || replay_state > 3) {
        return;
    }
    if (!replay_started && bank == BANK_TEST_BATTLE &&
        address == ADDR_TEST_BATTLE_INIT_OPPONENT) {
        replay_last_hook = 9;
        GB_write_memory(gb, W_CUR_OPPONENT, 200 + replay_trainer_class);
        GB_write_memory(gb, W_TRAINER_NO, 1);
        return;
    }
    if (!replay_started && bank == BANK_BATTLE_CORE &&
        address == ADDR_INIT_BATTLE_COMMON) {
        replay_last_hook = 2;
        install_replay_state();
        if (replay_state < 0) {
            return;
        }
        replay_started = true;
        replay_state = 3;
        return;
    }
    if (replay_started && bank == BANK_BATTLE_CORE &&
        address == ADDR_MAIN_BATTLE_LOOP) {
        replay_last_hook = 8;
        if (!replay_initial_active_synced) {
            install_initial_active_mons();
        }
        synchronize_previous_replay_action();
        return;
    }
    if (!replay_started || replay_action_index >= replay_action_count) {
        if (bank == BANK_BATTLE_CORE && replay_action_index == replay_action_count &&
            replay_outcome < 0 && address == ADDR_PLAYER_LOSS_CLEAR_SCREEN) {
            finish_replay();
        }
        else if (bank == BANK_BATTLE_CORE && replay_action_index == replay_action_count &&
                 replay_outcome > 0 && address == ADDR_PLAYER_WIN_RETURN &&
                 finish_replay()) {
            GB_registers_t *registers = GB_get_registers(gb);
            GB_write_memory(gb, registers->sp, ADDR_TERMINAL_TRAMPOLINE & 0xff);
            GB_write_memory(gb, (uint16_t) (registers->sp + 1), ADDR_TERMINAL_TRAMPOLINE >> 8);
        }
        return;
    }

    uint8_t player_action = replay_player_actions[replay_action_index];
    if (bank == BANK_BATTLE_CORE && address == ADDR_DISPLAY_BATTLE_MENU) {
        replay_last_hook = 3;
        verify_previous_replay_action();
        if (replay_requests[replay_action_index] != 0) {
            replay_fail(2);
            return;
        }
        if (player_action >= 4 && player_action <= 9) {
            select_player_party_slot(player_action - 4);
            GB_write_memory(gb, W_ACTION_RESULT, 1);
            uint8_t *trampoline = rom_address(BANK_BATTLE_CORE, ADDR_DISPLAY_TRAMPOLINE);
            if (!trampoline) {
                replay_fail(10);
                return;
            }
            trampoline[0] = 0xc3; /* jp SwitchPlayerMon */
            trampoline[1] = ADDR_SWITCH_PLAYER_MON & 0xff;
            trampoline[2] = ADDR_SWITCH_PLAYER_MON >> 8;
            return;
        }
        if (player_action <= 3 || player_action == 10 || player_action == 11) {
            GB_write_memory(gb, W_ACTION_RESULT, 0);
            uint8_t *trampoline = rom_address(BANK_BATTLE_CORE, ADDR_DISPLAY_TRAMPOLINE);
            if (!trampoline) {
                replay_fail(10);
                return;
            }
            trampoline[0] = 0xaf; /* xor a; ret: choose FIGHT */
            trampoline[1] = 0xc9;
            return;
        }
        replay_fail(3);
        return;
    }
    if (bank == BANK_BATTLE_CORE && address == ADDR_MOVE_SELECTION_MENU) {
        replay_last_hook = 4;
        if (player_action <= 3) {
            GB_write_memory(gb, W_PLAYER_MOVE_LIST_INDEX, player_action);
            uint8_t move = GB_read_memory(
                gb,
                (uint16_t) (W_BATTLE_MON_MOVES + player_action)
            );
            GB_write_memory(gb, W_PLAYER_SELECTED_MOVE, move);
            GB_write_memory(gb, W_TEST_BATTLE_PLAYER_SELECTED_MOVE, move);
        }
        else if (player_action == 11) {
            GB_write_memory(gb, W_PLAYER_MOVE_LIST_INDEX, 0);
            GB_write_memory(gb, W_PLAYER_SELECTED_MOVE, MOVE_STRUGGLE);
            GB_write_memory(gb, W_TEST_BATTLE_PLAYER_SELECTED_MOVE, MOVE_STRUGGLE);
        }
        else {
            replay_fail(4);
            return;
        }
        return;
    }
    if (bank == BANK_BATTLE_CORE && address == ADDR_CHOOSE_NEXT_MON) {
        replay_last_hook = 5;
        verify_previous_replay_action();
        if (replay_requests[replay_action_index] != 1 ||
            player_action < 4 || player_action > 9) {
            replay_fail(5);
            return;
        }
        select_player_party_slot(player_action - 4);
        return;
    }
    if (bank == BANK_BATTLE_CORE && address == ADDR_LINK_EXCHANGE) {
        replay_last_hook = 6;
        verify_previous_replay_action();
        uint8_t enemy_action = replay_enemy_actions[replay_action_index];
        GB_write_memory(gb, W_SERIAL_RECEIVE, link_packet(enemy_action));
        replay_action_index++;
    }
}

static void reset_replay_configuration(void)
{
    replay_state = 0;
    replay_started = false;
    replay_initial_active_synced = false;
    replay_outcome = 0;
    replay_trainer_class = 0;
    replay_action_count = 0;
    replay_action_index = 0;
    replay_mismatch_count = 0;
    replay_first_mismatch = 0;
    replay_first_expected = 0;
    replay_first_actual = 0;
    replay_last_verified = -1;
    replay_last_synced = -1;
    replay_last_hook = 0;
    memset(replay_expected_counts, 0, sizeof(replay_expected_counts));
}

int sb_create(void)
{
    if (initialized) {
        GB_free(&gameboy);
    }
    GB_init(&gameboy, GB_MODEL_DMG_B);
    GB_set_boot_rom_load_callback(&gameboy, load_boot_rom);
    GB_set_pixels_output(&gameboy, framebuffer);
    GB_set_rgb_encode_callback(&gameboy, encode_rgba);
    GB_set_sample_rate(&gameboy, AUDIO_SAMPLE_RATE);
    GB_apu_set_sample_callback(&gameboy, receive_audio_sample);
    audio_frame_count = 0;
    initialized = true;
    loaded = false;
    demo_state = 0;
    runtime_patched = false;
    replay_patch_count = 0;
    reset_replay_configuration();
    return 0;
}

int sb_load_rom(const uint8_t *rom, size_t size)
{
    if (!initialized || !rom || size < 0x150 || size > 8 * 1024 * 1024) {
        return -1;
    }
    GB_load_rom_from_buffer(&gameboy, rom, size);
    GB_reset(&gameboy);
    loaded = true;
    demo_state = 0;
    runtime_patched = false;
    replay_patch_count = 0;
    reset_replay_configuration();
    return 0;
}

void sb_reset(void)
{
    if (initialized && loaded) {
        restore_runtime_patch();
        GB_reset(&gameboy);
        GB_set_execution_callback(&gameboy, NULL);
        demo_state = 0;
        audio_frame_count = 0;
        reset_replay_configuration();
    }
}

int sb_run_frame(void)
{
    if (!initialized || !loaded) {
        return -1;
    }
    audio_frame_count = 0;
    GB_run_frame(&gameboy);
    return 0;
}

uintptr_t sb_audio_buffer(void)
{
    return (uintptr_t) audio_samples;
}

size_t sb_audio_frames(void)
{
    return audio_frame_count;
}

unsigned sb_audio_sample_rate(void)
{
    return AUDIO_SAMPLE_RATE;
}

uintptr_t sb_framebuffer(void)
{
    return (uintptr_t) framebuffer;
}

size_t sb_framebuffer_size(void)
{
    return sizeof(framebuffer);
}

void sb_set_key(unsigned key, int pressed)
{
    if (initialized && key <= GB_KEY_START) {
        GB_set_key_state(&gameboy, (GB_key_t) key, pressed != 0);
    }
}

uint8_t sb_read_memory(uint16_t address)
{
    return initialized ? GB_read_memory(&gameboy, address) : 0xff;
}

void sb_write_memory(uint16_t address, uint8_t value)
{
    if (initialized) {
        GB_write_memory(&gameboy, address, value);
    }
}

uint16_t sb_program_counter(void)
{
    return initialized ? GB_get_registers(&gameboy)->pc : 0;
}

void sb_start_test_battle(void)
{
    if (!initialized || !loaded || demo_state != 0 || replay_state != 0) {
        return;
    }
    if (!install_runtime_patch()) {
        demo_state = -1;
        return;
    }
    demo_state = 1;
    GB_set_execution_callback(&gameboy, runtime_callback);
}

int sb_test_battle_state(void)
{
    return demo_state;
}

int sb_replay_configure(unsigned player_count, unsigned enemy_count,
                        unsigned action_count, int outcome, unsigned trainer_class)
{
    if (!initialized || !loaded || replay_state != 0 ||
        player_count < 1 || player_count > 6 ||
        enemy_count < 1 || enemy_count > 6 ||
        action_count < 1 || action_count > MAX_REPLAY_ACTIONS ||
        (outcome != -1 && outcome != 1) ||
        trainer_class < 1 || trainer_class > 47) {
        return -1;
    }
    replay_player_count = (uint8_t) player_count;
    replay_enemy_count = (uint8_t) enemy_count;
    replay_action_count = action_count;
    replay_outcome = outcome;
    replay_trainer_class = (uint8_t) trainer_class;
    replay_action_index = 0;
    replay_mismatch_count = 0;
    replay_first_mismatch = 0;
    replay_first_expected = 0;
    replay_first_actual = 0;
    replay_last_verified = -1;
    replay_last_synced = -1;
    replay_started = false;
    replay_initial_active_synced = false;
    memset(replay_player_species, 0, sizeof(replay_player_species));
    memset(replay_enemy_species, 0, sizeof(replay_enemy_species));
    memset(replay_player_party, 0, sizeof(replay_player_party));
    memset(replay_enemy_party, 0, sizeof(replay_enemy_party));
    memset(replay_player_ot, 0x50, sizeof(replay_player_ot));
    memset(replay_enemy_ot, 0x50, sizeof(replay_enemy_ot));
    memset(replay_player_nicks, 0x50, sizeof(replay_player_nicks));
    memset(replay_enemy_nicks, 0x50, sizeof(replay_enemy_nicks));
    memset(replay_expected_counts, 0, sizeof(replay_expected_counts));
    return 0;
}

int sb_replay_set_byte(unsigned region, unsigned offset, unsigned value)
{
    uint8_t *target = NULL;
    size_t size = 0;
    switch (region) {
        case 0: target = replay_player_species; size = sizeof(replay_player_species); break;
        case 1: target = replay_player_party; size = sizeof(replay_player_party); break;
        case 2: target = replay_player_ot; size = sizeof(replay_player_ot); break;
        case 3: target = replay_player_nicks; size = sizeof(replay_player_nicks); break;
        case 4: target = replay_enemy_species; size = sizeof(replay_enemy_species); break;
        case 5: target = replay_enemy_party; size = sizeof(replay_enemy_party); break;
        case 6: target = replay_enemy_ot; size = sizeof(replay_enemy_ot); break;
        case 7: target = replay_enemy_nicks; size = sizeof(replay_enemy_nicks); break;
        default: return -1;
    }
    if (offset >= size || value > 0xff) {
        return -1;
    }
    target[offset] = (uint8_t) value;
    return 0;
}

int sb_replay_set_rng(unsigned index, unsigned value)
{
    if (index >= sizeof(replay_rng) || value > 0xff) {
        return -1;
    }
    replay_rng[index] = (uint8_t) value;
    return 0;
}

int sb_replay_set_rng_index(unsigned index)
{
    if (index >= 9) {
        return -1;
    }
    replay_rng_index = (uint8_t) index;
    return 0;
}

int sb_replay_set_action(unsigned index, unsigned player, unsigned enemy,
                         unsigned request)
{
    if (index >= replay_action_count || player > 12 || enemy > 12 || request > 2) {
        return -1;
    }
    replay_player_actions[index] = (uint8_t) player;
    replay_enemy_actions[index] = (uint8_t) enemy;
    replay_requests[index] = (uint8_t) request;
    return 0;
}

int sb_replay_expect(unsigned decision, unsigned address, unsigned value)
{
    if (decision >= replay_action_count || address > 0xffff || value > 0xff) {
        return -1;
    }
    unsigned index = replay_expected_counts[decision];
    if (index >= MAX_EXPECTATIONS) {
        return -1;
    }
    replay_expected_addresses[decision][index] = (uint16_t) address;
    replay_expected_values[decision][index] = (uint8_t) value;
    replay_expected_counts[decision]++;
    return 0;
}

int sb_start_recorded_battle(void)
{
    if (!initialized || !loaded || replay_state != 0 || !replay_action_count) {
        return -1;
    }
    if (!install_runtime_patch()) {
        replay_state = -1;
        return -1;
    }
    GB_reset(&gameboy);
    replay_state = 1;
    GB_set_execution_callback(&gameboy, runtime_callback);
    return 0;
}

int sb_replay_state(void)
{
    return replay_state;
}

unsigned sb_replay_action_index(void)
{
    return replay_action_index;
}

int sb_replay_mismatch_count(void)
{
    return replay_mismatch_count;
}

int sb_replay_first_mismatch(void)
{
    return replay_first_mismatch;
}

int sb_replay_last_hook(void)
{
    return replay_last_hook;
}

int sb_replay_first_expected(void)
{
    return replay_first_expected;
}

int sb_replay_first_actual(void)
{
    return replay_first_actual;
}

size_t sb_state_size(void)
{
    return initialized ? GB_get_save_state_size(&gameboy) : 0;
}

int sb_save_state(uint8_t *output, size_t size)
{
    size_t required = sb_state_size();
    if (!loaded || !output || size < required) {
        return -1;
    }
    GB_save_state_to_buffer(&gameboy, output);
    return (int) required;
}

int sb_load_state(const uint8_t *state, size_t size)
{
    if (!loaded || !state || !size) {
        return -1;
    }
    return GB_load_state_from_buffer(&gameboy, state, size);
}
