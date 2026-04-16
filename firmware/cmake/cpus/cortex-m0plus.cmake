#-----------------------------------------------------------------------------
# NanoSoC CPU description: ARM Cortex-M0+
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# CMSDK_CM0plus device tree vendored under software/cmsis/Device/ARM/CMSDK_CM0plus
# (sourced from Arm BP200-r1p1 Corstone-101 release).
#-----------------------------------------------------------------------------

set(NanoSoC_CPU_DISPLAY_NAME    "Cortex-M0+")
set(NanoSoC_CPU_DEFINE          "CORTEX_M0PLUS")
set(NanoSoC_CPU_DEVICE_DIR_NAME "CMSDK_CM0plus")
set(NanoSoC_CPU_STARTUP_STEM    "startup_CMSDK_CM0plus")
set(NanoSoC_CPU_SYSTEM_STEM     "system_CMSDK_CM0plus")
set(NanoSoC_CPU_ARCH            "armv6-m")

set(NanoSoC_CPU_HAS_FPU         FALSE)
set(NanoSoC_CPU_HAS_DSP         FALSE)
set(NanoSoC_CPU_HAS_MVE         FALSE)
set(NanoSoC_CPU_HAS_TRUSTZONE   FALSE)

set(NanoSoC_CPU_FLAGS_GCC       "-mcpu=cortex-m0plus" "-mthumb")
set(NanoSoC_CPU_FLAGS_ARMCLANG  "-mcpu=Cortex-M0plus")
set(NanoSoC_CPU_FLAGS_ARMCC     "--cpu" "Cortex-M0plus")
