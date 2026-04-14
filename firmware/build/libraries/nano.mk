#-----------------------------------------------------------------------------
# NanoSoC C library variant: newlib-nano (GCC) — Make flow
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Make-side sibling of cmake/libraries/nano.cmake. Matches the historical
# GCC_SPEC_OPTS in toolchain/gcc.mk (--specs=nano.specs -Wl,--gc-sections).
#
# Required variables every library file must set:
#   CLIB_DISPLAY_NAME    Human-readable name
#   CLIB_SUPPORTED       Space-separated list of supported TOOL_CHAIN values
#   CLIB_FLAGS_GCC       Compile flags for gcc
#   CLIB_LINK_GCC        Link flags for gcc (merged into GCC_SPEC_OPTS)
#   CLIB_CC_ARMCLANG     armclang compile flags (added to ARM_CC_OPTIONS)
#   CLIB_ASM_ARMCLANG    armclang/armasm extra flags (ARM_ASM_OPTIONS)
#   CLIB_LINK_ARMCLANG   armlink flags (ARM_LINK_OPTIONS)
#   CLIB_CC_ARMCC        armcc compile flags
#   CLIB_ASM_ARMCC       armasm flags
#   CLIB_LINK_ARMCC      armlink flags
#   CLIB_DEFINES         Preprocessor defines (compile + asm)
#-----------------------------------------------------------------------------

CLIB_DISPLAY_NAME := newlib-nano
CLIB_SUPPORTED    := gcc

CLIB_FLAGS_GCC    :=
CLIB_LINK_GCC     := --specs=nano.specs -Wl,--gc-sections

CLIB_CC_ARMCLANG  :=
CLIB_ASM_ARMCLANG :=
CLIB_LINK_ARMCLANG :=
CLIB_CC_ARMCC     :=
CLIB_ASM_ARMCC    :=
CLIB_LINK_ARMCC   :=

CLIB_DEFINES      :=
