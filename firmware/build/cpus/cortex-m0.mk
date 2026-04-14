#-----------------------------------------------------------------------------
# NanoSoC CPU description: ARM Cortex-M0 (Make flow)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Make-side sibling of cmake/cpus/cortex-m0.cmake. Single source of truth for
# everything Cortex-M0-specific in the Make flow. Adding a new CPU variant
# means dropping a new file here with the same variable schema AND a matching
# file in cmake/cpus/.
#
# Required variables:
#   CPU_DISPLAY_NAME    Human-readable name
#   CPU_DEFINE          C macro the source uses (#ifdef). Feeds USER_DEFINE = -D$(CPU_DEFINE).
#   CPU_DEVICE_DIR_NAME CMSIS device dir under software/cmsis/Device/ARM/
#   CPU_STARTUP_STEM    Filename of startup .s (without extension)
#   CPU_SYSTEM_STEM     Filename of system .c (without extension)
#   CPU_ARCH            Architecture name (armv6-m, armv7-m, armv8-m, ...)
#   CPU_FLAGS_GCC       Compile flags for arm-none-eabi-gcc
#   CPU_FLAGS_ARMCLANG  Compile flags for armclang (DS-6 / AC6)
#   CPU_FLAGS_ARMCC     Compile flags for armcc (DS-5 / AC5, legacy)
#-----------------------------------------------------------------------------

CPU_DISPLAY_NAME    := Cortex-M0
CPU_DEFINE          := CORTEX_M0
CPU_DEVICE_DIR_NAME := CMSDK_CM0
CPU_STARTUP_STEM    := startup_CMSDK_CM0
CPU_SYSTEM_STEM     := system_CMSDK_CM0
CPU_ARCH            := armv6-m

# Capability flags (informational; makefiles may key off these).
CPU_HAS_FPU         := 0
CPU_HAS_DSP         := 0
CPU_HAS_MVE         := 0
CPU_HAS_TRUSTZONE   := 0

# Toolchain CPU flags — each CMSDK toolchain spells the CPU differently.
# GCC needs -mthumb explicitly; armclang/armcc default to Thumb for M-profile.
CPU_FLAGS_GCC       := -mcpu=cortex-m0 -mthumb
CPU_FLAGS_ARMCLANG  := -mcpu=Cortex-M0
CPU_FLAGS_ARMCC     := --cpu Cortex-M0
