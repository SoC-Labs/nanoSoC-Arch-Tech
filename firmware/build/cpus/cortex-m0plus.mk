#-----------------------------------------------------------------------------
# NanoSoC CPU description: ARM Cortex-M0+ (Make flow)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# CMSDK_CM0plus device tree vendored under software/cmsis/Device/ARM/CMSDK_CM0plus
# (sourced from Arm BP200-r1p1 Corstone-101 release).
#-----------------------------------------------------------------------------

CPU_DISPLAY_NAME    := Cortex-M0+
CPU_DEFINE          := CORTEX_M0PLUS
CPU_DEVICE_DIR_NAME := CMSDK_CM0plus
CPU_STARTUP_STEM    := startup_CMSDK_CM0plus
CPU_SYSTEM_STEM     := system_CMSDK_CM0plus
CPU_ARCH            := armv6-m

CPU_HAS_FPU         := 0
CPU_HAS_DSP         := 0
CPU_HAS_MVE         := 0
CPU_HAS_TRUSTZONE   := 0

CPU_FLAGS_GCC       := -mcpu=cortex-m0plus -mthumb
CPU_FLAGS_ARMCLANG  := -mcpu=Cortex-M0plus
CPU_FLAGS_ARMCC     := --cpu Cortex-M0plus
