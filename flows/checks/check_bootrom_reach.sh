#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# check_bootrom_reach.sh — the boot ROM's size exists in four places. Prove the
# AHB decode can actually reach every word the ROM holds.
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# The four copies of one number:
#   flow   BOOTROM_ADDRW                  (flows/Makefile.bootrom / nanosoc.config)
#   ROM    bootrom.sv  word_addr width    (generated)
#   decode nanosoc_region_bootrom.v slice (generated)
#   SW     BOOTROM_0 LENGTH in the .ld    (generated from the system YAML)
#
# All four are WORD address widths or the bytes they imply: bytes = 4 * 2**N.
# The decode used to slice HADDR[ROM_ADDR_W-1:2], reading the WORD width as a
# BYTE width, which drove ROM_ADDR_W-2 of the ROM's ROM_ADDR_W word_addr bits.
# With ROM_ADDR_W = 11 that is 512 of 2048 words: the top 6 KB of an 8 KB ROM
# was unreachable and aliased onto the bottom 2 KB, with nothing reporting it.
#
# Usage: check_bootrom_reach.sh <bootrom.sv> <nanosoc_region_bootrom.v> <ADDRW> [bootloader.ld]
# Exit 0 = every word reachable and all copies agree; 1 = mismatch (named).
#-----------------------------------------------------------------------------
set -uo pipefail

ROM_SV="${1:-}"; REGION_V="${2:-}"; ADDRW="${3:-}"; LD="${4:-}"

self_test() {
  local t rc=0; t=$(mktemp -d)
  printf 'module bootrom (\n  input logic [11-1:0] word_addr\n);\nendmodule\n' > "$t/rom.sv"
  printf 'module r #(parameter ROM_ADDR_W = 11)();\n  localparam ROM_WORD_ADDR_W = 11;\n  b u (.word_addr (HADDR[ROM_ADDR_W+1:2]));\nendmodule\n' > "$t/good.v"
  printf 'module r #(parameter ROM_ADDR_W = 11)();\n  localparam ROM_WORD_ADDR_W = 11;\n  b u (.word_addr (HADDR[ROM_ADDR_W-1:2]));\nendmodule\n' > "$t/bad.v"
  "$0" "$t/rom.sv" "$t/good.v" 11 >/dev/null 2>&1 \
    && echo "PASS  self-test: full-reach decode accepted" \
    || { echo "FAIL  self-test: full-reach decode rejected" >&2; rc=1; }
  if "$0" "$t/rom.sv" "$t/bad.v" 11 >"$t/out" 2>&1; then
    echo "FAIL  self-test: the 2 KB-of-8 KB decode was ACCEPTED" >&2; rc=1
  elif grep -q '2048 words (8192 bytes)' "$t/out" && grep -q '512 words (2048 bytes)' "$t/out"; then
    echo "PASS  self-test: aliasing decode rejected, message names both sizes"
  else
    echo "FAIL  self-test: rejected but the message does not name both sizes" >&2
    cat "$t/out" >&2; rc=1
  fi
  rm -rf "$t"; return $rc
}

[ "${1:-}" = "--self-test" ] && { self_test; exit $?; }

if [ -z "$ROM_SV" ] || [ -z "$REGION_V" ] || [ -z "$ADDRW" ]; then
  echo "usage: $0 <bootrom.sv> <region.v> <ADDRW> [bootloader.ld] | --self-test" >&2; exit 2
fi
for f in "$ROM_SV" "$REGION_V"; do
  [ -f "$f" ] || { echo "ERROR: check_bootrom_reach: missing $f" >&2; exit 1; }
done

words() { echo $(( 1 << $1 )); }
bytes() { echo $(( 4 << $1 )); }
say()   { echo "    $1: $(words "$2") words ($(bytes "$2") bytes)"; }

rc=0

# 1. ROM depth, from the generated word_addr port width.
rom_w=$(sed -nE 's/.*word_addr.*\[[[:space:]]*([0-9]+)[[:space:]]*-[[:space:]]*1[[:space:]]*:[[:space:]]*0\].*/\1/p' "$ROM_SV" | head -1)
[ -n "$rom_w" ] || rom_w=$(sed -nE 's/.*\[[[:space:]]*([0-9]+)-1:0\][[:space:]]*word_addr.*/\1/p' "$ROM_SV" | head -1)

# 2. Reachable depth, from the generated decode slice.
slice=$(sed -nE 's/.*word_addr[[:space:]]*\([[:space:]]*HADDR\[(.*)\][[:space:]]*\).*/\1/p' "$REGION_V" | head -1)
case "$slice" in
  "ROM_ADDR_W+1:2") reach_w="$rom_w" ;;
  "ROM_ADDR_W-1:2") reach_w=$(( rom_w - 2 )) ;;
  *)  echo "ERROR: check_bootrom_reach: cannot read the decode slice from $REGION_V" >&2
      echo "       found: word_addr (HADDR[$slice])" >&2; exit 1 ;;
esac

if [ "$rom_w" != "$ADDRW" ]; then
  echo "ERROR: check_bootrom_reach: the ROM and the flow disagree about its size:" >&2
  say "BOOTROM_ADDRW (flow)" "$ADDRW" >&2
  say "$(basename "$ROM_SV") word_addr" "$rom_w" >&2
  rc=1
fi

if [ "$reach_w" != "$rom_w" ]; then
  echo "ERROR: check_bootrom_reach: the AHB decode cannot reach the whole boot ROM." >&2
  echo "    $(basename "$ROM_SV") holds      $(words "$rom_w") words ($(bytes "$rom_w") bytes)" >&2
  echo "    $(basename "$REGION_V") reaches  $(words "$reach_w") words ($(bytes "$reach_w") bytes)" >&2
  echo "    decode slice: word_addr (HADDR[$slice])" >&2
  echo "    Everything above $(bytes "$reach_w") bytes aliases onto the bottom of the ROM." >&2
  echo "    ROM_ADDR_W is a WORD address width; the byte slice must be [ROM_ADDR_W+1:2]." >&2
  rc=1
fi

# 3. Linker MEMORY block, if one was given.
if [ -n "$LD" ] && [ -f "$LD" ]; then
  ld_len=$(sed -nE 's/^[[:space:]]*BOOTROM_0[[:space:]]*\([rwx]+\)[[:space:]]*:[[:space:]]*ORIGIN[[:space:]]*=[^,]+,[[:space:]]*LENGTH[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\1/p' "$LD" | head -1)
  if [ -n "$ld_len" ] && [ $(( ld_len )) -gt $(bytes "$rom_w") ]; then
    echo "ERROR: check_bootrom_reach: the bootloader linker script offers more ROM than exists:" >&2
    echo "    $(basename "$LD") BOOTROM_0 LENGTH = $(printf '0x%X' $(( ld_len ))) ($(( ld_len )) bytes)" >&2
    echo "    $(basename "$ROM_SV") holds          $(bytes "$rom_w") bytes ($(words "$rom_w") words)" >&2
    rc=1
  fi
fi

exit $rc
