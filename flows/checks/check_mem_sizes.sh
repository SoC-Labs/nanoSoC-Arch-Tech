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
# A check that compared nothing is not a pass. A missing input, a width it
# cannot evaluate, or zero regions compared (all unmatched or all waived) is a
# finding with the same severity as a mismatch.
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

# A finding that is not a mismatch but means "this check did not do its job":
# an input missing, a width it could not evaluate, nothing compared at all. It
# carries the same severity as a mismatch, so MEM_SIZE_CHECK=error can never
# return 0 having checked nothing.
unchecked() { echo "$(sev | tr a-z A-Z): mem-size: $1" >&2; shift; for l in "$@"; do echo "    $l" >&2; done; }

# Every `localparam|parameter [type] [range] NAME = RHS` whose NAME is a memory
# width, as "NAME VALUE", or "NAME ? RHS" when RHS is not a constant integer
# expression. Any type (int, integer, int unsigned, logic [31:0], none) is
# accepted; RHS may be arithmetic over integer literals, e.g. 12+2 or (1<<4)-2.
pkg_widths() {
  grep -oE '(localparam|parameter)[^;=]*[[:space:]]([A-Z0-9_]+_RAM_ADDR_W|BOOTROM_ADDR_W)[[:space:]]*=[^;,)]*' "$1" |
  while IFS= read -r line; do
    local name rhs
    name=$(echo "$line" | sed -E 's/^.*[[:space:]]([A-Z0-9_]+)[[:space:]]*=.*/\1/')
    rhs=$(echo "$line" | sed -E 's/^[^=]*=[[:space:]]*//; s#//.*##; s/[[:space:]]+$//')
    if [[ "$rhs" =~ ^[0-9[:space:]+*/()\<\>-]+$ ]] && v=$(( rhs )) 2>/dev/null; then
      echo "$name $v"
    else
      echo "$name ? $rhs"
    fi
  done
}

# Byte value of NAME in a make-syntax memory map; =, := and ?= all count.
mm_value() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*(::?|\?)?=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\2/p" "$2" | head -1
}

