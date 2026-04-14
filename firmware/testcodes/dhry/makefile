#-----------------------------------------------------------------------------
# NanoSoC Test: dhry
# Dhrystone benchmark
#-----------------------------------------------------------------------------
TESTNAME           := dhry
SOURCE_DIR          = $(SOFTWARE_DIR)/common/dhry
MAIN_SOURCE         = $(SOURCE_DIR)/dhry_1.c
SOURCE_FILES       += $(SOURCE_DIR)/dhry_2.c
EXTRA_INCLUDES     += -I $(SOFTWARE_DIR)/common/dhry -DITERATIONS=200
# AC5 has -Ono_inline / --no_inline / --no_multifile / -Oloopref. AC6
# armclang is clang-based, so gcc-style -fno-inline is the nearest equivalent
# (the armcc-specific ones have no AC6 counterpart and simply get dropped).
CC_EXTRA_FLAGS_ARMCC    := -Ono_inline --no_inline --no_multifile -Oloopref
CC_EXTRA_FLAGS_ARMCLANG := -fno-inline
GNU_CC_EXTRA_FLAGS      := -fno-inline -fno-common

include $(SOCLABS_NANOSOC_ARCH_TECH_DIR)/firmware/build/testcode.mk
