#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# check_mem_sizes.sh — every memory size in this SoC exists twice. Make them
# disagree loudly instead of silently.
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# A nanoSoC memory is sized in TWO places that nothing checks against each other:
#
#   RTL   build_soc/rtl/nanosoc_soc_config_pkg.sv   <REGION>_RAM_ADDR_W
#   SW    build_soc/firmware/nanosoc_memmap.mk      <REGION>_SIZE
#                            (and the .ld fragment next to it)
#
# and the two use different units. sl_ahb_sram / sl_ahb_rom slice
# HADDR[RAM_ADDR_W-1:0] and index a word array of 1<<(RAM_ADDR_W-2) entries, so
#     RAM_ADDR_W is a BYTE address width:   bytes = 1 << RAM_ADDR_W
# while the boot ROM's word_addr is a WORD address width, so
#     BOOTROM_ADDR_W is a WORD address width:  bytes = 4 << BOOTROM_ADDR_W
#
# The live consequence: IMEM_RAM_ADDR_W = 14 is 16 KB of hardware, while
# IMEM_0_SIZE = 0x10000 and the linker's LENGTH = 0x10000 both say 64 KB. An
# application between 16 KB and 64 KB links clean and then aliases in silence.
#
# Severity is a knob because the two Academic Access consumers carry this exact
# mismatch today and this check must not break their builds:
#   MEM_SIZE_CHECK=warn   (default) print and return 0  -- today's behaviour + a name
#   MEM_SIZE_CHECK=error  print and return 1            -- what a project should set
#   MEM_SIZE_CHECK=off    say nothing
#
# Usage:
#   check_mem_sizes.sh <config_pkg.sv> <nanosoc_memmap.mk> [ld_dir]
#   check_mem_sizes.sh --self-test
#-----------------------------------------------------------------------------
set -uo pipefail

