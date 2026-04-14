#-----------------------------------------------------------------------------
# NanoSoC C library variant: ARM microlib (AC6 / AC5)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# microlib is ARM's minimal embedded C library (no locale, minimal stdio, no
# file I/O). Useful for very small footprint builds. AC6/AC5 only.
#
# Matches the historical behaviour when COMPILE_MICROLIB=1 in testcode.mk.
#
# The __MICROLIB define is also emitted — used by CMSIS startup code
# (startup_CMSDK_CM0.s:233 `IF :DEF:__MICROLIB`) to switch between the
# microlib and stdlib entry-point conventions.
#-----------------------------------------------------------------------------

set(NanoSoC_CLIB_DISPLAY_NAME "ARM microlib")
set(NanoSoC_CLIB_SUPPORTED    "armclang" "armcc")

set(NanoSoC_CLIB_FLAGS_GCC      "")
set(NanoSoC_CLIB_LINK_GCC       "")

# --library_type=microlib is an armlink-only option; armclang rejects it on
# the compile step. Only add it to link flags for AC6.
#
# For AC6 the armasm `--pd` predefine must be passed through `-Wa,` because
# armclang -masm=armasm intercepts flags by default. Required so that
# startup_CMSDK_CM0.s `IF :DEF:__MICROLIB` selects the microlib entry
# convention (otherwise link fails on __use_two_region_memory etc.).
set(NanoSoC_CLIB_FLAGS_ARMCLANG "")
set(NanoSoC_CLIB_ASM_ARMCLANG   "SHELL:-Wa,\"--pd=__MICROLIB SETA 1\"")
set(NanoSoC_CLIB_LINK_ARMCLANG  "--library_type=microlib")
# AC5 armcc does accept --library_type on the compile line.
set(NanoSoC_CLIB_FLAGS_ARMCC    "--library_type=microlib")
set(NanoSoC_CLIB_ASM_ARMCC      "SHELL:--pd \"__MICROLIB SETA 1\"")
set(NanoSoC_CLIB_LINK_ARMCC     "--library_type=microlib")

set(NanoSoC_CLIB_DEFINES        "__MICROLIB")
