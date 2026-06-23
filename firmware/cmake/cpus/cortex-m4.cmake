#-----------------------------------------------------------------------------
# NanoSoC CPU description: ARM Cortex-M4 (compute core)
# Copyright 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Mirrors nanosoc_arch_tech/firmware/cmake/cpus/cortex-m0plus.cmake for the M4
# compute core. FPU on (FPU_PRESENT=1 -> single-precision M4F, hard-float ABI),
# DSP on; trace/ETM excluded at the RTL level (TRACE_LVL=1).
#-----------------------------------------------------------------------------

set(NanoSoC_CPU_DISPLAY_NAME    "Cortex-M4")
set(NanoSoC_CPU_DEFINE          "CORTEX_M4")
set(NanoSoC_CPU_DEVICE_DIR_NAME "CMSDK_CM4")
set(NanoSoC_CPU_STARTUP_STEM    "startup_CMSDK_CM4")
set(NanoSoC_CPU_SYSTEM_STEM     "system_CMSDK_CM4")
set(NanoSoC_CPU_ARCH            "armv7e-m")

set(NanoSoC_CPU_HAS_FPU         TRUE)
set(NanoSoC_CPU_HAS_DSP         TRUE)
set(NanoSoC_CPU_HAS_MVE         FALSE)
set(NanoSoC_CPU_HAS_TRUSTZONE   FALSE)

# Hard-float ABI (single-precision M4F). Boot stages emit no FP, but keeping one
# ABI across stages + Zephyr avoids soft/hard mixing at link time.
set(NanoSoC_CPU_FLAGS_GCC       "-mcpu=cortex-m4" "-mthumb" "-mfpu=fpv4-sp-d16" "-mfloat-abi=hard")
set(NanoSoC_CPU_FLAGS_ARMCLANG  "-mcpu=Cortex-M4" "-mfpu=fpv4-sp-d16" "-mfloat-abi=hard")
set(NanoSoC_CPU_FLAGS_ARMCC     "--cpu" "Cortex-M4.fp.sp")
