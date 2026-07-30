#!/usr/bin/env bash
set -euo pipefail

readonly expected_commit=213a12ce93d66b105a113debd9396306066a7cfc
readonly repository=https://github.com/LIJI32/SameBoy.git
script_path="$(realpath "${BASH_SOURCE[0]}")"
readonly script_path
readonly script_dir="${script_path%/*}"
readonly output_dir="${1:-${script_dir}/../battle_training/web}"

sameboy_root="${SAMEBOY_ROOT:-}"
cleanup=""
if [[ -z "${sameboy_root}" ]]; then
  cleanup="$(mktemp -d)"
  trap 'rm -rf "${cleanup}"' EXIT
  git clone --quiet "${repository}" "${cleanup}/SameBoy"
  git -C "${cleanup}/SameBoy" checkout --quiet "${expected_commit}"
  sameboy_root="${cleanup}/SameBoy"
fi

actual_commit="$(git -C "${sameboy_root}" rev-parse HEAD)"
if [[ "${actual_commit}" != "${expected_commit}" ]]; then
  printf 'SameBoy revision mismatch: expected %s, got %s\n' "${expected_commit}" "${actual_commit}" >&2
  exit 1
fi

if [[ ! -f "${sameboy_root}/build/bin/BootROMs/dmg_boot.bin" ]]; then
  make -C "${sameboy_root}" bootroms
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "${build_dir}" ${cleanup:+"${cleanup}"}' EXIT
python - "${sameboy_root}/build/bin/BootROMs/dmg_boot.bin" "${build_dir}/dmg_boot.h" <<'PY'
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
data = source.read_bytes()
rows = [", ".join(f"0x{byte:02x}" for byte in data[index:index + 16]) for index in range(0, len(data), 16)]
target.write_text(
    "#pragma once\n#include <stddef.h>\n#include <stdint.h>\n"
    "static const uint8_t sameboy_dmg_boot[] = {\n    "
    + ",\n    ".join(rows)
    + "\n};\n"
    + f"static const size_t sameboy_dmg_boot_length = {len(data)};\n"
)
PY

mkdir -p "${output_dir}"
core_sources=(
  gb sgb apu memory mbc timing display camera sm83_cpu joypad save_state random rumble
)
source_paths=()
for source in "${core_sources[@]}"; do
  source_paths+=("${sameboy_root}/Core/${source}.c")
done

emcc \
  -std=gnu11 -O3 -flto \
  -D_GNU_SOURCE -DGB_INTERNAL \
  -DGB_DISABLE_TIMEKEEPING -DGB_DISABLE_REWIND -DGB_DISABLE_DEBUGGER \
  -DGB_DISABLE_CHEATS -DGB_DISABLE_CHEAT_SEARCH \
  -DGB_VERSION='"1.0.3"' -DGB_COPYRIGHT_YEAR='"2026"' \
  -I"${sameboy_root}" -I"${build_dir}" \
  "${script_dir}/sameboy_web.c" "${source_paths[@]}" \
  --no-entry \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createSameBoy \
  -sENVIRONMENT=worker -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=33554432 \
  -sFILESYSTEM=0 -sASSERTIONS=0 -sEXPORTED_RUNTIME_METHODS='["HEAPU8"]' \
  -sEXPORTED_FUNCTIONS='["_malloc","_free","_sb_create","_sb_load_rom","_sb_reset","_sb_run_frame","_sb_framebuffer","_sb_framebuffer_size","_sb_set_key","_sb_read_memory","_sb_write_memory","_sb_program_counter","_sb_start_test_battle","_sb_test_battle_state","_sb_replay_configure","_sb_replay_set_byte","_sb_replay_set_rng","_sb_replay_set_rng_index","_sb_replay_set_action","_sb_replay_expect","_sb_start_recorded_battle","_sb_replay_state","_sb_replay_action_index","_sb_replay_mismatch_count","_sb_replay_first_mismatch","_sb_replay_last_hook","_sb_replay_first_expected","_sb_replay_first_actual","_sb_state_size","_sb_save_state","_sb_load_state"]' \
  -o "${output_dir}/sameboy-core.js"

cp "${sameboy_root}/LICENSE" "${output_dir}/sameboy-LICENSE.txt"
printf 'Built SameBoy web core %s (%s bytes)\n' \
  "${expected_commit}" "$(stat -c %s "${output_dir}/sameboy-core.wasm")"
