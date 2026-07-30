/*
 * Minimal browser bridge for SameBoy's Expat-licensed core.
 *
 * The ROM is supplied by the browser at runtime and is never embedded in this
 * module. Keep this bridge deliberately small: rendering, input, save states,
 * and memory inspection are enough for the replay adapter without coupling the
 * dashboard to a full libretro frontend.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "Core/gb.h"
#include "Core/display.h"
#include "Core/joypad.h"
#include "Core/memory.h"
#include "Core/save_state.h"

#include "dmg_boot.h"

static GB_gameboy_t gameboy;
static uint32_t framebuffer[160 * 144];
static bool initialized;
static bool loaded;
static int demo_state;
static bool demo_patched;
static uint8_t demo_original[3];

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

static uint8_t *rom_bytes(size_t *size)
{
    uint16_t bank = 0;
    return GB_get_direct_access(&gameboy, GB_DIRECT_ACCESS_ROM, size, &bank);
}

static void restore_demo_patch(void)
{
    if (!demo_patched) {
        return;
    }
    size_t size = 0;
    uint8_t *rom = rom_bytes(&size);
    if (rom && size > 0x443d) {
        memcpy(rom + 0x443b, demo_original, sizeof(demo_original));
    }
    demo_patched = false;
}

static void detect_test_battle(GB_gameboy_t *gb, uint16_t address, uint8_t opcode)
{
    (void) opcode;
    if (demo_state == 1 && address == 0x443b) {
        demo_state = 2;
        GB_set_execution_callback(gb, NULL);
    }
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
    initialized = true;
    loaded = false;
    demo_state = 0;
    demo_patched = false;
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
    demo_patched = false;
    return 0;
}

void sb_reset(void)
{
    if (initialized && loaded) {
        restore_demo_patch();
        GB_reset(&gameboy);
        GB_set_execution_callback(&gameboy, NULL);
        demo_state = 0;
    }
}

int sb_run_frame(void)
{
    if (!initialized || !loaded) {
        return -1;
    }
    GB_run_frame(&gameboy);
    return 0;
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
    if (!initialized) {
        return 0;
    }
    return GB_get_registers(&gameboy)->pc;
}

void sb_start_test_battle(void)
{
    if (!initialized || !loaded || demo_state != 0) {
        return;
    }
    size_t size = 0;
    uint8_t *rom = rom_bytes(&size);
    static const uint8_t trampoline[] = {
        0xcd, 0x0f, 0x19, /* call ClearScreen */
        0xcd, 0x80, 0x36, /* call LoadFontTilePatterns */
        0xcd, 0xc0, 0x36, /* call LoadHpBarAndStatusTilePatterns */
        0xcd, 0x82, 0x00, /* call ClearSprites */
        0xcd, 0xed, 0x3d, /* call RunDefaultPaletteCommand */
        0xc3, 0xa6, 0x4d, /* jp TestBattle */
    };
    if (!rom || size <= 0x7c49 + sizeof(trampoline)) {
        demo_state = -1;
        return;
    }
    memcpy(demo_original, rom + 0x443b, sizeof(demo_original));
    memcpy(rom + 0x7c49, trampoline, sizeof(trampoline));
    rom[0x443b] = 0xc3;
    rom[0x443c] = 0x49;
    rom[0x443d] = 0x7c;
    demo_patched = true;
    write_name(0xd158, "RED");
    write_name(0xd34a, "BLUE");
    demo_state = 1;
    GB_set_execution_callback(&gameboy, detect_test_battle);
}

int sb_test_battle_state(void)
{
    return demo_state;
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
