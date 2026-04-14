#-----------------------------------------------------------------------------
# NanoSoC C library variant: ARM microlib (AC6 / AC5) — Make flow
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Matches historical behaviour when COMPILE_MICROLIB=1 in testcode.mk.
# Startup asm references `IF :DEF:__MICROLIB` (see startup_CMSDK_CM0.s:233)
# so the armasm --pd flag is needed to set it symbolically, not via -D.
#-----------------------------------------------------------------------------

CLIB_DISPLAY_NAME := ARM microlib
CLIB_SUPPORTED    := ds5 ds6

CLIB_FLAGS_GCC    :=
CLIB_LINK_GCC     :=

# --library_type=microlib is an armlink-only option. armclang rejects it on
# the compile step with "unsupported option". Pre-refactor Make added it to
# ARM_CC_OPTIONS too, which was broken (just never exercised). Fixed here.
#
# For AC6 (armclang -masm=armasm) the armasm `--pd` predefine must be passed
# through via -Wa, otherwise armclang intercepts it. Startup_CMSDK_CM0.s uses
# `IF :DEF:__MICROLIB` to switch entry conventions, so this predefine is
# required at assembly time for microlib to link successfully.
CLIB_CC_ARMCLANG   :=
CLIB_ASM_ARMCLANG  := -Wa,"--pd=__MICROLIB SETA 1"
CLIB_LINK_ARMCLANG := --library_type=microlib
CLIB_CC_ARMCC      := --library_type=microlib
CLIB_ASM_ARMCC     := --library_type=microlib --pd "__MICROLIB SETA 1"
CLIB_LINK_ARMCC    := --library_type=microlib

CLIB_DEFINES       :=
