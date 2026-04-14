#-----------------------------------------------------------------------------
# NanoSoC C library variant: toolchain default (AC6 / AC5) — Make flow
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# "default" = each toolchain's built-in libc with no overrides.
# Matches historical behaviour when COMPILE_MICROLIB=0 in testcode.mk.
#-----------------------------------------------------------------------------

CLIB_DISPLAY_NAME := toolchain default
CLIB_SUPPORTED    := gcc ds6 ds5

CLIB_FLAGS_GCC    :=
CLIB_LINK_GCC     := -Wl,--gc-sections

CLIB_CC_ARMCLANG  :=
CLIB_ASM_ARMCLANG :=
CLIB_LINK_ARMCLANG :=
CLIB_CC_ARMCC     :=
CLIB_ASM_ARMCC    :=
CLIB_LINK_ARMCC   :=

CLIB_DEFINES      :=
