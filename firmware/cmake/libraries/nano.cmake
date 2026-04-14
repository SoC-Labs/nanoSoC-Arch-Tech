#-----------------------------------------------------------------------------
# NanoSoC C library variant: newlib-nano (GCC)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Copyright (C) 2021-6, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
#
# Single source of truth for the newlib-nano C library configuration. Matches
# the historical default GCC flags in firmware/build/toolchain/gcc.mk
# (--specs=nano.specs -Wl,--gc-sections).
#
# Required variables every library file must set:
#   NanoSoC_CLIB_DISPLAY_NAME    Human-readable name
#   NanoSoC_CLIB_SUPPORTED       List of toolchain IDs this variant supports
#                                (gcc, armclang, armcc). Others will error.
#   NanoSoC_CLIB_FLAGS_GCC       Compile flags for arm-none-eabi-gcc
#   NanoSoC_CLIB_LINK_GCC        Link flags for arm-none-eabi-gcc
#   NanoSoC_CLIB_FLAGS_ARMCLANG  Compile flags for armclang
#   NanoSoC_CLIB_LINK_ARMCLANG   Link flags for armlink (via armclang)
#   NanoSoC_CLIB_FLAGS_ARMCC     Compile flags for armcc
#   NanoSoC_CLIB_LINK_ARMCC      Link flags for armlink (via armcc)
#   NanoSoC_CLIB_DEFINES         Preprocessor defines (both compile and asm)
#-----------------------------------------------------------------------------

set(NanoSoC_CLIB_DISPLAY_NAME "newlib-nano")
set(NanoSoC_CLIB_SUPPORTED    "gcc")

set(NanoSoC_CLIB_FLAGS_GCC      "")
set(NanoSoC_CLIB_ASM_GCC        "")
set(NanoSoC_CLIB_LINK_GCC       "--specs=nano.specs" "-Wl,--gc-sections")

# Not supported on AC6/AC5 — they use their own libc defaults. Selecting
# nano with those toolchains is a configuration error (caught at configure time).
set(NanoSoC_CLIB_FLAGS_ARMCLANG "")
set(NanoSoC_CLIB_ASM_ARMCLANG   "")
set(NanoSoC_CLIB_LINK_ARMCLANG  "")
set(NanoSoC_CLIB_FLAGS_ARMCC    "")
set(NanoSoC_CLIB_ASM_ARMCC      "")
set(NanoSoC_CLIB_LINK_ARMCC     "")

set(NanoSoC_CLIB_DEFINES        "")
