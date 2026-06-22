# nanosoc-multicore SWD smoke — shared TCL library
#
# Sourced by both multicore_smoke.tcl (basic) and multicore_smoke_extended.tcl
# (T1–T6). Holds the helpers and constants both scripts use, so a fix in one
# place propagates to both. Both smoke variants count failures into the
# global `fails` integer; each `shutdown error $fails` at the end of the
# variant returns the count to openocd's exit code.
#
# Run-time wiring: the run_multicore_smoke.sh wrapper streams
#   nanosoc_multicore.cfg + multicore_smoke_lib.tcl + <variant>.tcl
# concatenated over ssh into a single /tmp/<run>.cfg on the dev-host. So
# variants don't `source` the lib explicitly — it just sits inline above
# them. (For local invocations, openocd reads `-f` files in order, so
# the wrapper passes -f cfg -f lib -f variant.)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)

# ============================================================================
# Constants — Cortex-M0 / SoC-400 architectural values
# ============================================================================

# CPUID PartNo nibbles (CPUID[15:4]).
set CORTEX_M0_PARTNO     0xC20
set CORTEX_M0PLUS_PARTNO 0xC60

# Cortex-M0 Private Peripheral Bus (PPB) registers.
set DHCSR_ADDR     0xE000EDF0
set CPUID_ADDR     0xE000ED00

# DHCSR fields.
set DBGKEY         0xA05F0000
set C_DEBUGEN      0x00000001
set C_HALT         0x00000002
set S_HALT         0x00020000

# Multicore eth-ss DMEM base — both APs hit the same physical SRAM here
# through the system bus matrix (PPB-isolated, system-memory federated;
# see sys_desc/nanosoc_multicore_soc.yaml header for the architectural
# truth). Tests use offsets above DMEM[0] for bulk + byte/halfword ranges.
# Overridable so other nanosoc systems (e.g. M0+/M4 compute) can set their own
# DMEM base before sourcing this lib; defaults to the standard 0x18000000.
if {![info exists DMEM_BASE]} { set DMEM_BASE 0x18000000 }

# ============================================================================
# Failure counter — shared by all variants. Each variant's final
# `shutdown error $fails` reports the count via openocd's exit code.
# ============================================================================
set fails 0

# ============================================================================
# Memory access helpers — read 32/16/8-bit words from the currently-targeted
# core. OpenOCD 0.12+ provides `read_memory` returning a Tcl list; the
# helpers wrap that for single-word reads.
# ============================================================================

proc rd32 {addr} { return [lindex [read_memory $addr 32 1] 0] }
proc rd16 {addr} { return [lindex [read_memory $addr 16 1] 0] }
proc rd8  {addr} { return [lindex [read_memory $addr  8 1] 0] }

# ============================================================================
# Result emitters — both increment `fails` on failure.
#
#   smoke_check        compares two integers; emits PASS/FAIL line.
#   smoke_check_partno decodes a CPUID word and asserts ARM Cortex-M0/M0+.
#   smoke_assert       takes an already-evaluated boolean; emits PASS/FAIL.
#                       Callers wrap conditions in [expr {...}] so the
#                       expression evaluates in the caller's variable scope.
# ============================================================================

proc smoke_check {label expected actual} {
    global fails
    if { $expected == $actual } {
        echo "PASS  $label  expected=[format 0x%08X $expected]  actual=[format 0x%08X $actual]"
    } else {
        echo "FAIL  $label  expected=[format 0x%08X $expected]  actual=[format 0x%08X $actual]"
        incr fails
    }
}

proc smoke_check_partno {label cpuid_word} {
    global fails CORTEX_M0_PARTNO CORTEX_M0PLUS_PARTNO
    set partno [expr {($cpuid_word >> 4) & 0xFFF}]
    set impl   [expr {($cpuid_word >> 24) & 0xFF}]
    if { $impl == 0x41 && ($partno == $CORTEX_M0_PARTNO || $partno == $CORTEX_M0PLUS_PARTNO) } {
        echo "PASS  $label  CPUID=[format 0x%08X $cpuid_word]  Impl=ARM PartNo=[format 0x%03X $partno]"
    } else {
        echo "FAIL  $label  CPUID=[format 0x%08X $cpuid_word]  Impl=[format 0x%02X $impl] PartNo=[format 0x%03X $partno] (not ARM Cortex-M0/M0+)"
        incr fails
    }
}

proc smoke_assert {label result detail} {
    global fails
    if { $result } {
        echo "PASS  $label  $detail"
    } else {
        echo "FAIL  $label  $detail"
        incr fails
    }
}

# ============================================================================
# Raw AP register helpers — drive DHCSR via CSW/TAR/DRW directly without
# going through OpenOCD's cortex_m halt/resume helpers. Needed pre-examine
# (with the AHBSLV=0 PPB-mirror gotcha) and during T1/T2 of the extended
# smoke for unambiguous halt/resume control.
#
# AHB-AP register layout (CoreSight ADIv5):
#   reg 0x00 (CSW) — control/status. 0x23000002 = 32-bit, master debug,
#                    device enable, dbgswenable.
#   reg 0x04 (TAR) — transfer address.
#   reg 0x0C (DRW) — data read/write.
# ============================================================================

proc dhcsr_write_via_apreg {ap value} {
    global DHCSR_ADDR
    nanosoc.dap apreg $ap 0x00 0x23000002
    nanosoc.dap apreg $ap 0x04 $DHCSR_ADDR
    nanosoc.dap apreg $ap 0x0C $value
}

proc halt_via_apreg {ap} {
    global DBGKEY C_HALT C_DEBUGEN
    dhcsr_write_via_apreg $ap [expr {$DBGKEY | $C_HALT | $C_DEBUGEN}]
}

proc resume_via_apreg {ap} {
    global DBGKEY C_DEBUGEN
    dhcsr_write_via_apreg $ap [expr {$DBGKEY | $C_DEBUGEN}]
}
