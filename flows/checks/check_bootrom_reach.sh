#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# check_bootrom_reach.sh — the boot ROM's size exists in several places. Prove
# the AHB decode, AS ELABORATED, reaches every word the ROM holds, and name
# every copy of the size that disagrees.
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# The copies of one number (all WORD address widths, bytes = 4 * 2**N):
#   flow    BOOTROM_ADDRW                         (Makefile.bootrom / nanosoc.config)
#   ROM     bootrom.sv word_addr width            (generated, bootrom_gen.py -a)
#   wrapper ROM_WORD_ADDR_W localparam            (generated, same -a)
#   decode  the ROM_ADDR_W VALUE the SoC passes   (build_soc/rtl, e.g.
#           nanosoc_ss_cpu.sv `.ROM_ADDR_W (BOOTROM_ADDR_W)`, resolved through
#           the SoC config package) fed through the wrapper's HADDR slice
#   SW      BOOTROM_0 LENGTH in the bootloader .ld (generated from the YAML)
#
# Two classes of finding, deliberately treated differently:
#
#   HARD (always rc 1) -- the decode cannot reach part of the ROM, or the
#     generated files disagree with each other. That is a broken design on every
#     project: words are unreachable and alias with no message. It is what the
#     old HADDR[ROM_ADDR_W-1:2] slice did, and what a too-small ROM_ADDR_W
#     override does through a correct slice.
#
#   SIZE (MEM_SIZE_CHECK: warn by default, error opt-in, off) -- the ROM is
#     smaller than the region the SoC decodes or the linker offers. Every word is
#     reachable; the ROM simply repeats inside a larger window, and an image
#     bigger than the ROM would alias. The Academic Access projects build a 1 KB
#     ROM (flow default BOOTROM_ADDRW = 8) under an 8 KB region and an 8 KB
#     linker script today; that must stay a named warning, not break their
#     build. Same knob, same waiver (MEM_SIZE_WAIVE=BOOTROM) as
#     check_mem_sizes.sh.
#
# Usage: check_bootrom_reach.sh <bootrom.sv> <region.v> <ADDRW> [bootloader.ld] [soc_config_pkg.sv]
#        check_bootrom_reach.sh --self-test
#-----------------------------------------------------------------------------
set -uo pipefail

sev()    { echo "${MEM_SIZE_CHECK:-warn}"; }
waived() { case " ${MEM_SIZE_WAIVE:-} " in *" BOOTROM "*) return 0 ;; *) return 1 ;; esac; }
words()  { echo $(( 1 << $1 )); }
bytes()  { echo $(( 4 << $1 )); }
sz()     { echo "$(words "$1") words ($(bytes "$1") bytes)"; }

HARD=0; SIZE=0
hard() { echo "ERROR: check_bootrom_reach: $1" >&2; shift; for l in "$@"; do echo "    $l" >&2; done; HARD=$((HARD+1)); }
size() {
  local tag; tag=$(sev | tr a-z A-Z)
  [ "$tag" = OFF ] && return 0
  if waived; then echo "note: check_bootrom_reach: $1 (waived by MEM_SIZE_WAIVE=BOOTROM)" >&2; return 0; fi
  echo "$tag: check_bootrom_reach: $1" >&2; shift; for l in "$@"; do echo "    $l" >&2; done
  SIZE=$((SIZE+1))
}

# Integer value of NAME from `localparam|parameter [type] [range] NAME = <int>` in
# FILE, wherever on the line it sits (an inline `#(parameter NAME = 11)` counts).
param_value() {
  grep -oE "(localparam|parameter)[[:space:]]+([A-Za-z_]+[[:space:]]+)?(\[[^]]*\][[:space:]]*)?$1[[:space:]]*=[[:space:]]*[0-9]+" "$2" \
    | head -1 | grep -oE '[0-9]+$'
}