scan() {
  local pkg="$1" mm="$2" lddir="${3:-}"
  local bad=0 checked=0

  if [ ! -f "$pkg" ] || [ ! -f "$mm" ]; then
    [ -f "$pkg" ] || unchecked "no SoC config package at $pkg: no memory size was checked"
    [ -f "$mm" ]  || unchecked "no memory map at $mm: no memory size was checked"
    return 1
  fi

  local widths; widths=$(pkg_widths "$pkg")
  local w_name w_val w_rhs
  while read -r w_name w_val w_rhs; do
    [ -n "$w_name" ] || continue
    if [ "$w_val" = "?" ]; then
      unchecked "cannot evaluate $w_name = $w_rhs in $pkg; that memory was NOT checked"
      bad=1
    fi
  done <<< "$widths"

  # ---- memory map: <PREFIX>_RAM_ADDR_W (bytes = 1 << N) and BOOTROM_ADDR_W (4 << N) ----
  while read -r w_name w_val w_rhs; do
    [ -n "$w_name" ] && [ "$w_val" != "?" ] || continue
    local prefix rtl_bytes cands
    if [ "$w_name" = BOOTROM_ADDR_W ]; then
      prefix=BOOTROM; rtl_bytes=$(( 4 << w_val )); cands="BOOTROM_0_SIZE BOOTROM_SIZE"
    else
      prefix="${w_name%_RAM_ADDR_W}"; rtl_bytes=$(( 1 << w_val )); cands="${prefix}_SIZE ${prefix}_0_SIZE"
    fi
    local sw_name="" sw_val="" cand
    for cand in $cands; do
      sw_val=$(mm_value "$cand" "$mm")
      if [ -n "$sw_val" ]; then sw_name="$cand"; break; fi
    done
    [ -n "$sw_name" ] || continue
    local sw_bytes=$(( sw_val ))
    [ "$sw_bytes" -gt 0 ] || continue
    if waived "$prefix"; then
      [ "$sw_bytes" != "$rtl_bytes" ] && \
        echo "note: mem-size: $prefix mismatch waived by MEM_SIZE_WAIVE ($(hex "$rtl_bytes") of hardware, $(hex "$sw_bytes") declared)" >&2
      continue
    fi
    checked=$((checked+1))
    if [ "$sw_bytes" != "$rtl_bytes" ]; then
      report "$prefix" "$w_name" "$w_val" "$rtl_bytes" "$sw_name" "$sw_bytes" "$pkg" "$mm"
      bad=1
    fi
  done <<< "$widths"

  # ---- linker MEMORY blocks next to the memory map ----
  if [ -n "$lddir" ] && [ -d "$lddir" ]; then
    local ld
    for ld in "$lddir"/*.ld; do
      [ -e "$ld" ] || continue
      # The debug tester is the ADP host model, not SoC firmware: its MEMORY
      # block is a deliberately oversized window onto the SoC (phys_size in the
      # system YAML), so it is not a claim about how much RAM exists.
      case "$(basename "$ld")" in *debugtester*) continue ;; esac
      local region len
      while read -r region len; do
        local prefix="${region%_0}" param width rtl_bytes
        if [ "$region" = "BOOTROM_0" ]; then
          param=BOOTROM_ADDR_W
        else
          param="${prefix}_RAM_ADDR_W"
        fi
        width=$(awk -v n="$param" '$1==n && $2!="?" {print $2; exit}' <<< "$widths")
        [ -n "$width" ] || continue
        if [ "$param" = BOOTROM_ADDR_W ]; then rtl_bytes=$(( 4 << width )); else rtl_bytes=$(( 1 << width )); fi
        local ld_bytes=$(( len ))
        if waived "$prefix" || waived "$region"; then continue; fi
        checked=$((checked+1))
        # A region may be deliberately trimmed (size_adjust in the YAML), so only
        # complain when the linker hands software MORE than the hardware has.
        if [ "$ld_bytes" -gt "$rtl_bytes" ]; then
          report "$region (linker)" "$param" "$width" "$rtl_bytes" "LENGTH" "$ld_bytes" "$pkg" "$ld"
          bad=1
        fi
      done < <(sed -nE 's/^[[:space:]]*([A-Z0-9_]+)[[:space:]]*\([rwx]+\)[[:space:]]*:[[:space:]]*ORIGIN[[:space:]]*=[[:space:]]*[^,]+,[[:space:]]*LENGTH[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+).*/\1 \2/p' "$ld")
    done
  fi

  if [ "$checked" -eq 0 ]; then
    unchecked "compared ZERO memory sizes -- every region was unparsable, unmatched or waived." \
              "config package: $pkg" "memory map:     $mm" "MEM_SIZE_WAIVE: '${MEM_SIZE_WAIVE:-}'"
    bad=1
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

  # Each of these used to return 0 in error mode having checked nothing, or
  # having missed the defect. Each must now fail.
  # Asserts the REASON, not just the exit code: a specimen that fails for a
  # different rule than the one under test proves nothing about that rule.
  must_fail() { local label="$1" why="$2"; shift 2
    if "$@" >"$t/o" 2>&1; then echo "FAIL  self-test: $label -- ACCEPTED" >&2; cat "$t/o" >&2; rc=1
    elif ! grep -q -- "$why" "$t/o"; then echo "FAIL  self-test: $label -- rejected, but not for '$why'" >&2; cat "$t/o" >&2; rc=1
    else echo "PASS  self-test: $label -- rejected ($why)"; fi; }
  sed 's/localparam int /localparam integer /' "$t/pkg.sv" > "$t/pkg_integer.sv"
  sed 's/= 14;/= 12+2;/' "$t/pkg.sv" > "$t/pkg_expr.sv"
  sed 's/= 14;/= IMEM_W;/' "$t/pkg.sv" > "$t/pkg_ident.sv"
  sed 's/IMEM_0_SIZE  = /IMEM_0_SIZE := /' "$t/bad.mk" > "$t/bad_colon.mk"
  must_fail "every region waived"               "compared ZERO" env MEM_SIZE_CHECK=error MEM_SIZE_WAIVE="IMEM BOOTROM" "$0" "$t/pkg.sv" "$t/ok.mk"
  must_fail "config package path wrong"         "no SoC config package" env MEM_SIZE_CHECK=error "$0" "$t/nope.sv" "$t/ok.mk"
  must_fail "memory map path wrong"             "no memory map" env MEM_SIZE_CHECK=error "$0" "$t/pkg.sv" "$t/nope.mk"
  must_fail "'localparam integer' + mismatch"   "IMEM is declared twice" env MEM_SIZE_CHECK=error "$0" "$t/pkg_integer.sv" "$t/bad.mk"
  must_fail "memmap ':=' + mismatch"            "IMEM is declared twice" env MEM_SIZE_CHECK=error "$0" "$t/pkg.sv" "$t/bad_colon.mk"
  must_fail "width '12+2' (=14) + mismatch"     "IMEM_RAM_ADDR_W = 14" env MEM_SIZE_CHECK=error "$0" "$t/pkg_expr.sv" "$t/bad.mk"
  must_fail "width not a constant expression"   "cannot evaluate IMEM_RAM_ADDR_W" env MEM_SIZE_CHECK=error "$0" "$t/pkg_ident.sv" "$t/ok.mk"
  if MEM_SIZE_CHECK=error "$0" "$t/pkg_expr.sv" "$t/ok.mk" >/dev/null 2>&1; then
    echo "PASS  self-test: width '12+2' evaluated, agreeing sizes accepted"
  else echo "FAIL  self-test: width '12+2' with agreeing sizes rejected" >&2; rc=1; fi
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
