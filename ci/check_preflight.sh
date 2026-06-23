#!/bin/bash
# check_preflight.sh - Validate presence of EDA tool binaries needed by CI.
#
# Exit 0 if all binaries resolve; exit 1 otherwise.
# Honours VCS_HOME, VERDI_HOME, SPYGLASS_HOME, XCELIUM_HOME, RTLA_HOME,
# VIVADO_HOME, ARM_GCC_HOME so CI can set paths via .gitlab-ci.yml.
#
# Copyright 2026, SoC Labs (www.soclabs.org)

set -u

pass=0
fail=0
missing=()

echo "========================================"
echo " nanosoc Preflight Tool Check"
echo "========================================"

# Augment PATH with well-known EDA installs if env vars are set
if [ -n "${VCS_HOME:-}"     ]; then export PATH="$VCS_HOME/bin:$PATH"; fi
if [ -n "${VERDI_HOME:-}"   ]; then export PATH="$VERDI_HOME/bin:$PATH"; fi
if [ -n "${SPYGLASS_HOME:-}"]; then export PATH="$SPYGLASS_HOME/bin:$PATH"; fi
if [ -n "${XCELIUM_HOME:-}" ]; then export PATH="$XCELIUM_HOME/tools/bin:$PATH"; fi
if [ -n "${RTLA_HOME:-}"    ]; then export PATH="$RTLA_HOME/bin:$PATH"; fi
if [ -n "${VIVADO_HOME:-}"  ]; then export PATH="$VIVADO_HOME/bin:$PATH"; fi
if [ -n "${ARM_GCC_HOME:-}" ]; then export PATH="$ARM_GCC_HOME/bin:$PATH"; fi

check_bin() {
    local name="$1"
    local bin="$2"
    local optional="${3:-no}"
    if command -v "$bin" >/dev/null 2>&1; then
        printf "  OK    %-24s (%s)\n" "$name" "$(command -v "$bin")"
        pass=$((pass + 1))
    else
        if [ "$optional" = "optional" ]; then
            printf "  WARN  %-24s (%s not found, optional)\n" "$name" "$bin"
        else
            printf "  FAIL  %-24s (%s not found on PATH)\n" "$name" "$bin"
            fail=$((fail + 1))
            missing+=("$bin")
        fi
    fi
}

echo ""
echo "-- Simulation / Verification ------------"
check_bin "Synopsys VCS"       "vcs"
check_bin "Synopsys Verdi"     "verdi"           optional

echo ""
echo "-- ASIC Synthesis -----------------------"
check_bin "Design Compiler"    "dc_shell"
check_bin "RTL Architect"      "rtl_shell"
check_bin "SpyGlass (CDC)"     "spyglass"
check_bin "SpyGlass sg_shell"  "sg_shell"        optional

echo ""
echo "-- FPGA ---------------------------------"
check_bin "Xilinx Vivado"      "vivado"

echo ""
echo "-- Firmware / Build ---------------------"
check_bin "CMake"              "cmake"
check_bin "ARM GCC"            "arm-none-eabi-gcc"

echo ""
echo "-- Supporting tooling -------------------"
check_bin "Python 3"           "python3"          optional
check_bin "cocotb-config"      "cocotb-config"    optional

echo ""
echo "========================================"
echo " Preflight Summary  PASS=$pass  FAIL=$fail"
echo "========================================"

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "ERROR: $fail required tool(s) not found on PATH:"
    for m in "${missing[@]}"; do
        echo "  - $m"
    done
    echo ""
    echo "Fix the tool-path variables in .gitlab-ci.yml or install the missing tools on the runner."
    exit 1
fi

echo "All required tools resolved successfully."
exit 0