run() {
  local ROM_SV="$1" REGION_V="$2" ADDRW="$3" LD="${4:-}" PKG="${5:-}"
  local f; for f in "$ROM_SV" "$REGION_V"; do
    [ -f "$f" ] || { hard "missing $f"; return; }; done

  # 1. ROM depth, from the generated word_addr port.
  local rom_w
  rom_w=$(sed -nE 's/.*\[[[:space:]]*([0-9]+)[[:space:]]*-[[:space:]]*1[[:space:]]*:[[:space:]]*0[[:space:]]*\][[:space:]]*word_addr.*/\1/p' "$ROM_SV" | head -1)
  [ -n "$rom_w" ] || { hard "cannot read the word_addr width from $ROM_SV"; return; }

  if [ "$rom_w" != "$ADDRW" ]; then
    hard "the generated ROM and the flow disagree about its size (stale or foreign bootrom.sv):" \
         "BOOTROM_ADDRW (flow)          $(sz "$ADDRW")" \
         "$(basename "$ROM_SV") word_addr   $(sz "$rom_w")"
  fi

  # 2. The wrapper's record of the -a it was generated with.
  local lw; lw=$(param_value ROM_WORD_ADDR_W "$REGION_V")
  if [ -n "$lw" ] && [ "$lw" != "$rom_w" ]; then
    hard "the region wrapper and the ROM were generated from different sizes:" \
         "$(basename "$REGION_V") ROM_WORD_ADDR_W   $(sz "$lw")" \
         "$(basename "$ROM_SV") word_addr         $(sz "$rom_w")"
  fi

  # 3. The decode: slice FORM from the wrapper, ROM_ADDR_W VALUE from the SoC.
  local slice; slice=$(sed -nE 's/.*word_addr[[:space:]]*\([[:space:]]*HADDR[[:space:]]*\[(.*)\][[:space:]]*\).*/\1/p' "$REGION_V" | head -1)
  slice=$(echo "$slice" | tr -d '[:space:]')
  local off
  case "$slice" in
    "ROM_ADDR_W+1:2") off=0 ;;
    "ROM_ADDR_W-1:2") off=2 ;;
    *) hard "cannot read the decode slice from $REGION_V" "found: word_addr (HADDR[$slice])"; return ;;
  esac

  local mod; mod=$(basename "$REGION_V"); mod="${mod%.*}"
  local val="" src="" expr=""
  if [ -n "$PKG" ]; then
    if [ ! -f "$PKG" ]; then
      size "SoC config package not found, so the ROM_ADDR_W the SoC elaborates cannot be checked: $PKG"
    else
      local d inst; d=$(dirname "$PKG")
      inst=$(grep -lE "^[[:space:]]*$mod[[:space:]]*#" "$d"/*.sv "$d"/*.v 2>/dev/null | head -1)
      if [ -n "$inst" ]; then
        expr=$(awk -v m="$mod" '
          $0 ~ "^[[:space:]]*" m "[[:space:]]*#" {f=1}
          f && /\.ROM_ADDR_W[[:space:]]*\(/ { s=$0; sub(/.*\.ROM_ADDR_W[[:space:]]*\([[:space:]]*/,"",s); sub(/[[:space:]]*\).*/,"",s); print s; exit }
          f && /\)[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/ { exit }' "$inst")
        if [[ "$expr" =~ ^[0-9]+$ ]]; then val="$expr"; src="literal in $(basename "$inst")"
        elif [[ "$expr" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          val=$(param_value "$expr" "$PKG"); src="$expr in $(basename "$PKG")"
          [ -n "$val" ] || { val=$(param_value "$expr" "$inst"); src="$expr default in $(basename "$inst")"; }
        fi
        if [ -z "$val" ] && [ -n "$expr" ]; then
          size "cannot resolve the ROM_ADDR_W the SoC passes ('$expr' in $(basename "$inst")); checking the wrapper default instead"
        fi
      fi
    fi
  fi
  if [ -z "$val" ]; then
    val=$(param_value ROM_ADDR_W "$REGION_V"); src="parameter default in $(basename "$REGION_V")"
    [ -n "$val" ] || { hard "cannot read ROM_ADDR_W from $REGION_V or the SoC"; return; }
  fi

  local dec_w=$(( val - off ))
  if [ "$dec_w" -lt "$rom_w" ]; then
    hard "the AHB decode cannot reach the whole boot ROM." \
         "$(basename "$ROM_SV") holds      $(sz "$rom_w")" \
         "the decode reaches   $(sz "$dec_w")" \
         "ROM_ADDR_W = $val ($src), slice word_addr (HADDR[$slice])" \
         "Everything above $(bytes "$dec_w") bytes aliases onto the bottom of the ROM." \
         "ROM_ADDR_W is a WORD address width and must be at least the ROM's ($rom_w);" \
         "the byte slice must be [ROM_ADDR_W+1:2]."
  elif [ "$dec_w" -gt "$rom_w" ]; then
    size "the SoC decodes a larger boot ROM than was generated:" \
         "ROM_ADDR_W = $val ($src)   $(sz "$dec_w")" \
         "$(basename "$ROM_SV") holds                 $(sz "$rom_w")" \
         "Every word is reachable; the ROM repeats $(( 1 << (dec_w - rom_w) ))x inside its region." \
         "Set BOOTROM_ADDRW := $val in nanosoc.config to build the ROM the SoC expects."
  fi

  # 4. Linker MEMORY block.
  if [ -n "$LD" ]; then
    if [ ! -f "$LD" ]; then
      size "bootloader linker script not found, so its BOOTROM_0 LENGTH cannot be checked: $LD"
    else
      local ld_len
      ld_len=$(sed -nE 's/^[[:space:]]*BOOTROM_0[[:space:]]*\([rwx]+\)[[:space:]]*:[[:space:]]*ORIGIN[[:space:]]*=[^,]+,[[:space:]]*LENGTH[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\1/p' "$LD" | head -1)
      if [ -z "$ld_len" ]; then
        size "no BOOTROM_0 MEMORY entry found in $LD"
      elif [ $(( ld_len )) -gt $(bytes "$rom_w") ]; then
        size "the bootloader linker script offers more ROM than exists:" \
             "$(basename "$LD") BOOTROM_0 LENGTH = $(printf '0x%X' $(( ld_len ))) ($(( ld_len )) bytes)" \
             "$(basename "$ROM_SV") holds          $(bytes "$rom_w") bytes ($(words "$rom_w") words)" \
             "A bootloader between those sizes links clean and aliases at run time."
      fi
    fi
  fi
}

self_test() {
  local t rc=0; t=$(mktemp -d)
  printf 'module bootrom (\n  input logic [11-1:0] word_addr\n);\nendmodule\n' > "$t/rom.sv"
  mk() { printf 'module r #(parameter ROM_ADDR_W = %s)();\n  localparam ROM_WORD_ADDR_W = 11;\n  b u (.word_addr (HADDR[%s]));\nendmodule\n' "$2" "$3" > "$t/$1.v"; }
  mk good 11 'ROM_ADDR_W+1:2'; mk oldslice 11 'ROM_ADDR_W-1:2'; mk param9 9 'ROM_ADDR_W+1:2'
  printf 'MEMORY {\n  BOOTROM_0  (rx) : ORIGIN = 0x08000000, LENGTH = 0x4000\n}\n' > "$t/big.ld"
  expect() { # <want-rc> <label> <grep-for-or-empty> <env...> -- <args...>
    local want=$1 label=$2 pat=$3; shift 3; local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    env "${envs[@]}" "$0" "$@" > "$t/out" 2>&1; local got=$?
    if [ "$got" = "$want" ] && { [ -z "$pat" ] || grep -q "$pat" "$t/out"; }; then echo "PASS  self-test: $label"
    else echo "FAIL  self-test: $label (rc $got, wanted $want)" >&2; cat "$t/out" >&2; rc=1; fi; }
  expect 0 "full-reach decode accepted"                            ""  MEM_SIZE_CHECK=error -- "$t/rom.sv" "$t/good.v" 11
  expect 1 "old slice rejected, names both sizes"                  "reaches   512 words (2048 bytes)" MEM_SIZE_CHECK=warn -- "$t/rom.sv" "$t/oldslice.v" 11
  expect 1 "ROM_ADDR_W=9 over an 11-bit ROM rejected (value, not text)" "ROM_ADDR_W = 9" MEM_SIZE_CHECK=warn -- "$t/rom.sv" "$t/param9.v" 11
  expect 0 "oversized linker script is a WARNING by default"       "WARN: .*offers more ROM" MEM_SIZE_CHECK=warn -- "$t/rom.sv" "$t/good.v" 11 "$t/big.ld"
  expect 1 "oversized linker script is an ERROR when opted in"     "ERROR: .*offers more ROM" MEM_SIZE_CHECK=error -- "$t/rom.sv" "$t/good.v" 11 "$t/big.ld"
  expect 1 "missing linker script is an ERROR when opted in"       "not found" MEM_SIZE_CHECK=error -- "$t/rom.sv" "$t/good.v" 11 "$t/nope.ld"
  expect 1 "a hard reach error ignores MEM_SIZE_CHECK=off"         "cannot reach" MEM_SIZE_CHECK=off -- "$t/rom.sv" "$t/oldslice.v" 11
  rm -rf "$t"; return $rc
}

[ "${1:-}" = "--self-test" ] && { self_test; exit $?; }
if [ $# -lt 3 ]; then
  echo "usage: $0 <bootrom.sv> <region.v> <ADDRW> [bootloader.ld] [soc_config_pkg.sv] | --self-test" >&2; exit 2
fi
run "$@"
[ "$HARD" -gt 0 ] && exit 1
[ "$SIZE" -gt 0 ] && [ "$(sev)" = "error" ] && exit 1
exit 0
