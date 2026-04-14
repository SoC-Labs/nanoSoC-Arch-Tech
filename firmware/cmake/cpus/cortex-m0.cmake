#-----------------------------------------------------------------------------
# NanoSoC CPU description: ARM Cortex-M0
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Single source of truth for everything Cortex-M0-specific. Adding a new CPU
# variant means dropping a sibling file with the same variable schema.
#
# Required variables every CPU file must set:
#   NanoSoC_CPU_DISPLAY_NAME    Human-readable name (e.g. "Cortex-M0")
#   NanoSoC_CPU_DEFINE          C macro define (e.g. CORTEX_M0). Source uses #ifdef <define>.
#   NanoSoC_CPU_DEVICE_DIR_NAME CMSIS device dir under software/cmsis/Device/ARM/
#   NanoSoC_CPU_STARTUP_STEM    Filename of startup .s (without .s suffix)
#   NanoSoC_CPU_SYSTEM_STEM     Filename of system .c (without .c suffix)
#   NanoSoC_CPU_ARCH            Architecture name (armv6-m, armv7-m, armv8-m, ...)
#   NanoSoC_CPU_FLAGS_GCC       Compile flags for arm-none-eabi-gcc
#   NanoSoC_CPU_FLAGS_ARMCLANG  Compile flags for armclang (DS-6 / AC6)
#   NanoSoC_CPU_FLAGS_ARMCC     Compile flags for armcc (DS-5 / AC5, legacy)
#-----------------------------------------------------------------------------

set(NanoSoC_CPU_DISPLAY_NAME    "Cortex-M0")
set(NanoSoC_CPU_DEFINE          "CORTEX_M0")
set(NanoSoC_CPU_DEVICE_DIR_NAME "CMSDK_CM0")
set(NanoSoC_CPU_STARTUP_STEM    "startup_CMSDK_CM0")
set(NanoSoC_CPU_SYSTEM_STEM     "system_CMSDK_CM0")
set(NanoSoC_CPU_ARCH            "armv6-m")

# Capability flags (informational; tests / libraries may key off these).
set(NanoSoC_CPU_HAS_FPU         FALSE)
set(NanoSoC_CPU_HAS_DSP         FALSE)
set(NanoSoC_CPU_HAS_MVE         FALSE)
set(NanoSoC_CPU_HAS_TRUSTZONE   FALSE)

# Toolchain CPU flags. Each CMSDK toolchain spells the CPU differently:
#   GCC:      lowercase  (-mcpu=cortex-m0)
#   armclang: capitalised (-mcpu=Cortex-M0)
#   armcc:    space-separated (--cpu Cortex-M0)
set(NanoSoC_CPU_FLAGS_GCC       "-mcpu=cortex-m0" "-mthumb")
set(NanoSoC_CPU_FLAGS_ARMCLANG  "-mcpu=Cortex-M0")
set(NanoSoC_CPU_FLAGS_ARMCC     "--cpu" "Cortex-M0")
