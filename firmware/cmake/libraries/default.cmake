#-----------------------------------------------------------------------------
# NanoSoC C library variant: toolchain default (AC6 / AC5)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# "default" = let each toolchain pick its built-in C library with no overrides.
# For armclang/armcc this is standardlib (not microlib). For GCC this is
# effectively the same as having no --specs flag — full newlib.
#
# Matches the historical behaviour when COMPILE_MICROLIB=0 in testcode.mk.
#-----------------------------------------------------------------------------

set(NanoSoC_CLIB_DISPLAY_NAME "toolchain default")
set(NanoSoC_CLIB_SUPPORTED    "gcc" "armclang" "armcc")

set(NanoSoC_CLIB_FLAGS_GCC      "")
set(NanoSoC_CLIB_ASM_GCC        "")
set(NanoSoC_CLIB_LINK_GCC       "-Wl,--gc-sections")

set(NanoSoC_CLIB_FLAGS_ARMCLANG "")
set(NanoSoC_CLIB_ASM_ARMCLANG   "")
set(NanoSoC_CLIB_LINK_ARMCLANG  "")
set(NanoSoC_CLIB_FLAGS_ARMCC    "")
set(NanoSoC_CLIB_ASM_ARMCC      "")
set(NanoSoC_CLIB_LINK_ARMCC     "")

set(NanoSoC_CLIB_DEFINES        "")
