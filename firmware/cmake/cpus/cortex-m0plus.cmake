#-----------------------------------------------------------------------------
# NanoSoC CPU description: ARM Cortex-M0+
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# NOTE: As of 2026-04, the CMSIS device files for CMSDK_CM0plus are not yet
# vendored under software/cmsis/Device/ARM/. Selecting this CPU will produce
# a configure-time error pointing the user at this file. To enable, drop the
# CMSDK_CM0plus device tree (Include/, Source/{ARM,GCC}/) into that path.
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