sev() { echo "${MEM_SIZE_CHECK:-warn}"; }
# Regions a project has NOT yet reconciled. Named, so a waiver is a statement
# about a specific memory rather than a switch that turns the check off.
waived() { case " ${MEM_SIZE_WAIVE:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

hex() { printf '0x%X' "$1"; }

# Print a mismatch. Always names BOTH numbers, both units and both files.
report() {
  local region="$1" rtl_param="$2" rtl_w="$3" rtl_bytes="$4" sw_name="$5" sw_bytes="$6" pkg="$7" mm="$8"
  {
    echo "$(sev | tr a-z A-Z): mem-size: $region is declared twice and the two disagree:"
    echo "    RTL  $rtl_param = $rtl_w  ->  $(hex "$rtl_bytes") ($((rtl_bytes/1024)) KB)   $pkg"
    echo "    SW   $sw_name = $(hex "$sw_bytes")  ($((sw_bytes/1024)) KB)   $mm"
    echo "    The hardware is the smaller of the two. Software built against the"
    echo "    larger number links clean and aliases at run time with no message."
  } >&2
}

scan() {
  local pkg="$1" mm="$2" lddir="${3:-}"
  local bad=0

  [ -f "$pkg" ] || { echo "check_mem_sizes: no config package at $pkg (nothing to check)" >&2; return 0; }
  [ -f "$mm" ]  || { echo "check_mem_sizes: no memory map at $mm (nothing to check)" >&2; return 0; }

  # ---- byte-width regions: <PREFIX>_RAM_ADDR_W ----
  while read -r param width; do
    [ -n "$param" ] || continue
    local prefix="${param%_RAM_ADDR_W}"
    local rtl_bytes=$(( 1 << width ))
    local sw_name="" sw_val=""
    for cand in "${prefix}_SIZE" "${prefix}_0_SIZE"; do
      sw_val=$(sed -nE "s/^[[:space:]]*${cand}[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\1/p" "$mm" | head -1)
      if [ -n "$sw_val" ]; then sw_name="$cand"; break; fi
    done
    [ -n "$sw_name" ] || continue
    local sw_bytes=$(( sw_val ))
    [ "$sw_bytes" -gt 0 ] || continue
    if [ "$sw_bytes" != "$rtl_bytes" ]; then
      if waived "$prefix"; then
        echo "note: mem-size: $prefix mismatch waived by MEM_SIZE_WAIVE ($(hex "$rtl_bytes") of hardware, $(hex "$sw_bytes") declared)" >&2
        continue
      fi
      report "$prefix" "$param" "$width" "$rtl_bytes" "$sw_name" "$sw_bytes" "$pkg" "$mm"
      bad=1
    fi
  done < <(sed -nE 's/^[[:space:]]*localparam[[:space:]]+(int[[:space:]]+)?([A-Z0-9_]+_RAM_ADDR_W)[[:space:]]*=[[:space:]]*([0-9]+).*/\2 \3/p' "$pkg")

  # ---- word-width region: BOOTROM_ADDR_W (bytes = 4 << N) ----
  local brw
  brw=$(sed -nE 's/^[[:space:]]*localparam[[:space:]]+(int[[:space:]]+)?BOOTROM_ADDR_W[[:space:]]*=[[:space:]]*([0-9]+).*/\2/p' "$pkg" | head -1)
  if [ -n "$brw" ]; then
    local rtl_bytes=$(( 4 << brw ))
    local sw_val
    sw_val=$(sed -nE 's/^[[:space:]]*BOOTROM_0_SIZE[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\1/p' "$mm" | head -1)
    if [ -n "$sw_val" ] && [ $(( sw_val )) -gt 0 ] && [ $(( sw_val )) != "$rtl_bytes" ]; then
      report "BOOTROM" "BOOTROM_ADDR_W" "$brw" "$rtl_bytes" "BOOTROM_0_SIZE" "$(( sw_val ))" "$pkg" "$mm"
      bad=1
    fi
  fi

  # ---- linker MEMORY blocks next to the memory map ----
  if [ -n "$lddir" ] && [ -d "$lddir" ]; then
    for ld in "$lddir"/*.ld; do
      [ -e "$ld" ] || continue
      # The debug tester is the ADP host model, not SoC firmware: its MEMORY
      # block is a deliberately oversized window onto the SoC (phys_size in the
      # system YAML), so it is not a claim about how much RAM exists.
      case "$(basename "$ld")" in *debugtester*) continue ;; esac
      while read -r region len; do
        local prefix="${region%_0}"
        local param="" width=""
        if [ "$region" = "BOOTROM_0" ]; then
          [ -n "$brw" ] || continue
          param=BOOTROM_ADDR_W; width="$brw"; local rtl_bytes=$(( 4 << brw ))
        else
          width=$(sed -nE "s/^[[:space:]]*localparam[[:space:]]+(int[[:space:]]+)?${prefix}_RAM_ADDR_W[[:space:]]*=[[:space:]]*([0-9]+).*/\2/p" "$pkg" | head -1)
          [ -n "$width" ] || continue
          param="${prefix}_RAM_ADDR_W"; local rtl_bytes=$(( 1 << width ))
        fi
        local ld_bytes=$(( len ))
        # A region may be deliberately trimmed (size_adjust in the YAML), so only
        # complain when the linker hands software MORE than the hardware has.
        if [ "$ld_bytes" -gt "$rtl_bytes" ]; then
          if waived "$prefix" || waived "$region"; then continue; fi
          report "$region (linker)" "$param" "$width" "$rtl_bytes" "LENGTH" "$ld_bytes" "$pkg" "$ld"
          bad=1
        fi
      done < <(sed -nE 's/^[[:space:]]*([A-Z0-9_]+)[[:space:]]*\([rwx]+\)[[:space:]]*:[[:space:]]*ORIGIN[[:space:]]*=[[:space:]]*[^,]+,[[:space:]]*LENGTH[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\1 \2/p' "$ld")
    done
  fi

  return $bad
}

self_test() {
  local t; t=$(mktemp -d); local rc=0
  cat > "$t/pkg.sv" <<'EOF'
package p;
  localparam int     BOOTROM_ADDR_W               = 11;
  localparam int     IMEM_RAM_ADDR_W              = 14;
endpackage
EOF
  # agreeing pair: 1<<14 = 0x4000, 4<<11 = 0x2000
  printf 'IMEM_0_SIZE  = 0x4000\nBOOTROM_0_SIZE  = 0x2000\n' > "$t/ok.mk"
  # the live mismatch: 64 KB declared over 16 KB of hardware
  printf 'IMEM_0_SIZE  = 0x10000\nBOOTROM_0_SIZE  = 0x2000\n' > "$t/bad.mk"

  MEM_SIZE_CHECK=error scan "$t/pkg.sv" "$t/ok.mk" >/dev/null 2>&1 \
    && echo "PASS  self-test: agreeing sizes accepted" \
    || { echo "FAIL  self-test: agreeing sizes rejected" >&2; rc=1; }

  if MEM_SIZE_CHECK=error scan "$t/pkg.sv" "$t/bad.mk" >"$t/out" 2>&1; then
    echo "FAIL  self-test: IMEM 64 KB over 16 KB of hardware was ACCEPTED" >&2; rc=1
  elif grep -q 'IMEM_RAM_ADDR_W = 14' "$t/out" && grep -q 'IMEM_0_SIZE = 0x10000' "$t/out"; then
    echo "PASS  self-test: mismatch rejected, message names both numbers"
  else
    echo "FAIL  self-test: mismatch rejected but the message does not name both numbers" >&2
    cat "$t/out" >&2; rc=1
  fi
  if MEM_SIZE_CHECK=error MEM_SIZE_WAIVE=IMEM scan "$t/pkg.sv" "$t/bad.mk" >/dev/null 2>&1; then
    echo "PASS  self-test: a named waiver lets that one region through"
  else
    echo "FAIL  self-test: MEM_SIZE_WAIVE=IMEM did not waive IMEM" >&2; rc=1
  fi
  rm -rf "$t"; return $rc
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") echo "usage: $0 <config_pkg.sv> <nanosoc_memmap.mk> [ld_dir] | --self-test" >&2; exit 2 ;;
esac

[ "$(sev)" = "off" ] && exit 0
if scan "$@"; then exit 0; fi
[ "$(sev)" = "error" ] && exit 1
exit 0
